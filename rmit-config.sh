#!/bin/bash
#
# rmit-config.sh
#
# Run this script manually post-provisioning of hosts in order to configure the
# masters in a way that more closely resembles RMIT's configuration.
# Specifically:
#
# - Modules as listed in the Puppetfile
# - Creation of a "site" directory in the production environment and
#   configuration to use it
# - Copying of profile::puppet::agent from the puppet-controlrepo into the
#   production environment on the masters
#
# This Vagrant environment is suitable for testing basic things regarding
# Puppet Enterprise, but not so good at testing RMIT's particular set up,
# especially when it comes to testing Agent upgrades with the
# puppetlabs-puppet_agent module due to the way it is used in our environment
# (wrapped by a profile::puppet::agent class because Solaris.)
#
# Manual configuration of this environment post-install takes too long and is
# prone to missing steps, so this script will help automate it.  It assumes you
# have a cloned copy of the puppet-controlrepo available locally, the location
# of which will default to "$HOME/src/puppet-controlrepo" unless specifically
# overridden with the '-r' option.
#
PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin

progname=${0##*/}


# Don't run this on the VMs.

[[ "$(uname -n)" =~ "puppettest" ]]

if [ "$?" -eq "0" ]; then
    echo "Run this script on your workstation, not the VMs." >&2
    exit 1
fi


usage() {
    echo "Usage: $progname [-h] [-d] [-k] [-v] [-K ssh_key_file] [-r control_repo_location]"
}


# Messages will be displayed with colour for consistency with the other
# scripts.

verb_message() {
    [ "$verbose" ] && echo -e "\n\033[1;34m=== $1\033[0m"
}


error_message() {
    echo -e "\033[1;31mERROR:\033[0m $1" >&2
    error_flag=1
}


# Time to gather command line arguments.

debug= keep_files= verbose= ssh_key= control_repo=

while getopts :hdkvK:r: opt; do
    case $opt in
        h)
            usage
            echo
            echo "Optional parameters:"
            echo "    -h                Show this help message and exit"
            echo "    -d                Debug (set -x), implies -k"
            echo "    -k                Keep bootstrap.sh, pe-site.tgz, and the copied SSH key"
            echo "    -v                Be verbose"
            echo "    -K                Path to SSH key (for Git repo access)"
            echo "    -r                Path to clone of Control Repo"
            exit
            ;;
        d)
            debug=" -x"
            keep_files=1
            ;;
        k)
            keep_files=1
            ;;
        v)
            verbose="-v"
            ;;
        K)
            ssh_key=$OPTARG
            ;;
        r)
            control_repo=$OPTARG
            ;;
        '?')
            usage >&2
            exit 1
            ;;
    esac
done


# Enable debug tracing if "-d" was specified.

[ "$debug" ] && set -x


# Set a default location of the Control Repo.  This is correct for me, maybe
# not for anyone else.  That's what the "-r" option is for.  Once we have the
# repo, make sure we can read the Puppetfile.

control_repo=${control_repo:="${HOME}/src/puppet-controlrepo"}

if [ ! -r "${control_repo}/Puppetfile" ]; then
    error_message "Cannot read ${control_repo}/Puppetfile"
    exit 1
fi


# Masters obviously need to be up and running for this script to be useful.  At
# the very least, the MoM should be up.

verb_message "Checking for running Masters."
masters=($(vagrant status | grep 'running' | egrep -o '^pt(mom|cm\d)'))
masters=${masters[*]}

[[ "$masters" =~ "ptmom" ]]

if [ "$?" -ne "0" ]; then
    error_message "ptmom is not running."
    exit 1
else
    verb_message "Found: $masters"
fi


# Copy the SSH key into the current directory so it will be usable by the
# Masters.

if [ ! -z "$ssh_key" ]; then
    if [ -r "$ssh_key" ]; then
        verb_message "Making temporary copy of SSH key ${ssh_key##*/}"
        cp $ssh_key .
    else
        error_message "Cannot read $ssh_key"
        exit 1
    fi
fi


# Create a tarball of the profile::puppet class and subclasses.

verb_message "Creating site tarball from control repo"
cwd=$PWD

cd $control_repo
tar czf ${cwd}/pe-site.tgz site/profile/manifests/puppet manifests/site.pp
cd $cwd


# Start building the bootstrap.sh script.  This script will be run on each of
# the Masters.

verb_message "Generating 'bootstrap.sh' script"

echo "#!/bin/bash$debug" > bootstrap.sh

cat >> bootstrap.sh << EOF
PATH=/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin


# This function will be noop if "-v" was not passed to rmit-config.sh,
# otherwise it will produce green messages.

verb_message() {
EOF

if [ "$verbose" ]; then
    echo '    echo -e "\n\033[1;32m--- $1\033[0m"' >> bootstrap.sh
else
    echo '    :' >> bootstrap.sh
fi

cat >> bootstrap.sh << EOF
}


# Change directory to the Production environment and extract the site tarball.

verb_message "Extracting site tarball"

cd /etc/puppetlabs/code/environments/production

tar xzvf /vagrant/pe-site.tgz


# Fix the source location for pc_repo in profile::puppet::agent

verb_message "Correcting pc_repo URI in profile::puppet::agent"

sed -e 's/pe-master.its.rmit.edu.au:8140/pt-master.its.rmit.edu.au:8140/' \\
    -i site/profile/manifests/puppet/agent.pp


# Installing git if required.  May be needed for some modules in the
# Puppetfile.

grep -q 'git archive' \$0
if [ "\$?" -eq "0" ]; then
    which git >/dev/null 2>&1
    if [ "\$?" -eq "1" ]; then
        verb_message "Installing git"
        yum install -y git
    fi
fi


# Grab the SSH key if available.  Also make sure the known_hosts file has the
# host key of the Stash server.  This of course assumes that we are only using
# the SSH key for connections to RMIT's Stash server.  Using ssh-keyscan in this
# way is not secure, but frankly if someone compromises our Stash server we have
# bigger problems.

ssh_key="${ssh_key##*/}"
[ ! -z "\$ssh_key" ] && ssh_key="/vagrant/\$ssh_key"
if [ -r "\$ssh_key" ]; then
    verb_message "Setting up SSH key and known_hosts"
    host="stash.its.rmit.edu.au"
    ip=\$(dig +short \$host | tail -n 1)
    eval \$(ssh-agent)
    ssh-add \$ssh_key
    ssh-keyscan \$host,\$ip >> \$HOME/.ssh/known_hosts 2>/dev/null
fi


# Install modules sourced from the control repo Puppetfile.

verb_message "Installing modules from Puppetfile"
cd modules

EOF

chmod 755 bootstrap.sh


# We can apparently use Puppet Bolt to install modules from a Puppetfile, but
# we're not currently using Bolt here at RMIT. I don't want to diverge too much
# from the Prod installation, so therefore we need to parse the Puppetfile for
# the modules installed in RMIT's production environment.  For each module, add
# a line to bootstrap.sh to install that module

modules=$(awk -F\' '/^mod/ {print $2 "," $4}' ${control_repo}/Puppetfile)
for module in $modules; do
    module_name=${module%,*}
    module_version=${module#*,}


    # Modules with a version number are installed via "puppet-module".

    if [ ! -z "$module_version" ]; then
        echo "/usr/local/bin/puppet module install --force --ignore-dependencies --version $module_version $module_name" >> bootstrap.sh
    else


        # Modules without a version number are assumed to be installed via
        # git.  So we need to determine the remote and the ref/branch.

        remote=$(sed -n "/$module_name/{n;p;}" ${control_repo}/Puppetfile | awk -F\' '{print $2}')
        ref=$(sed -n "\#${remote}#{n;p;}" ${control_repo}/Puppetfile | awk -F\' '{print $2}')


        # Getting an archive of a Git repo is dependent on whether or not the
        # repo lives on GitHub.  We aren't currently using any modules from
        # GitHub, but you never know.  Note that this will only work for
        # public GitHub repos.

        [[ "$remote" =~ "github.com" ]]
        if [ "$?" -eq "0" ]; then
            org_repo=${remote##*github.com/}
            org=${org_repo%%/*}
            repo=${org_repo##*/}
            echo "rm -rf $module_name && mkdir $module_name && cd $module_name" >> bootstrap.sh
            echo "echo 'Installing $module_name from GitHUb'" >> bootstrap.sh
            echo "curl -sL https://api.github.com/repos/${org}/${repo}/tarball/$ref | tar --strip=1 -xzf -" >> bootstrap.sh
            echo "cd .." >> bootstrap.sh
        else
            if [ ! -z "$ssh_key" ]; then
                echo "rm -rf $module_name && mkdir $module_name && cd $module_name" >> bootstrap.sh
                echo "echo 'Installing git-based module $module_name'" >> bootstrap.sh
                echo "git archive --format=tar --remote=$remote $ref | tar -xf -" >> bootstrap.sh
                echo "cd .." >> bootstrap.sh
            else
                echo "Skipping $module_name: No SSH key available."
            fi
        fi
    fi
done


# Build the rest of bootstrap.sh

cat >> bootstrap.sh << EOF

cd /etc/puppetlabs/code/environments/production


# Delete SSH keys from ssh-agent.

verb_message "Removing SSH key from ssh-agent"
ssh-add -D


# Set modulepath.  Do it after installing modules so I don't have to provide
# "--modulepath" to each call of "puppet module".

verb_message "Configuring modulepath"
grep -q '^modulepath = ' environment.conf
if [ "\$?" -ne "0" ]; then
    echo 'modulepath = site:modules:\$basemodulepath' >> environment.conf
fi


# Set correct ownership of the files extracted from the site tarball.

verb_message "Fixing file ownership"
chown -R pe-puppet:pe-puppet site modules manifests


# Perform some MoM-specific configuration if we are running on the MoM.

this_host=\$(uname -n)
[[ "\$this_host" =~ "puppettest-mom" ]]

if [ "\$?" -eq "0" ]; then

    verb_message "Running configuration update on MoM"

    classifier_api="https://\${this_host}:4433/classifier-api/v1"
    cert_chain="--cert /etc/puppetlabs/puppet/ssl/certs/\${this_host}.pem \\
                --key /etc/puppetlabs/puppet/ssl/private_keys/\${this_host}.pem \\
                --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem"
    post='-X POST -H "Content-Type: application/json"'


    # Update classes

    verb_message "Trigger refresh of class definitions"
    eval curl -s \$post \$cert_chain \$classifier_api/update-classes


    # Set up Package Inventory

    verb_message "Enable Package Inventory"

    pa_group_id=\$(curl -s \$cert_chain \$classifier_api/groups | \\
        jq -r '.[] | select(.name=="PE Agent") | .id')

    pa_pie_data=\$(cat << EOT
'{"id":"\$pa_group_id","classes":{"puppet_enterprise::profile::agent":{"package_inventory_enabled":true}}}'
EOT
)
    eval curl -s \$post \$cert_chain \$classifier_api/groups/\$pa_group_id -d \$pa_pie_data


    # Set up display of local time in Console

    verb_message "Use local time for timestamps in Console."
    pec_group_id=\$(curl -s \$cert_chain \$classifier_api/groups | \\
        jq -r '.[] | select(.name=="PE Console") | .id')

    pec_dlt_data=\$(cat << EOT
'{"id":"\$pec_group_id","classes":{"puppet_enterprise::profile::console":{"display_local_time":true}}}'
EOT
)
    eval curl -s \$post \$cert_chain \$classifier_api/groups/\$pec_group_id -d \$pec_dlt_data


    # Check for classification group for profile::puppet::agent, create it if it
    # doesn't exist.

    check=\$(curl -s \$cert_chain \$classifier_api/groups | \\
        jq -r '.[] | select(.name=="Old Agent Upgrade")')

    if [ -z "\$check" ]; then


        # Create the "Old Agent Upgrade" group as it exists currently exists in
        # our production PE installation.  Parent ID for groups attached to the
        # "All Nodes" root is always the same, and a random ID will be assigned
        # for this group.

        verb_message "Creating the 'Old Agent Upgrade' classification group"

        oau_data=\$(cat << EOT
'{"name":"Old Agent Upgrade","environment":"production","environment_trumps":false,"description":"Temporary group that applies profile::puppet::agent to all nodes to ensure they are upgraded","parent":"00000000-0000-4000-8000-000000000000","rule":["and",["~","name",".*"]],"classes":{"profile::puppet::agent":{}}}'
EOT
)
    eval curl -s \$post \$cert_chain \$classifier_api/groups -d \$oau_data
    fi
fi


# Our Production PE install also includes profile::puppet::agent from
# inside site::common because why not?  Not something I agree with (because it
# hard codes parameters for ::puppet_agent), but I'm trying to make this test
# install act like our Prod install, so...  Adding the class to the site.pp
# manifest file as we aren't using the site::common class in this test
# environment.

grep -q 'profile::puppet::agent' manifests/site.pp

if [ "\$?" -ne "0" ]; then
    verb_message "Adding profile::puppet::agent to site.pp"
    sed '/^}$/i\\
  include profile::puppet::agent
' -i manifests/site.pp
fi


# Run Puppet Agent

verb_message "Running Puppet Agent"
puppet agent -t


# Done.

verb_message "Done."

exit 0
EOF


# Run the bootstrap.sh script on all the Masters.

for master in $masters; do
    verb_message "Running 'bootstrap.sh' on $master"
    vagrant ssh $master -- sudo /vagrant/bootstrap.sh
done


# Clean up.

if [ ! -z "$ssh_key" ]; then
    if [ -z "$keep_files" ]; then
        verb_message "Removing temporary copy of SSH key '${ssh_key##*/}'"
        rm ${ssh_key##*/}
    else
        verb_message "Keeping temporary copy of SSH key '${ssh_key##*/}'"
    fi
fi

if [ -z "$keep_files" ]; then
    verb_message "Removing temporary files 'bootstrap.sh' and 'pe-site.tgz'"
    rm -f bootstrap.sh pe-site.tgz
else
    verb_message "Keeping temporary files 'bootstrap.sh' and 'pe-site.tgz'"
fi

verb_message "Done."

exit 0
