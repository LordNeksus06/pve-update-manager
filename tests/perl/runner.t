#!/usr/bin/perl
# PVE::UpdateManager::Runner - which interpreter, which command line.
#
# run_command is stubbed, so what is checked here is the argv that would have
# been executed. That is the part worth pinning: the script reaches the shell as
# a single argv element, never as a string a shell gets to re-parse.

use strict;
use warnings;

use File::Temp qw(tempdir);
use MIME::Base64 ();
use Test::More tests => 56;

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
            MIME::Base64::encode_base64($script, ''), $script, '/bin/bash',
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
            '/usr/bin/env', @PVE::UpdateManager::Runner::HOST_ENV,
            '/bin/sh', '-c', "#!/bin/sh\nuptime\n",
        ],
        'the host runs the script directly, without pct',
    );

    # A worker forked by pvedaemon has no HOME - systemd gives a service none -
    # so a host script running composer, npm or git would fail there and work
    # from a shell. The environment is spelled out rather than inherited.
    my %env = map { split(/=/, $_, 2) } @PVE::UpdateManager::Runner::HOST_ENV;
    is($env{HOME}, '/root', 'the host script is given a HOME');
    is($env{USER}, 'root', 'and a USER');
    is($env{LOGNAME}, 'root', 'and a LOGNAME');
    like($env{PATH}, qr{/usr/local/bin}, 'and a PATH that includes /usr/local/bin');
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

# ── what reaches exec is bytes, not characters ──────────────────────────────
#
# The storage decodes what it reads, because everything above it speaks
# characters. argv does not: left to itself Perl writes anything below U+0100 as
# Latin-1, so a script whose only non-ASCII is an umlaut would arrive inside the
# container as fc rather than c3 bc, and its own shell would show mojibake.
{
    local @PVE::Tools::RUN_CALLS = ();

    my $script = "echo \"\x{fc}\x{f6}\x{e4} \x{1F4E6}\"\n";
    PVE::UpdateManager::Runner::run_lxc(101, $script, 30, sub { });

    # [0..5] pct exec ... /bin/sh -c, [6] the prologue, [7..9] $0 secs grace,
    # [10] the script itself, [11..] the interpreter argv.
    # [10] is the base64 the prologue decodes, [11] the raw script beside it for
    # a container with no base64.
    my $b64 = $PVE::Tools::RUN_CALLS[0]->{cmd}->[10];
    my $raw = $PVE::Tools::RUN_CALLS[0]->{cmd}->[11];

    like($b64, qr/\A[A-Za-z0-9+\/=]+\z/, 'the script travels as ASCII base64');
    is(
        MIME::Base64::decode_base64($b64),
        "echo \"\xc3\xbc\xc3\xb6\xc3\xa4 \xf0\x9f\x93\xa6\"\n",
        'which decodes to the script as UTF-8 bytes',
    );
    is($raw, MIME::Base64::decode_base64($b64), 'and the fallback carries the same thing');
    ok(!utf8::is_utf8($raw), 'as a byte string, so perl does not encode it again on its own');

    local @PVE::Tools::RUN_CALLS = ();
    PVE::UpdateManager::Runner::run_host($script, 30, sub { });
    my $host = $PVE::Tools::RUN_CALLS[0]->{cmd}->[-1];
    is($host, "echo \"\xc3\xbc\xc3\xb6\xc3\xa4 \xf0\x9f\x93\xa6\"\n", 'and so does a host script');
}

# ── a script with non-ASCII in it survives the trip into the container ──────
#
# `pct exec` replaces every non-ASCII BYTE of an argument with U+FFFD - measured
# on a real 9.2 - so a script carrying an umlaut arrived inside the container
# already destroyed. It travels base64-encoded for that reason, and what proves
# it is a shell running the REAL prologue and printing what it got.
SKIP: {
    skip 'no /bin/sh, /usr/bin/env or base64 to run the prologue with', 2
        if !-x '/bin/sh' || !-x '/usr/bin/env';

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $file = "$dir/prologue.sh";
    open(my $fh, '>', $file) or die "cannot write the prologue - $!";
    print $fh $PVE::UpdateManager::Runner::LXC_PROLOGUE;
    close($fh);

    # Real UTF-8 bytes, the way run_lxc hands them over.
    my $script = "printf %s \"\xc3\xbc\xc3\xb6\xc3\xa4 \xf0\x9f\x93\xa6\"\n";

    open(
        my $out, '-|',
        '/usr/bin/env', '-i', '/bin/sh', $file, 30, 5,
        MIME::Base64::encode_base64($script, ''), 'echo WRONG-the-raw-one-was-used',
        '/bin/sh',
    ) or die "cannot run the prologue - $!";
    my $seen = do { local $/; <$out> };
    close($out);

    is(
        $seen,
        "\xc3\xbc\xc3\xb6\xc3\xa4 \xf0\x9f\x93\xa6",
        'the script arrives byte for byte, umlauts and emoji included',
    );
    unlike($seen, qr/WRONG/, 'and it is the decoded one that ran, not the raw fallback');
}

# ── the environment a script actually finds ─────────────────────────────────
#
# `pct exec` hands the CALLER's environment to the container, and the caller is
# whoever started the run - pvedaemon for the button, the timer's service for a
# scheduled one, a login shell for pvesh. Measured on a real 9.2: a caller
# without HOME gives the script HOME=[], USER=[], LOGNAME=[] and four variables
# in total, while the same run over ssh arrives carrying the admin's session.
#
# So this runs the REAL prologue with an empty environment - which is what a
# worker forked by pvedaemon has - and asks what the script sees. Not the text
# of the prologue: a claim about a variable is only worth anything if a shell
# was the one to answer it.
SKIP: {
    skip 'no /bin/sh or /usr/bin/env to run the prologue with', 5
        if !-x '/bin/sh' || !-x '/usr/bin/env';

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $file = "$dir/prologue.sh";
    open(my $fh, '>', $file) or die "cannot write the prologue - $!";
    print $fh $PVE::UpdateManager::Runner::LXC_PROLOGUE;
    close($fh);

    my $probe = 'echo "HOME=$HOME"; echo "USER=$USER"; echo "LOGNAME=$LOGNAME";'
        . ' echo "PATH=$PATH"';

    # Same positional layout the real call has: secs, grace, the base64 of the
    # script, the raw script, then the interpreter argv.
    open(
        my $out, '-|',
        '/usr/bin/env', '-i', '/bin/sh', $file, 30, 5,
        MIME::Base64::encode_base64($probe, ''), $probe, '/bin/sh',
    ) or die "cannot run the prologue - $!";
    my $seen = do { local $/; <$out> };
    close($out);

    like($seen, qr{^HOME=/root$}m, 'a script started with nothing inherited still has a HOME');
    like($seen, qr{^USER=root$}m, 'and a USER');
    like($seen, qr{^LOGNAME=root$}m, 'and a LOGNAME');
    like($seen, qr{^PATH=\S*/usr/local/bin}m, 'and a PATH with /usr/local/bin in it');
    unlike($seen, qr{^HOME=$}m, 'never the empty HOME that made composer refuse to run');
}

# ── leaving the control group of the daemon that forked the worker ──────────
#
# systemd's default KillMode is control-group, so `systemctl restart pvedaemon`
# SIGTERMs every process in that unit - the update worker and the dist-upgrade
# under it included. Reproduced on PVE 9.2: the task ended "received interrupt"
# and the node was left with sixteen packages unpacked and one configured.
#
# What is checked here is the argv of the move and, above all, that the answer is
# honest: the run is only reported as protected once the process really is
# somewhere else, because a false "you are safe" is worse than no line at all.
{
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $cgfile = "$dir/cgroup";

    my $write_cgroup = sub {
        open(my $fh, '>', $cgfile) or die "cannot write the cgroup file - $!";
        print $fh "0::$_[0]\n";
        close($fh);
    };

    local $PVE::UpdateManager::Runner::CGROUP_FILE = $cgfile;
    local $PVE::UpdateManager::Runner::BUSCTL = '/bin/sh';    # -x, and never run

    # A login shell's own scope: nothing restarts underneath it, and moving the
    # run out of the session it belongs to would be a change with no upside.
    {
        $write_cgroup->('/user.slice/user-0.slice/session-33541.scope');
        local @PVE::Tools::RUN_CALLS = ();
        my @log;

        is(
            PVE::UpdateManager::Runner::detach_from_daemon(sub { push @log, $_[0] }),
            0,
            'a run that is not inside a service is left where it is',
        );
        is(scalar(@PVE::Tools::RUN_CALLS), 0, 'and nothing is asked of systemd');
        is(scalar(@log), 0, 'and the task log says nothing about it');
    }

    # The real case: forked by pvedaemon, which is what a package's postinst
    # restarts.
    {
        $write_cgroup->('/system.slice/pvedaemon.service');
        local @PVE::Tools::RUN_CALLS = ();
        local $PVE::Tools::RUN_RC = 0;
        # systemd answers the call before it has done the move, so the move is
        # what the caller waits for - simulated here by the file changing.
        local $PVE::Tools::RUN_HOOK =
            sub { $write_cgroup->("/system.slice/pve-update-manager-run-$$.scope") };
        my @log;

        is(
            PVE::UpdateManager::Runner::detach_from_daemon(sub { push @log, $_[0] }, 'UPID:x:'),
            1,
            'a worker inside pvedaemon.service is moved into a scope of its own',
        );
        is_deeply(
            $PVE::Tools::RUN_CALLS[0]->{cmd},
            [
                '/bin/sh', 'call',
                'org.freedesktop.systemd1', '/org/freedesktop/systemd1',
                'org.freedesktop.systemd1.Manager', 'StartTransientUnit',
                'ssa(sv)a(sa(sv))', "pve-update-manager-run-$$.scope", 'fail', 3,
                'PIDs', 'au', 1, $$,
                'Description', 's', 'pve-update-manager: UPID:x:',
                'CollectMode', 's', 'inactive-or-failed',
                0,
            ],
            'and the move carries this very pid, not a new process',
        );
        is(scalar(@log), 1, 'one line in the task log');
        like(
            $log[0],
            qr/moved out of pvedaemon\.service/,
            'which names the service that can no longer interrupt the run',
        );
    }

    # systemd took the request and nothing happened. The old behaviour is back
    # and the log has to say so, rather than leaving a run that believes it is
    # detached.
    {
        $write_cgroup->('/system.slice/pvedaemon.service');
        local @PVE::Tools::RUN_CALLS = ();
        local $PVE::Tools::RUN_RC = 0;
        local $PVE::UpdateManager::Runner::SCOPE_WAIT = 0;
        my @log;

        is(
            PVE::UpdateManager::Runner::detach_from_daemon(sub { push @log, $_[0] }),
            0,
            'a move that never happens is not reported as one that did',
        );
        like($log[0], qr/^WARNING: .*still in pvedaemon\.service/, 'and it is a warning');
    }

    # The call itself refused - an old systemd, a missing bus, a name already
    # taken. Same rule: the run goes ahead, the log says what it lost.
    {
        $write_cgroup->('/system.slice/pvedaemon.service');
        local @PVE::Tools::RUN_CALLS = ();
        local $PVE::Tools::RUN_RC = 1;
        local $PVE::Tools::RUN_OUTPUT = ['Unit pve-update-manager-run.scope already exists.'];
        my @log;

        is(
            PVE::UpdateManager::Runner::detach_from_daemon(sub { push @log, $_[0] }),
            0,
            'a refused call leaves the run in the service, and says so',
        );
        like($log[0], qr/^WARNING: could not move this run out of pvedaemon\.service/, 'warned');
        like($log[0], qr/already exists/, "and busctl's own words are kept");
    }

    # No busctl at all. The update still has to run.
    {
        $write_cgroup->('/system.slice/pvedaemon.service');
        local @PVE::Tools::RUN_CALLS = ();
        local $PVE::UpdateManager::Runner::BUSCTL = "$dir/no-such-busctl";
        my @log;

        is(
            PVE::UpdateManager::Runner::detach_from_daemon(sub { push @log, $_[0] }),
            0,
            'a node without busctl updates anyway',
        );
        is(scalar(@PVE::Tools::RUN_CALLS), 0, 'nothing was executed');
        like($log[0], qr/^WARNING: .*busctl/, 'and the log names what is missing');
    }

    # An unreadable /proc/self/cgroup, or a node still on cgroup v1: no single
    # answer to "where am I", so nothing is moved on a guess.
    {
        local $PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/not-there";
        local @PVE::Tools::RUN_CALLS = ();
        my @log;

        is(
            PVE::UpdateManager::Runner::detach_from_daemon(sub { push @log, $_[0] }),
            0,
            'a cgroup that cannot be read is not guessed at',
        );
        is(scalar(@PVE::Tools::RUN_CALLS), 0, 'and nothing is executed');
    }
}
