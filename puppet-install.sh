#!/bin/bash
#
# puppet-install.sh
#
# This script installs and configures Puppet Enterprise on a monolithic
# Master of Masters, Compile Masters, and standard clients. The type of
# installation performed depends on the value of the "role" parameter.
#
# A "post-install" argument ("-p") triggers role-based configuration of
# the node on the Master; cert signing at a minimum, or in the case of
# Compile Masters also pinning the node to the "PE Masters" classification
# group and configuring the relevant Puppet groups for load-balanced
# Compile Masters.  It is a argument only of use when the script is
# running on MoM, so is essentially an internal argument.
#
# Error checking is minimal as, provided all the required components
# have downloaded correctly there shouldn't be any errors while
# installing.
#
# By default this script installs PE 2018.1.2.  This can be changed
# via use of the "-V" argument.
#
PATH=/bin:/usr/bin:/sbin:/usr/sbin:/opt/puppetlabs/bin

progname_path=$(readlink -f $0)
progname_dir=${progname_path%/*}
progname=${progname_path##*/}

# $progname_path will not be set correctly if this script was run on an OS
# other than Linux due to lack of GNU readlink.  This is mostly to remind
# myself not to try and run this script in macOS.

[ -z "$progname_path" ] && exit 1

usage() {
    echo "Usage: $progname [-d] [-v] [-V PE_version] [-p] role"
}


# Puppet installation is already verbose, so this is more of a "what am I
# attempting now" level of verbosity for this script.  Coloured blue to help
# it stand out.

verb_message() {
    echo -e "\n\033[1;34m=== $1\033[0m"
}


# "ERROR" will be displayed in red to help it stand out.  Unfortunately
# vagrant seems to be colouring stderr output as red now, so that's why I'm
# only colourising the first word.

error_message() {
    echo -e "\033[1;31mERROR:\033[0m $1" >&2
    error_flag=1
}


# Some sanity checks.  There must be at least one argument ("role"), and we
# should be able to tell which host is the MoM and which is the load-balancer
# VIP from the /etc/hosts file.  This is just in case someone decides they
# don't like the names and decide to change them in their own installation.

if [ "$#" -lt 1 ];then
    usage >&2
    exit 1
fi

error_flag=
puppetmom=$(awk '/ptmom/ {print $2}' /etc/hosts)
pt_master=$(awk '/pt-master/ {print $2}' /etc/hosts)

[ -z "$puppetmom" ] && error_message "Entry for ptmom not present in /etc/hosts."
[ -z "$pt_master" ] && error_message "Entry for pt-master not present in /etc/hosts."
[ -z "$error_flag" ] || exit 1


# Compile Masters install their Agent from the MoM, standard clients do it via
# the VIP.

pe_cm_agent_installer="https://${puppetmom}:8140/packages/current/install.bash"
pe_agent_installer="https://${pt_master}:8140/packages/current/install.bash"


# Triggers if the download of the installer gets interrupted or was not
# successful.  Won't be called if the download is successful as we keep the
# installer.

cleanup_installer() {
    rm $pe_installer
    rmdir $pe_installer_dir 2>/dev/null
}


# Removes the extracted installer directory if present and removes the installer
# if required.

cleanup() {
    [ "$verbose" ] && verb_message "Cleaning up"
    [ -d "$tempdir" ] && rm -r $tempdir
    if [ ! -z "$downloading" ]; then
        [ "$verbose" ] && verb_message "Download of installer interrupted, removing file"
        cleanup_installer
        exit 130
    fi
}


# Checks if the installer is present, and if not downloads it into the
# "./installer" directory. If the download was interrupted or isn't the expected
# file type (eg we got a "404" HTML page instead of a gzipped file) we remove the
# file.

check_for_installer() {
    if [ ! -f "$pe_installer" ]; then
        [ -d "$pe_installer_dir" ] || mkdir -p $pe_installer_dir
        [ "$verbose"] && verb_message "Downloading $pe_installer_file"
        downloading=1
        curl -L --progress-bar $pe_installer_url -o $pe_installer
        echo
        downloading=
        if [ -e "$pe_installer" ]; then
            file $pe_installer | grep -q gzip
            if [ "$?" -ne 0 ]; then
                error_message "$pe_installer_file is not the expected file type."
                error_message "Removing file and exiting."
                cleanup_installer
                exit 1
            fi
        else
            error_message "Installer file $pe_installer_file was not downloaded."
            exit 1
        fi
    else
        [ "$verbose" ] && verb_message "Installer file $pe_installer_file is present"
    fi
}


# The puppet-ca API can only be accessed from the server running the CA itself
# (ie MoM), at least initially.  It's also uses certificates for
# authentication, so RBAC tokens won't work.  Given that, we need a way to
# run commands on the Master after installing Puppet on something else.
# Hence this insane function.

run_ssh_command() {
    # $1 - host to SSH to
    # $2 - command to run on that host
    #
    # This took me too long to figure out, so for the benefit of my future self
    # here's what it does.
    #
    # We need to SSH into a host as the vagrant user using the standard vagrant
    # password (no SSH keys).  So we start a new session ("setsid") with a fake
    # DISPLAY and the SSH_ASKPASS environment variable pointing to a script
    # that echoes "vagrant" to stdout.  Then comes the SSH command, which
    # doesn't check host keys and doesn't save the destination host's public
    # key into known_hosts.  It will get the password from the SSH_ASKPASS
    # script, but only if stdin is coming from /dev/null, hence the redirect.
    # (We also redirect stderr to /dev/null to silence messages from ssh about
    # saving the host key).  This script requires stdout pointing to a TTY to
    # work, so we force creation of a pseudo-terminal in the session ("-tt").
    # And all of that receives a new line via "echo", because otherwise the
    # script will hang waiting for input when the ssh command terminates.

    echo | SSH_ASKPASS="/vagrant/ssh_pass.sh" DISPLAY=dummy setsid \
        ssh -tt -o "UserKnownHostsFile /dev/null" \
            -o "StrictHostKeyChecking no" -- vagrant@$1 "$2" \
            </dev/null 2>/dev/null
}


# jq makes working with JSON data to/from the API easier.  Only available via
# EPEL for RHEL.  This is a function because originally I was going to install
# it on all Masters, but this changed once I found out the puppet-ca API is
# only usable from the MoM.

install_jq() {
    [ "$verbose" ] && verb_message "Installing jq from EPEL"
    yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    yum install -y jq
}

check_for_jq() {
    [ -e "/usr/bin/jq" ] || error_message "jq was not installed."
    [ -z "$error_flag" ] || exit 1
}


# There is a possible issue where the cert isn't available straight away on the
# MoM, so we make a couple of attempts to check for the presence of the cert
# before attempting to sign it.

check_for_cert() {
    local cert=
    local attempts=3

    while [ $attempts -gt 0 ]; do
        cert=$(puppet cert list | sed 's/"//g' | awk '{print $1}')
        if [ -z "$cert" ]; then
            attempts=$(( attempts - 1 ))
            sleep 5
        else
            break
        fi
    done

    if [ -z "$cert" ]; then
        error_message "No cert waiting to be signed."
        exit 1
    else
        echo $cert
    fi
}


# This function installs Puppet Enterprise on the Master of Masters.

install_mom() {
    # If this function is interrupted, initiate a cleanup.

    trap 'cleanup' 2


    # We are assuming that the MoM is running EL7 (RHEL 7, CentOS 7, OEL 7,
    # etc).  The version is 2018.1.2, unless overridden with the "-V" argument.
    # We also require a customised pe.conf file in the "/vagrant" directory. In
    # theory we could have just modified the default pe.conf when the tarball
    # is extracted, but putting the config in "/vagrant" gives people a chance
    # to look at it and modify it if needed.

    pe_installer_repo="https://pm.puppetlabs.com/puppet-enterprise"
    pe_installer_file="puppet-enterprise-${version}-el-7-x86_64.tar.gz"
    pe_installer_url="${pe_installer_repo}/${version}/${pe_installer_file}"
    pe_installer_dir="${progname_dir}/installers/PE_${version}"
    pe_installer="${pe_installer_dir}/${pe_installer_file}"
    pe_config_file="${progname_dir}/pe.conf"

    if [ ! -r "$pe_config_file" ]; then
        error_message "Cannot read $pe_config_file"
        exit 1
    fi


    # Check if the installer is present, download it if required.

    check_for_installer


    # Extract the installer into a temporary directory, and run it using the
    # pe.conf file in the "/vagrant" directory.

    [ "$verbose" ] && verb_message "Installing Puppet Enterprise $version as Master"
    tempdir=$(mktemp -d /tmp/pe_${version}_XXXXXX)
    [ "$verbose" ] && verb_message "Extracting $pe_installer_file to directory $tempdir"
    (cd $tempdir && tar xzf $pe_installer --strip 1)
    if [ ! -e ${tempdir}/puppet-enterprise-installer ]; then
        error_message "Failure extracting $pe_installer_file"
        cleanup
        exit 1
    fi
    [ "$verbose" ] && verb_message "Running ${tempdir}/puppet-enterprise-installer"
    (cd $tempdir && ./puppet-enterprise-installer -c $pe_config_file)


    # Run the Puppet Agent a couple of times once Puppet is installed to finish
    # off configuration of the MoM.

    [ "$verbose" ] && verb_message "Running Puppet Agent post-install"
    puppet agent -t
    puppet agent -t


    # Install jq and check to make sure it is installed, otherwise later API
    # calls are going to have issues.

    install_jq
    check_for_jq
}


# This function would trigger if the script is run with "-p" in the "mom" role.
# There is essentially no need for this to ever happen, but provide a message
# just in case.

post_install_mom() {
    echo "No post-install needed for mom"
}


# This function installs the Puppet Agent on a node destined to become
# a Compile Master ("cm" role).

install_cm() {
    # Install the Puppet Agent via PE Package Management.  Supply a DNS Alt
    # Name when creating the node's cert as this Compile Master will be part of
    # a load-balanced pool behind the "pt-master" VIP.

    [ "$verbose" ] && verb_message "Installing Puppet Agent"
    dns_alt_name="$pt_master"
    curl -sk $pe_cm_agent_installer | bash -s main:dns_alt_names=$dns_alt_name


    # SSH into the MoM, sign the CM's cert, and configure Puppet for
    # load-balanced Compile Masters.

    [ "$verbose" ] && verb_message "Configuring for load-balanced Compile Masters on $puppetmom"
    run_ssh_command $puppetmom "sudo /vagrant/puppet-install.sh $debug $verbose $version_arg -p cm"


    # Run the Puppet Agent once Puppet is installed to finish off the
    # configuration of the CM if needed.

    [ "$verbose" ] && verb_message "Running Puppet Agent post-install"
    puppet agent -t
}


# This function signs the CM cert and configures Puppet for load-balanced
# Compile Masters.  This all runs on the MoM, so "post_install_cm" is a bit of
# a misnomer.

post_install_cm() {
    # This is probably redundant, but if you ran "vagrant up" instead of
    # bringing each box up individually and weren't paying attention it probably
    # won't hurt.

    check_for_jq


    # Set up some variables to make the upcoming curl commands easier to
    # manage.  As we are running on the MoM we may as well use
    # certificate-based authentication rather than bother with RBAC tokens.
    # Also set a variable to describe the "POST" method for brevity.  Of
    # course, variables containing quoted words are all sorts of fun when
    # used as command arguments.  More on that later.

    classifier_api="https://${puppetmom}:4433/classifier-api/v1"
    cert_chain="--cert /etc/puppetlabs/puppet/ssl/certs/${puppetmom}.pem \
                --key /etc/puppetlabs/puppet/ssl/private_keys/${puppetmom}.pem \
                --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem"
    post='-X POST -H "Content-Type: application/json"'


    # The assumption is that the cert returned by "puppet cert list" is the
    # node that just had its Puppet Agent installed and is waiting for the MoM
    # to finish off the config.  This should be true so far as Vagrant is
    # concerned where the boxes come up sequentially.

    puppetcm=$(check_for_cert)


    # We can't apparently sign certs with DNS alt names via the puppet-ca API,
    # but we can't access the puppet-ca API from anything other than the MoM
    # anyway, so we might as well run the "puppet" command directly given that
    # we are already here.

    [ "$verbose" ] && verb_message "Signing cert for $puppetcm"
    puppet cert --allow-dns-alt-names sign $puppetcm


    # Pin the just-signed Compile Master node to the "PE Master" group.  Note
    # we need to use the "evil" eval built-in because $post is a string that
    # has quotes in it.  Not running the command through eval first results in
    # the shell individually quoting each word in the string, which breaks
    # attempts to access the API.

    [ "$verbose" ] && verb_message 'Retrieving Group ID for "PE Master" group'
    pm_group_id=$(curl -s $cert_chain $classifier_api/groups | \
        jq -r '.[] | select(.name=="PE Master") | .id')

    [ "$verbose" ] && verb_message "Pinning $puppetcm to \"PE Master\" node group"
    eval curl -s $post $cert_chain $classifier_api/groups/$pm_group_id/pin?nodes=$puppetcm


    # We've already SSHed into $puppetmom from the $puppetcm to run this
    # function, but now we have to SSH back into $puppetcm in order to run the
    # Puppet Agent and configure $puppetcm as a Master.  Then we need to run
    # the Agent on the MoM again so the MoM knows about the new Compile Master.

    [ "$verbose" ] && verb_message "Running Puppet on $puppetcm"
    run_ssh_command $puppetcm "sudo /opt/puppetlabs/bin/puppet agent -t"

    [ "$verbose" ] && verb_message "Running Puppet on $puppetmom"
    puppet agent -t


    # Check that we haven't already configured load balancing on the Master.
    # This is useful for when additional CM nodes are being installed after the
    # first.  It doesn't hurt to run this config each time, but may as well
    # save a few seconds.

    check=$(curl -s $cert_chain $classifier_api/groups | \
        jq -r '.[] | select(.name=="PE Master") | .classes.pe_repo.compile_master_pool_address')

    if [ "$check" != "$pt_master" ]; then

        # The check indicated we haven't done the config yet, so let's do it.

        [ "$verbose" ] && verb_message "Configuring installation for load-balanced Compile Masters"


        # Get the relevant Group IDs.

        [ "$verbose" ] && verb_message 'Retrieving Group IDs for "PE Infrastructure Agent" and "PE Agent" groups'
        pia_group_id=$(curl -s $cert_chain $classifier_api/groups | \
            jq -r '.[] | select(.name=="PE Infrastructure Agent") | .id')
        pa_group_id=$(curl -s $cert_chain $classifier_api/groups | \
            jq -r '.[] | select(.name=="PE Agent") | .id')


        # A word about why the data is being built this way.  Like the $post
        # variable, these variables use strings of quoted words.  They are
        # single-quoted so I don't have to escape every double-quote (yay
        # JSON) but if I'd just done it using "variable='data'" none of the
        # variables inside the data string would have been been expanded.
        # Using a heredoc was the way around this.
        #
        # This also took too long to figure out, so this comment is another
        # reminder note to my future self.

        pm_cmpa_data=$(cat <<EOT
'{"id":"$pm_group_id","classes":{"pe_repo":{"compile_master_pool_address":"$pt_master"}}}'
EOT
)
        pia_pcpb_data=$(cat <<EOT
'{"id":"$pia_group_id","classes":{"puppet_enterprise::profile::agent":{"pcp_broker_list":["${puppetmom}:8142"],"master_uris":["https://${puppetmom}:8140"],"pcp_broker_ws_uris":null}}}'
EOT
)
        pa_pcpb_data=$(cat <<EOT
'{"id":"$pa_group_id","classes":{"puppet_enterprise::profile::agent":{"pcp_broker_list":["${pt_master}:8142"],"master_uris":["https://${pt_master}:8140"],"pcp_broker_ws_uris":null}}}'
EOT
)

        # The Puppet install docs list a set of steps required to configure
        # Puppet for load-balanced Compile Masters that frequently involve
        # running Puppet on the various Masters.  Not that this always does
        # anything, which seems a little strange. So don't be surprised if
        # nothing seems to happen during a Puppet run.

        # Set the "compile_master_pool_address" parameter in the "pe_repo"
        # class attached to the "PE Master" group to the load-balanced
        # pt-master name.

        [ "$verbose" ] && verb_message 'Configuring "PE Master" group'
        eval curl -s $post $cert_chain $classifier_api/groups/$pm_group_id -d $pm_cmpa_data >/dev/null

        # Run the agent on the Compile Master and the MoM to apply the new setting.

        [ "$verbose" ] && verb_message "Running Puppet on $puppetcm"
        run_ssh_command $puppetcm "sudo /opt/puppetlabs/bin/puppet agent -t"

        [ "$verbose" ] && verb_message "Running Puppet on $puppetmom"
        puppet agent -t


        # Configure the "puppet_enterprise::profile::agent" class attached to
        # the "PE Infrastructure Agent" group to ensure that the Compile
        # Masters communicate with the MoM rather than the pt-master VIP.
        #
        # Interestingly, RMIT's installation doesn't do this despite this step
        # being in the installation docs.  I'm not sure why.

        [ "$verbose" ] && verb_message 'Configuring "PE Infrastructure Agent" group'
        eval curl -s $post $cert_chain $classifier_api/groups/$pia_group_id -d $pia_pcpb_data >/dev/null

        [ "$verbose" ] && verb_message "Running Puppet on $puppetcm"
        run_ssh_command $puppetcm "sudo /opt/puppetlabs/bin/puppet agent -t"

        [ "$verbose" ] && verb_message "Running Puppet on $puppetmom"
        puppet agent -t


        # Same as the above, but standard Agents connect via the pt-master VIP.

        [ "$verbose" ] && verb_message 'Configuring "PE Agent" group'
        eval curl -s $post $cert_chain $classifier_api/groups/$pa_group_id -d $pa_pcpb_data >/dev/null

        [ "$verbose" ] && verb_message "Running Puppet on $puppetmom"
        puppet agent -t
    fi


    # Do I need to run Puppet on all the Compile Masters each time a new
    # one is added?  I don't know. Let's see what happens.
    #
    # This of course assumes that CM hosts are coming up in sequential
    # numbered order.

    this_cm="${puppetcm//[^0-9]/}"
    if [ "$this_cm" -gt "1" ]; then
        [ "$verbose" ] && verb_message "Running Puppet on all the Compile Masters"
        for n in $(seq 1 $this_cm); do
            [ "$verbose" ] && verb_message "Running Puppet on ${puppetcm/[0-9]/$n}"
            run_ssh_command ${puppetcm/[0-9]/$n} "sudo /opt/puppetlabs/bin/puppet agent -t"
        done
    fi
}


# This function install the Puppet Agent on a standard node.

install_cl() {
    [ "$verbose" ] && verb_message "Installing Puppet Agent"
    curl -sk $pe_agent_installer | sudo bash

    [ "$verbose" ] && verb_message "Configuring $(uname -n) on Master"
    run_ssh_command $puppetmom "sudo /vagrant/puppet-install.sh $debug $verbose $version_arg -p cl"

    [ "$verbose" ] && verb_message "Running Puppet agent post-install"
    puppet agent -t
}


# This function signs the cert for the newly install client node on the MoM.

post_install_cl() {
    puppetcl=$(check_for_cert)

    [ "$verbose" ] && verb_message "Signing cert for $puppetcl"
    puppet cert sign $puppetcl
}


# So now that we have all the functions sorted, the rest of the script begins.

debug= verbose= version= version_arg= post=

while getopts :hdvV:p opt; do
    case $opt in
        h)
            usage
            echo
            echo "Required parameter:"
            echo "    role              The host's role (mom|cm|cl)"
            echo
            echo "Optional parameters:"
            echo "    -h                Show this help message and exit"
            echo "    -d                Debug (set -x)"
            echo "    -v                Be verbose"
            echo "    -V                PE version (2018.1.2 if not defined)"
            echo "    -p                Run post-install tasks"
            exit
            ;;
        d)
            debug="-d"
            ;;
        v)
            verbose="-v"
            ;;
        V)
            version=$OPTARG
            version_arg="-V $version"
            ;;
        p)
            [[ "$(uname -n)" =~ "$puppetmom" ]]
            if [ "$?" -ne "0" ]; then
                error_message "'-p' is valid only on $puppetmom."
                exit 1
            fi
            post="post_"
            ;;
        '?')
            usage >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

[ "$debug" ] && set -x

role=$1
version=${version:="2018.1.2"}

case $role in
    "mom"|"cm"|"cl")
        ${post}install_$role
        ;;
    *)
        error_message "Role must be one of 'mom', 'cm', or 'cl'."
        exit 1
        ;;
esac

if [ -z "$post" ]; then
    [ "$role" == "mom" ] && cleanup
    [ "$verbose" ] && verb_message "Done."
fi
exit 0
