package PVE::Storage;

# Test stub. Two things only: the snapshot capability check reads config(), and
# the rollback path asks which snapshots stand between a volume and a rollback.
#
# The real storage.cfg is never read here - PVE::LXC::Config's stub decides
# whether a container can be snapshotted, which is the decision those tests are
# about. What this file does model faithfully is the refusal a storage answers a
# rollback with, because that refusal is the whole subject of the blocker tests:
# ZFS, classic LVM and qcow2 chains list every snapshot newer than the one being
# rolled back to and die, and there is no force to pass on.

use strict;
use warnings;

our $CONFIG = { ids => {} };

sub config { return $CONFIG; }

# Snapshots that exist on the storage and NOT in the container's config, keyed
# by volume id: { 'teststore:subvol-101-disk-0' => [ { name => ..., snaptime => ... } ] }.
#
# That combination is not exotic, it is what a tool calling `zfs snapshot`
# directly leaves behind - and it is the case a config-only model would miss,
# because snapshot_delete cannot remove one of those.
our %STORAGE_ONLY;

# Which volume snapshots refuse to be removed, keyed by name, so a test can take
# the path where the storage says no to the removal as well.
our %DELETE_DIE;

# Every snapshot on a volume, oldest first - the container's own, from the
# config, plus the ones somebody took behind PVE's back. Reading the other stub
# rather than keeping a second list is deliberate: the tests write snapshots
# straight into %CONFIGS, and a list that had to be kept in step with that would
# be wrong in exactly the tests that matter.
sub _snapshot_list {
    my ($volid) = @_;

    my ($vmid) = $volid =~ m/subvol-(\d+)-disk/;
    return [] if !defined($vmid);

    my $snapshots = $PVE::LXC::Config::CONFIGS{$vmid}->{snapshots} // {};

    my @all = map { { name => $_, snaptime => $snapshots->{$_}->{snaptime} // 0 } }
        keys %$snapshots;
    push @all, @{ $STORAGE_ONLY{$volid} // [] };

    return [sort { $a->{snaptime} <=> $b->{snaptime} or $a->{name} cmp $b->{name} } @all];
}

# Mirrors ZFSPoolPlugin::volume_rollback_is_possible on pve-manager 9.2.4,
# including the part its caller depends on: the list of blockers is filled in
# BEFORE it dies, which is the only way to learn what is in the way.
sub volume_rollback_is_possible {
    my ($cfg, $volid, $snap, $blockers) = @_;

    $blockers //= [];

    my $found;
    for my $entry (@{ _snapshot_list($volid) }) {
        if ($entry->{name} eq $snap) {
            $found = 1;
        } elsif ($found) {
            push @$blockers, $entry->{name};
        }
    }

    die "can't rollback, snapshot '$snap' does not exist on '$volid'\n" if !$found;

    die "can't rollback, '$snap' is not most recent snapshot on '$volid'\n"
        if scalar(@$blockers);

    return 1;
}

sub volume_snapshot_delete {
    my ($cfg, $volid, $snap) = @_;

    die "$DELETE_DIE{$snap}\n" if defined($DELETE_DIE{$snap});

    my $list = $STORAGE_ONLY{$volid} // [];
    my $before = scalar(@$list);
    $STORAGE_ONLY{$volid} = [grep { $_->{name} ne $snap } @$list];

    die "volume snapshot '$snap' does not exist on '$volid'\n"
        if scalar(@{ $STORAGE_ONLY{$volid} }) == $before;

    return;
}

1;
