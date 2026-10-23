#!/usr/bin/perl
# A cap on how many targets of one parallel wave run at the same time.
#
# Measured on a real node before this existed: a scheduled parallel run started
# 36 targets in the same second, the node's DNS and reverse-proxy containers
# among them, and the failures that night were network fetches that went through
# when retried one at a time. The cap is the operator's answer to that; the
# claims here are that it holds, that it does not change what a wave IS (the
# next position still waits for the whole of this one), and that 0 still means
# what parallel meant before - everything at once.

use strict;
use warnings;

use File::Path ();
use File::Temp qw(tempdir);
use IO::Handle;
use Test::More tests => 29;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Settings;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
# The target lock directory is root's below /run (#71); a test user cannot make it.
$PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";

# See job.t: the cgroup move is a real busctl call and has no place in a test.
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";

# The shutdown inhibitor is a real systemd-inhibit call; job.t pins what it asks
# for. Here it would only print "Access denied" into the test output.
{
    no warnings 'redefine';
    *PVE::UpdateManager::Runner::inhibit_shutdown = sub { return undef };
}

# Into a file, not a scalar: the children of a wave write into the log too.
sub capture {
    my ($code) = @_;

    my $path = "$dir/capture.log";
    unlink($path);

    open(my $saved, '>&', \*STDOUT) or die "cannot dup STDOUT - $!";
    close(STDOUT);
    open(STDOUT, '>', $path) or die "cannot redirect STDOUT - $!";
    STDOUT->autoflush(1);

    my $err;
    eval { $code->(); 1 } or do { $err = $@ };

    close(STDOUT);
    open(STDOUT, '>&', $saved) or die "cannot restore STDOUT - $!";
    close($saved);

    my $out = '';
    if (open(my $fh, '<', $path)) {
        local $/ = undef;
        $out = <$fh> // '';
        close($fh);
    }

    return ($out, $err);
}

sub note_event {
    my ($file, $text) = @_;

    open(my $fh, '>>', $file) or die "cannot record an event - $!";
    print $fh "$text\n";
    close($fh);

    return;
}

sub events_of {
    my ($file) = @_;

    open(my $fh, '<', $file) or return [];
    local $/ = undef;
    my $raw = <$fh> // '';
    close($fh);

    return [grep { length } split(/\n/, $raw)];
}

# Five targets on position 1, one on position 2.
my @first = (301 .. 305);
my $targets = [
    (map { { type => 'lxc', id => $_, name => "ct$_" } } @first),
    { type => 'lxc', id => 306, name => 'after' },
];

for my $t (@$targets) {
    PVE::UpdateManager::Config::save_script('lxc', $t->{id}, "apt-get update\n");
    $PVE::LXC::RUNNING{ $t->{id} } = 7000 + $t->{id};
}
PVE::UpdateManager::Config::save_order('lxc', $_, 1) for @first;
PVE::UpdateManager::Config::save_order('lxc', 306, 2);

# Runs the six targets with the given options and returns (peak, events, out, err).
#
# The peak is counted, not timed: every target drops a marker while it runs and
# counts the markers it sees, and holds on long enough that a neighbour started
# alongside it is certain to see it. A cap that does not hold shows up as a
# number above it, not as a run that was a little slower.
sub run_with {
    my ($opts) = @_;

    my $events = "$dir/events";
    my $live = "$dir/live";
    unlink($events);
    File::Path::remove_tree($live) if -d $live;
    mkdir($live);

    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        my $vmid = $cmd->[2];

        open(my $fh, '>', "$live/$vmid") or die "cannot mark $vmid - $!";
        close($fh);
        note_event($events, "start $vmid");

        my $peak = 0;
        for (1 .. 8) {
            opendir(my $dh, $live) or die "cannot read $live - $!";
            my $now = scalar(grep { !m/\A\./ } readdir($dh));
            closedir($dh);
            $peak = $now if $now > $peak;
            select(undef, undef, undef, 0.05);
        }

        note_event($events, "peak $peak");
        note_event($events, "end $vmid");
        unlink("$live/$vmid");
    };

    my ($out, $err) = capture(sub { PVE::UpdateManager::Job::run_all($targets, 60, $opts) });

    my $seen = events_of($events);
    my ($peak) = sort { $b <=> $a } map { m/\Apeak (\d+)\z/ ? $1 : () } @$seen;

    return ($peak // 0, $seen, $out, $err);
}

sub index_of {
    my ($events, $want) = @_;
    for my $i (0 .. $#$events) {
        return $i if $events->[$i] eq $want;
    }
    return -1;
}

# ── the cap holds ───────────────────────────────────────────────────────────
{
    my ($peak, $seen, $out, $err) = run_with({ parallel => 1, parallel_max => 2 });

    # The premise: every target ran, so the peak below is a peak over a whole
    # wave and not over a run that started two things and stopped.
    is(scalar(grep { m/\Astart / } @$seen), 6, 'all six targets ran under a cap of 2');
    ok(!defined($err), 'and none of them failed');
    is($peak, 2, 'never more than two of them at the same time');

    my $last_first = (sort { $b <=> $a } map { index_of($seen, "end $_") } @first)[0];
    ok(
        index_of($seen, 'start 306') > $last_first,
        'the next position still waits for the WHOLE of the capped one',
    );
    like($out, qr/=== position 1 of 2: .*, at most 2 at once ===/, 'the log says the wave is capped');
    like($out, qr/6 ok, 0 failed, 0 skipped, 6 total/, 'and the summary counts the run');

    # In the group's order, not in the order they happened to finish - the same
    # promise an uncapped wave makes, and the one a reaping loop breaks first.
    my @verdicts = $out =~ m/^--- CT (\d+) /mg;
    is_deeply(\@verdicts, [301 .. 306], 'the verdicts come in the order of the group');

    for my $vmid (301, 305) {
        is(
            PVE::UpdateManager::Config::last_run('lxc', $vmid)->{last_state},
            'ok',
            "the row of CT $vmid was written by the child that updated it",
        );
    }
}

# ── a cap of 1 inside a parallel run ────────────────────────────────────────
{
    my ($peak, $seen) = run_with({ parallel => 1, parallel_max => 1 });
    is(scalar(grep { m/\Astart / } @$seen), 6, 'a cap of 1 still runs every target');
    is($peak, 1, 'one at a time');
}

# ── the control: 0 is no cap ────────────────────────────────────────────────
#
# Without this, a cap that throttled EVERY parallel run to one would pass the
# assertions above.
{
    my ($peak, $seen, $out) = run_with({ parallel => 1, parallel_max => 0 });
    is(scalar(grep { m/\Astart / } @$seen), 6, 'with no cap every target ran as well');
    is($peak, 5, 'and all five of the first position overlapped');
    unlike($out, qr/at most \d+ at once/, 'an uncapped wave does not claim a cap');
}

# ── a cap that is larger than the wave changes nothing ──────────────────────
{
    my ($peak) = run_with({ parallel => 1, parallel_max => 50 });
    is($peak, 5, 'a cap of 50 on a wave of 5 lets all five overlap');
}

# ── a child that is already gone frees its slot ─────────────────────────────
#
# With SIGCHLD ignored the kernel reaps every child itself and waitpid answers
# -1. Counted as still running, such a child would hold its slot for ever and
# the run would hang; the alarm turns that into a red test instead.
{
    my $ran = eval {
        local $SIG{ALRM} = sub { die "hung\n" };
        local $SIG{CHLD} = 'IGNORE';
        alarm(30);
        my ($peak, $seen) = run_with({ parallel => 1, parallel_max => 2 });
        alarm(0);
        scalar(grep { m/\Astart / } @$seen);
    };
    alarm(0);
    is($@, '', 'a wave whose children are reaped by the kernel does not hang');
    is($ran, 6, 'and every target of it ran');
}

# ── a child the cap reaped keeps its exit status ────────────────────────────
#
# Waiting for a free slot reaps the child that freed it. Its status has to be
# kept then: the collecting loop cannot waitpid it a second time, and a child
# that died without reporting is described by the signal that killed it.
{
    local $PVE::Tools::RUN_RC = 0;
    local $PVE::Tools::RUN_HOOK = sub {
        my ($cmd) = @_;
        # Runs inside the forked child of CT 301, which then dies without
        # reporting anything - an OOM kill, as far as the parent can tell.
        kill('KILL', $$) if $cmd->[2] == 301;
    };

    my ($out, $err) = capture(
        sub {
            PVE::UpdateManager::Job::run_all(
                [$targets->[0], $targets->[1]], 60, { parallel => 1, parallel_max => 1 },
            );
        },
    );

    like($err // '', qr/1 of 2 update targets failed/, 'the killed target fails the run');
    like(
        $out,
        qr/--- CT 301 \(ct301\): FAILED \(its process died without reporting a result \(killed by signal 9\)\)/,
        'and is reported with the signal that really killed it',
    );
    like($out, qr/--- CT 302 \(ct302\): OK/, 'the target that waited for its slot still ran');
}

# ── the two settings that feed it ───────────────────────────────────────────
{
    my $node = 'pve-cap';
    my $set = PVE::UpdateManager::Settings::load_settings($node);
    is($set->{parallel_manual_max}, 0, 'a manual parallel run has no cap by default');
    is($set->{schedule_parallel_max}, 0, 'and neither has a scheduled one');

    PVE::UpdateManager::Settings::save_settings($node, { parallel_manual_max => 8 });
    $set = PVE::UpdateManager::Settings::load_settings($node);
    is($set->{parallel_manual_max}, 8, 'the manual cap is stored');
    is($set->{schedule_parallel_max}, 0, 'without touching the scheduled one');

    ok(
        !defined(
            eval {
                PVE::UpdateManager::Settings::save_settings($node, { schedule_parallel_max => 101 });
            }
        ),
        'a cap above the ceiling is refused',
    );
    like($@, qr/schedule_parallel_max/, 'and the refusal names the field');

    my $file = PVE::UpdateManager::Settings::settings_file($node);
    open(my $in, '<', $file) or die "cannot read $file - $!";
    my $raw = do { local $/ = undef; <$in> };
    close($in);
    $raw =~ s/^parallel_manual_max=.*$/parallel_manual_max=5000/m;
    open(my $outfh, '>', $file) or die "cannot write $file - $!";
    print $outfh $raw;
    close($outfh);
    is(
        PVE::UpdateManager::Settings::load_settings($node)->{parallel_manual_max},
        $PVE::UpdateManager::Settings::MAX_PARALLEL,
        'a hand-edited cap above the ceiling is clamped, not stored',
    );

    # Each switch carries its own number into the run, and no switch carries none.
    is(
        PVE::UpdateManager::Settings::run_opts({}, 1, 9)->{parallel_max},
        9,
        'run_opts hands the run the cap it was given',
    );
    is(PVE::UpdateManager::Settings::run_opts({}, 0, 9)->{parallel_max}, 0, 'a serial run carries no cap');
}
