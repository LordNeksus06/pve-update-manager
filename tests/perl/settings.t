#!/usr/bin/perl
# The node's settings: the two parallel switches, and the schedule.
#
# The parts worth pinning are the ones that decide whether an unattended
# dist-upgrade starts: the due calculation against a calendar event, the rule
# that saving settings must never move the clock, and the fact that the manual
# and scheduled parallel switches really are separate.

use strict;
use warnings;

use File::Temp qw(tempdir);
use POSIX qw(tzset);
use Test::More tests => 42;

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Runner;

# A calendar event is a LOCAL time, so a fixed epoch and a fixed wall clock only
# line up if the zone is pinned. Without this the "02:30" arithmetic below is off
# by the tester's UTC offset.
BEGIN {
    $ENV{TZ} = 'UTC';
    POSIX::tzset();
}

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# ── defaults ────────────────────────────────────────────────────────────────
my $set = PVE::UpdateManager::Config::load_settings('pve-a');
is($set->{parallel_manual}, 0, 'a manual run goes one target at a time by default');
is($set->{schedule_parallel}, 0, 'and so does a scheduled one');
is($set->{schedule_enabled}, 0, 'and there is no schedule until one is set');
is($set->{schedule_time}, '03:00', 'with a sane time of day to start from');
is($set->{schedule_vmids}, '', 'and no targets');
is(
    PVE::UpdateManager::Config::schedule_is_due($set),
    0,
    'a disabled schedule is never due',
);

is(
    PVE::UpdateManager::Config::settings_file('pve-a'),
    "$dir/store/settings-pve-a.conf",
    'the settings sit beside the scripts, under their own prefix',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::settings_file('../etc/passwd') }),
    'and a node name that is not one is refused, same as everywhere else',
);

# ── the two switches are genuinely separate ─────────────────────────────────
PVE::UpdateManager::Config::save_settings(
    'pve-a', { parallel_manual => 1, schedule_parallel => 0 },
);
$set = PVE::UpdateManager::Config::load_settings('pve-a');
is($set->{parallel_manual}, 1, 'the manual switch can be turned on by itself');
is($set->{schedule_parallel}, 0, 'without dragging the scheduled one with it');

# ── enabling a schedule starts its clock ────────────────────────────────────
#
# Due-ness is measured from last_run. Left at 0 it would measure from 1970 and
# fire the instant the box is ticked - not what "every day at 03:00" says, and
# not while the operator is still looking at the dialog.
{
    my $before = time();
    PVE::UpdateManager::Config::save_settings(
        'pve-fresh', { schedule_enabled => 1, schedule_time => '03:00' },
    );
    my $fresh = PVE::UpdateManager::Config::load_settings('pve-fresh');

    ok($fresh->{last_run} >= $before, 'switching a schedule on starts its clock');
    is(
        PVE::UpdateManager::Config::schedule_is_due($fresh, $fresh->{last_run} + 60),
        0,
        'so it is not due a minute later',
    );

    # ... and turning it off and on again must not restart the clock, which would
    # let a run be postponed for ever by toggling.
    PVE::UpdateManager::Config::save_settings('pve-fresh', { schedule_enabled => 0 });
    my $stamp = PVE::UpdateManager::Config::load_settings('pve-fresh')->{last_run};
    PVE::UpdateManager::Config::save_settings('pve-fresh', { schedule_enabled => 1 });
    is(
        PVE::UpdateManager::Config::load_settings('pve-fresh')->{last_run},
        $stamp,
        'and toggling it later leaves the clock where it was',
    );
}

# ── storing a schedule ──────────────────────────────────────────────────────
PVE::UpdateManager::Config::save_settings(
    'pve-a',
    {
        schedule_enabled => 1,
        schedule_time => '02:30',
        schedule_host => 1,
        schedule_vmids => '101,102',
    },
);
$set = PVE::UpdateManager::Config::load_settings('pve-a');
is($set->{schedule_enabled}, 1, 'enabled survives');
is($set->{schedule_time}, '02:30', 'so does the time of day');
is($set->{schedule_vmids}, '101,102', 'and the target list');
is($set->{parallel_manual}, 1, 'and a field nobody sent keeps its stored value');

ok(
    !defined(
        eval { PVE::UpdateManager::Config::save_settings('pve-a', { schedule_time => 'never' }) }
    ),
    'a schedule nothing can parse is refused rather than silently never firing',
);
ok(
    !defined(
        eval { PVE::UpdateManager::Config::save_settings('pve-a', { schedule_vmids => '1;reboot' }) }
    ),
    'and so is a vmid list that is not one',
);

# ── due, against a time of day ──────────────────────────────────────────────
#
# 02:30 on a fixed day, so the arithmetic is checkable rather than "whenever the
# suite happens to run".
my $day = 1_786_000_000 - (1_786_000_000 % 86400);    # midnight UTC-ish
my $at_0230 = $day + 2 * 3600 + 30 * 60;

PVE::UpdateManager::Config::mark_schedule_run('pve-a', $day);
$set = PVE::UpdateManager::Config::load_settings('pve-a');

is($set->{last_run}, $day, 'the run is stamped');
is(
    PVE::UpdateManager::Config::schedule_is_due($set, $at_0230 - 60),
    0,
    'nothing is due a minute before the appointed time',
);
is(
    PVE::UpdateManager::Config::schedule_is_due($set, $at_0230),
    1,
    'and it is due at it',
);
is(
    PVE::UpdateManager::Config::schedule_is_due($set, $at_0230 + 12 * 3600),
    1,
    'a node that was switched off through 02:30 still runs once it is back',
);

PVE::UpdateManager::Config::mark_schedule_run('pve-a', $at_0230);
$set = PVE::UpdateManager::Config::load_settings('pve-a');
is(
    PVE::UpdateManager::Config::schedule_is_due($set, $at_0230 + 60),
    0,
    'and having just run at 02:30 it does not run again at 02:31',
);

# ── the clock belongs to the scheduler ──────────────────────────────────────
PVE::UpdateManager::Config::save_settings('pve-a', { schedule_time => '05:00' });
$set = PVE::UpdateManager::Config::load_settings('pve-a');
is($set->{last_run}, $at_0230, 'saving settings leaves the clock alone');
is($set->{schedule_time}, '05:00', 'while the new time is stored');

# ── a file edited by hand ───────────────────────────────────────────────────
PVE::Tools::file_set_contents(
    PVE::UpdateManager::Config::settings_file('pve-b'),
    "schedule_enabled=1\nschedule_time=nonsense\nschedule_vmids=rubbish\n",
);
$set = PVE::UpdateManager::Config::load_settings('pve-b');
is($set->{schedule_time}, '03:00', 'an unparsable schedule falls back to the default');
is($set->{schedule_vmids}, '', 'and a target list that is not one is dropped');
is($set->{schedule_enabled}, 1, 'while the rest of the file is still read');

# ── a run must not be started on top of one still going ────────────────────
{
    my $dir2 = tempdir(CLEANUP => 1);
    local $PVE::UpdateManager::Config::BASE_DIR = "$dir2/store";
    local $PVE::INotify::NODENAME = 'pve-test';

    my $targets = [{ type => 'lxc', id => 101 }, { type => 'lxc', id => 102 }];

    PVE::UpdateManager::Config::save_state(
        'lxc', 102,
        {
            state => 'running',
            upid => 'UPID:pve-test:0000AAAA:00000001:6A80A49D:ctupdate:102:root@pam:',
            started => time(),
        },
    );

    {
        local $PVE::ProcFSTools::ALIVE = 1;
        my $busy = PVE::UpdateManager::Config::any_target_running($targets);
        is($busy && $busy->{id}, 102, 'a target mid-run is reported, and which one');
    }
    {
        local $PVE::ProcFSTools::ALIVE = 0;
        is(
            PVE::UpdateManager::Config::any_target_running($targets),
            undef,
            'a run whose worker is gone does not block the next scheduled one',
        );
    }
}

# ── the kill limit ──────────────────────────────────────────────────────────
#
# This one used to be a constant nobody could see or change, and it did not
# actually stop anything - run_command killed its direct child and the update
# kept going. Now that it kills the process tree, the number decides whether a
# long dist-upgrade finishes or is cut off mid-dpkg, so it belongs in the
# settings and it has to survive a round trip.
{
    my $node = 'timeout-node';

    is(
        PVE::UpdateManager::Config::load_settings($node)->{timeout},
        $PVE::UpdateManager::Runner::DEFAULT_TIMEOUT,
        'an unconfigured node gets the default limit',
    );

    PVE::UpdateManager::Config::save_settings($node, { timeout => 7200 });
    is(
        PVE::UpdateManager::Config::load_settings($node)->{timeout},
        7200,
        'a saved limit comes back',
    );

    # Partial saves are the normal case from the dialog - one switch at a time.
    PVE::UpdateManager::Config::save_settings($node, { parallel_manual => 1 });
    is(
        PVE::UpdateManager::Config::load_settings($node)->{timeout},
        7200,
        'and is not reset by a save that does not mention it',
    );

    ok(
        !defined(eval { PVE::UpdateManager::Config::save_settings($node, { timeout => 0 }) }),
        'a limit of zero is refused rather than stored as "no limit"',
    );
    ok(
        !defined(
            eval {
                PVE::UpdateManager::Config::save_settings($node, { timeout => 999999 });
            },
        ),
        'and one beyond a day is refused too',
    );
    is(
        PVE::UpdateManager::Config::load_settings($node)->{timeout},
        7200,
        'a refused save leaves the stored limit alone',
    );
}

# A settings file edited by hand into nonsense must not disarm the limit.
{
    my $node = 'clamp-node';
    PVE::UpdateManager::Config::save_settings($node, { timeout => 600 });

    my $file = PVE::UpdateManager::Config::settings_file($node);
    my $raw = PVE::Tools::file_get_contents($file);
    $raw =~ s/^timeout=.*$/timeout=0/m;
    PVE::Tools::file_set_contents($file, $raw);

    is(
        PVE::UpdateManager::Config::load_settings($node)->{timeout},
        $PVE::UpdateManager::Runner::MIN_TIMEOUT,
        'a zero on disk is clamped up, never read as "run for ever"',
    );

    $raw =~ s/^timeout=.*$/timeout=99999999/m;
    PVE::Tools::file_set_contents($file, $raw);
    is(
        PVE::UpdateManager::Config::load_settings($node)->{timeout},
        $PVE::UpdateManager::Runner::MAX_TIMEOUT,
        'and an absurd one is clamped down',
    );
}

# The opt-in for starting stopped containers.
{
    my $node = 'startstop-node';

    is(
        PVE::UpdateManager::Config::load_settings($node)->{start_stopped},
        0,
        'skipping a stopped container is the default, and stays it',
    );

    PVE::UpdateManager::Config::save_settings($node, { start_stopped => 1 });
    is(
        PVE::UpdateManager::Config::load_settings($node)->{start_stopped},
        1,
        'the opt-in survives a round trip',
    );

    PVE::UpdateManager::Config::save_settings($node, { parallel_manual => 1 });
    is(
        PVE::UpdateManager::Config::load_settings($node)->{start_stopped},
        1,
        'and a save that does not mention it leaves it alone',
    );
}
