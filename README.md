# Puppet Enterprise Test Environment

This repo contains almost everything needed to configure a Puppet Enterprise
environment with monolithic Master, two load-balanced Compile Masters, and
a client node using VirtualBox VMs via Vagrant.

The architecture is equivalent to RMIT's (based on a combination of the
"Monolithic installation with compile masters" and "Large environment
installation" types described in the *Puppet Enterprise
[User Guide](https://puppet.com/docs/pe/2018.1/pe_user_guide.html)* under
["Choosing an Architecture"](https://puppet.com/docs/pe/2018.1/choosing_an_architecture.html).)

It assumes the presence of the RMIT RHEL7 Vagrant box, but should work with any
el7 box (eg "`centos/7`")


## The Environment
```
ptlb:  Load balancer, see haproxy.cfg
|
+-- pt-console (VIP for Console on ptmom)
+-- pt-master  (VIP for load-balanced compile masters)

ptmom: Master of Masters, monolithic install

ptcm1: Compile Master #1

ptcm2: Compile Master #2

ptcl:  Standard node with Puppet Agent installed
```
By default PE 2018.1.2 is installed, as that is the current version in use at
RMIT, however this can be changed by modifying the `Vagrantfile` and ensuring
that references to "`puppet-install.sh`" have the "`-V`" argument added to specify
the version.  For example, to install 2018.1.8, add "`-V 2018.1.8`" as the
argument.

**NOTE:** This build isn't actually all that useful for testing Puppet code as
Code Manager is not configured, nor is File Sync set up in standalone mode
(which is a pain anyway as you need to initiate a sync manually through the API
as far as I can tell.)  As a result any Puppet code you add will not get pushed
out to the Compile Masters.  If you want to test Puppet code, consider
installing `ptmom` only .  You can install `ptcl`, but note that it will
attempt to install Puppet Agent via the `pt-master` VIP during provisioning;
this is not what you want for a standalone Master.


## Requirements

- [VirtualBox](https://www.virtualbox.org)
- [Vagrant](https://www.vagrantup.com/)
- Assumed knowledge of how to use Vagrant and Puppet. :)

If you are using the default `rmit-rhel7` box (assuming you are located on
campus) you can obtain the latest `rmit-rhel-server-7` version of the box from
the [Satellite](http://satellite.its.rmit.edu.au/boxes/) server.  Get the link
and install it via:

```
$ vagrant box add rmit-rhel7 <link>
```

If you don't want to use `rmit-rhel7`, or you can't, be sure to change the
relevant `vm.box` entries in the `Vagrantfile` to `centos/7`.


## How To Use

Provided you've met the above requirements:

```
$ vagrant up
```

Then wait half an hour or so for everything to come up. The PE Console will be
available at `https://pt-console.its.rmit.edu.au` with the highly-secure
credentials of `admin/password`, and if you need it and don't want to explore
the esoteric use of `socat` to control `haproxy`, you can control the load
balancer at `http://puppettest-lb.its.rmit.edu.au:9000`, also with the
credentials `admin/password`.

All of this assume you haven't changed anything in the various config files, of
course.


### RMIT config

While this environment is modelled on RMIT's, it is not really useful for
testing how RMIT's code behaves for situations such as Agent upgrades.  To
assist with this, the `rmit-config.sh` post-install script was added in order
to make the installation look and behave as closely as possible to the current
RMIT PE environment.

In order to use it you need a local copy of `puppet-controlrepo` and possibly
access to the SSH key used for access to the relevant Git repo (if you intend
to use the modules in the `Puppetfile` that are installed via SSH.)

Run the script after all the Masters are up.

```
Usage: rmit-config.sh [-h] [-d] [-k] [-v] [-K ssh_key_file] [-r control_repo_location]

Optional parameters:
    -h                Show this help message and exit
    -d                Debug (set -x), implies -k
    -k                Keep bootstrap.sh, pe-site.tgz, and the copied SSH key
    -v                Be verbose
    -K                Path to SSH key (for Git repo access)
    -r                Path to clone of Control Repo
```
