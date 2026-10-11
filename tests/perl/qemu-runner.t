#!/usr/bin/perl
# PVE::UpdateManager::QemuRunner - a script run inside a VM through the guest
# agent, against an agent that is played by the test.
#
# The fake agent below answers the way the real one was measured to answer on
# PVE 9.2.4 with qemu-guest-agent 8.2.2: guest-exec returns a pid at once, a file
# handle keeps its position and returns what was appended since the last read,
# guest-exec-status says {"exited":false} until the end and the exit code once,
# an agent-side error comes back as a RETURN value rather than a die - and a
# restarted agent has forgotten every pid and handle ("PID ... does not exist",
# "handle '...' has not been found") while the script itself runs on.
#
# The guest-side shell text is not faked: it is run under the local /bin/sh at
# the bottom, which is the half of the transport that can be checked without a
# VM. What only a VM shows - systemd-run really moving the script out of the
# agent's control group - was measured there and is described in the module.

use strict;
use warnings;

use B ();
use File::Temp qw(tempdir);
use MIME::Base64 qw(encode_base64 decode_base64);
use Test::More tests => 60;

use PVE::QemuServer::Monitor;
use PVE::UpdateManager::QemuRunner;
use PVE::UpdateManager::Runner;

$PVE::UpdateManager::QemuRunner::POLL = 0;
$PVE::UpdateManager::QemuRunner::RM_WAIT = 0;

# A scripted VM and its agent.
#
#   chunks   what the script prints, one entry per guest-exec-status poll
#   exit     the final status of the script ({exitcode => n} or {signal => n})
#   restart  the poll after which the agent is restarted: pid and handles gone
#   fail     command => list of answers that replace the normal one, in order;
#            a string dies like mon_cmd does, a hash is returned as it is
#   no_log   the log file never appears
sub fake_agent {
    my (%o) = @_;

    my @chunks = @{ $o{chunks} // [] };
    my %fail = map { $_ => [@{ $o{fail}->{$_} }] } keys %{ $o{fail} // {} };
    my %files;               # path => content
    my %handles;             # handle => { path, pos }
    my $next_handle = 1000;
    my ($log, $rcf);
    my $pid_known = 0;
    my $polls = 0;
    my $finished = 0;

    my $finish = sub {
        return if $finished;
        $finished = 1;
        my $exit = $o{exit} // { exitcode => 0 };
        $files{$rcf} = (defined($exit->{signal}) ? 128 + $exit->{signal} : $exit->{exitcode}) . "\n"
            if defined($rcf);
    };

    # The script makes progress whenever the host looks, whichever way it looks.
    my $tick = sub {
        if (@chunks) {
            my $chunk = shift @chunks;
            $files{$log} .= $chunk if defined($log) && !$o{no_log};
        } else {
            $finish->();
        }
    };

    return sub {
        my ($vmid, $cmd, %args) = @_;

        if (my $queue = $fail{$cmd}) {
            if (@$queue) {
                my $answer = shift @$queue;
                die "$answer\n" if !ref($answer);
                return $answer;
            }
        }

        return {} if $cmd eq 'guest-ping';

        if ($cmd eq 'guest-exec') {
            if (($args{path} // '') eq '/bin/rm') {
                return { pid => 4243 };
            }
            ($log, $rcf) = @{ $args{arg} }[3, 5];
            $files{$log} = '' if !$o{no_log};
            $pid_known = 1;
            return { pid => 4242 };
        }

        if ($cmd eq 'guest-file-open') {
            die "agent error: failed to open file '$args{path}' (mode: 'r'): No such file or directory\n"
                if !exists($files{ $args{path} });
            my $h = $next_handle++;
            $handles{$h} = { path => $args{path}, pos => 0 };
            return $h;
        }

        if ($cmd eq 'guest-file-seek') {
            my $h = $handles{ $args{handle} } or return { error => { desc => "handle '$args{handle}' has not been found" } };
            $h->{pos} = $args{offset};
            return { position => $h->{pos}, eof => 0 };
        }

        if ($cmd eq 'guest-file-read') {
            my $h = $handles{ $args{handle} } or return { error => { desc => "handle '$args{handle}' has not been found" } };
            my $data = substr($files{ $h->{path} }, $h->{pos}, $args{count});
            $h->{pos} += length($data);
            return { count => length($data), 'buf-b64' => encode_base64($data, ''), eof => 1 };
        }

        if ($cmd eq 'guest-file-close') {
            delete $handles{ $args{handle} };
            return {};
        }

        if ($cmd eq 'guest-exec-status') {
            return { exited => 1, exitcode => $o{rm_exit} // 0 } if $args{pid} == 4243;

            $polls++;
            if (defined($o{restart}) && $polls == $o{restart}) {
                $pid_known = 0;
                %handles = ();
            }
            return { error => { desc => "PID $args{pid} does not exist" } } if !$pid_known;

            $tick->();
            return { exited => 0 } if !$finished;

            $pid_known = 0;    # fetched once, then gone - as measured
            my $exit = $o{exit} // { exitcode => 0 };
            return { exited => 1, %$exit };
        }

        die "unexpected agent command $cmd\n";
    }, sub {
        # After a restart nobody polls the pid any more; the script still runs.
        $tick->() if !$pid_known;
        return \%files;
    };
}

sub run {
    my (%o) = @_;

    my ($agent, $vm) = fake_agent(%o);

    local @PVE::QemuServer::Monitor::CALLS = ();
    local $PVE::QemuServer::Monitor::HANDLER = sub {
        $vm->() if $_[1] eq 'guest-file-open';
        return $agent->(@_);
    };

    my @log;
    my $rc = PVE::UpdateManager::QemuRunner::run_vm(
        $o{vmid} // 200, $o{script} // "echo hi\n", $o{timeout} // 60, sub { push @log, $_[0] },
    );

    return ($rc, \@log, [@PVE::QemuServer::Monitor::CALLS], $vm->());
}

sub calls_of {
    my ($calls, $cmd) = @_;
    return grep { $_->{cmd} eq $cmd } @$calls;
}

sub main_exec {
    my ($calls) = @_;
    my ($exec) = grep { ($_->{args}->{path} // '') eq '/bin/sh' } calls_of($calls, 'guest-exec');
    return $exec;
}

sub is_string { return (B::svref_2object(\$_[0])->FLAGS & B::SVf_POK()) ? 1 : 0; }

# ── the output, live and in order ───────────────────────────────────────────
{
    my ($rc, $log, $calls) = run(
        chunks => ["line 1\nli", "ne 2\n", "", "line 3\nno newline at the end"],
        exit => { exitcode => 3 },
    );

    is($rc, 3, "the script's exit code is the run's exit code");
    is_deeply(
        $log,
        ['line 1', 'line 2', 'line 3', 'no newline at the end'],
        'every line arrives once and whole, also one split across two reads, and the last'
            . ' one without a newline too',
    );

    my $exec = main_exec($calls);
    ok($exec, 'the script was started with /bin/sh');
    my @arg = @{ $exec->{args}->{arg} };
    is($arg[1], $PVE::UpdateManager::QemuRunner::VM_OUTER, 'running the outer part');
    is($arg[4], $PVE::UpdateManager::QemuRunner::VM_INNER, 'which is handed the inner part as an argument');

    my ($open) = calls_of($calls, 'guest-file-open');
    is($open->{args}->{path}, $arg[3], 'the file that is read is the one the outer part writes');
    like($arg[3], qr{\A/var/tmp/pve-update-manager-200-\d+-\d+\.log\z}, 'in /var/tmp, named after the VM');
    (my $rcf = $arg[3]) =~ s/\.log\z/.rc/;
    is($arg[5], $rcf, 'and the exit code goes beside it');

    my @rm = grep { ($_->{args}->{path} // '') eq '/bin/rm' } calls_of($calls, 'guest-exec');
    is(scalar(@rm), 1, 'both are removed inside the VM afterwards');
    is_deeply($rm[0]->{args}->{arg}, ['-f', '--', $arg[3], $rcf], 'those two files, and nothing else');
    is(scalar(calls_of($calls, 'guest-file-close')), 1, 'the log handle is given back');
    ok(
        (grep { $_->{args}->{pid} == 4243 } calls_of($calls, 'guest-exec-status')),
        "and the rm's result is fetched, so the agent does not keep it for ever",
    );
    ok(!grep({ m/WARNING/ } @$log), 'a clean run puts no warning in the log');
}

{
    my ($rc, $log) = run(chunks => ["x\n"], rm_exit => 1);
    is($rc, 0, "a failed removal does not change the run's verdict");
    like($log->[-1], qr{WARNING: could not remove /var/tmp/pve-update-manager-200-\S+\.log and }, 'but it is said');
}

# ── the JSON types the agent insists on ─────────────────────────────────────
{
    my ($rc, $log, $calls) = run(chunks => ["x\n"]);

    my ($status) = calls_of($calls, 'guest-exec-status');
    ok(!is_string($status->{args}->{pid}), 'the pid goes to the agent as a number');
    my ($read) = calls_of($calls, 'guest-file-read');
    ok(!is_string($read->{args}->{handle}), 'so does the file handle');
    ok(!is_string($read->{args}->{count}), 'and the byte count');

    my @numbers = grep { !is_string($_) } @{ main_exec($calls)->{args}->{arg} };
    is(scalar(@numbers), 0, 'every argument goes as a string, the time limit and the grace included');
}

# ── nothing but ASCII crosses the agent ─────────────────────────────────────
{
    my $script = "#!/bin/sh\necho 'f\x{fc}r \x{1F4E6}'\n";
    my ($rc, $log, $calls) = run(script => $script);

    my @wide = grep { m/[^\x00-\x7f]/ } @{ main_exec($calls)->{args}->{arg} };
    is(scalar(@wide), 0, 'a script with an umlaut and an emoji sends ASCII only');
    is(
        decode_base64(main_exec($calls)->{args}->{arg}->[8]),
        PVE::UpdateManager::Runner::to_bytes($script),
        'because it travels as base64 of its UTF-8 bytes',
    );
}

{
    my ($rc, $log, $calls) = run(script => "#!/opt/b\x{e4}sh\necho x\n");

    is($rc, -1, 'an interpreter line the agent cannot carry fails the run');
    is(scalar(calls_of($calls, 'guest-exec')), 0, 'and is never sent - it would wedge the agent');
    like($log->[0], qr/other than ASCII/, 'the log says why');
}

# ── no agent ────────────────────────────────────────────────────────────────
{
    my ($rc, $log, $calls) = run(fail => { 'guest-ping' => ["VM 200 qga command 'guest-ping' failed - got timeout"] });

    is($rc, -1, 'an agent that does not answer fails the run');
    is(scalar(calls_of($calls, 'guest-exec')), 0, 'and nothing is started');
    like($log->[0], qr/guest agent of VM 200 is not answering/, 'the log names the agent');
}

# An agent error is a RETURN value of mon_cmd. Taken for a result, this would
# have gone on with an undefined pid.
{
    my ($rc, $log) = run(
        fail => { 'guest-exec' => [{ error => { class => 'GenericError', desc => 'Guest exec is disabled' } }] },
    );

    is($rc, -1, 'an agent that refuses the exec fails the run');
    like($log->[0], qr/could not start the update script in VM 200 - agent error: Guest exec is disabled/,
        "with the agent's own reason");
}

# ── an agent that hiccups, one that goes silent ─────────────────────────────
{
    my $timeout = "VM 200 qga command 'guest-exec-status' failed - got timeout";
    my ($rc, $log) = run(chunks => ["a\n", "b\n"], fail => { 'guest-exec-status' => [$timeout, $timeout] });

    is($rc, 0, 'two timeouts in a row do not end a run - the channel was measured to recover');
    is_deeply($log, ['a', 'b'], 'and no output is lost over them');
}

{
    local $PVE::UpdateManager::QemuRunner::MAX_MISSES = 4;
    my $timeout = "VM 200 qga command 'guest-exec-status' failed - got timeout";
    my ($rc, $log) = run(chunks => ["a\n"], fail => { 'guest-exec-status' => [($timeout) x 4] });

    is($rc, -1, 'an agent silent for MAX_MISSES polls in a row ends the run');
    like($log->[-1], qr/stopped answering .* may still be running inside the VM/,
        'and says the update itself may not have stopped');
}

# ── an agent restarted under the run ────────────────────────────────────────
#
# What an upgrade of qemu-guest-agent does in the middle of a dist-upgrade. The
# script runs on in its own scope; the agent has forgotten its pid and the log
# handle.
{
    my ($rc, $log, $calls, $files) = run(
        chunks => ["before 1\n", "before 2\n", "after 1\n", "after 2\n"],
        restart => 3,
        exit => { exitcode => 0 },
    );

    is($rc, 0, 'the run ends with the exit code the script wrote into its file');
    is_deeply(
        [grep { !m/restarted while/ } @$log],
        ['before 1', 'before 2', 'after 1', 'after 2'],
        'and every line arrives exactly once across the restart - nothing lost, nothing twice',
    );
    ok((grep { m/was restarted while the update ran .* following it on/ } @$log), 'the log says what happened');

    my @seeks = calls_of($calls, 'guest-file-seek');
    ok(@seeks, 'the log is opened again after the restart');
    is($seeks[0]->{args}->{offset}, length("before 1\nbefore 2\n"), 'at the byte where reading stopped');
    ok(!is_string($seeks[0]->{args}->{offset}), 'the offset as a number');
}

{
    my ($rc) = run(chunks => ["a\n", "b\n"], restart => 2, exit => { exitcode => 42 });
    is($rc, 42, 'a failure after the restart is still reported as one');
}

{
    my ($rc) = run(chunks => ["a\n"], restart => 2, exit => { signal => 9 });
    is($rc, 137, 'and a kill too, through the same file');
}

# ── exit codes ──────────────────────────────────────────────────────────────
{
    my ($rc) = run(exit => { signal => 9 });
    is($rc, 137, 'a script killed by signal 9 reports 128+9, as a shell would');

    ($rc) = run(exit => { exitcode => 124 });
    is($rc, $PVE::UpdateManager::Runner::TIMEOUT_RC, 'the time limit inside the VM comes back as 124');
}

{
    my ($rc, $log) = run(no_log => 1, chunks => ["lost\n"], exit => { exitcode => 5 });

    is($rc, 5, 'a log file that never appears still yields the exit code');
    like($log->[-1], qr/could never be opened - its output is not shown/, 'and says the output is missing');
}

{
    local @PVE::QemuServer::Monitor::CALLS = ();
    ok(
        !defined(eval { PVE::UpdateManager::QemuRunner::run_vm('1;reboot', 'x', 60, sub { }) })
            && !@PVE::QemuServer::Monitor::CALLS,
        'a vmid that is not a number dies before anything is sent, like run_lxc',
    );
}

# ── the guest-side shell, run for real under the local /bin/sh ──────────────
#
# The same argv a VM gets, minus the agent. It proves the shell text writes
# everything into the files the host reads, decodes the script intact and
# returns its exit code - for this machine's /bin/sh, not for every guest's.
my $dir = tempdir(CLEANUP => 1);

sub inner {
    my ($name, $secs, $b64) = @_;

    my $log = "$dir/$name.log";
    my $pid = fork() // die;
    if (!$pid) {
        open(STDOUT, '>', $log) or die;
        open(STDERR, '>&', \*STDOUT) or die;
        exec('/bin/sh', '-c', $PVE::UpdateManager::QemuRunner::VM_INNER, 'pve-update-manager',
            "$dir/$name.rc", $secs, 1, $b64, '/bin/sh');
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;

    open(my $fh, '<', $log) or die;
    my @lines = <$fh>;
    close($fh);
    chomp(@lines);

    my $rcfile = -e "$dir/$name.rc" ? do { open(my $r, '<', "$dir/$name.rc") or die; local $/; <$r> } : undef;

    return ($rc, \@lines, $rcfile);
}

{
    my $script = "echo out\necho err >&2\necho \"\$HOME \$PATH\"\nprintf 'f\\303\\274r\\n'\nexit 7\n";
    my ($rc, $lines, $rcfile) = inner('ok', 30, encode_base64($script, ''));

    is($rc, 7, "the inner part exits with the script's code");
    is($rcfile, "7\n", 'and writes it into the exit-code file');
    ok(!-e "$dir/ok.rc.tmp", 'renamed into place, nothing half-written left beside it');
    is_deeply(
        $lines,
        ['out', 'err', '/root /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', "f\xc3\xbcr"],
        'stdout and stderr both land in the log, with the fixed HOME and PATH, bytes intact',
    );
}

{
    my $start = time();
    my ($rc, $lines, $rcfile) = inner('slow', 1, encode_base64("sleep 20\n", ''));
    is($rc, 124, 'the time limit is enforced inside, by timeout');
    is($rcfile, "124\n", 'and the file says so too');
    cmp_ok(time() - $start, '<', 10, 'and the run really ended there');
}

{
    my ($rc, $lines, $rcfile) = inner('bad', 30, '!!!not base64');
    is($rc, 127, 'a script that cannot be decoded is not run');
    like(join("\n", @$lines), qr/no usable 'base64'/, 'the log says so');
    is($rcfile, "127\n", 'and the host still learns the end from the file');
}

# The outer part, with systemd-run replaced by a stand-in that records how it
# was called and then runs the command it was given - which is what --scope
# does after moving the process.
{
    mkdir("$dir/bin") or die;
    open(my $fh, '>', "$dir/bin/systemd-run") or die;
    print $fh "#!/bin/sh\nprintf '%s\\n' \"\$@\" > '$dir/systemd-run.args'\n"
        . "while [ \"\$1\" != '--' ]; do shift; done\nshift\nexec \"\$@\"\n";
    close($fh);
    chmod(0755, "$dir/bin/systemd-run") or die;

    local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
    my $rc = system(
        '/bin/sh', '-c', $PVE::UpdateManager::QemuRunner::VM_OUTER, 'pve-update-manager',
        "$dir/outer.log", $PVE::UpdateManager::QemuRunner::VM_INNER,
        "$dir/outer.rc", 30, 1, encode_base64("echo scoped\nexit 3\n", ''), '/bin/sh',
    );

    SKIP: {
        skip('no /run/systemd/system on this machine, so the outer part takes its fallback', 3)
            if !-d '/run/systemd/system';

        my @args;
        if (open(my $a, '<', "$dir/systemd-run.args")) {
            @args = <$a>;
            close($a);
            chomp(@args);
        }
        is_deeply([@args[0 .. 3]], ['--scope', '--quiet', '--collect', '--'],
            'the outer part hands over through systemd-run --scope');
        is($rc >> 8, 3, "and the run still ends with the script's code");
        is((stat("$dir/outer.log"))[2] & 07777, 0600, 'the log it opened is readable by root only');
    }
}

unlike($PVE::UpdateManager::QemuRunner::VM_OUTER . $PVE::UpdateManager::QemuRunner::VM_INNER,
    qr/[^\x00-\x7f]/, 'the guest-side shell text is ASCII itself');
