package PVE::QemuConfig;

# Test stub. The VM counterpart of the PVE::LXC::Config stub, as far as the
# addon asks: does the config exist on this node, and is it a template.

use strict;
use warnings;

our %CONFIGS;

sub load_config {
    my ($class, $vmid) = @_;

    die "Configuration file 'nodes/pve-test/qemu-server/$vmid.conf' does not exist\n"
        if !exists($CONFIGS{$vmid});

    my $conf = $CONFIGS{$vmid};
    $conf->{vmid} = $vmid;

    return $conf;
}

# The real ones, from PVE::AbstractConfig: the lock lives IN the config, so
# anything reading it sees it; set_lock refuses when any lock is set, and
# remove_lock refuses a lock that is not the one named.
sub set_lock {
    my ($class, $vmid, $lock) = @_;

    my $conf = $class->load_config($vmid);
    die "VM is locked ($conf->{lock})\n" if $conf->{lock};
    $conf->{lock} = $lock;

    return $lock;
}

sub remove_lock {
    my ($class, $vmid, $lock) = @_;

    my $conf = $class->load_config($vmid);
    die "no lock found trying to remove '$lock' lock\n" if !$conf->{lock};
    die "found lock '$conf->{lock}' trying to remove '$lock' lock\n"
        if defined($lock) && $conf->{lock} ne $lock;
    delete $conf->{lock};

    return;
}

# The real one, from PVE::AbstractConfig.
sub is_template {
    my ($class, $conf) = @_;

    return 1 if defined($conf->{template}) && $conf->{template} == 1;

    return 0;
}

1;
