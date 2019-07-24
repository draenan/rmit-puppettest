#
# Vagrantfile
#
# This Vagrant file configures a Puppet Enterprise environment with monolithic
# Master, two load-balanced Compile Masters, and a client node.
# The architecture is equivalent to RMIT's (based on a combination of the
# "Monolithic installation with compile masters" and "Large environment
# installation" types described at
# https://puppet.com/docs/pe/2018.1/choosing_an_architecture.html)
#
# It assumes the presence of the RMIT RHEL7 Vagrant box, but should work with
# any el7 box (eg "centos/7")
#
# ptlb:  Load balancer, see haproxy.cfg
# |
# +-- pt-console (VIP for Console on ptmom)
# +-- pt-master  (VIP for load-balanced compile masters)
#
# ptmom: Master of Masters, monolithic install
#
# ptcm1: Compile Master #1
#
# ptcm2: Compile Master #2
#
# ptcl:  Standard node with Puppet Agent installed
#
# See the bottom of this file for /etc/hosts config. Consider putting the entry
# for ptlb and pt-console into your own /etc/hosts file.
#
Vagrant.configure("2") do |config|

  # I usually disable vbguest auto-update on RHEL boxes because the plugin
  # fires before provisioning is complete, with the box yet to be subscribed
  # to the relevant channels in Satellite.  However, if using 'centos/7' you
  # might want to enable auto_update in order to install the VirtualBox Guest
  # Additions, and uncomment the synced_folder line in order to mount
  # '/vagrant' in the box.  Otherwise you'll be rsyncing '.' into '/vagrant'
  # in the box rather than mounting it.

  if Vagrant.has_plugin?('vagrant-vbguest')
    config.vbguest.auto_update = false
  end

  # config.vm.synced_folder ".", "/vagrant", type: "virtualbox"

  # Load Balancer
  config.vm.define "ptlb" do |ptlb|
    ptlb.vm.box = "rmit-rhel7"
    ptlb.vm.hostname = "puppettest-lb.its.rmit.edu.au"
    ptlb.vm.network :private_network, ip: "192.168.160.60"
    ptlb.vm.network :private_network, ip: "192.168.160.100"
    ptlb.vm.network :private_network, ip: "192.168.160.101"
    ptlb.vm.provider "virtualbox" do |v|
      v.name = "puppettest-lb"
      v.memory = "1024"
      v.cpus = "1"
      v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end
    ptlb.vm.provision "shell", inline: "/vagrant/loadbalancer.sh -v"
  end

  # Monolithic Master of Masters
  config.vm.define "ptmom", primary: true do |ptmom|
    ptmom.vm.box = "rmit-rhel7"
    ptmom.vm.hostname = "puppettest-mom.its.rmit.edu.au"
    ptmom.vm.network :private_network, ip: "192.168.160.50"
    ptmom.vm.provider "virtualbox" do |v|
      v.name = "puppettest-mom"
      v.memory = "3072"
      v.cpus = "2"
      v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end
    ptmom.vm.provision "shell", inline: "/vagrant/puppet-install.sh -v mom"
  end

  # Compile Master #1
  config.vm.define "ptcm1" do |ptcm1|
    ptcm1.vm.box = "rmit-rhel7"
    ptcm1.vm.hostname = "puppettest-cm1.its.rmit.edu.au"
    ptcm1.vm.network :private_network, ip: "192.168.160.51"
    ptcm1.vm.provider "virtualbox" do |v|
      v.name = "puppettest-cm1"
      v.memory = "2048"
      v.cpus = "2"
      v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end
    ptcm1.vm.provision "shell", inline: "/vagrant/puppet-install.sh -v cm"
  end

  # Compile Master #2
  config.vm.define "ptcm2" do |ptcm2|
    ptcm2.vm.box = "rmit-rhel7"
    ptcm2.vm.hostname = "puppettest-cm2.its.rmit.edu.au"
    ptcm2.vm.network :private_network, ip: "192.168.160.52"
    ptcm2.vm.provider "virtualbox" do |v|
      v.name = "puppettest-cm2"
      v.memory = "2048"
      v.cpus = "2"
      v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end
    ptcm2.vm.provision "shell", inline: "/vagrant/puppet-install.sh -v cm"
  end

  # Client
  config.vm.define "ptcl" do |ptcl|
    ptcl.vm.box = "rmit-rhel7"
    ptcl.vm.hostname = "puppettest-cl.its.rmit.edu.au"
    ptcl.vm.network :private_network, ip: "192.168.160.200"
    ptcl.vm.provider "virtualbox" do |v|
      v.name = "puppettest-cl"
      v.memory = "1024"
      v.cpus = "1"
      v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end
    ptcl.vm.provision "shell", inline: "/vagrant/puppet-install.sh -v cl"
  end

  $common = <<-SCRIPT
  sed -i '/rmit.edu.au/d' /etc/hosts
  printf "192.168.160.50\tpuppettest-mom.its.rmit.edu.au\tpuppettest-mom\tptmom\n" >> /etc/hosts
  printf "192.168.160.51\tpuppettest-cm1.its.rmit.edu.au\tpuppettest-cm1\tptcm1\n" >> /etc/hosts
  printf "192.168.160.52\tpuppettest-cm2.its.rmit.edu.au\tpuppettest-cm2\tptcm2\n" >> /etc/hosts
  printf "192.168.160.60\tpuppettest-lb.its.rmit.edu.au\tpuppettest-lb\tptlb\n" >> /etc/hosts
  printf "192.168.160.100\tpt-master.its.rmit.edu.au\tpt-master\n" >> /etc/hosts
  printf "192.168.160.101\tpt-console.its.rmit.edu.au\tpt-console\n" >> /etc/hosts
  printf "192.168.160.200\tpuppettest-cl.its.rmit.edu.au\tpuppettest-cl\tptcl\n" >> /etc/hosts
  grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config && \
      printf "Match User vagrant\n    PasswordAuthentication yes\n" >> /etc/ssh/sshd_config
  systemctl restart rsyslog
  systemctl reload sshd
  yum update -y
SCRIPT

  config.vm.provision "shell", inline: $common

end

