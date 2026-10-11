package PVE::UpdateManager::QemuRunner;

# Runs an update script inside a VM through the QEMU guest agent, and streams
# what it prints into the caller's log function line by line - the VM half of
# what PVE::UpdateManager::Runner does for containers with `pct exec`.
#
# A module of its own rather than more of Runner.pm: the transport has nothing
# in common with pct beyond the script it carries, and the pieces that ARE shared
# - the interpreter line, the time limit, the byte encoding - are called from
# there, not copied.
#
# Everything below was measured on PVE 9.2.4 against an Ubuntu 24.04 VM with
# qemu-guest-agent 8.2.2.
#
# ── why the output goes through a file ──
#
# guest-exec gives no live output. With a script that prints one line a second,
# every guest-exec-status while it runs answers {"exited":false} and nothing
# else, all of the output arrives in one piece once the process has ended, and
# that answer can be fetched exactly ONCE - the next poll is "PID ... does not
# exist". A dist-upgrade would show nothing for twenty minutes and then
# everything, and a hung one nothing at all until its limit.
#
# So the script writes into a file inside the VM, and the host reads that file
# while it grows: guest-file-read on a handle that stays open keeps its position
# and returns what was appended since the last read, even after it once reported
# eof. Five reads a second apart returned line1 ... line5, one each.
#
# ── why the script runs in a scope of its own ──
#
# Whatever the agent starts lives in qemu-guest-agent.service's control group,
# and that unit has KillMode=control-group: restarting the agent kills it. An
# upgrade of the qemu-guest-agent package does exactly that - its prerm runs
# `deb-systemd-invoke stop qemu-guest-agent.service`. Reproduced with
# `apt-get install --reinstall qemu-guest-agent` as the update script: the run
# died in the middle of dpkg and left the package `iF`, half configured. Any
# dist-upgrade that happens to carry a new guest agent would do the same.
#
# So the script is moved into a transient scope with `systemd-run --scope`,
# outside the agent's group. Measured: a script started that way survived
# `systemctl restart qemu-guest-agent` and finished. The agent forgets it, of
# course - its pid and the log's file handle are gone with the old agent - so the
# script writes its exit code into a file of its own, and the host, after a
# restart, opens the log again where it stopped reading and waits for that file.
#
# ── why every argument is ASCII ──
#
# One non-ASCII character anywhere in a guest-exec argument - an umlaut, an emoji,
# passed as UTF-8 bytes or as a Perl character string alike - and the command
# never reaches the agent: it times out, and the guest-ping after it times out
# too. Twice: once the channel came back by itself within seconds, the second
# time it stayed dead for over a minute until qemu-guest-agent was restarted
# inside the VM. So the script travels as base64, the guest-side text is plain
# ASCII, and anything else that is not ASCII is refused here, before it is sent.
#
# ── why pid and handle go through int(), and arguments through "" ──
#
# The agent checks JSON types strictly in both directions. It wants numbers for
# pid, handle and count, and the JSON encoder writes a Perl value that has ever
# been used as a string as a string: a pid that had been put into a log line
# came back as "Invalid parameter type for 'pid', expected: integer". And it
# wants strings in `arg`: a number there - the kill grace - came back as
# "Invalid parameter type for 'arg[5]', expected: string". Both errors arrive as
# a return value, not as a die.

use strict;
use warnings;

use MIME::Base64 qw(encode_base64 decode_base64);
use Time::HiRes ();

use PVE::QemuConfig;
use PVE::QemuServer::Monitor;

use PVE::UpdateManager::Runner;

our $POLL = 2;               # seconds between two looks at the log file
our $READ_CHUNK = 65536;     # bytes per guest-file-read
our $AGENT_TIMEOUT = 10;     # seconds one agent command may take
our $PING_TIMEOUT = 3;       # the same limit PVE's own qga_check_running uses

# How many agent calls in a row may fail before the run is given up on. A
# channel that hiccups recovers (see above), so one timeout is not a verdict;
# fifteen polls is half a minute of silence, which a working agent never shows.
# A RESTARTED agent is not counted here - it answers, it has only forgotten.
our $MAX_MISSES = 15;

# How long the `rm` of the files at the end is waited for.
our $RM_TRIES = 10;
our $RM_WAIT = 0.2;

# Where the files live inside the VM. /var/tmp because /tmp is a tmpfs on many
# distributions and a long dist-upgrade log is not something to keep in RAM;
# both files are removed again after the run.
our $GUEST_DIR = '/var/tmp';

# The guest half, in two parts. The OUTER part is what guest-exec starts: it
# opens the log - with umask 077, because an update log can carry what a script
# echoes and /var/tmp is world-readable - and hands over to the inner part in a
# scope of its own. The INNER part travels as an argument rather than as a file:
# nothing has to be written into the VM before the run can start.
our $VM_OUTER = <<'EOS';
log=$1
inner=$2
shift 2
umask 077
exec >"$log" 2>&1
if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    exec systemd-run --scope --quiet --collect -- /bin/sh -c "$inner" pve-update-manager "$@"
fi
echo "WARNING: no systemd in this VM - if the update restarts qemu-guest-agent, as an upgrade of that package does, the update is killed with it"
exec /bin/sh -c "$inner" pve-update-manager "$@"
EOS

# The time limit is enforced in here, by coreutils `timeout` in its own process
# group, for the same reason as in a container: the host cannot kill a process
# inside a VM, it can only stop waiting for it.
#
# The exit code goes into its own file, renamed into place so the host never
# reads half of it. That file is how the end of a run is noticed after the agent
# was restarted and has forgotten the pid.
#
# Unlike the container prologue there is no raw-script fallback for a guest
# without base64: the raw script is exactly what must not cross the agent.
our $VM_INNER = <<'EOS';
rcf=$1
secs=$2
grace=$3
b64=$4
shift 4
if script=$(printf %s "$b64" | base64 -d 2>/dev/null) && [ -n "$script" ]; then
    HOME=/root
    USER=root
    LOGNAME=root
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME USER LOGNAME PATH
    if timeout -k 1 1 true 2>/dev/null; then
        timeout -k "$grace" "$secs" "$@" -c "$script"
    else
        echo "WARNING: no usable 'timeout' in this VM - a run that exceeds ${secs}s will be abandoned, not killed"
        "$@" -c "$script"
    fi
    rc=$?
else
    echo "ERROR: no usable 'base64' in this VM - the update script cannot be passed in"
    rc=127
fi
echo "$rc" >"$rcf.tmp" && mv -f "$rcf.tmp" "$rcf"
exit "$rc"
EOS

# ── Keeping the VM from being switched off mid-update ─────────────────────
#
# The same mechanism a container gets: a config lock, which every stop,
# shutdown, reboot and migrate path of PVE checks first. The value has to come
# out of the enum in PVE's own schema, and for a VM that is (9.2.4)
#
#   backup clone create migrate rollback snapshot snapshot-delete suspending suspended
#
# None is neutral the way 'mounted' is for a container. 'backup' is the owner's
# choice (#31), knowing what it costs: the interface shows the VM as locked by a
# backup while it updates, and a backup job that comes along in that time FAILS
# for it - measured: "Backup of VM ... failed - VM is locked (backup)", the job
# ends "with errors" and sends its notification. What it buys, measured the same
# way: qm shutdown, qm stop and qm reboot all refuse with "VM is locked (backup)"
# and the VM keeps running.
#
# The snapshot values were not an option - the snapshot code would take our
# lock for its own. Adding a value of our own to the schema was rejected for the
# same reason as for containers: a lock left behind after the package is gone
# would be one the schema no longer knows, and the config could not be written.
our $VM_LOCK = 'backup';

sub lock_vm {
    my ($vmid) = @_;

    # set_lock checks first and dies if something else holds a lock - a real
    # backup, a migration - which is the behaviour wanted: that VM is not one
    # to update now.
    PVE::QemuConfig->set_lock(PVE::UpdateManager::Runner::_safe_vmid($vmid), $VM_LOCK);

    return 1;
}

sub unlock_vm {
    my ($vmid, $logfunc) = @_;

    # remove_lock with the value named refuses to take off somebody else's lock.
    eval { PVE::QemuConfig->remove_lock(PVE::UpdateManager::Runner::_safe_vmid($vmid), $VM_LOCK) };
    if (my $err = $@) {
        chomp($err);
        $logfunc->("WARNING: could not remove the update lock - $err") if $logfunc;
        return 0;
    }

    return 1;
}

# One agent command. Returns the answer, or dies with a sentence. The real
# mon_cmd does both: it dies on a timeout, and it RETURNS an agent-side error as
# {error => {desc => ...}} - which a caller that only checks $@ takes for a
# result.
sub _agent {
    my ($vmid, $cmd, %args) = @_;

    my $res = PVE::QemuServer::Monitor::mon_cmd($vmid, $cmd, timeout => $AGENT_TIMEOUT, %args);

    if (ref($res) eq 'HASH' && ref($res->{error}) eq 'HASH') {
        die "agent error: " . ($res->{error}->{desc} // 'unknown') . "\n";
    }

    return $res;
}

sub _ascii_or_die {
    my ($what, @values) = @_;

    for my $value (@values) {
        die "$what contains characters other than ASCII, which the guest agent cannot"
            . " carry - its channel stops answering\n"
            if defined($value) && $value =~ m/[^\x00-\x7f]/;
    }

    return;
}

# Is the agent of this VM answering at all? Never dies.
sub agent_running {
    my ($vmid) = @_;

    return eval {
        PVE::QemuServer::Monitor::mon_cmd($vmid, 'guest-ping', timeout => $PING_TIMEOUT);
        1;
    } ? 1 : 0;
}

# The agent answers, but no longer knows what it started: it was restarted under
# the run. Both errors were measured - the first for the pid, the second for the
# file handle, which is the one that comes up first because the log is read
# before the status is asked.
sub _forgotten {
    my ($err) = @_;

    return $err =~ m/does not exist|has not been found/ ? 1 : 0;
}

# Splits what was read into lines and hands each complete one on. A line can end
# up split across two reads, so the tail is kept until its newline arrives.
sub _emit {
    my ($pending, $data, $logfunc) = @_;

    $$pending .= $data;

    while ($$pending =~ s/\A([^\n]*)\n//) {
        $logfunc->($1);
    }

    return;
}

# Reads whatever has been appended since the last read. Returns the number of
# bytes read; dies when the agent does.
sub _drain {
    my ($vmid, $handle, $pending, $logfunc) = @_;

    my $total = 0;
    while (1) {
        my $res = _agent($vmid, 'guest-file-read', handle => int($handle), count => int($READ_CHUNK));
        my $count = $res->{count} // 0;
        _emit($pending, decode_base64($res->{'buf-b64'} // ''), $logfunc) if $count;
        $total += $count;
        last if $count < $READ_CHUNK;
    }

    return $total;
}

# Opens a file in the VM, positioned where the last reader of it stopped.
sub _open_at {
    my ($vmid, $path, $offset) = @_;

    my $handle = int(_agent($vmid, 'guest-file-open', path => $path, mode => 'r'));

    if ($offset) {
        eval { _agent($vmid, 'guest-file-seek', handle => $handle, offset => int($offset), whence => 'set') };
        if (my $err = $@) {
            eval { _agent($vmid, 'guest-file-close', handle => $handle) };
            die $err;
        }
    }

    return $handle;
}

# The exit code the script wrote, or undef while there is none yet.
sub _read_rc {
    my ($vmid, $path) = @_;

    my $handle = eval { _open_at($vmid, $path, 0) };
    return undef if !defined($handle);

    my $res = eval { _agent($vmid, 'guest-file-read', handle => $handle, count => 64) };
    eval { _agent($vmid, 'guest-file-close', handle => $handle) };

    my $text = decode_base64(($res // {})->{'buf-b64'} // '');

    return $text =~ m/\A(\d+)\s*\z/ ? int($1) : undef;
}

# The exit code of a finished guest-exec-status answer.
sub _exit_code {
    my ($status) = @_;

    return 128 + int($status->{signal}) if defined($status->{signal});

    return int($status->{exitcode} // -1);
}

sub _guest_files {
    my ($vmid) = @_;

    my $stem = "$GUEST_DIR/pve-update-manager-$vmid-" . time() . "-$$";

    return ("$stem.log", "$stem.rc");
}

# Returns the script's exit code like run_lxc does: 124 for the time limit, 128+n
# for a signal, -1 when the run could not be started or followed - in which case
# the reason has been logged.
sub run_vm {
    my ($vmid, $script, $timeout, $logfunc) = @_;

    my $safe_vmid = PVE::UpdateManager::Runner::_safe_vmid($vmid);
    my $secs = PVE::UpdateManager::Runner::_limit($timeout);
    my $interp = PVE::UpdateManager::Runner::interpreter($script);
    my ($log, $rcf) = _guest_files($safe_vmid);

    # Strings, every one: the mirror image of the pid trap above.
    my @args = map { "$_" } (
        '-c', $VM_OUTER, 'pve-update-manager',
        $log, $VM_INNER,
        $rcf, $secs, $PVE::UpdateManager::Runner::KILL_GRACE,
        encode_base64(PVE::UpdateManager::Runner::to_bytes($script), ''),
        @$interp,
    );

    # The script itself is base64 by now; what can still carry a stray character
    # is the interpreter line of its shebang.
    if (!eval { _ascii_or_die('the interpreter line of the script', @args); 1 }) {
        my $err = $@;
        chomp($err);
        $logfunc->("ERROR: $err");
        return -1;
    }

    if (!agent_running($safe_vmid)) {
        $logfunc->("ERROR: the QEMU guest agent of VM $safe_vmid is not answering - the VM"
            . " needs the guest agent enabled in its options and qemu-guest-agent running inside");
        return -1;
    }

    my $pid = eval {
        my $res = _agent($safe_vmid, 'guest-exec', path => '/bin/sh', arg => \@args);
        die "agent returned no pid\n" if !defined($res->{pid});
        int($res->{pid});
    };
    if (!defined($pid)) {
        my $err = $@ // '';
        chomp($err);
        $logfunc->("ERROR: could not start the update script in VM $safe_vmid - $err");
        return -1;
    }

    my ($rc, $handle) = _follow($safe_vmid, $pid, $log, $rcf, $secs, $logfunc);

    _cleanup($safe_vmid, $handle, [$log, $rcf], $logfunc);

    return $rc;
}

# Follows a started run to its end. Returns (exit code, the open log handle).
#
# Two ways to learn the end: the agent's guest-exec-status for as long as the
# agent still knows the pid, and the exit-code file once it does not. The log is
# read the same way in both, from a handle that is opened again - at the same
# offset - whenever the agent has lost it.
sub _follow {
    my ($vmid, $pid, $log, $rcf, $secs, $logfunc) = @_;

    my $pending = '';
    my $offset = 0;
    my $handle;
    my $opened = 0;
    my $misses = 0;
    my $deadline = time() + $secs + $PVE::UpdateManager::Runner::OUTER_GRACE;

    my $flush = sub {
        $logfunc->($pending) if length($pending);
        $pending = '';
        $logfunc->("WARNING: the log of the run inside VM $vmid could never be opened - its"
            . " output is not shown") if !$opened;
    };

    # A log that is not there (yet) is not an agent failure: the outer part
    # creates it as its first act, and the first read can simply come a moment
    # earlier. Swallowed here so the status below is still asked - otherwise a
    # log that never appears would also hide the end of the run.
    my $read = sub {
        eval {
            $handle //= _open_at($vmid, $log, $offset);
            $opened = 1;
            $offset += _drain($vmid, $handle, \$pending, $logfunc);
            1;
        } or do {
            my $err = $@;
            die $err if $opened || $err !~ m/No such file/i;
        };
    };

    while (1) {
        my $status = eval {
            $read->();
            defined($pid) ? _agent($vmid, 'guest-exec-status', pid => int($pid)) : undef;
        };

        if (my $err = $@) {
            chomp($err);

            if (_forgotten($err)) {
                if (defined($pid)) {
                    $logfunc->("the guest agent of VM $vmid was restarted while the update ran"
                        . " (an upgrade of qemu-guest-agent does that) - following it on");
                }
                $pid = undef;
                $handle = undef;
                $misses = 0;
            } elsif (++$misses >= $MAX_MISSES) {
                $flush->();
                $logfunc->("ERROR: the guest agent of VM $vmid stopped answering ($err) -"
                    . " the update may still be running inside the VM");
                return (-1, $handle);
            }
        } else {
            $misses = 0;

            if (defined($status) && $status->{exited}) {
                # What the script printed between the last read and its end.
                eval { $read->() };
                $flush->();
                return (_exit_code($status), $handle);
            }

            if (!defined($pid)) {
                my $rc = _read_rc($vmid, $rcf);
                if (defined($rc)) {
                    eval { $read->() };
                    $flush->();
                    return ($rc, $handle);
                }
            }
        }

        if (time() > $deadline) {
            $flush->();
            $logfunc->("ERROR: VM $vmid did not finish within ${secs}s although the limit is"
                . " enforced inside it - the update may still be running there");
            return (-1, $handle);
        }

        Time::HiRes::sleep($POLL);
    }
}

# Never dies, and never decides the outcome: the run has already happened.
sub _cleanup {
    my ($vmid, $handle, $files, $logfunc) = @_;

    eval { _agent($vmid, 'guest-file-close', handle => int($handle)) } if defined($handle);

    # Waited for, although its outcome decides nothing: the agent keeps the
    # result of every guest-exec until somebody fetches it, so an `rm` that is
    # started and forgotten would leave one entry behind in the agent per run.
    my $removed = eval {
        my $pid = int(_agent($vmid, 'guest-exec', path => '/bin/rm', arg => ['-f', '--', @$files])->{pid});
        my $status;
        for (1 .. $RM_TRIES) {
            $status = _agent($vmid, 'guest-exec-status', pid => $pid);
            last if $status->{exited};
            Time::HiRes::sleep($RM_WAIT);
        }
        $status->{exited} && !$status->{exitcode} && !defined($status->{signal});
    };
    $logfunc->("WARNING: could not remove " . join(' and ', @$files) . " inside VM $vmid"
        . ($@ ? " - $@" : ''))
        if !$removed;

    return;
}

1;
