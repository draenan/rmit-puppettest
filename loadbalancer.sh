#!/bin/bash
#
# loadbalancer.sh
#
# Sets up an haproxy-based load balancer with VIPs for various Puppet services.
#
# pt-console: VIP that reverse proxies to Puppet Console on ptmom
# pt-master: VIP for the Compile Masters ptcm1 and ptcm2
#
# pt-master listens on both 8140 for Puppet Agent communication, and 8142 for
# Orchestration.  There is also an HTTP->HTTPS redirect listening on port 80
# for pt-console.  See haproxy.cfg for details.
#
PATH=/bin:/usr/bin:/sbin:/usr/sbin

progname=${0##*/}


# Only makes sense to run on the load balancer host.

[[ "$(uname -n)" =~ "puppettest-lb" ]]

if [ "$?" -ne "0" ]; then
    echo "Run this script on puppettest-lb." >&2
    exit 1
fi


usage() {
    echo "Usage: $progname [-d] [-v]"
}


# Bring a little colour (in this case blue) to messages to distinguish them
# from vagrant's messages.

verb_message() {
    echo -e "\n\033[1;34m=== $1\033[0m"
}


debug= verbose=

while getopts :hdv opt; do
    case $opt in
        h)
            usage
            exit
            ;;
        d)
            debug=1
            ;;
        v)
            verbose=1
            ;;
        '?')
            usage >&2
            exit 1
            ;;
    esac
done

[ "$debug" ] && set -x

# socat is for if you want to try and figure out how to control haproxy by
# echoing commands to haproxy's unix socket using socat.  There'a also the
# stats interface on puppettest-lb:9000 that will allow for state changes.

[ "$verbose" ] && verb_message "Installing haproxy and socat"
yum install -y haproxy socat


# This will symlink /etc/haproxy/haproxy.cfg to /vagrant/haproxy.cfg if it
# exists, and it most likely does.  However in doing that we also have to
# change haproxy.service so haproxy starts after the /vagrant directory is
# mounted.

if [ ! -L /etc/haproxy/haproxy.cfg -a -r /vagrant/haproxy.cfg ]; then
    [ "$verbose" ] && verb_message "Linking /etc/haproxy/haproxy.cfg to /vagrant/haproxy.cfg"
    rm /etc/haproxy/haproxy.cfg
    ln -s /vagrant/haproxy.cfg /etc/haproxy/haproxy.cfg


    # Using SELinux, you mad, crazy fool?  haproxy won't work because
    # haproxy.cfg is outside of "/etc".  This is a Dev environment, can I be
    # bothered trying to figure out SELinux?  No.  No, I cannot.  So let's set
    # haproxy_t to be permissive.

    [ "$verbose" ] && verb_message "Checking for SELinux in Enforcing mode"

    if [ $(getenforce) == "Enforcing" ]; then
        verb_message "SELinux is enforcing"
        if [ ! -r "/sbin/semanage" ]; then
            verb_message "Can't find semanage, Installing policycoreutils-python"
            yum install -y policycoreutils-python
        fi
        [ "$verbose" ] && verb_message "Setting process type haproxy_t to 'permissive'"
        semanage permissive -a haproxy_t
    fi

    [ "$verbose" ] && verb_message "Configuring haproxy.service to start after vagrant.mount"
    cp -p /lib/systemd/system/haproxy.service /etc/systemd/system/haproxy.service
    sed -e 's/WantedBy=multi-user.target/WantedBy=vagrant.mount/' \
        -i /etc/systemd/system/haproxy.service
    systemctl daemon-reload
fi


# haproxy is chrooted, and thus can't access the syslog socket.  Haproxy
# recommends that remote logging be enabled to compensate.  Except rsyslog
# seems to not be able to bind to a particular port for TCP, only UDP.  Best
# fix would be to create a new syslog socket inside the chroot, but I've got
# no idea how to do that for rsyslog, only syslog, and it's not worth
# the time investigating for now.

[ "$verbose" ] && verb_message "Enable remote logging to rsyslog for haproxy"
sed -e 's/#$ModLoad imudp/$ModLoad imudp/' \
    -e 's/#$UDPServerRun/$UDPServerRun/' \
    -e 's/#$ModLoad imtcp/$ModLoad imtcp/' \
    -e 's/#$InputTCPServerRun/$InputTCPServerRun/' \
    -i /etc/rsyslog.conf

echo "local2.*                       /var/log/haproxy.log" > /etc/rsyslog.d/haproxy.conf
touch /var/log/haproxy.log

[ "$verbose" ] && verb_message "Restarting rsyslog"
systemctl restart rsyslog

[ "$verbose" ] && verb_message "Enabling and starting haproxy"
systemctl enable haproxy
systemctl start haproxy

[ "$verbose" ] && verb_message "Done."
exit 0
