#!/usr/bin/perl
# A rollback point before the update, and what happens to the old ones.
#
# This is the setting that is ON by default, so the questions worth pinning are
# the ones about restraint: that it never touches a snapshot somebody else made,
# that it does nothing at all where the storage cannot snapshot, and that when
# it does fire, it fires BEFORE the update rather than around it.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 68;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Storage;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Runner;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# Same trick job.t uses: a worker writes with print, because inside a Proxmox
# worker STDOUT is the task log.
sub capture {
    my ($code) = @_;

    my $out = '';
    open(my $saved, '>&', \*STDOUT) or die "cannot dup STDOUT - $!";
    close(STDOUT);
    open(STDOUT, '>', \$out) or die "cannot redirect STDOUT - $!";

    my $err;
    eval {
        $code->();
        1;
    } or do {
        $err = $@;
    };

    close(STDOUT);
    open(STDOUT, '>&', $saved) or die "cannot restore STDOUT - $!";
    close($saved);

    return ($out, $err);
}

sub snapshots_of {
    my ($vmid) = @_;
    return [sort keys %{ $PVE::LXC::Config::CONFIGS{$vmid}->{snapshots} // {} }];
}

sub run {
    my ($target, $opts) = @_;

    return capture(
        sub { PVE::UpdateManager::Job::run_all([$target], 60, $opts) },
    );
}

PVE::UpdateManager::Config::save_script('lxc', 101, "#!/bin/bash\napt-get update\n");
PVE::UpdateManager::Config::save_script('lxc', 102, "apt-get update\n");
PVE::UpdateManager::Config::save_script('node', 'pve-test', "apt-get update\n");
$PVE::LXC::RUNNING{101} = 4711;
$PVE::LXC::RUNNING{102} = undef;

my $ON = { snapshot_before => 1, snapshot_keep => 3 };

# ── the name ────────────────────────────────────────────────────────────────
{
    my $name = PVE::UpdateManager::Runner::snapshot_name(1786817167);

    # PVE's pve-configid format, which is what a snapshot name has to satisfy:
    # a letter first, then letters, digits, underscores and dashes, at most 40.
    like($name, qr/\A[a-z][a-z0-9_-]+\z/i, 'the name is a valid Proxmox config id');
    cmp_ok(length($name), '<=', 40, 'and fits the 40 character limit');
    like($name, qr/\Aupdmgr-\d{8}-\d{6}\z/, 'and says who made it and when');

    ok(PVE::UpdateManager::Runner::is_our_snapshot($name), 'we recognise our own');
    ok(
        !PVE::UpdateManager::Runner::is_our_snapshot('before-the-upgrade'),
        'a snapshot somebody took by hand is not ours',
    );
    ok(
        !PVE::UpdateManager::Runner::is_our_snapshot('updmgr'),
        'and neither is a name that only starts like ours',
    );
    ok(
        !PVE::UpdateManager::Runner::is_our_snapshot('updmgr-2026-08-19'),
        'nor one that merely looks similar',
    );
}

# ── can this container be snapshotted at all ────────────────────────────────
{
    is(PVE::UpdateManager::Runner::can_snapshot(101), 1, 'a normal container can');

    local $PVE::LXC::Config::NO_SNAPSHOT{101} = 1;
    is(
        PVE::UpdateManager::Runner::can_snapshot(101),
        0,
        'and one whose storage says no, cannot',
    );
}
{
    # Called while building a settings dialog, so it may not die on anything.
    is(PVE::UpdateManager::Runner::can_snapshot('not-a-vmid'), 0, 'a bad id is a no, not a death');
}

# ── a run that takes one ────────────────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    # What the world looked like at the moment the update command ran.
    my $during;
    local $PVE::Tools::RUN_HOOK = sub { $during = snapshots_of(101) };

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'nextcloud' }, $ON);

    ok(!defined($err), 'the run succeeds');
    is(scalar(@{ snapshots_of(101) }), 1, 'exactly one snapshot was taken');
    is(
        scalar(@$during),
        1,
        'and it already existed when the update command ran - it is a rollback point,'
            . ' not a record of what happened',
    );
    like($out, qr/taking snapshot updmgr-\d{8}-\d{6} before the update/, 'the log names it');

    my $state = PVE::UpdateManager::Config::load_state('lxc', 101);
    ok(
        !defined($state->{note}),
        'a run that worked leaves no note - the green tick already says everything',
    );
}

# ── and one that does not ───────────────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out) = run({ type => 'lxc', id => 101 }, { snapshot_before => 0, snapshot_keep => 3 });

    is_deeply(snapshots_of(101), [], 'switched off, nothing is snapshotted');
    unlike($out, qr/snapshot/, 'and nothing about snapshots is said either');
    is(scalar(@PVE::Tools::RUN_CALLS), 1, 'the update still ran');
}

# ── a storage that cannot ───────────────────────────────────────────────────
#
# The instruction is explicit: where the system does not support it, behave
# exactly as before. Not a refusal, not a failure - an update.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::Config::NO_SNAPSHOT{101} = 1;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = run({ type => 'lxc', id => 101 }, $ON);

    ok(!defined($err), 'the container is updated anyway');
    is(scalar(@PVE::Tools::RUN_CALLS), 1, 'the update command really ran');
    is_deeply(snapshots_of(101), [], 'with no snapshot');
    like($out, qr/cannot snapshot - updating without one/, 'and the log says why');
}

# ── a storage that can, and then does not ───────────────────────────────────
#
# A different case entirely: the safety net was promised and is missing. The one
# that produces this is a full thin pool, which is the worst moment to walk into
# a dist-upgrade.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::Config::SNAPSHOT_DIE = 'no space left on device';
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = run({ type => 'lxc', id => 101 }, $ON);

    ok(defined($err), 'the task goes red');
    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'and the update never started');
    like($out, qr/FAILED .*could not be snapshotted/, 'the summary says which of the two it was');

    my $state = PVE::UpdateManager::Config::load_state('lxc', 101);
    is($state->{state}, 'failed', 'the row is failed, not skipped');
    like($state->{note}, qr/no space left on device/, 'and carries the reason');

    # The config lock is taken after the snapshot, so this early exit must not
    # have left one behind - a container nobody can stop is a worse outcome than
    # a container nobody snapshotted.
    ok(!$PVE::LXC::Config::LOCKS{101}, 'and no update lock was left on the container');
}

# ── a stopped container that gets started for its update ────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{102}->{snapshots};

    # The first thing pct is asked to do, so the test can say whether the
    # snapshot came before the container was started.
    my $first_pct;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        $first_pct //= { cmd => join(' ', @$cmd), snapshots => scalar(@{ snapshots_of(102) }) };
    };

    my ($out, $err) = run(
        { type => 'lxc', id => 102, name => 'stopped-one' },
        { %$ON, start_stopped => 1 },
    );

    ok(!defined($err), 'it is started, updated and put back');
    is(scalar(@{ snapshots_of(102) }), 1, 'and it was snapshotted');
    like($first_pct->{cmd}, qr/pct start 102/, 'the first thing pct did was start it');
    is(
        $first_pct->{snapshots},
        1,
        'so the snapshot is of the stopped container - the state somebody left it in',
    );
}

# ── the host is never snapshotted ───────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    my ($out, $err) = run({ type => 'node', id => 'pve-test', name => 'pve-test' }, $ON);

    ok(!defined($err), 'the host still updates');
    unlike($out, qr/snapshot/, 'and nothing tries to snapshot a machine');
}

# ── keeping the newest, and only ours ───────────────────────────────────────
{
    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100 },
        'updmgr-20260102-000000' => { snaptime => 200 },
        'updmgr-20260103-000000' => { snaptime => 300 },
        'before-migration' => { snaptime => 50 },
        'daily' => { snaptime => 400 },
    };

    my $removed = PVE::UpdateManager::Runner::prune_snapshots(101, 2, undef);

    is($removed, 1, 'one too many, one removed');
    is_deeply(
        snapshots_of(101),
        ['before-migration', 'daily', 'updmgr-20260102-000000', 'updmgr-20260103-000000'],
        'the oldest of OURS goes and everybody else is left alone',
    );

    is(PVE::UpdateManager::Runner::prune_snapshots(101, 5, undef), 0, 'under the limit, nothing goes');

    # keep=0 would delete the snapshot the run just took, which is the opposite
    # of the point. The floor is enforced here as well as in the settings, since
    # this is callable on its own.
    PVE::UpdateManager::Runner::prune_snapshots(101, 0, undef);
    is(scalar(@{ snapshots_of(101) }), 3, 'and asking for none still keeps one of ours');
}

# The names carry LOCAL time, so one hour a year they sort in the wrong order.
# What decides is the snaptime PVE records, which does not.
{
    $PVE::LXC::Config::CONFIGS{103}->{snapshots} = {
        # The name says later, the clock says earlier: the hour after a DST
        # change back, written out.
        'updmgr-20261025-023000' => { snaptime => 100 },
        'updmgr-20261025-013000' => { snaptime => 200 },
    };

    PVE::UpdateManager::Runner::prune_snapshots(103, 1, undef);

    is_deeply(
        snapshots_of(103),
        ['updmgr-20261025-013000'],
        'the one that was really taken later survives, whatever its name sorts as',
    );
}

# ── pruning happens after the update, not before ────────────────────────────
#
# The other way round would leave a container mid-upgrade with one fewer
# rollback point than it had a moment earlier, for no gain at all.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100 },
        'updmgr-20260102-000000' => { snaptime => 200 },
    };

    my $during;
    local $PVE::Tools::RUN_HOOK = sub { $during //= scalar(@{ snapshots_of(101) }) };

    my ($out) = run({ type => 'lxc', id => 101 }, { snapshot_before => 1, snapshot_keep => 2 });

    is($during, 3, 'all three existed while the update was running');
    is(scalar(@{ snapshots_of(101) }), 2, 'and the oldest was dropped afterwards');
    like($out, qr/removing old update snapshot updmgr-20260101-000000/, 'the log says which');
}

# ── the row names the snapshot when it is going to be needed ────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = run({ type => 'lxc', id => 101 }, $ON);

    ok(defined($err), 'a failed update fails the task');

    my $state = PVE::UpdateManager::Config::load_state('lxc', 101);
    like(
        $state->{note},
        qr/snapshot updmgr-\d{8}-\d{6}/,
        'and the row says which snapshot to go back to',
    );
}

# ── the options every run is given ──────────────────────────────────────────
#
# Three callers build these - the node's run endpoint, a container's, and the
# timer - and this is the function all three go through. An option that exists
# in the settings and not here is a scheduled run that quietly behaves
# differently from the manual one somebody tested with.
{
    my $opts = PVE::UpdateManager::Config::run_opts(
        PVE::UpdateManager::Config::default_settings(),
    );

    is_deeply(
        [sort keys %$opts],
        ['snapshot_before', 'snapshot_keep', 'start_stopped'],
        'every setting a run acts on is carried into it',
    );
    is($opts->{snapshot_before}, 1, 'and snapshots before an update are on by default');
    is($opts->{snapshot_keep}, 3, 'keeping the last few of them');
    is($opts->{start_stopped}, 0, 'while starting a stopped container is still not');
}

# ── a container somebody else has locked ────────────────────────────────────
#
# The case that made this a bug rather than a detail: a nightly backup holds the
# container's lock through the update window, so the run is skipped - every
# single night. Snapshotting first would leave one snapshot per attempt behind,
# and the pruning could not clear them either, because removing a snapshot takes
# a config lock too and that is exactly what is not available.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    local $PVE::LXC::Config::LOCKS{101} = 'backup';

    my ($out, $err) = run({ type => 'lxc', id => 101 }, $ON);

    ok(!defined($err), 'a locked container is skipped, not failed');
    is_deeply(snapshots_of(101), [], 'and nothing was snapshotted for a run that never happened');
    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'nor did anything run inside it');
    like($out, qr/SKIPPED \(another task holds the lock \(backup\)\)/, 'the log names the lock');
}

# The pre-check above is a check-then-act: the lock can still be taken in the
# gap before this run takes its own. Then the snapshot HAS been made and the
# target is skipped anyway - so the pruning has to happen on that way out too,
# or snapshot_keep would quietly mean nothing for that container.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100 },
        'updmgr-20260102-000000' => { snaptime => 200 },
    };
    # Not a lock in the config - so the pre-check lets this through - but
    # set_lock refuses, which is what happens when the two race.
    local $PVE::LXC::Config::SET_LOCK_DIE = 'CT is locked (backup)';

    my ($out, $err) = run({ type => 'lxc', id => 101 }, { snapshot_before => 1, snapshot_keep => 2 });

    ok(!defined($err), 'the run is still a skip');
    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'and nothing ran');
    # Pruning is attempted on this way out too - but removing a snapshot takes a
    # lock of its own, so while somebody else holds the container nothing can be
    # removed. Leaving all three is the right outcome: the alternative is taking
    # a backup's lock off behind its back.
    is(
        scalar(@{ snapshots_of(101) }),
        3,
        'the snapshot it had already taken stays while somebody else holds the container',
    );
}

# Same on the other early way out: the container was asked to be started and
# would not.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;

    $PVE::LXC::Config::CONFIGS{102}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100 },
        'updmgr-20260102-000000' => { snaptime => 200 },
    };
    # `pct start` fails, everything else would have worked.
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return ($cmd->[1] // '') eq 'start' ? 1 : 0;
    };

    my ($out, $err) = run(
        { type => 'lxc', id => 102 },
        { snapshot_before => 1, snapshot_keep => 2, start_stopped => 1 },
    );

    ok(defined($err), 'a container that will not start fails the task');
    is(
        scalar(@{ snapshots_of(102) }),
        2,
        'and that way out prunes too',
    );
}

# ── a removal that fails must not leave the container locked ────────────────
#
# Issue #14. PVE's snapshot_delete locks the container and writes
# `snapstate: delete` into the snapshot BEFORE it asks the storage to remove the
# volume. When that removal fails it dies with both still in place and nothing
# ever clears them: the container is locked from then on, so its next update,
# its next backup and its next start all refuse, and the web interface shows the
# snapshot stuck in state "delete".
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::Config::LOCKS = ();

    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100 },
        'updmgr-20260102-000000' => { snaptime => 200 },
    };
    local %PVE::LXC::Config::DELETE_DIE = (
        'updmgr-20260101-000000' => 'lvremove failed: Logical volume in use',
    );

    my ($out) = run({ type => 'lxc', id => 101 }, { snapshot_before => 1, snapshot_keep => 2 });

    is($PVE::LXC::Config::LOCKS{101}, undef, 'the container is not left locked by a failed removal');
    my $left = snapshots_of(101);
    is(scalar(@$left), 2, 'two snapshots are left, which is the retention count');
    ok(
        !grep({ $_ eq 'updmgr-20260101-000000' } @$left),
        'and the half-deleted one is forced out of the config rather than left in it',
    );
    like($out, qr/could not remove the old snapshot updmgr-20260101-000000/, 'the reason is logged');
    like($out, qr/forcing it out of the config/, 'and so is the repair');
    like($out, qr/volume may still be on the storage/, 'including that the volume may survive it');
}

# The same failure where even the forced removal will not go through. The
# snapshot stays, but the container must still come out usable, and the row has
# to say so - a run that reports success while the guest is locked is the worst
# of the outcomes.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::Config::LOCKS = ();

    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100 },
        'updmgr-20260102-000000' => { snaptime => 200 },
    };
    local %PVE::LXC::Config::DELETE_DIE = (
        'updmgr-20260101-000000' => 'lvremove failed: Logical volume in use',
    );
    local $PVE::LXC::Config::DELETE_DIE_FORCE = 1;

    run({ type => 'lxc', id => 101 }, { snapshot_before => 1, snapshot_keep => 2 });

    is($PVE::LXC::Config::LOCKS{101}, undef, 'the container is unlocked even when the force fails');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note} // '',
        qr/1 snapshot could NOT be removed/,
        'and the row says a snapshot is stuck instead of reporting a clean run',
    );
}

# A lock that is not ours is not ours to remove. A container being backed up
# while its snapshot cannot be deleted must come out of this still locked by the
# backup.
{
    local %PVE::LXC::Config::LOCKS = (101 => 'backup');
    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260101-000000' => { snaptime => 100, snapstate => 'delete' },
    };
    my @log;

    my $repaired = PVE::UpdateManager::Runner::_repair_stuck_delete(
        101, 'updmgr-20260101-000000', sub { push @log, $_[0] });

    is($PVE::LXC::Config::LOCKS{101}, 'backup', "somebody else's lock is left alone");
    ok(!$repaired, 'so the half-deleted snapshot is reported as stuck instead of forced');
    like(join("\n", @log), qr/not ours to remove/, 'and the log says why nothing was done');
}
