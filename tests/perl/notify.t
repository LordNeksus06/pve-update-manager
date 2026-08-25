#!/usr/bin/perl
# PVE::UpdateManager::Notify - the notification a failed run sends.
#
# What matters here is the SHAPE of it, because nothing downstream will complain
# about a bad one: Proxmox renders the template with whatever data it is handed,
# so a column whose id does not match a key comes out as an empty cell in
# somebody's mail at 03:00 and nowhere else. The table is therefore checked
# against the data it is built from, key by key.
#
# The other half is when it is sent at all: on a failure, once, for the whole run
# - not for a run that only skipped something, and not for one that worked.

use strict;
use warnings;

use Test::More tests => 69;

use PVE::Notify;
use PVE::UpdateManager::Notify;

# ── nothing to report ───────────────────────────────────────────────────────
is(
    PVE::UpdateManager::Notify::failure_report([], 'UPID:x'),
    undef,
    'a run with no targets at all reports nothing',
);
is(
    PVE::UpdateManager::Notify::failure_report(undef, 'UPID:x'),
    undef,
    'and neither does no list at all',
);
is(
    PVE::UpdateManager::Notify::failure_report(
        [{ desc => 'CT 101', state => 'OK', note => 'exit 0 after 3s' }],
    ),
    undef,
    'a run in which everything worked sends nothing - silence is the good news',
);
is(
    PVE::UpdateManager::Notify::failure_report(
        [
            { desc => 'CT 101', state => 'OK', note => 'exit 0 after 3s' },
            { desc => 'CT 102', state => 'SKIPPED', note => 'no update script stored' },
        ],
    ),
    undef,
    'and a target that was SKIPPED is not a failure - that is an answer, not breakage',
);

# ── what a failure says ─────────────────────────────────────────────────────
#
# One stacked block per target, not one wide table row: the fields that matter
# most when an update fails are the ones a table squeezes off the right-hand side.
{
    my $results = [
        {
            desc => 'CT 101 (db)', state => 'FAILED', note => 'exit 100 after 12s',
            exit => 100, finished => 1787249277,
            facts => {
                started => 1787249265, finished => 1787249277, elapsed => 12,
                exit => 100, snapshot => 'updmgr-20260820-201105',
                rolled_back => 0, rollback_failed => 0, timed_out => 0,
                dropped => 0, shutdown_failed => 0, stuck => 0,
            },
        },
        {
            desc => 'CT 102 (web)', state => 'OK', note => 'exit 0 after 4s',
            exit => 0, finished => 1787249280, facts => {},
        },
        {
            desc => 'CT 103 (idle)', state => 'SKIPPED',
            note => 'container is not running', finished => 1787249281, facts => {},
        },
        {
            desc => 'Host pve-test', state => 'FAILED', note => 'timed out after 600s',
            exit => 124, finished => 1787249900,
            facts => {
                started => 1787249300, finished => 1787249900, elapsed => 600,
                exit => 124, timed_out => 1, dropped => 4212,
                rolled_back => 0, rollback_failed => 0, shutdown_failed => 0, stuck => 0,
            },
        },
    ];

    my $report = PVE::UpdateManager::Notify::failure_report($results, 'UPID:pve-test:1:2:3:');

    ok(defined($report), 'a failed target produces a report');

    is($report->{failed}, 2, 'the counts say how many failed');
    is($report->{ok}, 1, 'how many worked');
    is($report->{skipped}, 1, 'how many were skipped');
    is($report->{total}, 4, 'and how many there were');
    is($report->{upid}, 'UPID:pve-test:1:2:3:', 'the task is named, so the log can be opened');

    # Proxmox' own shape: the subject of every PVE notification is built from a
    # single status line handed in as data, not assembled inside the template.
    is(
        $report->{'status-text'},
        '2 of 4 update targets failed',
        'and the one line the subject is built from says the same as the summary',
    );

    my $blocks = $report->{'failed-targets'};
    is(scalar(@$blocks), 2, 'only the failures are listed');

    my $first = $blocks->[0];
    is($first->{target}, 'CT 101 (db)', 'the first one by name');
    is($first->{exit}, 100, 'with the exit code its script gave');
    is($first->{finished}, 1787249277, 'when it stopped, as an epoch for the renderer');
    is($first->{ran}, 12, 'and how long it ran before it did - the question after "when"');
    is(
        $first->{snapshot},
        'updmgr-20260820-201105',
        'the snapshot by name, which is the one thing needed to undo this by hand',
    );
    like(
        $first->{rollback},
        qr/\Ano - the snapshot above is still there/,
        'and whether the run already went back to it - here it did not, and says so',
    );
    is($first->{outcome}, 'the script exited', 'the exit code came from the script');
    is($first->{also}, 'nothing else to report', 'with nothing unusual left over');

    my $second = $blocks->[1];
    is($second->{target}, 'Host pve-test', 'the host is a target like any other');
    is($second->{exit}, 124, 'and a timeout brings its own exit code along');
    is(
        $second->{outcome},
        'the time limit killed it',
        '124 is not "the script exited 124" - the limit killed the process tree,'
            . ' and the line says which of the two it was',
    );
    is($second->{ran}, 600, 'the full 600 seconds it was given');
    is(
        $second->{snapshot},
        'none was taken',
        'a target without a snapshot says so rather than leaving the line blank',
    );
    like($second->{rollback}, qr/no snapshot of this container/, 'and nothing to go back to');
    is(
        $second->{also},
        '4212 further output lines not logged',
        'while the part of the note that is nowhere else is kept',
    );

    # Every field the template prints has to exist on every block, or the reader
    # gets a blank where an answer belongs and nothing anywhere says why.
    for my $field (qw(target finished ran exit outcome snapshot rollback also note)) {
        ok(defined($blocks->[$_]->{$field}), "block $_ carries '$field'") for (0, 1);
    }
}

# The three rollback outcomes are three different things to do next, so they must
# not read alike: the update was taken back, the container is down, or there is
# still a snapshot sitting there.
{
    my $rollback_of = sub {
        my ($facts) = @_;
        my $report = PVE::UpdateManager::Notify::failure_report(
            [{ desc => 'CT 101', state => 'FAILED', note => 'n', exit => 1,
                finished => 5, facts => { finished => 5, elapsed => 1, %$facts } }],
        );
        return $report->{'failed-targets'}->[0]->{rollback};
    };

    like(
        $rollback_of->({ snapshot => 'updmgr-x', rolled_back => 1 }),
        qr/\Ayes - the update was taken back/,
        'rolled back and up again',
    );
    like(
        $rollback_of->({ snapshot => 'updmgr-x', rolled_back => 1, rollback_failed => 1 }),
        qr/did NOT come back up/,
        'rolled back and still down - the one that needs somebody now',
    );
    like(
        $rollback_of->({ snapshot => 'updmgr-x', rollback_failed => 1 }),
        qr/tried and FAILED/,
        'the rollback itself failed, so the container is NOT on the snapshot',
    );
    like(
        $rollback_of->({ snapshot => 'updmgr-x' }),
        qr/still there to go back to/,
        'not rolled back, and the snapshot is the way out',
    );
    like(
        $rollback_of->({}),
        qr/no snapshot of this container/,
        'no snapshot at all, which is a different answer from "not rolled back"',
    );
}

# ── the running time, the way vzdump reports its own ───────────────────────
{
    my $results = [{ desc => 'CT 101', state => 'FAILED', note => 'x', exit => 1, finished => 9 }];

    is(
        PVE::UpdateManager::Notify::failure_report($results, 'UPID:x', 754)->{'total-time'},
        754,
        'the run\'s length goes in as seconds, for the same duration helper vzdump uses',
    );
    is(
        PVE::UpdateManager::Notify::failure_report($results, 'UPID:x')->{'total-time'},
        0,
        'and a caller that does not time its run sends a 0 rather than an undef the'
            . ' template would print as nothing',
    );
}

# ── the ordering of the rows follows the run ────────────────────────────────
{
    my $report = PVE::UpdateManager::Notify::failure_report([
        { desc => 'CT 300', state => 'FAILED', note => 'a', exit => 1, finished => 3 },
        { desc => 'CT 100', state => 'FAILED', note => 'b', exit => 2, finished => 1 },
    ]);

    is_deeply(
        [map { $_->{target} } @{ $report->{'failed-targets'} }],
        ['CT 300', 'CT 100'],
        'the rows are in the order the run walked them, not sorted again behind its back',
    );
}

# ── a report with nothing recorded still renders ────────────────────────────
#
# A run started outside a Proxmox worker has no UPID, and a failure that never
# reached a command has no exit code. Both have to come out as something a
# template can print rather than as an undef.
{
    my $report = PVE::UpdateManager::Notify::failure_report(
        [{ desc => 'CT 101', state => 'FAILED', note => 'could not be started for the update' }],
    );

    is($report->{upid}, '', 'no task means an empty string, not an undefined value');
    is($report->{'failed-targets'}->[0]->{exit}, '', 'and so does no exit code');
    is($report->{'failed-targets'}->[0]->{ran}, 0, 'and a run that never started ran for 0s');

    # But NOT the time. That column is rendered by Proxmox' `timestamp` renderer,
    # and a null arrives in the reader's mail as the literal word ERROR in the
    # cell - watched in a delivered mail. A row that says ERROR where a time
    # belongs reads like a second failure.
    like(
        $report->{'failed-targets'}->[0]->{finished},
        qr/\A\d+\z/,
        'a missing finish time becomes a number rather than a null the renderer chokes on',
    );
}

# ── and the sending ─────────────────────────────────────────────────────────
{
    local @PVE::Notify::SENT = ();

    my $sent = PVE::UpdateManager::Notify::notify_failures(
        [{ desc => 'CT 101', state => 'OK', note => 'exit 0 after 1s' }],
        'UPID:x',
    );

    is($sent, 0, 'a run that worked hands nothing over');
    is(scalar(@PVE::Notify::SENT), 0, 'and really nothing was sent');
}

{
    local @PVE::Notify::SENT = ();

    my $sent = PVE::UpdateManager::Notify::notify_failures(
        [{ desc => 'CT 101', state => 'FAILED', note => 'exit 1 after 1s', exit => 1,
            finished => 42 }],
        'UPID:y',
    );

    is($sent, 1, 'a failure is handed over');
    is(scalar(@PVE::Notify::SENT), 1, 'exactly once - one run is one notification');

    my $call = $PVE::Notify::SENT[0];
    is($call->{severity}, 'error', 'at error severity, which is what a matcher selects on');
    is($call->{template}, 'pve-update-manager', 'through our own template');
    is(
        $call->{fields}->{type},
        'pve-update-manager',
        'carrying a type field, so a matcher can route update failures somewhere of their own',
    );
    is(
        $call->{data}->{fqdn},
        'pve-test.example.invalid',
        "and Proxmox' own template data underneath ours, which is where the hostname comes from",
    );
    is($call->{data}->{failed}, 1, 'with our counts on top of it');
}

# A notification system that refuses must not turn a run that already happened
# into a failed task. The run is over either way and the task log is the record
# of it.
{
    local @PVE::Notify::SENT = ();
    local $PVE::Notify::DIE = 'no notification config';

    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $sent = eval {
        PVE::UpdateManager::Notify::notify_failures(
            [{ desc => 'CT 101', state => 'FAILED', note => 'exit 1 after 1s', exit => 1 }],
            'UPID:z',
        );
    };

    ok(!$@, 'a notification that cannot be sent does not die');
    ok(!defined($sent), 'and says so rather than claiming it went out');
    like($warned, qr/no notification config/, 'the reason is in the log, not swallowed');
}
