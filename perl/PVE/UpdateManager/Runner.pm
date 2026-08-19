package PVE::UpdateManager::Runner;

# Runs an update script - inside a container via `pct exec`, or on the node
# itself - and streams every line into the caller's log function (which, inside
# a Proxmox worker, is the task log).

use strict;
use warnings;

use PVE::LXC::Config;
use PVE::Storage;
use PVE::Tools;

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

# The same job done inside the container, where we cannot know in advance
# whether coreutils, busybox or nothing at all provides `timeout`. The probe
# costs nothing and a container without a usable one still runs - it just gets
# the old behaviour, and says so in the log instead of pretending it is guarded.
#
# The script travels as a positional parameter, never interpolated into this
# text, so there is still no shell that gets to re-parse it.
our $LXC_PROLOGUE = <<'EOS';
secs=$1
grace=$2
script=$3
shift 3
if timeout -k 1 1 true 2>/dev/null; then
    exec timeout -k "$grace" "$secs" "$@" -c "$script"
fi
echo "WARNING: no usable 'timeout' in this container - a run that exceeds ${secs}s will be abandoned, not killed" >&2
exec "$@" -c "$script"
EOS

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

# ── A rollback point before the update ──────────────────────────────────────
#
# A dist-upgrade is the operation people most want to be able to undo, and on a
# storage that can snapshot, undoing it costs a second. So this is on by
# default - but only where the storage really can, which is not a question about
# ZFS: LVM-thin, RBD and btrfs snapshot too, and a container on a directory
# storage cannot however the node is set up. PVE already knows the answer per
# container, and asking it is better than keeping our own list of storage types
# that would be wrong the first time a plugin gains the feature.

our $SNAPSHOT_PREFIX = 'updmgr';

# The name has to satisfy PVE's pve-configid format - a letter first, then
# letters, digits, underscores and dashes, at most 40 characters - which
# `updmgr-20260819-031500` does at 22.
#
# Local time, because this name is what an operator reads in the snapshot list
# and a UTC timestamp there is a puzzle. It is deliberately NOT what the pruning
# below sorts on: an hour repeats itself once a year and a name that sorts
# wrongly would delete the wrong snapshot.
sub snapshot_name {
    my ($when) = @_;

    my @t = localtime($when // time());

    return sprintf(
        '%s-%04d%02d%02d-%02d%02d%02d',
        $SNAPSHOT_PREFIX, $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0],
    );
}

# Ours and nobody else's. Whatever is pruned has to be something this addon made:
# deleting a snapshot somebody took by hand before a migration would be a data
# loss with our name on it.
sub is_our_snapshot {
    my ($name) = @_;

    return defined($name) && $name =~ m/\A\Q$SNAPSHOT_PREFIX\E-\d{8}-\d{6}\z/ ? 1 : 0;
}

# Can this container be snapshotted at all? PVE's own answer, per container -
# every one of its volumes has to support it, which is why a container with one
# mountpoint on a directory storage says no even on a node full of ZFS.
#
# Never dies: this is asked while building a settings dialog and while deciding
# whether to snapshot, and neither is a place to fail over a storage.cfg that
# cannot be read. Unknown means "no", which costs a snapshot and never a run.
# $storecfg is optional and only an optimisation: the settings endpoint asks
# this for every container on the node in turn, and reading storage.cfg once for
# all of them also means one warning in the syslog rather than one per container
# when it is the storage config that is broken.
sub can_snapshot {
    my ($vmid, $storecfg) = @_;

    my $safe = eval { _safe_vmid($vmid) };
    return 0 if !defined($safe);

    my $res = eval {
        my $conf = PVE::LXC::Config->load_config($safe);
        $storecfg //= PVE::Storage::config();

        # $snapname and $running are both undef: the question is whether a
        # snapshot can be taken of the container as it is now, and for a
        # container the storage plugins do not consult the running state at all -
        # that argument exists for a VM's saved memory, which an LXC snapshot
        # never has.
        PVE::LXC::Config->has_feature('snapshot', $conf, $storecfg, undef, undef);
    };
    if (my $err = $@) {
        chomp($err);
        warn "pve-update-manager: cannot tell whether CT $safe can be snapshotted: $err\n";
        return 0;
    }

    return $res ? 1 : 0;
}

# Returns the name of the snapshot it made, or dies. Dying is the point: the
# caller asked for a rollback point on a storage that says it can provide one,
# and a run that quietly went ahead without it would have removed the safety net
# in exactly the situation - a full thin pool - where it is needed most.
sub snapshot_lxc {
    my ($vmid, $logfunc, $when) = @_;

    my $safe = _safe_vmid($vmid);
    my $name = snapshot_name($when);

    $logfunc->("taking snapshot $name before the update") if $logfunc;

    PVE::LXC::Config->snapshot_create($safe, $name, 0, 'pve-update-manager: before the update');

    return $name;
}

# Keeps the newest $keep of OUR snapshots and removes the rest.
#
# Ordered by the snaptime PVE records in the config rather than by the name: the
# names carry local time, and one hour a year is lived through twice.
#
# Never dies. Pruning is housekeeping that runs after the update; a snapshot
# that cannot be removed is a warning in the log and a disk that fills up
# slower than it would have, not a failed update.
sub prune_snapshots {
    my ($vmid, $keep, $logfunc) = @_;

    my $safe = eval { _safe_vmid($vmid) };
    return 0 if !defined($safe);

    # The floor is one, not zero: keeping none would delete the snapshot the run
    # has just taken. The pattern is checked before the comparison because this
    # is callable with whatever a settings file happened to contain, and `<` on
    # a non-number is a warning in the task log rather than an answer.
    $keep = 1 if !defined($keep) || "$keep" !~ m/\A\d+\z/ || $keep < 1;

    my $snapshots = eval { PVE::LXC::Config->load_config($safe)->{snapshots} } || {};

    my @ours =
        sort { ($snapshots->{$a}->{snaptime} // 0) <=> ($snapshots->{$b}->{snaptime} // 0)
                or $a cmp $b }
        grep { is_our_snapshot($_) }
        keys %$snapshots;

    my $excess = scalar(@ours) - $keep;
    return 0 if $excess <= 0;

    my $removed = 0;
    for my $name (@ours[0 .. $excess - 1]) {
        $logfunc->("removing old update snapshot $name") if $logfunc;

        eval { PVE::LXC::Config->snapshot_delete($safe, $name, 0); 1 } or do {
            my $err = $@ // '';
            chomp($err);
            $logfunc->("WARNING: could not remove the old snapshot $name - $err") if $logfunc;
            next;
        };

        $removed++;
    }

    return $removed;
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
our $LXC_LOCK = 'mounted';

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

sub run_lxc {
    my ($vmid, $script, $timeout, $logfunc) = @_;

    my $safe_vmid = _safe_vmid($vmid);

    my $secs = _limit($timeout);
    my $interp = interpreter($script);
    my $cmd = [
        $PCT, 'exec', $safe_vmid, '--',
        '/bin/sh', '-c', $LXC_PROLOGUE,
        'pve-update-manager', $secs, $KILL_GRACE, untaint($script), @$interp,
    ];

    return _run($cmd, $secs + $OUTER_GRACE, $logfunc);
}

sub run_host {
    my ($script, $timeout, $logfunc) = @_;

    # No probe here: coreutils is Essential on Debian, so a Proxmox node that
    # cannot run `timeout` cannot run an update script either.
    my $secs = _limit($timeout);
    my $interp = interpreter($script);
    my $cmd = [$TIMEOUT, '-k', $KILL_GRACE, $secs, @$interp, '-c', untaint($script)];

    return _run($cmd, $secs + $OUTER_GRACE, $logfunc);
}

1;
