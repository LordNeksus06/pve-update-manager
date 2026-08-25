#!/usr/bin/perl
# The kept logs of past runs.
#
# What matters here is the same thing that matters about the saved script
# versions: the last few are on disk, they are readable, the retention count
# drops the OLDEST rather than the wrong one, and a target that is destroyed does
# not leave its history to whatever gets its vmid next.
#
# And one thing that is only true of logs: they do NOT live in /etc/pve. pmxcfs
# refuses a file over 1 MiB - measured on PVE 9.2 - while one target may write
# 8 MiB to a log, and the whole cluster filesystem is memory-resident on every
# node. So the path is node-local, and that is pinned here rather than left to a
# comment.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 45;

use PVE::Tools;
use PVE::UpdateManager::Config;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
$PVE::UpdateManager::Config::LOG_DIR = "$dir/logs";

# ── where they go ───────────────────────────────────────────────────────────
is(
    PVE::UpdateManager::Config::log_file('lxc', 101, '2026-08-21-13-21-12'),
    "$dir/logs/lxc-101\@2026-08-21-13-21-12.log",
    'a log is named like a saved version and ends in .log',
);
is(
    PVE::UpdateManager::Config::log_file('node', 'pve-test', '2026-08-21-13-21-12'),
    "$dir/logs/node-pve-test\@2026-08-21-13-21-12.log",
    'and the host has its own',
);
unlike(
    PVE::UpdateManager::Config::log_file('lxc', 101, '2026-08-21-13-21-12'),
    qr{\Q$PVE::UpdateManager::Config::BASE_DIR\E},
    'NOT beside the script in /etc/pve - a log can be larger than pmxcfs allows a file to be',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::log_file('lxc', 101, '1755690000') }),
    'an epoch is not a log name - there was never an old shape to keep reading here',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::log_file('lxc', 101, '../../etc/passwd') }),
    'and a name that would climb out of the directory is refused',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::log_file('lxc', '../x', '2026-08-21-13-21-12') }),
    'as is an id that would',
);

# ── writing, listing, reading ───────────────────────────────────────────────
is_deeply(
    PVE::UpdateManager::Config::list_logs('lxc', 101),
    [],
    'a target that has never run has no logs - and asking does not die on the missing directory',
);

my $first = PVE::UpdateManager::Config::save_log('lxc', 101, "first run\n", 3, 1787310000);
like($first, qr/\A[0-9]{4}(-[0-9]{2}){5}\z/, 'a save answers with the stamp it stored under');
ok(-f PVE::UpdateManager::Config::log_file('lxc', 101, $first), 'and the file is there');

my $logs = PVE::UpdateManager::Config::list_logs('lxc', 101);
is(scalar(@$logs), 1, 'one log is listed');
is($logs->[0]->{log}, $first, 'under the stamp it was stored as');
is($logs->[0]->{time}, 1787310000, 'with the second behind it, for rendering');
is($logs->[0]->{size}, length("first run\n"), 'and how big it is');
is(
    PVE::UpdateManager::Config::load_log('lxc', 101, $first),
    "first run\n",
    'and it reads back byte for byte',
);
is(
    PVE::UpdateManager::Config::load_log('lxc', 101, '2020-01-01-00-00-00'),
    undef,
    'a log that is not there is an empty answer, not an exception',
);

# Text with an umlaut in it: a log is what apt printed, and apt prints in the
# container's locale. It has to come back out the way it went in.
{
    my $stamp = PVE::UpdateManager::Config::save_log(
        'lxc', 102, "Vorgang wird \x{fc}bersprungen\n", 3, 1787310001,
    );
    is(
        PVE::UpdateManager::Config::load_log('lxc', 102, $stamp),
        "Vorgang wird \x{fc}bersprungen\n",
        'an umlaut survives the round trip',
    );
}

# ── retention ───────────────────────────────────────────────────────────────
for my $i (1 .. 4) {
    PVE::UpdateManager::Config::save_log('lxc', 101, "run $i\n", 3, 1787310000 + $i);
}

$logs = PVE::UpdateManager::Config::list_logs('lxc', 101);
is(scalar(@$logs), 3, 'the retention count keeps three');
is(
    PVE::UpdateManager::Config::load_log('lxc', 101, $logs->[0]->{log}),
    "run 4\n",
    'the newest first',
);
is(
    PVE::UpdateManager::Config::load_log('lxc', 101, $logs->[2]->{log}),
    "run 2\n",
    'and the oldest of the three left is the second run - the OLDEST went, not the wrong one',
);
ok(
    $logs->[0]->{time} > $logs->[1]->{time} && $logs->[1]->{time} > $logs->[2]->{time},
    'strictly newest first',
);

# Two runs of one target in the same second - a wave of one container that fails
# instantly, twice. The second must not overwrite the first.
{
    PVE::UpdateManager::Config::save_log('lxc', 103, "A\n", 5, 1787320000);
    PVE::UpdateManager::Config::save_log('lxc', 103, "B\n", 5, 1787320000);

    my $same = PVE::UpdateManager::Config::list_logs('lxc', 103);
    is(scalar(@$same), 2, 'two runs in one second are two logs');
    isnt($same->[0]->{log}, $same->[1]->{log}, 'under two different names');
}

# ── switching it off ────────────────────────────────────────────────────────
is(
    PVE::UpdateManager::Config::save_log('lxc', 104, "nothing\n", 0, 1787330000),
    undef,
    'a retention of 0 stores nothing at all',
);
is_deeply(PVE::UpdateManager::Config::list_logs('lxc', 104), [], 'so there is nothing to list');

# And turning it down removes what is over the new count, on the next run rather
# than by a sweep - the same way the script versions behave.
{
    PVE::UpdateManager::Config::save_log('lxc', 105, "one\n", 5, 1787340000);
    PVE::UpdateManager::Config::save_log('lxc', 105, "two\n", 5, 1787340001);
    PVE::UpdateManager::Config::save_log('lxc', 105, "three\n", 1, 1787340002);

    my $left = PVE::UpdateManager::Config::list_logs('lxc', 105);
    is(scalar(@$left), 1, 'turning it down to 1 leaves one');
    is(
        PVE::UpdateManager::Config::load_log('lxc', 105, $left->[0]->{log}),
        "three\n",
        'and it is the newest',
    );
}

# ── the count itself ────────────────────────────────────────────────────────
is(PVE::UpdateManager::Config::log_retention(undef), 3, 'nothing given is the default');
is(PVE::UpdateManager::Config::log_retention('abc'), 3, 'and so is nonsense');
is(PVE::UpdateManager::Config::log_retention(0), 0, 'zero is a real answer here');
is(PVE::UpdateManager::Config::log_retention(999), 50, 'and too many is clamped, not refused');

# ── a target that is destroyed takes its logs with it ───────────────────────
#
# A log of what CT 101 did last week, handed to whatever is created as 101 next,
# is somebody else's history in somebody else's editor.
{
    is(PVE::UpdateManager::Config::delete_logs('lxc', 101), 3, 'a purge removes all of them');
    is_deeply(PVE::UpdateManager::Config::list_logs('lxc', 101), [], 'and nothing is left');
    is(PVE::UpdateManager::Config::delete_logs('lxc', 101), 0, 'twice is not an error');
    ok(
        -f PVE::UpdateManager::Config::log_file('lxc', 102, '2026-08-21-13-21-12')
            || scalar(@{ PVE::UpdateManager::Config::list_logs('lxc', 102) }),
        'and the logs of a DIFFERENT container are untouched',
    );
}

# A file in the directory that this did not write is not a log: it has no place
# in the order and a menu entry that cannot be opened is worse than none.
{
    PVE::UpdateManager::Config::save_log('lxc', 106, "real\n", 3, 1787350000);
    PVE::Tools::file_set_contents("$dir/logs/lxc-106\@2026-99-99-99-99-99.log", "no\n");
    PVE::Tools::file_set_contents("$dir/logs/lxc-106.log", "no\n");
    PVE::Tools::file_set_contents("$dir/logs/lxc-1060\@2026-08-21-13-21-12.log", "other target\n");

    my $list = PVE::UpdateManager::Config::list_logs('lxc', 106);
    is(scalar(@$list), 1, 'only the one this wrote is listed');
    is(
        PVE::UpdateManager::Config::load_log('lxc', 106, $list->[0]->{log}),
        "real\n",
        'and it is the right one',
    );
}

# ── what a listing says about each run without reading it ──────────────────
#
# "Which of these failed" has to be answerable from the list, or the only way to
# find the failed run is to open all of them. Read from the log's own header, and
# only the header: fifty logs of 8 MiB are 400 MiB nobody may read to draw a
# window.
{
    my $header = join(
        "\n",
        '=== pve-update-manager ===',
        'target:   CT 201 (web)',
        'started:  2026-08-21 14:07:02',
        'finished: 2026-08-21 14:07:03',
        'result:   FAILED (exit 100 after 1s, snapshot updmgr-20260821-140702)',
        'task:     UPID:pve:00001234:00005678:00000000:ctupdate:201:root@pam:',
        '',
        '',
    );

    PVE::UpdateManager::Config::save_log('lxc', 201, $header . "output\n", 3, 1787360000);

    my $entry = PVE::UpdateManager::Config::list_logs('lxc', 201)->[0];
    is($entry->{state}, 'failed', 'the listing says how the run ended');
    is(
        $entry->{note},
        'exit 100 after 1s, snapshot updmgr-20260821-140702',
        'and what the verdict said beyond that - the same pair the grid renders a run with',
    );
    is(
        $entry->{upid},
        'UPID:pve:00001234:00005678:00000000:ctupdate:201:root@pam:',
        'and which task produced it, so Proxmox own log is one click away while it lasts',
    );

    # A log a killed worker left half written has no header to read. It must cost
    # its own row's detail and not the listing.
    PVE::Tools::file_set_contents("$dir/logs/lxc-201\@2026-08-21-13-00-00.log", "just outp");
    my $list = PVE::UpdateManager::Config::list_logs('lxc', 201);
    is(scalar(@$list), 2, 'a log without a header is still listed');
    is($list->[1]->{state}, undef, 'it just has nothing to say about how it went');
    is($list->[1]->{upid}, undef, 'and no task to open');
    ok(defined($list->[1]->{time}), 'while the time from its NAME is still there');
}

# A result line with no note behind it - a run that simply worked.
{
    PVE::UpdateManager::Config::save_log(
        'lxc', 202,
        "=== pve-update-manager ===\nresult:   OK\n\noutput\n",
        3, 1787360100,
    );

    my $entry = PVE::UpdateManager::Config::list_logs('lxc', 202)->[0];
    is($entry->{state}, 'ok', 'a bare result is still a state');
    is($entry->{note}, undef, 'with no note invented for it');
}
