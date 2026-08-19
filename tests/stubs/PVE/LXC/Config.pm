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

# The vmid is stamped into the config the real one does not carry, so the
# has_feature stub below can tell which container it is being asked about - the
# real has_feature gets that from the volumes it walks, which a stub has none of.
sub load_config {
    my ($class, $vmid) = @_;

    my $conf = $CONFIGS{$vmid} ||= {};
    $conf->{vmid} = $vmid;

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
