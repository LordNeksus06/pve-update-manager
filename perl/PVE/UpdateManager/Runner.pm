package PVE::UpdateManager::Runner;

# Runs an update script - inside a container via `pct exec`, or on the node
# itself - and streams every line into the caller's log function (which, inside
# a Proxmox worker, is the task log).

use strict;
use warnings;

use Encode qw(encode);
use MIME::Base64 qw(encode_base64);
use Time::HiRes ();

use PVE::LXC::Config;
use PVE::Tools;

# For STALE_WEDGE_SECONDS, which stale_own_lock reads.
use PVE::UpdateManager::Snapshot;

our $PCT = '/usr/sbin/pct';
our $TIMEOUT = '/usr/bin/timeout';

# Four hours, not one. This limit used to be decorative - it ended the task but
# left the command running - so nobody ever hit it in a way they noticed. Now
# that it really does kill the process group, the number matters: a dist-upgrade
# cut off mid-dpkg leaves a container needing `dpkg --configure -a`. The job of
# this limit is to end a run that is hung (waiting on stdin, on a dead mirror),
# and those hang for ever, so it can afford to sit far above any real upgrade.
our $DEFAULT_TIMEOUT = 4 * 3600;
our $MIN_TIMEOUT = 10;
our $MAX_TIMEOUT = 86400;

# What run_command's own timeout does when it fires is `kill(9, $pid)` on the
# process it started - and nothing else. That kills `pct` on the host while the
# shell it attached to keeps running inside the container, and on the node it
# kills the interpreter while every child it spawned survives. Both were
# measured on PVE 9.2: the task went red, and `sleep 400` was still running
# afterwards. A timeout that leaves an apt-get holding the dpkg lock is worse
# than no timeout, because the next run then fails for a reason that looks
# unrelated.
#
# So the real limit is enforced by coreutils `timeout`, which puts the command
# in its own process group and signals the whole group. run_command's timeout
# stays as an outer backstop, set far enough out that the inner one always wins
# when it works - if it ever fires, something ignored both TERM and KILL.
our $KILL_GRACE = 10;    # seconds between the TERM and the KILL
our $OUTER_GRACE = 30;   # how much longer run_command waits than the inner limit

# The exit code coreutils uses for "the command hit the limit". Worth naming:
# it is the difference between "your update failed" and "your update was cut
# off", which is not something the operator should have to decode from a number.
our $TIMEOUT_RC = 124;

# The environment the script runs in, spelled out rather than inherited.
#
# `pct exec` hands the CALLER's environment to the container, and the caller is
# whoever started the run: pvedaemon for the button in the web interface, the
# timer's service for a scheduled one, a login shell for `pvesh`. Measured on a
# real 9.2 - a caller without HOME gives the script `HOME=[]`, `USER=[]`,
# `LOGNAME=[]` and four variables in total, while the same run started over ssh
# arrives with the admin's HOME, TERM, and even SSH_CLIENT and XDG_SESSION_ID.
#
# So the same script behaved differently depending on who pressed what, and
# anything that wants a home directory - composer, npm, pip, git, gpg - failed
# from the button and worked when it was tested by hand. Composer says it
# outright: "The HOME or COMPOSER_HOME environment variable must be set for
# composer to run correctly".
#
# PATH is here for the same reason and one more: lxc-attach hands over
# /sbin:/bin:/usr/sbin:/usr/bin, without /usr/local/bin - which is where an
# installer puts what it just built, so the next line of the same script cannot
# find it. This is root's login PATH, the one a shell in that container would
# have.
#
# Set, not defaulted: a value that arrives from the caller is a value that
# depends on the caller, which is the thing being fixed.
#
# ── and the timeout ──
#
# Done inside the container, where we cannot know in advance whether coreutils,
# busybox or nothing at all provides `timeout`. The probe costs nothing and a
# container without a usable one still runs - it just gets the old behaviour,
# and says so in the log instead of pretending it is guarded.
#
# The script travels as a positional parameter, never interpolated into this
# text, so there is still no shell that gets to re-parse it.
our $LXC_PROLOGUE = <<'EOS';
secs=$1
grace=$2
b64=$3
raw=$4
shift 4
if script=$(printf %s "$b64" | base64 -d 2>/dev/null) && [ -n "$script" ]; then
    :
else
    echo "WARNING: no usable 'base64' in this container - the script is used as it arrived, and any non-ASCII character in it was replaced on the way" >&2
    script=$raw
fi
HOME=/root
USER=root
LOGNAME=root
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME USER LOGNAME PATH
if timeout -k 1 1 true 2>/dev/null; then
    exec timeout -k "$grace" "$secs" "$@" -c "$script"
fi
echo "WARNING: no usable 'timeout' in this container - a run that exceeds ${secs}s will be abandoned, not killed" >&2
exec "$@" -c "$script"
EOS

# Why the script does not travel as a plain argument.
#
# `pct exec` replaces every non-ASCII BYTE of an argument with U+FFFD. Measured
# on a real 9.2, in one line and without this addon in it:
#
#   pct exec 101 -- sh -c 'printf %s "$1" | od -An -tx1' x "X📦Y"
#     58 ef bf bd ef bf bd ef bf bd ef bf bd 59
#
# X, four replacement characters where the emoji's four bytes were, Y. So a
# script carrying an umlaut arrived inside the container already destroyed -
# before any shell there had seen it - and what it then printed was destroyed
# too, which is how a task log fills up with question marks. A host run has no
# pct in the way and was always clean, which is what made this look like a
# logging problem.
#
# base64 is ASCII, so it survives. The raw script travels beside it for the one
# case that cannot be helped: a container with no `base64`, where the old
# behaviour is kept and said out loud rather than silently running something
# else. coreutils and busybox both have it.
our $SCRIPT_TRANSPORT = 'base64';

# An update script is CHARACTERS by the time it gets here - the storage decodes
# what it reads, because everything above it speaks characters. exec does not:
# argv is bytes. Left to itself Perl writes anything below U+0100 as Latin-1, so
# a script whose only non-ASCII is `üöä` would reach the container as fc f6 e4
# and its own shell would see mojibake.
sub to_bytes {
    my ($script) = @_;

    return $script if !defined($script);

    return encode('UTF-8', $script);
}

# pvedaemon runs with -T, so everything that arrived over the API or came out
# of a file is tainted and perl refuses to exec it. Untainting here is
# deliberate and not a hole being punched: an update script IS arbitrary root
# code by design. What guards it is the permission check on the API method
# (VM.Console for a container, Sys.Console for the node), not a pattern match -
# there is no pattern that separates a good `apt-get` line from a bad one.
sub untaint {
    my ($str) = @_;
    return undef if !defined($str);
    my ($clean) = $str =~ m/\A(.*)\z/s;
    return $clean;
}

# The first line may be a shebang and picks the interpreter. Default /bin/sh:
# an Alpine or busybox container has no bash, and a default of bash would turn
# "your commands did not run" into a puzzle about which shell was missing.
sub interpreter {
    my ($script) = @_;

    if (defined($script) && $script =~ m|\A\#\!\s*(/[^\s\n]+)([^\n]*)|) {
        my ($prog, $rest) = ($1, $2 // '');
        my @args = grep { length($_) } split(/\s+/, $rest);
        return [untaint($prog), map { untaint($_) } @args];
    }

    return ['/bin/sh'];
}

# run_command dies on a timeout no matter what `noerr` says, and a worker that
# dies with a raw perl message reads badly in the task log. Catch it here and
# turn every failure into an exit code the caller can report uniformly.
sub _run {
    my ($cmd, $timeout, $logfunc) = @_;

    my $out = sub { $logfunc->($_[0]) };

    my $rc;
    eval {
        $rc = PVE::Tools::run_command(
            $cmd,
            timeout => $timeout,
            outfunc => $out,
            errfunc => $out,
            noerr => 1,
        );
    };
    if (my $err = $@) {
        chomp($err);
        $logfunc->("ERROR: $err");
        return -1;
    }

    return $rc;
}

# The limit reaches the command line, so it has to be a plain number there. This
# both untaints it and rejects anything that is not one, rather than handing a
# surprise to the shell.
sub _limit {
    my ($timeout) = @_;

    my $wanted = $timeout // $DEFAULT_TIMEOUT;
    my ($secs) = "$wanted" =~ m/\A([1-9][0-9]{0,6})\z/
        or die "invalid timeout '$wanted'\n";

    return $secs;
}

sub _safe_vmid {
    my ($vmid) = @_;

    my ($safe) = "$vmid" =~ m/\A([1-9][0-9]{2,8})\z/
        or die "invalid vmid '$vmid'\n";

    return $safe;
}

# ── Bringing a stopped container up for its update, and putting it back ──────
#
# Off by default and opt-in per node, because starting a container that somebody
# deliberately stopped is not a neutral act: it runs its services, its cron, and
# whatever else its init does, for as long as the update takes.

our $START_TIMEOUT = 180;      # how long `pct start` itself may take
our $ONLINE_TIMEOUT = 90;      # how long to wait for the container to be usable
our $SHUTDOWN_TIMEOUT = 120;   # how long a graceful shutdown may take

# What switching one container off and on again can cost on top of the limit
# that bounds its script: two shutdowns at worst - the graceful one and the hard
# stop behind it - a start, and the wait for a default route. None of that is
# inside the per-target timeout, so anything that sizes a run by the timeout
# alone underestimates a batch that starts stopped containers or takes its
# snapshots cold.
our $PER_TARGET_GRACE =
    2 * ($SHUTDOWN_TIMEOUT + 30) + $START_TIMEOUT + $ONLINE_TIMEOUT;

# "Usable" cannot mean "the process exists": lxc-attach works long before the
# container has an address, and an apt-get that starts there fails on DNS in a
# way that reads like a broken mirror. A default route is the closest honest
# signal, and reading it out of /proc needs no tools inside the container - this
# works on busybox and on systemd alike, which `ip route` would not.
our $ONLINE_PROBE = <<'EOS';
while read -r _ dest _; do
    [ "$dest" = "00000000" ] && exit 0
done < /proc/net/route
exit 1
EOS

sub start_lxc {
    my ($vmid, $logfunc) = @_;

    my $safe = _safe_vmid($vmid);

    return _run([$PCT, 'start', $safe], $START_TIMEOUT, $logfunc);
}

# Returns true once the container has a default route, false if it never gets
# one. A false is deliberately not fatal - a container with no network at all is
# a legitimate thing to update from a local mirror or a bind mount.
sub wait_online {
    my ($vmid, $logfunc, $seconds) = @_;

    my $safe = _safe_vmid($vmid);
    my $deadline = time() + ($seconds // $ONLINE_TIMEOUT);

    while (1) {
        # Output swallowed: while the container is still coming up this fails
        # in a dozen different ways, none of which is worth a line in the log.
        my $rc = _run([$PCT, 'exec', $safe, '--', '/bin/sh', '-c', $ONLINE_PROBE], 30, sub { });
        return 1 if defined($rc) && $rc == 0;

        return 0 if time() >= $deadline;
        sleep 2;
    }
}

# Graceful first. We are putting a container back the way we found it, and a
# hard stop is a power cut - the wrong way to end an update that just rewrote
# half the packages on it. The hard stop stays as the fallback, because leaving
# it running would be a worse outcome than an unclean stop.
sub shutdown_lxc {
    my ($vmid, $logfunc) = @_;

    my $safe = _safe_vmid($vmid);

    my $rc = _run(
        [$PCT, 'shutdown', $safe, '--timeout', $SHUTDOWN_TIMEOUT],
        $SHUTDOWN_TIMEOUT + 30,
        $logfunc,
    );
    return $rc if defined($rc) && $rc == 0;

    $logfunc->('graceful shutdown did not finish, stopping the container');

    return _run([$PCT, 'stop', $safe], 60, $logfunc);
}

# ── Keeping things from being switched off mid-update ────────────────────────
#
# A dist-upgrade that is interrupted by a shutdown leaves a container needing
# `dpkg --configure -a`, and a node that goes down mid-apt is worse. Proxmox
# already knows how to refuse that - every stop, shutdown, reboot and migrate
# path calls check_lock first - so the container half needs no new mechanism,
# only the lock PVE already honours.
#
# The value has to come out of the enum in PVE's own config schema, which has no
# 'update' in it. Adding one at runtime was the tempting alternative and is a
# trap: a lock left behind after the package is removed would be a value the
# schema no longer knows, and the container's config could then not be written
# at all. 'mounted' is the closest of the permitted values - work is happening
# inside this container's filesystem - and it stays valid with or without us.
our $LXC_LOCK = 'mounted';    # also read by stale_own_lock() above

sub lock_guest {
    my ($vmid) = @_;

    # set_lock checks first and dies if something else holds it, which is the
    # behaviour we want: a container being backed up is not one to update.
    PVE::LXC::Config->set_lock(_safe_vmid($vmid), $LXC_LOCK);

    return 1;
}

sub unlock_guest {
    my ($vmid, $logfunc) = @_;

    eval { PVE::LXC::Config->remove_lock(_safe_vmid($vmid), $LXC_LOCK) };
    if (my $err = $@) {
        chomp($err);
        $logfunc->("WARNING: could not remove the update lock - $err") if $logfunc;
        return 0;
    }

    return 1;
}

# Has a lock of OURS been sitting untouched long enough to be abandoned?
#
# A worker that is killed - node reboot, an out-of-memory kill - never reaches
# unlock_guest, and the 'mounted' lock it took stays on the container. Every
# later run then skips it with "another task holds the lock (mounted)", every
# night, until somebody runs `pct unlock` - and nothing anywhere says that is
# what is needed.
#
# What this does NOT do is take the lock off. 'mounted' is a value PVE uses
# itself: `pct mount` sets exactly this one, and a container whose rootfs is
# mounted on the host is the last thing to start writing into from a second
# direction. There is no evidence available here that separates our abandoned
# lock from somebody else's live one - so the answer is a better sentence in the
# row, not an automatic repair.
#
# The clock is the container's own config file, the same measurement
# stale_delete_wedge uses: a lock somebody is actively working under gets that
# file written; one nobody has touched for ten minutes does not.
sub stale_own_lock {
    my ($vmid, $now) = @_;

    my $safe = eval { _safe_vmid($vmid) };
    return 0 if !defined($safe);

    my $conf = eval { PVE::LXC::Config->load_config($safe) } // {};
    return 0 if ($conf->{lock} // '') ne $LXC_LOCK;

    my $file = eval { PVE::LXC::Config->config_file($safe) };
    return 0 if !defined($file);

    my $mtime = (stat($file))[9];
    return 0 if !defined($mtime);

    $now //= time();

    return (($now - $mtime) >= $PVE::UpdateManager::Snapshot::STALE_WEDGE_SECONDS) ? 1 : 0;
}

# The node itself is not a guest and has no config lock, so shutdown and reboot
# are held off with a systemd inhibitor instead. --mode=block is what makes
# `systemctl poweroff` refuse and name us; an operator who means it can still
# override, which is the right balance for a machine somebody is standing at.
#
# The child is given a deadline rather than being trusted to be killed: if this
# worker is killed, the inhibitor still lets go by itself instead of blocking
# shutdown until the next reboot - which is a fine way to make a box unbootable
# to reason about.
our $INHIBIT = '/usr/bin/systemd-inhibit';

sub inhibit_shutdown {
    my ($seconds, $logfunc) = @_;

    return undef if !-x $INHIBIT;

    my ($secs) = "$seconds" =~ m/\A([1-9][0-9]{0,6})\z/
        or return undef;

    my $pid = open(my $fh, '-|', $INHIBIT,
        '--what=shutdown',
        '--who=pve-update-manager',
        '--why=an update is running',
        '--mode=block',
        '/bin/sleep', $secs,
    );

    if (!$pid) {
        $logfunc->('WARNING: could not hold off shutdown while updating') if $logfunc;
        return undef;
    }

    return { pid => $pid, fh => $fh };
}

sub release_shutdown {
    my ($handle) = @_;

    return if !$handle;

    kill('TERM', $handle->{pid});
    # Reaps the child, so a long run does not leave a zombie behind for the
    # lifetime of the worker.
    eval { close($handle->{fh}) };

    return;
}

# ── Surviving a restart of the daemon that started this run ─────────────────
#
# A worker forked by pvedaemon lives in pvedaemon.service's control group, and
# systemd's default KillMode is control-group: stopping a unit sends SIGTERM to
# EVERY process in it, not only to the main one. So `systemctl restart pvedaemon`
# does not merely replace the daemon - it kills the tasks running under it, and
# one of those is this addon's dist-upgrade.
#
# Measured on PVE 9.2 with a host script that prints a counter:
#
#   worker 545034: 0::/system.slice/pvedaemon.service
#   # systemctl restart pvedaemon
#   -> "TASK ERROR: received interrupt", worker and script both gone
#
# Not a theoretical hazard: it happened during a host update, at the "Setting
# up" of a package whose postinst restarts pvedaemon, and left the node with
# sixteen packages unpacked and one configured - needing `dpkg --configure -a`,
# which is the state every timeout in this file exists to avoid.
#
# Proxmox' own packages do not cause it. They use `deb-systemd-invoke
# reload-or-try-restart`, and pvedaemon's ExecReload is `pvedaemon restart` -
# PVE's own graceful re-exec, which leaves running workers alone. Measured too:
# the same run does not notice `systemctl reload pvedaemon`. But which packages
# an operator installs is not ours to choose, and a half-applied dist-upgrade is
# not something to lose to somebody else's postinst.
#
# So the worker leaves that control group before it starts anything, into a
# transient systemd scope of its own. It stays the same process - same pid, same
# task log file, same UPID - so the task list, the log window and the Stop button
# all keep working; Stop signals the process GROUP, which setsid() gave the
# worker and which a cgroup move does not touch. Every child forked afterwards
# lands in the scope too, which is the point: the script is what has to survive.
#
# busctl rather than `systemd-run --scope`, which forks a NEW process into a new
# scope. What has to move here already exists, and StartTransientUnit with a PIDs
# property is the documented way to move it. busctl ships with systemd, so it is
# on every node that has the problem.
our $BUSCTL = '/usr/bin/busctl';

# Read through a variable so a test can point it at a file it controls.
our $CGROUP_FILE = '/proc/self/cgroup';

# StartTransientUnit returns once the job is QUEUED, so the move has not
# necessarily happened by the time busctl exits - measured at well under a
# second, but waited for rather than assumed: a run that only believes it moved
# would report itself protected while it is not.
our $SCOPE_WAIT = 5;

sub _own_cgroup {
    open(my $fh, '<', $CGROUP_FILE) or return undef;
    my $line = <$fh>;
    close($fh);

    # The unified hierarchy only, which is the one line that starts "0::". A
    # node still on cgroup v1 has several lines and no single answer for "where
    # am I" - there the run stays where it is rather than being moved on a guess.
    return undef if !defined($line) || $line !~ m|\A0::(\S*)|;

    return $1;
}

# Returns true if this process now lives in a scope of its own. Never dies: this
# is protection, and a run that cannot have it is still a run that has to happen.
sub detach_from_daemon {
    my ($logfunc, $label) = @_;

    my $cgroup = _own_cgroup();
    return 0 if !defined($cgroup);

    # Only out of a SERVICE. A run started from a login shell sits in that
    # session's scope, where no daemon restarts underneath it and moving it would
    # only take it out of the session it belongs to.
    return 0 if $cgroup !~ m|/([^/]+)\.service\z|;
    my $unit = "$1.service";

    if (!-x $BUSCTL) {
        $logfunc->("WARNING: $BUSCTL is missing - a restart of $unit interrupts this run")
            if $logfunc;
        return 0;
    }

    my @out;
    my $rc = eval {
        PVE::Tools::run_command(
            [
                $BUSCTL, 'call',
                'org.freedesktop.systemd1', '/org/freedesktop/systemd1',
                'org.freedesktop.systemd1.Manager', 'StartTransientUnit',
                'ssa(sv)a(sa(sv))', "pve-update-manager-run-$$.scope", 'fail', 3,
                'PIDs', 'au', 1, $$,
                'Description', 's', 'pve-update-manager: ' . ($label // 'update run'),
                # Without this a scope whose process was killed stays behind in
                # "failed" state, and the run that later reuses that pid cannot
                # create its own.
                'CollectMode', 's', 'inactive-or-failed',
                0,
            ],
            timeout => 30,
            outfunc => sub { push @out, $_[0] },
            errfunc => sub { push @out, $_[0] },
            noerr => 1,
        );
    };
    if (my $err = $@) {
        chomp($err);
        push @out, $err;
        $rc = -1;
    }

    my $why = @out ? ' (' . join('; ', @out) . ')' : '';

    if (!defined($rc) || $rc != 0) {
        $logfunc->(
            "WARNING: could not move this run out of $unit - restarting that"
                . " service interrupts the update$why",
        ) if $logfunc;
        return 0;
    }

    my $deadline = time() + $SCOPE_WAIT;
    while (1) {
        my $now = _own_cgroup();
        last if defined($now) && $now ne $cgroup;

        if (time() >= $deadline) {
            $logfunc->(
                "WARNING: systemd took the request but this run is still in $unit -"
                    . " restarting that service interrupts the update",
            ) if $logfunc;
            return 0;
        }

        Time::HiRes::sleep(0.1);
    }

    $logfunc->(
        "this run has moved out of $unit into a systemd scope of its own -"
            . " restarting that service no longer interrupts it",
    ) if $logfunc;

    return 1;
}

sub run_lxc {
    my ($vmid, $script, $timeout, $logfunc) = @_;

    my $safe_vmid = _safe_vmid($vmid);

    my $secs = _limit($timeout);
    my $interp = interpreter($script);
    my $cmd = [
        $PCT, 'exec', $safe_vmid, '--',
        '/bin/sh', '-c', $LXC_PROLOGUE,
        'pve-update-manager', $secs, $KILL_GRACE,
        untaint(encode_base64(to_bytes($script), '')),
        untaint(to_bytes($script)),
        @$interp,
    ];

    return _run($cmd, $secs + $OUTER_GRACE, $logfunc);
}

# The same baseline the container prologue sets, for the same reason: a worker
# forked by pvedaemon has no HOME either, and a host script that runs composer or
# git would fail there and work from a shell. `env` rather than a wrapper script
# because there is no shell in between here - the argv is what runs.
our @HOST_ENV = (
    'HOME=/root',
    'USER=root',
    'LOGNAME=root',
    'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
);

our $ENV_BIN = '/usr/bin/env';

sub run_host {
    my ($script, $timeout, $logfunc) = @_;

    # No probe here: coreutils is Essential on Debian, so a Proxmox node that
    # cannot run `timeout` cannot run an update script either - and the same
    # goes for `env`.
    my $secs = _limit($timeout);
    my $interp = interpreter($script);
    my $cmd = [
        $TIMEOUT, '-k', $KILL_GRACE, $secs,
        $ENV_BIN, @HOST_ENV,
        @$interp, '-c', untaint(to_bytes($script)),
    ];

    return _run($cmd, $secs + $OUTER_GRACE, $logfunc);
}

1;
