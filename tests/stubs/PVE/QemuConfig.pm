package PVE::QemuConfig;

# Test stub. The VM counterpart of the PVE::LXC::Config stub, as far as the
# addon asks: does the config exist on this node, is it a template, its lock,
# and its snapshots.

use strict;
use warnings;

our %CONFIGS;

sub load_config {
    my ($class, $vmid) = @_;

    die "Configuration file 'nodes/pve-test/qemu-server/$vmid.conf' does not exist\n"
        if !exists($CONFIGS{$vmid});

    my $conf = $CONFIGS{$vmid};
    $conf->{vmid} = $vmid;

    # The same trick as in the container stub: a snapshot carries its vmid so
    # foreach_volume on it knows which disk to name.
    $_->{vmid} = $vmid for values %{ $conf->{snapshots} // {} };

    return $conf;
}

our $CONFIG_DIR = '/nonexistent';

sub config_file {
    my ($class, $vmid) = @_;

    return "$CONFIG_DIR/$vmid.conf";
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

# ── volumes and snapshots ───────────────────────────────────────────────────
#
# One disk on a storage and one CD-ROM, in the shapes QemuConfig's own
# parse_volume hands out: a drive keeps its volume under 'file', and a CD-ROM
# says so with media=cdrom. The CD-ROM is there so a test can see it is never
# handed to a storage plugin.

our $STORAGE = 'teststore';

sub volid_of {
    my ($vmid) = @_;

    return "$STORAGE:vm-$vmid-disk-0";
}

sub foreach_volume {
    my ($class, $conf, $func, @param) = @_;

    my $vmid = $conf->{vmid};
    return if !defined($vmid);

    $func->('scsi0', { file => volid_of($vmid) }, @param);
    $func->('ide2', { file => 'local:iso/installer.iso', media => 'cdrom' }, @param);

    return;
}

# What has_feature answers, per vmid. Undef means "yes".
our %NO_SNAPSHOT;

# What the last has_feature call was told about the VM running - QemuConfig hands
# that on to the storage, so the caller has to give the true answer.
our @FEATURE_CALLS;

our $SNAPSHOT_DIE;
our $SNAPTIME = 1000;

# Every snapshot_create call, with its $save_vmstate - the addon promises a VM
# snapshot without memory, and this is where a test can see that it kept it.
our @CREATE_CALLS;

sub has_feature {
    my ($class, $feature, $conf, $storecfg, $snapname, $running) = @_;

    push @FEATURE_CALLS, { vmid => $conf->{vmid}, feature => $feature, running => $running };

    return 0 if $feature ne 'snapshot';

    my $vmid = $conf->{vmid};

    return (defined($vmid) && $NO_SNAPSHOT{$vmid}) ? 0 : 1;
}

sub snapshot_create {
    my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;

    push @CREATE_CALLS, { vmid => $vmid, name => $snapname, vmstate => $save_vmstate };

    die "$SNAPSHOT_DIE\n" if defined($SNAPSHOT_DIE);
    die "snapshot '$snapname' already exists\n"
        if $CONFIGS{$vmid}->{snapshots}->{$snapname};

    $CONFIGS{$vmid}->{snapshots}->{$snapname} = {
        snaptime => $SNAPTIME++,
        description => $comment,
    };

    return;
}

our $ROLLBACK_DIE;

# Faithful to the real one in the ways that decide the caller's code: every
# volume is asked first, it refuses while a lock is set, and for a snapshot
# without memory it STOPS the VM and leaves it stopped
# (__snapshot_rollback_vm_stop, and no __snapshot_rollback_vm_start).
sub snapshot_rollback {
    my ($class, $vmid, $snapname) = @_;

    die "$ROLLBACK_DIE\n" if defined($ROLLBACK_DIE);
    die "snapshot '$snapname' does not exist\n"
        if !$CONFIGS{$vmid}->{snapshots}->{$snapname};

    my $conf = $class->load_config($vmid);
    $class->foreach_volume(
        $conf->{snapshots}->{$snapname},
        sub {
            my ($key, $drive) = @_;

            return if ($drive->{media} // '') eq 'cdrom';
            PVE::Storage::volume_rollback_is_possible($PVE::Storage::CONFIG, $drive->{file}, $snapname);
        },
    );

    die "VM is locked ($conf->{lock})\n" if $conf->{lock};

    $PVE::QemuServer::Helpers::RUNNING{$vmid} = 0;
    $CONFIGS{$vmid}->{rolled_back_to} = $snapname;

    return;
}

our %DELETE_DIE;

sub snapshot_delete {
    my ($class, $vmid, $snapname, $force) = @_;

    die "snapshot '$snapname' does not exist\n"
        if !$CONFIGS{$vmid}->{snapshots}->{$snapname};

    # The lock and `snapstate: delete` go in before the volume is touched, as in
    # the real one - see the container stub.
    $class->set_lock($vmid, 'snapshot-delete');
    $CONFIGS{$vmid}->{snapshots}->{$snapname}->{snapstate} = 'delete';

    die "$DELETE_DIE{$snapname}\n" if defined($DELETE_DIE{$snapname}) && !$force;

    delete $CONFIGS{$vmid}->{snapshots}->{$snapname};
    delete $CONFIGS{$vmid}->{lock};

    return;
}

1;
