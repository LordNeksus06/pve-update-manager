#!/usr/bin/perl
# Container snapshots, second half: the cold snapshot, two runs inside one
# second, our own lock left behind by a killed worker, rolling a failed update
# back, and a rollback the storage refuses because something newer is in the way.
#
# Split from snapshot.t (#21), which had grown past the 1000-line ceiling. The
# setup above the first section is the same in both files, and so is the reason:
#
# This is the setting that is ON by default, so the questions worth pinning are
# the ones about restraint: that it never touches a snapshot somebody else made,
# that it does nothing at all where the storage cannot snapshot, and that when
# it does fire, it fires BEFORE the update rather than around it.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 102;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Storage;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Target;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Settings;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
# The target lock directory is root's below /run (#71); a test user cannot make it.
$PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";

# A run moves its worker out of the control group of the daemon that forked it,
# which is a real busctl call and would land in RUN_CALLS as the first command of
# every run. Pointed at a file that does not exist, the runner cannot tell where
# it is and skips the move. Not optional dressing: the test machine decides
# otherwise, and a CI runner that happens to sit inside a .service made every
# "the first thing pct did" claim in here fail. run-tests.sh checks that each
# test touching Job sets this.
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

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


# ── a cold snapshot: stop, snapshot, start, then update ─────────────────────
#
# An LXC snapshot never holds memory, so a running container is caught as if the
# power had been pulled. The setting buys consistency with downtime, which is
# why what matters here is the SEQUENCE - and above all that the container is
# started again on every path out, including the ones where something failed.

# Which pct verb each recorded call was, in order. The update and the readiness
# probe are both `pct exec` and are told apart by the script they carry.
sub verbs {
    return map {
        my $c = $_->{cmd};
        my $verb = $c->[1] // '';
        if ($verb eq 'exec') {
            $verb = ($c->[6] // '') eq $PVE::UpdateManager::Runner::ONLINE_PROBE
                ? 'probe'
                : 'update';
        }
        $verb;
    } @PVE::Tools::RUN_CALLS;
}

my $COLD = { snapshot_before => 1, snapshot_keep => 3, snapshot_shutdown => 1 };

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    # What existed at the moment the update itself ran.
    my $during;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        return if ($cmd->[1] // '') ne 'exec';
        return if ($cmd->[6] // '') eq $PVE::UpdateManager::Runner::ONLINE_PROBE;
        $during = snapshots_of(101);
    };

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $COLD);

    ok(!defined($err), 'the run succeeds');
    is_deeply(
        [verbs()],
        ['shutdown', 'start', 'probe', 'update'],
        'the container is shut down, snapshotted, started again, and only then updated',
    );
    is(scalar(@{ snapshots_of(101) }), 1, 'one snapshot was taken');
    is(scalar(@{ $during // [] }), 1, 'and it existed before the update ran');
    like($out, qr/shutting the container down for a consistent snapshot/, 'the log says why it stopped');
    like($out, qr/starting the container again/, 'and that it came back');
    is(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{state},
        'ok',
        'the row records the update',
    );
}

# Without the setting nothing is switched off - the default has to stay exactly
# what it was before this existed.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    run({ type => 'lxc', id => 101, name => 'db' }, $ON);

    is_deeply([verbs()], ['update'], 'off by default: the container is snapshotted while it runs');
}

# A container that was found stopped is already as cold as it gets. Shutting it
# down again would be a `pct shutdown` on something that is not running, and
# starting it for the update is the other setting's job.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{102}->{snapshots};

    my ($out, $err) = run(
        { type => 'lxc', id => 102, name => 'off-one' },
        { %$COLD, start_stopped => 1 },
    );

    ok(!defined($err), 'a stopped container is updated');
    is_deeply(
        [verbs()],
        ['start', 'probe', 'update', 'shutdown'],
        'and is started once, for the update, not twice',
    );
    is(scalar(@{ snapshots_of(102) }), 1, 'it is still snapshotted, and while it is off');
}

# The shutdown fails: the run is refused rather than quietly falling back to a
# snapshot of a running container, which is the one thing the setting promises.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $COLD);

    like($err // '', qr/1 of 1 update targets failed/, 'the task goes red');
    is_deeply(snapshots_of(101), [], 'nothing was snapshotted');
    ok(!grep({ $_ eq 'update' } verbs()), 'and the update never started');
    my $state = PVE::UpdateManager::Config::load_state('lxc', 101);
    is($state->{state}, 'failed', 'the row is failed');
    like($state->{note}, qr/could not be shut down for its snapshot/, 'and says what did not happen');
    ok(!defined($PVE::LXC::Config::LOCKS{101}), 'no update lock was left behind');
}

# The snapshot fails after the container is already off. The failure is
# reported - but only after the container is running again, because a container
# left switched off is worse than the failure that caused it.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::Config::SNAPSHOT_DIE = 'storage is full';
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $COLD);

    like($err // '', qr/1 of 1 update targets failed/, 'the task goes red');
    is_deeply(
        [verbs()],
        ['shutdown', 'start', 'probe'],
        'the container is put back up before anything is reported, and is not updated',
    );
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/could not be snapshotted before the update - storage is full/,
        'and the row carries the storage\'s reason',
    );
}

# The container will not come back up. That is a failure of its own, and it must
# not be hidden behind a successful snapshot.
{
    local @PVE::Tools::RUN_CALLS = ();
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    # Everything works except the start.
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return 1 if ($cmd->[1] // '') eq 'start';
        return 0;
    };

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $COLD);

    like($err // '', qr/1 of 1 update targets failed/, 'the task goes red');
    ok(!grep({ $_ eq 'update' } verbs()), 'the update does not run on a container that is down');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/could not be started again after its snapshot/,
        'and the row says exactly that, not "the update failed"',
    );
    ok(!defined($PVE::LXC::Config::LOCKS{101}), 'and no lock is left on it');
}

# A storage that cannot snapshot must not cost the container its uptime: there
# is nothing to be consistent for.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::LXC::Config::NO_SNAPSHOT{101} = 1;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $COLD);

    ok(!defined($err), 'the container is updated');
    is_deeply([verbs()], ['update'], 'and is never switched off for a snapshot it cannot have');
}

# The worst thing this setting could do is leave a container off that was found
# running. It must not happen even when the update itself fails.
{
    local @PVE::Tools::RUN_CALLS = ();
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    # The update fails; the shutdown, the snapshot and the start all work.
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return 1 if ($cmd->[1] // '') eq 'exec'
            && ($cmd->[6] // '') ne $PVE::UpdateManager::Runner::ONLINE_PROBE;
        return 0;
    };

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, { %$COLD, start_stopped => 1 });

    like($err // '', qr/1 of 1 update targets failed/, 'the failed update is reported');
    is_deeply(
        [verbs()],
        ['shutdown', 'start', 'probe', 'update'],
        'and the container is NOT stopped again at the end - it was found running',
    );
    ok(!defined($PVE::LXC::Config::LOCKS{101}), 'the update lock is given back');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/snapshot updmgr-/,
        'and the row names the snapshot to roll back to',
    );
}

# ── two runs of one container inside the same second ────────────────────────
#
# The name carries a whole second, and PVE refuses one it already has. Pressing
# Update twice on a container whose script finishes instantly used to fail the
# second run before it started - "snapshot ... already exists" - which sounds
# like the storage and is not about the storage.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my $fixed = 1786817167;    # both runs are told the same second

    my ($out1, $err1) = capture(
        sub {
            PVE::UpdateManager::Target::run_one(
                { type => 'lxc', id => 101, name => 'db' }, 60, undef, $ON,
            );
        },
    );
    my ($out2, $err2) = capture(
        sub {
            PVE::UpdateManager::Target::run_one(
                { type => 'lxc', id => 101, name => 'db' }, 60, undef, $ON,
            );
        },
    );

    ok(!defined($err1) && !defined($err2), 'neither run dies');
    is(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{state},
        'ok',
        'the second run is updated rather than refused over a name',
    );
    is(scalar(@{ snapshots_of(101) }), 2, 'and both runs left a rollback point');

    # The same, driven straight at the runner with one fixed second, so it does
    # not depend on how fast the machine running the test is.
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    my $first = PVE::UpdateManager::Snapshot::snapshot_guest(101, undef, $fixed);
    my $second = PVE::UpdateManager::Snapshot::snapshot_guest(101, undef, $fixed);
    isnt($second, $first, 'the second name is moved forward rather than reused');
    ok(
        PVE::UpdateManager::Snapshot::is_our_snapshot($second),
        'and it is still recognisably one of ours, so pruning still sees it',
    );
    is(scalar(@{ snapshots_of(101) }), 2, 'both exist');

    # Beyond the retry budget it gives up and lets PVE say why, rather than
    # looping around a container somebody has filled with our names by hand.
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        map { (PVE::UpdateManager::Snapshot::snapshot_name($fixed + $_) => { snaptime => $_ }) }
            (0 .. $PVE::UpdateManager::Snapshot::SNAPSHOT_NAME_TRIES)
    };
    ok(
        !defined(eval { PVE::UpdateManager::Snapshot::snapshot_guest(101, undef, $fixed) }),
        'a name it cannot find room for is still an error',
    );

    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
}

# ── our own lock, left behind by a worker that was killed ───────────────────
#
# unlock_guest is never reached when a worker is killed - a node reboot, an
# out-of-memory kill - and the 'mounted' lock stays on the container. Every run
# after that skips it with "another task holds the lock (mounted)", for ever,
# and nothing says what would clear it.
#
# The lock is deliberately NOT taken off: 'mounted' is a value PVE sets itself
# for `pct mount`, and a container whose rootfs is mounted on the host is the
# last one to start writing into from a second direction. What changes is the
# sentence in the row.
{
    my $confdir = tempdir(CLEANUP => 1);
    local $PVE::LXC::Config::CONFIG_DIR = $confdir;
    PVE::Tools::file_set_contents("$confdir/101.conf", "stub\n");

    local %PVE::LXC::Config::LOCKS = (101 => $PVE::UpdateManager::Runner::LXC_LOCK);

    # Freshly written: somebody may well be working under this lock right now.
    is(PVE::UpdateManager::Runner::stale_own_lock(101), 0, 'a fresh lock is not abandoned');

    my ($fresh) = run({ type => 'lxc', id => 101 }, $ON);
    like($fresh, qr/another task holds the lock \(mounted\)/, 'and the row says only that');
    unlike($fresh, qr/pct unlock/, 'with no advice to clear somebody else\'s lock');

    # Untouched for an hour. A removal or a mount somebody is working under
    # writes that config as it goes; this one has not been written at all.
    my $old = time() - 3600;
    utime($old, $old, "$confdir/101.conf");

    is(PVE::UpdateManager::Runner::stale_own_lock(101), 1, 'an hour untouched is abandoned');

    my ($stale) = run({ type => 'lxc', id => 101 }, $ON);
    like($stale, qr/may be left over from an update that was interrupted/, 'the row says so');
    like($stale, qr/pct unlock 101/, 'and names the command that clears it');
    is(
        $PVE::LXC::Config::LOCKS{101},
        $PVE::UpdateManager::Runner::LXC_LOCK,
        'the lock itself is left exactly where it was',
    );

    # A lock that is not ours is never described as ours, however old it is.
    local %PVE::LXC::Config::LOCKS = (101 => 'backup');
    is(PVE::UpdateManager::Runner::stale_own_lock(101), 0, 'a backup lock is not our leftover');
    my ($backup) = run({ type => 'lxc', id => 101 }, $ON);
    unlike($backup, qr/pct unlock/, 'and gets no advice to clear it');
}

# ── rolling a failed update back ────────────────────────────────────────────
#
# Off by default, and it has to be: a rollback throws away everything that
# happened since the snapshot, not only what the update did. What is pinned here
# is that it fires on a FAILED run and on nothing else, that it goes to the
# snapshot THIS run took, and that the container ends up in the state it was
# found in - PVE stops it to roll it back and leaves it stopped.
my $ROLL = { snapshot_before => 1, snapshot_keep => 3, rollback_on_failure => 1 };

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 0;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL);

    ok(!defined($err), 'an update that WORKS is not rolled back');
    ok(!$PVE::LXC::Config::CONFIGS{101}->{rolled_back_to}, 'nothing was rolled back');
    unlike($out, qr/rolling the container back/, 'and nothing was said about it');
}

{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    my ($out, $err) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL);

    like($err // '', qr/1 of 1 update targets failed/, 'the run still reports the failure');
    my $snapshot = $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};
    ok($snapshot, 'the container was rolled back');
    ok(
        PVE::UpdateManager::Snapshot::is_our_snapshot($snapshot // ''),
        'to a snapshot this addon took',
    );
    like($out, qr/the update failed - rolling the container back/, 'the log says why');

    my $state = PVE::UpdateManager::Config::load_state('lxc', 101);
    like($state->{note}, qr/rolled back to $snapshot/, 'and the row says what happened');
    unlike(
        $state->{note},
        qr/, snapshot $snapshot/,
        'not "here is a snapshot to roll back to" - that would invite doing it twice',
    );

    # Found running, so it has to end running: PVE stops a container to roll it
    # back and leaves it stopped. What proves it here is the pct call - the stub
    # records commands rather than running them, so its idea of "running" would
    # only be its own bookkeeping.
    is(
        (verbs())[-1],
        'start',
        'a container that was running is started again after the rollback',
    );
    ok(!defined($PVE::LXC::Config::LOCKS{101}), 'no lock is left on it');
}

# Off by default: the snapshot is named on the row and nothing is undone.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    run({ type => 'lxc', id => 101, name => 'db' }, $ON);

    ok(!$PVE::LXC::Config::CONFIGS{101}->{rolled_back_to}, 'without the setting, nothing is undone');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/, snapshot updmgr-/,
        'and the row names the snapshot to roll back to by hand',
    );
}

# A container that was found stopped stays stopped afterwards - it was only
# started for the update in the first place.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC_HOOK = sub {
        my ($cmd) = @_;
        return 1 if ($cmd->[1] // '') eq 'exec'
            && ($cmd->[6] // '') ne $PVE::UpdateManager::Runner::ONLINE_PROBE;
        return 0;
    };
    local %PVE::LXC::RUNNING = (102 => undef);
    delete $PVE::LXC::Config::CONFIGS{102}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{102}->{rolled_back_to};

    run({ type => 'lxc', id => 102, name => 'off-one' }, { %$ROLL, start_stopped => 1 });

    ok($PVE::LXC::Config::CONFIGS{102}->{rolled_back_to}, 'it is rolled back too');
    ok(!$PVE::LXC::RUNNING{102}, 'and left stopped, which is how it was found');
    ok(
        !grep({ $_ eq 'shutdown' } verbs()),
        'without a shutdown of a container the rollback already stopped',
    );
}

# The rollback itself failing must be said out loud - the row would otherwise
# report a plain failed update and the operator would never know the container
# is not the one the update left behind.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    local $PVE::LXC::Config::ROLLBACK_DIE = 'storage is busy';
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    my ($out) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL);

    like($out, qr/WARNING: rolling back to updmgr-\S+ failed - storage is busy/, 'the log says so');
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/the rollback to it FAILED/,
        'and so does the row',
    );
}

# Never to a snapshot somebody else made, whatever is asked of it.
{
    ok(
        !defined(eval {
            PVE::UpdateManager::Snapshot::rollback_guest(101, 'before-migration', undef);
        }),
        'a snapshot that is not ours is refused',
    );
}

# ── a rollback the storage refuses, because something else snapshotted too ──
#
# The case this is about is not exotic and cannot be avoided by being careful:
# an auto-snapshot tool fires WHILE the update runs, and ZFS, classic LVM and
# qcow2 chains then refuse to roll back at all - "can't rollback, 'X' is not
# most recent snapshot on 'Y'" - because a rollback destroys everything newer
# and they will not do that behind the operator's back. There is no force to
# pass on: neither snapshot_rollback nor `pct rollback` has one. The only way
# through is to remove those snapshots first, and the reason that is not the
# data loss it looks like is the same sentence: the rollback destroys them
# either way.
#
# The clock is the point of $NEWER. The stub hands out snaptimes in order, so a
# number far above any of them is "taken after ours" no matter how many
# snapshots the tests above have already made.
my $NEWER = 999_000;
my $AUTOSNAP = 'autosnap-2026-09-20-1120';
my $ROLL_CLEAR = { %$ROLL, rollback_remove_newer => 1 };

# Takes a foreign snapshot while the update is running, which is the only way
# for one to be newer than the rollback point. Two homes, because removing one
# is a different operation in each: through PVE, where it lands in the
# container's config, and on the storage itself, where PVE never sees it.
sub autosnap_hook {
    my ($vmid, $name, $where) = @_;

    return sub {
        my ($cmd) = @_;

        return if ($cmd->[1] // '') ne 'exec';

        if ($where eq 'config') {
            $PVE::LXC::Config::CONFIGS{$vmid}->{snapshots}->{$name} //= { snaptime => $NEWER };
            return;
        }

        my $volid = PVE::LXC::Config::volid_of($vmid);
        my $list = $PVE::Storage::STORAGE_ONLY{$volid} //= [];
        push @$list, { name => $name, snaptime => $NEWER }
            if !grep { $_->{name} eq $name } @$list;

        return;
    };
}

# Switched off, the refusal stands - which is what the setting is FOR, and also
# the proof that the refusal is real rather than a message the fix invented.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};
    local $PVE::Tools::RUN_HOOK = autosnap_hook(101, $AUTOSNAP, 'config');

    my ($out) = run(
        { type => 'lxc', id => 101, name => 'db' },
        { %$ROLL, rollback_remove_newer => 0 },
    );

    ok(
        !$PVE::LXC::Config::CONFIGS{101}->{rolled_back_to},
        'switched off, a rollback with something newer in the way does not happen',
    );
    like($out, qr/is not most recent snapshot/, "and the log carries the storage's own words");
    ok(
        scalar(grep { $_ eq $AUTOSNAP } @{ snapshots_of(101) }),
        'the snapshot that stood in the way is left exactly where it was',
    );
    like(
        PVE::UpdateManager::Config::load_state('lxc', 101)->{note},
        qr/the rollback to it FAILED/,
        'and the row says the container is NOT on the snapshot',
    );
}

# Switched on, the same run rolls back.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};
    local $PVE::Tools::RUN_HOOK = autosnap_hook(101, $AUTOSNAP, 'config');

    my ($out) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL_CLEAR);

    my $snapshot = $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};
    ok($snapshot, 'switched on, the container is rolled back after all');
    ok(
        PVE::UpdateManager::Snapshot::is_our_snapshot($snapshot // ''),
        'and still only ever to a snapshot this addon took',
    );
    ok(
        !scalar(grep { $_ eq $AUTOSNAP } @{ snapshots_of(101) }),
        'the snapshot in the way is gone',
    );
    ok(
        scalar(grep { $_ eq $snapshot } @{ snapshots_of(101) }),
        'and the rollback point itself is not',
    );
    like(
        $out,
        qr/removing the snapshot \Q$AUTOSNAP\E, which is newer than \Q$snapshot\E/,
        'the log names what it removed and why - this is the one snapshot of'
            . " somebody else's the addon ever touches",
    );
    is((verbs())[-1], 'start', 'and the container that was running is running again');
}

# The other home: a tool that calls `zfs snapshot` itself leaves nothing in the
# container's config, so snapshot_delete cannot remove it - it would die with
# "does not exist" and the rollback would stay just as blocked.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    local %PVE::Storage::STORAGE_ONLY = ();
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    my $zfs = 'zfs-auto-snap_hourly-2026-09-20-1120';
    local $PVE::Tools::RUN_HOOK = autosnap_hook(101, $zfs, 'storage');

    my ($out) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL_CLEAR);

    ok(
        $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to},
        'a snapshot PVE never saw is cleared out of the way too',
    );
    is_deeply(
        $PVE::Storage::STORAGE_ONLY{ PVE::LXC::Config::volid_of(101) },
        [],
        'and it is gone from the storage, which is the only place it was',
    );
    like($out, qr/removing the snapshot \Q$zfs\E/, 'the log names that one as well');
}

# Restraint, and it is the whole reason this is not simply "delete everything
# that is not ours": a foreign snapshot OLDER than the rollback point survives
# the rollback, so there is no reason to touch it and it is not touched.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    local $PVE::LXC::Config::SNAPTIME = 500_000;
    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'before-migration' => { snaptime => 100 },
    };
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    my ($out) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL_CLEAR);

    ok($PVE::LXC::Config::CONFIGS{101}->{rolled_back_to}, 'the rollback happens');
    ok(
        scalar(grep { $_ eq 'before-migration' } @{ snapshots_of(101) }),
        'and the older snapshot somebody made by hand is still there',
    );
    unlike($out, qr/removing the snapshot/, 'nothing was removed to get there');
}

# PVE's replication owns its own snapshots and removes the ones in its way
# itself, before the check that produces this list ever runs. One reaching here
# is a surprise, and removing it by hand is how a replication job is made to
# start over from nothing.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};

    my $repl = '__replicate_101-0_1758000000__';
    local $PVE::Tools::RUN_HOOK = autosnap_hook(101, $repl, 'config');

    my ($out) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL_CLEAR);

    ok(
        scalar(grep { $_ eq $repl } @{ snapshots_of(101) }),
        'a replication snapshot is left alone even though it blocks the rollback',
    );
    ok(!$PVE::LXC::Config::CONFIGS{101}->{rolled_back_to}, 'so the rollback does not happen');
    like($out, qr/the replication snapshot \Q$repl\E blocks it too/, 'and the log says why');
}

# ── nothing is removed for a rollback that still cannot happen (#59) ────────
#
# "The rollback destroys them either way" is the whole licence to remove
# somebody else's snapshot, and it only holds when the retried rollback then
# happens. Each block below is a reason the retry is refused anyway, with a
# storage-only blocker - removed through the storage, which asks no lock - as
# the snapshot that must survive.
my $OURS = 'updmgr-20260920-111310';
my $HELD = 'zrepl_held';

sub blocked_by {
    my (@names) = @_;

    $PVE::LXC::Config::CONFIGS{101} = { snapshots => { $OURS => { snaptime => 1_000 } } };
    my $n = 0;
    $PVE::Storage::STORAGE_ONLY{ PVE::LXC::Config::volid_of(101) } =
        [map { { name => $_, snaptime => 2_000 + $n++ } } @names];

    return;
}

sub left_on_storage {
    return [map { $_->{name} } @{ $PVE::Storage::STORAGE_ONLY{ PVE::LXC::Config::volid_of(101) } }];
}

sub roll_clear {
    my @log;
    my $ok = eval {
        PVE::UpdateManager::Snapshot::rollback_guest(101, $OURS, sub { push @log, $_[0] }, 1);
        1;
    };
    return ($ok, join("\n", @log));
}

{
    local %PVE::Storage::STORAGE_ONLY = ();
    local %PVE::LXC::Config::LOCKS = (101 => 'backup');
    blocked_by($AUTOSNAP);

    my ($ok, $log) = roll_clear();

    ok(!$ok, 'a guest somebody else has locked is not rolled back');
    is_deeply(
        left_on_storage(),
        [$AUTOSNAP],
        'a snapshot standing in the way of a rollback a lock refuses anyway is not removed',
    );
    like($log, qr/carries a 'backup' lock/, 'and the log names the lock as the reason');
}

{
    local %PVE::Storage::STORAGE_ONLY = ();
    local %PVE::LXC::Config::LOCKS = (101 => $PVE::UpdateManager::Runner::LXC_LOCK);
    blocked_by($AUTOSNAP);

    roll_clear();

    is_deeply(
        left_on_storage(),
        [$AUTOSNAP],
        'nor while our own update lock could not be given back',
    );
}

{
    local %PVE::Storage::STORAGE_ONLY = ();
    blocked_by($AUTOSNAP);
    $PVE::LXC::Config::CONFIGS{101}->{snapshots}->{'__replicate_101-0_1758000000__'} =
        { snaptime => 5_000 };

    my ($ok) = roll_clear();

    ok(!$ok, 'a rollback a replication snapshot blocks does not happen');
    is_deeply(
        left_on_storage(),
        [$AUTOSNAP],
        'and the other snapshot in its way is not removed for it',
    );
}

{
    local %PVE::Storage::STORAGE_ONLY = ();
    local %PVE::Storage::DELETE_DIE = ($HELD => 'dataset is busy');
    blocked_by($HELD, $AUTOSNAP);

    my ($ok, $log) = roll_clear();

    ok(!$ok, 'a blocker the storage will not remove keeps the rollback from happening');
    is_deeply(
        left_on_storage(),
        [$HELD, $AUTOSNAP],
        'and no snapshot after it is removed for that rollback',
    );
    like($log, qr/stopping here - the rollback stays blocked by \Q$HELD\E/, 'the log says why it stopped');
}

{
    local %PVE::Storage::STORAGE_ONLY = ();
    blocked_by($AUTOSNAP);
    $PVE::LXC::Config::CONFIGS{101}->{template} = 1;

    roll_clear();
    delete $PVE::LXC::Config::CONFIGS{101}->{template};

    is_deeply(left_on_storage(), [$AUTOSNAP], 'nor for a template, which PVE never rolls back');
}

# The control: the same storage-only blocker, nothing else in the way, is
# removed and the rollback happens - so the blocks above are the checks, not a
# stub that never removes anything.
{
    local %PVE::Storage::STORAGE_ONLY = ();
    local %PVE::LXC::Config::LOCKS = ();
    blocked_by($AUTOSNAP);

    my ($ok) = roll_clear();

    ok($ok, 'with nothing else in the way the rollback happens');
    is_deeply(left_on_storage(), [], 'after the blocker was removed');
}

# The storage refusing the removal is the path that can wedge the container:
# snapshot_delete writes the lock and `snapstate: delete` BEFORE it asks the
# storage, so a failure there leaves both behind and every later run skips the
# container for good.
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_RC = 1;
    local %PVE::LXC::RUNNING = (101 => 4711);
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};
    delete $PVE::LXC::Config::CONFIGS{101}->{rolled_back_to};
    local %PVE::LXC::Config::DELETE_DIE = ($AUTOSNAP => 'lvremove failed');
    local $PVE::Tools::RUN_HOOK = autosnap_hook(101, $AUTOSNAP, 'config');

    my ($out) = run({ type => 'lxc', id => 101, name => 'db' }, $ROLL_CLEAR);

    ok(
        !$PVE::LXC::Config::CONFIGS{101}->{rolled_back_to},
        'a removal that fails fails the rollback',
    );
    like($out, qr/WARNING: could not remove \Q$AUTOSNAP\E - lvremove failed/, 'the log says so');
    ok(
        !defined($PVE::LXC::Config::LOCKS{101}),
        "and the container is not left locked over somebody else's snapshot",
    );
}

# The list itself, asked directly: it is per volume, and it is empty when there
# is nothing in the way - which is the control for every assertion above.
{
    local $PVE::LXC::Config::SNAPTIME = 600_000;
    $PVE::LXC::Config::CONFIGS{101}->{snapshots} = {
        'updmgr-20260920-111310' => { snaptime => 1_000 },
    };

    is_deeply(
        PVE::UpdateManager::Snapshot::rollback_blockers(101, 'updmgr-20260920-111310'),
        {},
        'the newest snapshot has nothing in its way',
    );

    $PVE::LXC::Config::CONFIGS{101}->{snapshots}->{$AUTOSNAP} = { snaptime => $NEWER };

    is_deeply(
        PVE::UpdateManager::Snapshot::rollback_blockers(101, 'updmgr-20260920-111310'),
        { PVE::LXC::Config::volid_of(101) => [$AUTOSNAP] },
        'and one taken after it is named, per volume, because that is where it has to be removed',
    );

    is_deeply(
        PVE::UpdateManager::Snapshot::rollback_blockers(101, 'updmgr-never-taken'),
        {},
        'a snapshot that does not exist blocks nothing - the caller reports the real error',
    );
}
