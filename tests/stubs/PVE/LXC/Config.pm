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

sub load_config { my ($class, $vmid) = @_; return $CONFIGS{$vmid} || {}; }

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
    delete $LOCKS{$vmid};

    return;
}

1;
