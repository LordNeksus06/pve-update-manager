#!/usr/bin/perl
# PVE::UpdateManager::Runner - which interpreter, which command line.
#
# run_command is stubbed, so what is checked here is the argv that would have
# been executed. That is the part worth pinning: the script reaches the shell as
# a single argv element, never as a string a shell gets to re-parse.

use strict;
use warnings;

use Test::More tests => 23;

use PVE::Tools;
use PVE::UpdateManager::Runner;

# ── interpreter selection ───────────────────────────────────────────────────
is_deeply(
    PVE::UpdateManager::Runner::interpreter("#!/bin/bash\napt-get update\n"),
    ['/bin/bash'],
    'a shebang picks the interpreter',
);
is_deeply(
    PVE::UpdateManager::Runner::interpreter("#!/bin/bash -e\napt-get update\n"),
    ['/bin/bash', '-e'],
    'shebang arguments are kept',
);
is_deeply(
    PVE::UpdateManager::Runner::interpreter("#! /usr/bin/env  bash\n"),
    ['/usr/bin/env', 'bash'],
    'space after #! and multiple arguments',
);
is_deeply(
    PVE::UpdateManager::Runner::interpreter("apt-get update\n"),
    ['/bin/sh'],
    'no shebang falls back to /bin/sh, which every container has',
);
is_deeply(PVE::UpdateManager::Runner::interpreter(''), ['/bin/sh'], 'empty script');
is_deeply(PVE::UpdateManager::Runner::interpreter(undef), ['/bin/sh'], 'undef script');
is_deeply(
    PVE::UpdateManager::Runner::interpreter("# not a shebang\n#!/bin/bash\n"),
    ['/bin/sh'],
    'a #! that is not on the first line is a comment, not an interpreter',
);

is(PVE::UpdateManager::Runner::untaint("a\nb"), "a\nb", 'untaint keeps multi-line text intact');

# ── container runs ──────────────────────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    my $script = "#!/bin/bash\napt-get update\n";

    my $rc = PVE::UpdateManager::Runner::run_lxc(101, $script, 60, sub { });
    is($rc, 0, 'exit code is passed through');

    my $call = $PVE::Tools::RUN_CALLS[0];
    is_deeply(
        $call->{cmd},
        [
            '/usr/sbin/pct', 'exec', '101', '--',
            '/bin/sh', '-c', $PVE::UpdateManager::Runner::LXC_PROLOGUE,
            'pve-update-manager', 60, $PVE::UpdateManager::Runner::KILL_GRACE,
            $script, '/bin/bash',
        ],
        'the script is one argv element - no shell re-parses it',
    );
    is(
        $call->{param}->{timeout},
        60 + $PVE::UpdateManager::Runner::OUTER_GRACE,
        'run_command only backstops the inner limit, so it must wait longer than it',
    );
    is($call->{param}->{noerr}, 1, 'a failing script must not die inside run_command');
}

{
    local @PVE::Tools::RUN_CALLS = ();
    ok(
        !defined(eval { PVE::UpdateManager::Runner::run_lxc('1;reboot', 'x', 60, sub { }) }),
        'a vmid that is not a number never reaches pct',
    );
}

# ── host runs ───────────────────────────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    PVE::UpdateManager::Runner::run_host("#!/bin/sh\nuptime\n", 30, sub { });
    is_deeply(
        $PVE::Tools::RUN_CALLS[0]->{cmd},
        [
            '/usr/bin/timeout', '-k', $PVE::UpdateManager::Runner::KILL_GRACE, 30,
            '/bin/sh', '-c', "#!/bin/sh\nuptime\n",
        ],
        'the host runs the script directly, without pct',
    );
}

# ── the limit has to reach the command, not just the watcher ────────────────
#
# This is the regression guard for a measured bug: run_command's timeout does
# kill(9) on its direct child only, so `pct` died while the shell inside the
# container kept going, and on the node every grandchild survived. coreutils
# `timeout` signals the whole process group instead. If these ever stop asserting
# that `timeout` is on the command line, the timeout is decorative again.
{
    local @PVE::Tools::RUN_CALLS = ();
    PVE::UpdateManager::Runner::run_host("uptime\n", 30, sub { });
    my $cmd = $PVE::Tools::RUN_CALLS[0]->{cmd};
    is($cmd->[0], '/usr/bin/timeout', 'the host limit is enforced by coreutils timeout');
    is($cmd->[1], '-k', 'and escalates to KILL for anything that ignores TERM');
}

{
    local @PVE::Tools::RUN_CALLS = ();
    PVE::UpdateManager::Runner::run_lxc(101, "uptime\n", 45, sub { });
    my $cmd = $PVE::Tools::RUN_CALLS[0]->{cmd};
    like(
        $cmd->[6],
        qr/exec timeout -k "\$grace" "\$secs"/,
        'a container run execs timeout inside the container, where its process group is',
    );
    like(
        $cmd->[6],
        qr/no usable 'timeout' in this container/,
        'and a container without one is told so instead of believing it is guarded',
    );
    is($cmd->[8], 45, 'the requested limit is what timeout gets');
}

# A timeout must not be able to arrive as shell text on that command line.
{
    local @PVE::Tools::RUN_CALLS = ();
    ok(
        !defined(eval { PVE::UpdateManager::Runner::run_host('uptime', '60; reboot', sub { }) }),
        'a timeout that is not a number never reaches the command line',
    );
    is(scalar(@PVE::Tools::RUN_CALLS), 0, 'and nothing ran');
}

# ── failures ────────────────────────────────────────────────────────────────
{
    local @PVE::Tools::RUN_CALLS = ();
    local $PVE::Tools::RUN_DIE = 'command timed out';
    my @logged;

    my $rc = PVE::UpdateManager::Runner::run_host("uptime\n", 1, sub { push @logged, $_[0] });

    is($rc, -1, 'a timeout becomes an exit code instead of a dying worker');
    like($logged[0] // '', qr/timed out/, 'and the reason reaches the task log');
}
