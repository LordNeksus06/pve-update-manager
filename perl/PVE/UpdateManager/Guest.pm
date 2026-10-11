package PVE::UpdateManager::Guest;

# The two kinds of guest a target can be - a container ('lxc') or a virtual
# machine ('qemu') - behind one set of questions: does it live on this node, is
# it a template, is it running, what is it called.
#
# The type names are Proxmox' own, the ones in /cluster/resources and in the API
# paths (/nodes/{node}/lxc/{vmid}, /nodes/{node}/qemu/{vmid}). They are also the
# prefix of every file stored for a target (lxc-101.conf, qemu-200.conf), so they
# are not to be renamed: a renamed type is a target whose script, history and
# logs are all suddenly somewhere else.
#
# A vmid is unique across the cluster and across both kinds, which is what lets
# the API and the schedule keep a plain list of numbers: which kind a number is
# can always be asked of the node that owns it.

use strict;
use warnings;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Helpers;

our @TYPES = ('lxc', 'qemu');

my %LABEL = (lxc => 'CT', qemu => 'VM');
my %NOUN = (lxc => 'container', qemu => 'VM');
my %CLASS = (lxc => 'PVE::LXC::Config', qemu => 'PVE::QemuConfig');

sub is_guest_type {
    my ($type) = @_;

    return defined($type) && exists($CLASS{$type}) ? 1 : 0;
}

# 'CT' / 'VM' - what the Proxmox interface itself calls them in a short label.
sub label {
    my ($type) = @_;

    return $LABEL{$type // ''} // 'CT';
}

# 'container' / 'VM' - for sentences.
sub noun {
    my ($type) = @_;

    return $NOUN{$type // ''} // 'container';
}

sub _class {
    my ($type) = @_;

    my $class = $CLASS{$type // ''} or die "unknown guest type '" . ($type // '') . "'\n";

    return $class;
}

# Dies when the guest has no config on THIS node, exactly like the PVE call it
# wraps - that is how a guest that has migrated away is told apart from one that
# is switched off.
sub load_config {
    my ($type, $vmid) = @_;

    return _class($type)->load_config($vmid);
}

sub is_template {
    my ($type, $conf) = @_;

    return _class($type)->is_template($conf) ? 1 : 0;
}

# Asked of the process table, not of a config: both calls look at the pid or the
# cgroup this node has, and neither dies for a guest that is merely stopped.
sub is_running {
    my ($type, $vmid) = @_;

    if ($type eq 'qemu') {
        return PVE::QemuServer::Helpers::vm_running_locally($vmid) ? 1 : 0;
    }

    return PVE::LXC::check_running($vmid) ? 1 : 0;
}

# What the guest is called: a container's hostname, a VM's name - the same field
# the resource tree shows.
sub name {
    my ($type, $conf, $vmid) = @_;

    $conf //= {};
    my $name = $type eq 'qemu' ? $conf->{name} : $conf->{hostname};

    return $name // label($type) . $vmid;
}

# Every guest of one kind that has its config on this node, as vmid => {}.
sub config_list {
    my ($type) = @_;

    return $type eq 'qemu' ? PVE::QemuServer::config_list() : PVE::LXC::config_list();
}

# Which kind a vmid is ON THIS NODE, or undef when it is neither here.
#
# Containers are asked first only because they were the only kind before VMs
# were supported; since a vmid is unique across both, the order cannot change
# the answer.
sub type_of {
    my ($vmid) = @_;

    for my $type (@TYPES) {
        return $type if eval { load_config($type, $vmid); 1 };
    }

    return undef;
}

# The target a vmid stands for in a run. A vmid that is not on this node stays
# a container target, which is what it always was: the job then reports it as
# "not a guest on this node" for that one row instead of the request failing for
# every target in it.
sub target {
    my ($vmid) = @_;

    my $type = type_of($vmid) // 'lxc';
    my $conf = eval { load_config($type, $vmid) };

    return { type => $type, id => "$vmid", name => ($conf ? name($type, $conf, $vmid) : undef) };
}

# Whether a VM's options switch the guest agent on. Read off the property string
# rather than through PVE::QemuServer::Agent, whose parser warns into the task
# log on anything it does not like: `agent: 1`, `agent: enabled=1,fstrim...` and
# `agent: 0` are the shapes PVE writes.
sub agent_enabled {
    my ($conf) = @_;

    my $value = ($conf // {})->{agent};
    return 0 if !defined($value);

    for my $part (split(/,/, $value)) {
        return ($1 ? 1 : 0) if $part =~ m/\A(?:enabled=)?([01])\z/;
    }

    return 0;
}

1;
