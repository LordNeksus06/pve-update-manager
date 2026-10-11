package PVE::LXC::Config;

# Test stub.

use strict;
use warnings;

our %CONFIGS;

# Which guests are locked, so a test can check that a lock is taken for the
# duration of an update and given back afterwards - and that a guest somebody
# else has locked is left alone.
our %LOCKS;
our $SET_LOCK_DIE;

# Which vmids this node has no config for. The real load_config dies there, and
# that is how a container that has been migrated away - or a vmid that names a
# VM - is told apart from one that is simply switched off.
our %NO_CONFIG;

# The vmid is stamped into the config the real one does not carry, so the
# has_feature stub below can tell which container it is being asked about - the
# real has_feature gets that from the volumes it walks, which a stub has none of.
sub load_config {
    my ($class, $vmid) = @_;

    die "Configuration file 'nodes/pve-test/lxc/$vmid.conf' does not exist\n"
        if $NO_CONFIG{$vmid};

    my $conf = $CONFIGS{$vmid} ||= {};
    $conf->{vmid} = $vmid;

    # The same trick, for the same reason, one level down: the real snapshot
    # config carries its own rootfs line, so foreach_volume on a SNAPSHOT knows
    # which volume to ask the storage about. Here that volume is derived from
    # the vmid - see volid_of - and the snapshots have to carry it too, because
    # the tests write them straight into %CONFIGS without going through
    # snapshot_create.
    $_->{vmid} = $vmid for values %{ $conf->{snapshots} // {} };

    # The real set_lock writes the lock INTO the config, so anything reading a
    # container's config sees it. Mirroring that here is what lets a test cover
    # the code that checks for somebody else's lock before touching the guest.
    if (defined($LOCKS{$vmid})) {
        $conf->{lock} = $LOCKS{$vmid};
    } else {
        delete $conf->{lock};
    }

    return $conf;
}

# The real one, from PVE::AbstractConfig: a template is `template: 1` in the
# config, and nothing else counts as one.
sub is_template {
    my ($class, $conf) = @_;

    return 1 if defined($conf->{template}) && $conf->{template} == 1;

    return 0;
}

# Where the stub pretends the container configs live. The real config_file
# returns a path under /etc/pve, and its mtime is what tells an abandoned
# snapshot removal from one that is still running - so a test needs a real file
# whose mtime it can set.
our $CONFIG_DIR = '/nonexistent';

sub config_file {
    my ($class, $vmid) = @_;

    return "$CONFIG_DIR/$vmid.conf";
}

sub set_lock {
    my ($class, $vmid, $lock) = @_;

    die "$SET_LOCK_DIE\n" if defined($SET_LOCK_DIE);
    # The real one refuses rather than overwriting somebody else's lock.
    die "CT is locked ($LOCKS{$vmid})\n" if $LOCKS{$vmid};

    $LOCKS{$vmid} = $lock;

    return $lock;
}

sub remove_lock {
    my ($class, $vmid, $lock) = @_;

    die "no lock to remove\n" if !$LOCKS{$vmid};
    # The real one refuses to remove a lock that is not the one asked for, which
    # is what keeps a repair from taking somebody else's lock off.
    die "found lock '$LOCKS{$vmid}' trying to remove '$lock' lock\n"
        if defined($lock) && $LOCKS{$vmid} ne $lock;
    delete $LOCKS{$vmid};

    return;
}

# The volume a stubbed container has, and the only one. The real one is parsed
# out of the rootfs line of whatever config is being walked; what the tests are
# about is which snapshot blocks a rollback, not how a mountpoint string parses.
our $STORAGE = 'teststore';

sub volid_of {
    my ($vmid) = @_;

    return "$STORAGE:subvol-$vmid-disk-0";
}

# Real enough for the one caller that matters: it hands out ('rootfs', a
# mountpoint hash with a type and a volume), and the type is what PVE's own
# storage code filters on so a bind mount is never handed to a storage plugin.
sub foreach_volume {
    my ($class, $conf, $func, @param) = @_;

    my $vmid = $conf->{vmid};
    return if !defined($vmid);

    $func->('rootfs', { type => 'volume', volume => volid_of($vmid) }, @param);

    return;
}

# ── snapshots ───────────────────────────────────────────────────────────────
#
# Real enough to test the pruning against: the snapshots live in %CONFIGS, the
# way the real ones live in the container's config, so a test can create three
# and check which two survive.

# What has_feature answers, per vmid. Undef means "yes" - most tests are not
# about a storage that cannot snapshot.
our %NO_SNAPSHOT;

# Lets a test take the path where the storage says yes and the snapshot still
# fails, which is a different outcome from "not supported".
our $SNAPSHOT_DIE;

# The clock the stub stamps snaptime with, so a test can create snapshots in a
# known order without sleeping.
our $SNAPTIME = 1000;

sub has_feature {
    my ($class, $feature, $conf, $storecfg, $snapname, $running) = @_;

    return 0 if $feature ne 'snapshot';

    my $vmid = $conf->{vmid};

    return (defined($vmid) && $NO_SNAPSHOT{$vmid}) ? 0 : 1;
}

sub snapshot_create {
    my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;

    die "$SNAPSHOT_DIE\n" if defined($SNAPSHOT_DIE);
    die "snapshot '$snapname' already exists\n"
        if $CONFIGS{$vmid}->{snapshots}->{$snapname};

    $CONFIGS{$vmid}->{snapshots}->{$snapname} = {
        snaptime => $SNAPTIME++,
        description => $comment,
    };

    return;
}

# Lets a test take the path where the rollback itself fails.
our $ROLLBACK_DIE;

# Faithful to the real one in the two ways that decide the caller's code: it
# refuses while a lock is set, and it STOPS the container and leaves it stopped.
sub snapshot_rollback {
    my ($class, $vmid, $snapname) = @_;

    die "$ROLLBACK_DIE\n" if defined($ROLLBACK_DIE);
    die "snapshot '$snapname' does not exist\n"
        if !$CONFIGS{$vmid}->{snapshots}->{$snapname};

    # Before the lock check and before anything is stopped, which is the order
    # AbstractConfig works in and the reason a refused rollback leaves the
    # container exactly as it was: every volume is asked first.
    my $conf = $class->load_config($vmid);
    $class->foreach_volume(
        $conf->{snapshots}->{$snapname},
        sub {
            my ($ms, $mountpoint) = @_;

            PVE::Storage::volume_rollback_is_possible(
                $PVE::Storage::CONFIG, $mountpoint->{volume}, $snapname,
            );
        },
    );

    die "CT is locked ($LOCKS{$vmid})\n" if $LOCKS{$vmid};

    $PVE::LXC::RUNNING{$vmid} = undef;
    $CONFIGS{$vmid}->{rolled_back_to} = $snapname;

    return;
}

# Which snapshots the storage refuses to remove the volume of, keyed by name.
# The real failure this models is an lvremove or zfs destroy that fails while
# the container's config has already been marked - see the comment below.
our %DELETE_DIE;

# And whether even a forced removal fails, which is the case where the config
# cannot be cleaned up at all and only the lock can be given back.
our $DELETE_DIE_FORCE;

sub snapshot_delete {
    my ($class, $vmid, $snapname, $force) = @_;

    die "snapshot '$snapname' does not exist\n"
        if !$CONFIGS{$vmid}->{snapshots}->{$snapname};

    # Faithful to the order the real one works in, because that order is the
    # whole bug: the lock and `snapstate: delete` are written BEFORE the volume
    # is touched, so a storage failure leaves both behind and the container
    # locked. set_lock refuses while any lock is set, force or not.
    $class->set_lock($vmid, 'snapshot-delete');
    $CONFIGS{$vmid}->{snapshots}->{$snapname}->{snapstate} = 'delete';

    if (defined($DELETE_DIE{$snapname}) && (!$force || $DELETE_DIE_FORCE)) {
        die "$DELETE_DIE{$snapname}\n";
    }

    delete $CONFIGS{$vmid}->{snapshots}->{$snapname};
    delete $LOCKS{$vmid};

    return;
}

1;
