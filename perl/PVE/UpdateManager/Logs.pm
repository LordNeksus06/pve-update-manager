package PVE::UpdateManager::Logs;

# the log of each past run per target, under /var/lib: writing, listing, reading, pruning.
#
# Split out of Config.pm (#21), which was 1705 lines. What stays there is the
# storage under /etc/pve that everything else builds on - the base directory,
# the scripts, the update order and the per-target state - and the target lock.

use strict;
use warnings;

use File::Path ();
use PVE::Tools;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Versions;

# ── the log of a past run, per target ───────────────────────────────────────
#
# One file per run and target, named the way a saved script version is:
#
#   /var/lib/pve-update-manager/logs/lxc-101@2026-08-21-13-21-12.log
#
# NOT in /etc/pve, and that is not a preference. It was measured on PVE 9.2, all
# four of these, because splitting a log into 1 MiB parts to fit it in there is an
# obvious idea and the numbers are what rule it out:
#
#   per file      1 MiB. 1024 KiB written, 1025 KiB refused.
#   in total      128 MiB for the WHOLE cluster filesystem - man pmxcfs says so
#                 out loud, and the reason is that a copy resides in RAM on every
#                 node. The real configuration of a node uses 44 KiB of it; one
#                 target's logs at this addon's own ceiling (8 MiB x 3) would use
#                 24 MiB, so five containers would fill the filesystem that PVE
#                 keeps its VM configs, firewall rules and locks in.
#   per write     3 MiB took 0.30s to /etc/pve and 0.009s to /var/lib - 32x, on a
#                 single node with no replication at all. In a cluster every byte
#                 of that goes through corosync to every node, synchronously,
#                 alongside the HA state.
#   afterwards    the space is not given back. Writing 40 MiB of files and
#                 deleting them again left config.db at 41 MiB, because SQLite
#                 does not reclaim on its own and pmxcfs has no VACUUM. A month of
#                 update runs would inflate the cluster database permanently even
#                 though every log had been pruned.
#
# A run happens on the node that owns the target, so its log belongs to that node.
# In a cluster that means a log is not replicated - and it is still readable from
# any node's web interface, because every endpoint that serves one is
# `proxyto => 'node'` and the interface addresses the owning node. What is
# node-local is the shell view.
#
# Why keep one at all when Proxmox already writes a task log: the task log stays
# on disk but stops being reachable. /var/log/pve/tasks/index is renamed to
# index.1 once it passes 50000 bytes - about a thousand tasks - so the entry that
# points at a log falls out of the task list after a couple of thousand tasks,
# and the file is then a name nobody can find. Read off
# PVE::RESTEnvironment rather than assumed, and there is no logrotate rule for
# the directory either: 431 files, the oldest a month old, on the test node.
our $LOG_DIR = '/var/lib/pve-update-manager/logs';

our $DEFAULT_RUN_LOGS = 3;

# Zero is allowed here, unlike the script versions: keeping none is a legitimate
# answer for a log ("do not spend the disk"), while keeping no version of the
# script would throw away the save that was just made.
our $MIN_RUN_LOGS = 0;
our $MAX_RUN_LOGS = 50;

# Above what a run can write, not equal to it: file_get_contents DIES on a file
# over its limit, and a log that cannot be read back is worse than a log that is
# large. One target is capped at 8 MiB of output by the job, and the header and
# the runner's own lines sit on top of that.
our $MAX_LOG_SIZE = 16 * 1024 * 1024;

# Root's alone, the directory and every log in it (#67): a log is what a script
# printed inside somebody's guest, and the API hands it only to a user with
# VM.Audit on that guest. Left to the umask it was 0755 with 0644 logs, readable
# by every local account of the node past that check.
our $LOG_DIR_MODE = 0700;
our $LOG_FILE_MODE = 0600;

sub _ensure_log_dir {
    # mkpath rather than mkdir: /var/lib/pve-update-manager exists on an
    # installed node, but not in a test tmpdir - and a log that fails to be
    # written must not depend on which of the two this is.
    File::Path::make_path($LOG_DIR, { mode => $LOG_DIR_MODE }) if !-d $LOG_DIR;

    die "unable to create '$LOG_DIR'\n" if !-d $LOG_DIR;

    # Every time, not only when it is created: a node that ran an older version
    # has the directory at 0755 already, with its logs at 0644 in it - and the
    # directory's mode is what closes those, without touching each file.
    chmod($LOG_DIR_MODE, $LOG_DIR) or die "unable to restrict '$LOG_DIR' - $!\n";

    return;
}

# The path of one run log. Built from the same validated target name the script
# file is built from, so a vmid that could walk out of a directory is refused in
# one place for both.
sub log_file {
    my ($type, $id, $stamp) = @_;

    my $stem = PVE::UpdateManager::Config::script_file($type, $id);
    $stem =~ s{\A.*/}{};
    $stem =~ s/\.conf\z//;

    my ($safe_stamp) = "$stamp" =~ m/\A($PVE::UpdateManager::Versions::STAMP_RE)\z/
        or die "invalid run log '$stamp'\n";

    return "$LOG_DIR/$stem\@$safe_stamp.log";
}

# Every stored log of a target's runs, newest first. Never dies: this is read
# while building a menu.
sub list_logs {
    my ($type, $id) = @_;

    my $stem = eval { PVE::UpdateManager::Config::script_file($type, $id) };
    return [] if !defined($stem);
    $stem =~ s{\A.*/}{};
    $stem =~ s/\.conf\z//;

    opendir(my $dh, $LOG_DIR) or return [];
    my @names = readdir($dh);
    closedir($dh);

    my $res = [];
    for my $name (@names) {
        my ($stamp) = $name =~ m/\A\Q$stem\E\@($PVE::UpdateManager::Versions::STAMP_RE)\.log\z/
            or next;

        my $epoch = PVE::UpdateManager::Versions::stamp_epoch($stamp);
        # A name whose date is not a date is a name this did not write, and it
        # has no place in an order.
        next if !defined($epoch);

        my $size = (stat("$LOG_DIR/$name"))[7];

        # The header, and only the header: a log is up to 8 MiB and a listing of
        # fifty of them may not read 400 MiB to answer "which of these failed".
        # What comes out is the same pair the grid already renders a run with -
        # a state and a note - so one renderer serves both.
        my $head = _log_header("$LOG_DIR/$name");

        push @$res, {
            log => $stamp,
            time => $epoch,
            size => defined($size) ? int($size) : 0,
            %$head,
        };
    }

    return [sort { $b->{time} <=> $a->{time} || ($b->{log} cmp $a->{log}) } @$res];
}

# How big a bite of a log is enough to hold its header. The header is six short
# lines; a kilobyte is room for a target name nobody would type and still cheap
# enough to do fifty times.
our $LOG_HEADER_BYTES = 1024;

# What the first lines of a stored log say about the run, for a listing.
#
# Parsed rather than kept in a second file: the log IS the record, and an index
# beside it is a second thing to keep in step - one that would be wrong for every
# log written before it existed. Never dies: a file half-written by a killed
# worker must cost its own row's detail, not the whole listing.
sub _log_header {
    my ($file) = @_;

    my $raw = '';
    if (open(my $fh, '<', $file)) {
        read($fh, $raw, $LOG_HEADER_BYTES);
        close($fh);
    }

    my $res = {};

    # The state as its own field, the rest of the line as the note - the same
    # shape PVE::UpdateManager::Config::last_run() hands the grid, so the same renderer draws both.
    # Words, not one: "NOT FIXED" (#73) is two, and a single \S+ left such a log
    # without a state. Underscored, as the state file writes it.
    if ($raw =~ m/^result:\s+([A-Z]+(?: [A-Z]+)*)(?:\s+\((.*)\))?\s*$/m) {
        ($res->{state} = lc($1)) =~ s/ /_/g;
        $res->{note} = $2 if defined($2) && length($2);
    }

    # A UPID is what opens Proxmox' own task log for the same run - while that
    # log is still reachable, which is the whole reason this copy exists.
    if ($raw =~ m/^task:\s+(UPID:\S+)\s*$/m) {
        $res->{upid} = $1;
    }

    return $res;
}

sub load_log {
    my ($type, $id, $stamp) = @_;

    my $file = log_file($type, $id, $stamp);
    return undef if !-f $file;

    return PVE::UpdateManager::Config::from_utf8(PVE::Tools::file_get_contents($file, $MAX_LOG_SIZE));
}

# Writes one, then drops the oldest above the retention count. Returns the stamp
# it was stored under, or undef when nothing was stored.
sub save_log {
    my ($type, $id, $text, $keep, $when) = @_;

    $keep = log_retention($keep);
    return undef if $keep < 1;

    my $epoch = $when // time();
    my $stamp = PVE::UpdateManager::Versions::version_stamp($epoch);

    # Past a name that is taken, for the reason the script versions have the same
    # loop: the name carries local time, and the hour a DST change repeats has
    # two of every second in it.
    # No eval around log_file here: version_stamp always produces a stamp it
    # accepts, so the only way it dies is an id that should never have reached
    # this - and swallowing that would mean 120 turns of `-e undef` before the
    # write fails anyway, with a warning about an uninitialised value instead of
    # the reason.
    for (1 .. 120) {
        last if !-e log_file($type, $id, $stamp);
        $epoch++;
        $stamp = PVE::UpdateManager::Versions::version_stamp($epoch);
    }

    _ensure_log_dir();

    PVE::Tools::file_set_contents(log_file($type, $id, $stamp), PVE::UpdateManager::Config::to_utf8($text),
        $LOG_FILE_MODE);

    prune_logs($type, $id, $keep);

    return $stamp;
}

# The retention count, clamped. Its own function because three places need the
# same answer and a `//` chain in each of them is three places to get it wrong.
sub log_retention {
    my ($keep) = @_;

    return $DEFAULT_RUN_LOGS if !defined($keep) || "$keep" !~ m/\A\d+\z/;
    return $MIN_RUN_LOGS if $keep < $MIN_RUN_LOGS;
    return $MAX_RUN_LOGS if $keep > $MAX_RUN_LOGS;

    return int($keep);
}

sub prune_logs {
    my ($type, $id, $keep) = @_;

    $keep = log_retention($keep);

    my $logs = list_logs($type, $id);
    return 0 if scalar(@$logs) <= $keep;

    my $removed = 0;
    for my $entry (@$logs[$keep .. $#$logs]) {
        my $file = eval { log_file($type, $id, $entry->{log}) };
        next if !defined($file);

        if (!unlink($file)) {
            warn "pve-update-manager: cannot remove the old run log '$file' - $!\n";
            next;
        }
        $removed++;
    }

    return $removed;
}

# Only for wiping a target on purpose - the destroy hook and a purge. A run log
# is not part of what `delete_script` takes: what a container did last week is
# not a fact about the commands that were stored at the time.
sub delete_logs {
    my ($type, $id) = @_;

    my $removed = 0;
    for my $entry (@{ list_logs($type, $id) }) {
        my $file = eval { log_file($type, $id, $entry->{log}) };
        next if !defined($file);
        $removed++ if unlink($file);
    }

    return $removed;
}

1;
