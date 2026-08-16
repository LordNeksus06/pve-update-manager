#!/usr/bin/perl
# The last-run bookkeeping: PVE::UpdateManager::Config's state files.
#
# This is what puts a status into every row of the grids and what the Last Log
# button follows, so the parts worth pinning are the file format (one record per
# line, no field can be forged from a note) and the mapping into the last_*
# properties the API hands to the web interface.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 33;

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;
use PVE::UpdateManager::Config;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

is(
    PVE::UpdateManager::Config::state_file('lxc', 101),
    "$dir/store/lxc-101.state",
    'the state file sits next to the script, not inside it',
);
is(
    PVE::UpdateManager::Config::state_file('node', 'pve-a'),
    "$dir/store/node-pve-a.state",
    'same for a node',
);

ok(!defined(PVE::UpdateManager::Config::load_state('lxc', 101)), 'nothing recorded yet');
is_deeply(PVE::UpdateManager::Config::last_run('lxc', 101), {}, 'and last_run says nothing');

# ── round trip ──────────────────────────────────────────────────────────────
PVE::UpdateManager::Config::save_state(
    'lxc', 101,
    {
        state => 'ok',
        upid => 'UPID:pve-a:0000:0000:0000:ctupdate:101:root@pam:',
        started => 1786800000,
        finished => 1786800042,
        exit => 0,
    },
);

my $state = PVE::UpdateManager::Config::load_state('lxc', 101);
is($state->{state}, 'ok', 'state survives');
is($state->{exit}, '0', 'so does an exit code of zero');
is($state->{upid}, 'UPID:pve-a:0000:0000:0000:ctupdate:101:root@pam:', 'and the upid, colons and all');

my $last = PVE::UpdateManager::Config::last_run('lxc', 101);
is($last->{last_state}, 'ok', 'last_run renames state');
is($last->{last_exit}, 0, 'and turns numbers into numbers');
is($last->{last_finished}, 1786800042, 'timestamps come through');
ok(!exists($last->{last_note}), 'a field that was never set is absent, not null');

# ── a note must not be able to forge a field ────────────────────────────────
PVE::UpdateManager::Config::save_state(
    'lxc', 102,
    {
        state => 'skipped',
        note => "container is not running\nstate=ok\nexit=0",
    },
);

my $forged = PVE::UpdateManager::Config::load_state('lxc', 102);
is($forged->{state}, 'skipped', 'the newlines in the note did not overwrite the state');
is($forged->{exit}, undef, 'and did not invent an exit code');
like($forged->{note}, qr/container is not running/, 'the note itself is still readable');

# ── a corrupt file is "no state", not an error ──────────────────────────────
PVE::Tools::file_set_contents(
    PVE::UpdateManager::Config::state_file('lxc', 103),
    "this is not a state file\n",
);
ok(
    !defined(PVE::UpdateManager::Config::load_state('lxc', 103)),
    'a file without a state line reads as nothing recorded',
);

# ── deleting the script KEEPS the state ─────────────────────────────────────
#
# When a target was last updated is a fact about the target, not about the
# script that happened to be stored at the time. Removing the commands must not
# throw that away - the grid still answers "last updated on ...", it just also
# says there is nothing stored to run.
PVE::UpdateManager::Config::save_script('lxc', 101, "apt-get update\n");
PVE::UpdateManager::Config::delete_script('lxc', 101);

ok(
    !-f PVE::UpdateManager::Config::script_file('lxc', 101),
    'delete_script removes the script',
);
is(
    PVE::UpdateManager::Config::last_run('lxc', 101)->{last_state},
    'ok',
    'and keeps the last run, which is a fact about the target',
);
is(
    PVE::UpdateManager::Config::has_script('lxc', 101),
    0,
    'while the target correctly reports having no commands',
);

# Wiping the history is its own, explicit operation.
is(PVE::UpdateManager::Config::delete_state('lxc', 101), 1, 'delete_state forgets the run');
is(PVE::UpdateManager::Config::delete_state('lxc', 101), 0, 'and is a no-op the second time');
is_deeply(PVE::UpdateManager::Config::last_run('lxc', 101), {}, 'nothing recorded any more');

# ── one unreadable target must not take out the whole list ──────────────────
#
# has_script is called once per target while the node and datacenter lists are
# built, and reading a file above the size limit dies. A single hand-written
# oversized script used to make BOTH tabs answer with an error and no list at
# all, for every target.
{
    my $file = PVE::UpdateManager::Config::script_file('lxc', 107);
    PVE::Tools::file_set_contents($file, 'x' x ($PVE::UpdateManager::Config::MAX_SCRIPT_SIZE + 10));

    my $warned = '';
    my $has;
    {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        $has = eval { PVE::UpdateManager::Config::has_script('lxc', 107) };
    }

    is($@, '', 'an oversized script does not blow up the listing');
    is($has, 0, 'the target reports no usable commands');
    like($warned, qr/too long/, 'and the reason is left in the log rather than swallowed');

    unlink($file);
}

# ── a worker that died leaves "running" behind ──────────────────────────────
#
# Without this the row spins for ever, the grid polls it for ever, and its
# Update button stays disabled because the target looks busy.
{
    PVE::UpdateManager::Config::save_state(
        'lxc', 108,
        {
            state => 'running',
            upid => 'UPID:pve-test:0000AAAA:00000001:6A80A49D:ctupdate:108:root@pam:',
            started => 1786800000,
        },
    );

    local $PVE::INotify::NODENAME = 'pve-test';

    {
        local $PVE::ProcFSTools::ALIVE = 1;
        is(
            PVE::UpdateManager::Config::last_run('lxc', 108)->{last_state},
            'running',
            'a run whose worker is alive really is still running',
        );
    }

    {
        local $PVE::ProcFSTools::ALIVE = 0;
        my $last = PVE::UpdateManager::Config::last_run('lxc', 108);
        is($last->{last_state}, 'unknown', 'a run whose worker is gone is not running any more');
        like($last->{last_note}, qr/without recording a result/, 'and says what happened');
        is(
            $last->{last_upid},
            'UPID:pve-test:0000AAAA:00000001:6A80A49D:ctupdate:108:root@pam:',
            'the log of that task is still reachable',
        );
    }

    # A worker on ANOTHER node has a /proc we cannot read. Guessing it is dead
    # would put "no result" on a container that is updating perfectly well.
    {
        local $PVE::ProcFSTools::ALIVE = 0;
        local $PVE::INotify::NODENAME = 'pve-other';
        is(
            PVE::UpdateManager::Config::last_run('lxc', 108)->{last_state},
            'running',
            'a run on another node is left alone rather than declared dead',
        );
    }

    # The state file is only written with a upid by a real worker; without one
    # there is nothing that could ever finish it.
    PVE::UpdateManager::Config::save_state('lxc', 109, { state => 'running' });
    is(
        PVE::UpdateManager::Config::last_run('lxc', 109)->{last_state},
        'unknown',
        'a running state with no upid cannot be waited on either',
    );
}

# ── a state value nobody wrote on purpose ──────────────────────────────────
{
    PVE::Tools::file_set_contents(
        PVE::UpdateManager::Config::state_file('lxc', 110),
        "state=bogus\nupid=x\n",
    );

    my $last = PVE::UpdateManager::Config::last_run('lxc', 110);
    is($last->{last_state}, 'unknown', 'an unknown state value is reported as unknown');
    like($last->{last_note}, qr/unreadable state/, 'with a note saying why');
    ok(
        (grep { $_ eq $last->{last_state} } @PVE::UpdateManager::Config::KNOWN_STATES),
        'so the API never returns a value its own schema forbids',
    );
}
