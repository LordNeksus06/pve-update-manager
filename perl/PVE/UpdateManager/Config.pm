package PVE::UpdateManager::Config;

# Storage for the update scripts.
#
# One plain file per target, holding exactly what the user typed into the text
# box - no encoding, no wrapper format. `cat /etc/pve/pve-update-manager/lxc-101.conf`
# shows the script and an editor can change it without going through the UI.
#
# The scripts live in the cluster filesystem on purpose: /etc/pve is replicated
# to every node, so a container keeps its update script when it migrates, and a
# second node shows the same content. pmxcfs supports both mkdir and the
# tmpfile+rename that file_set_contents does (verified on PVE 9.2).

use strict;
use warnings;

use POSIX ();

use Encode qw(decode encode);

use Errno ();
use Fcntl ();

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;

use PVE::UpdateManager::Runner;
use PVE::UpdateManager::Versions;

# `our` rather than a constant so the test suite can point it at a tmpdir.
our $BASE_DIR = '/etc/pve/pve-update-manager';

# ── bytes on disk, characters everywhere above ──────────────────────────────
#
# The files are UTF-8. Everything above this module speaks CHARACTERS, because
# that is PVE's own convention - ParseUtils::decode_text is an Encode::decode,
# and the REST layer encodes what an endpoint returns.
#
# Getting this wrong is not cosmetic, and both directions were measured on a
# real 9.2:
#
#   returning bytes   the REST layer encoded them a second time. 📦 (f0 9f 93
#                     a6) came back as c3b0 c29f c293 c2a6 - four characters
#                     where one belongs.
#   writing characters  Perl emits Latin-1 for anything below U+0100, so a
#                     script with nothing but umlauts was stored as fc f6 e4
#                     instead of c3 bc c3 b6 c3 a4. With an emoji in the same
#                     string it wrote UTF-8 for all of it, which is why this
#                     looked like it worked whenever it was tested with one.
#
# Together they are a loop that eats a script: the editor shows the doubly
# encoded text, saving it stores that, and a few rounds later what is left is a
# row of replacement characters.
sub from_utf8 {
    my ($raw) = @_;

    return $raw if !defined($raw);

    my $text = eval { decode('UTF-8', $raw, Encode::FB_CROAK()) };
    return $text if defined($text);

    # Not valid UTF-8. Almost certainly a file this addon wrote itself before
    # the above was fixed - Latin-1 for everything below U+0100 - so it is read
    # back the way it was written rather than shown as replacement characters,
    # and the next save rewrites it properly.
    return decode('ISO-8859-1', $raw);
}

sub to_utf8 {
    my ($text) = @_;

    return $text if !defined($text);

    return encode('UTF-8', $text);
}

# pmxcfs refuses files above 1 MiB. Cut off far below that: an update script is
# a handful of lines, and a request that tries to store a megabyte of text is a
# mistake we want to name rather than a write we want to attempt.
our $MAX_SCRIPT_SIZE = 64 * 1024;

# Builds the path AND validates the id. Every caller goes through here, so a
# vmid or node name from an API request can never walk out of $BASE_DIR.
# `or -d` because two saves racing on a fresh install would otherwise have one
# of them die on the other's EEXIST. $! is captured BEFORE the -d stat, which
# would otherwise overwrite it and report a genuine EACCES as "No such file or
# directory".
sub _ensure_base_dir {
    return if -d $BASE_DIR;

    return if mkdir($BASE_DIR);
    my $err = $!;

    return if -d $BASE_DIR;

    die "unable to create '$BASE_DIR' - $err\n";
}

# The public half of the same thing, for the modules that store something beside
# the per-target files - the template list, which has no target and so no
# script_file() call to create the directory as a side effect.
sub ensure_base_dir {
    _ensure_base_dir();

    return $BASE_DIR;
}

sub script_file {
    my ($type, $id) = @_;

    # 'qemu' is a type of its own rather than folded into 'lxc', although a
    # vmid is unique across both: the type is the prefix of every file a target
    # has, and a VM stored as lxc-200.conf would be read back as a container by
    # anything that walks the directory.
    die "unknown target type '$type'\n" if $type ne 'lxc' && $type ne 'qemu' && $type ne 'node';
    die "missing target id\n" if !defined($id) || $id eq '';

    my $safe;
    if ($type ne 'node') {
        ($safe) = $id =~ m/\A([1-9][0-9]{2,8})\z/
            or die "invalid vmid '$id'\n";
    } else {
        ($safe) = $id =~ m/\A([A-Za-z0-9](?:[A-Za-z0-9\-\.]{0,62}))\z/
            or die "invalid node name '$id'\n";
    }

    return "$BASE_DIR/$type-$safe.conf";
}

# Returns ($script, $exists). A target with no file yet is not an error - the
# UI shows the default template for it and only writes on save.
sub load_script {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    return (undef, 0) if !-f $file;

    my $raw = PVE::Tools::file_get_contents($file, $MAX_SCRIPT_SIZE);
    return (from_utf8($raw), 1);
}

# "Has a script" means "has something to run", not "has a file". An empty file
# would otherwise show a tick in the grid and then be skipped at run time for
# having no commands - a row that promises one thing and does another.
#
# Never dies. This is called once per target while building the node and
# datacenter lists, and load_script dies on a file above $MAX_SCRIPT_SIZE - so a
# single hand-written oversized file used to take out the WHOLE list, for every
# target, on both tabs. One broken target may cost its own row's tick and a line
# in the syslog; it may not cost the list.
sub has_script {
    my ($type, $id) = @_;

    my ($script) = eval { load_script($type, $id) };
    if (my $err = $@) {
        chomp($err);
        warn "pve-update-manager: cannot read the update script of $type $id: $err\n";
        return 0;
    }

    return (defined($script) && $script =~ m/\S/) ? 1 : 0;
}

sub save_script {
    my ($type, $id, $script, $user) = @_;

    my $file = script_file($type, $id);

    # Text pasted out of a Windows editor carries CR before every LF, and a shell
    # takes those as part of the command: measured, a pasted script died with
    # "$'uptime\r': command not found", which names neither the cause nor the
    # cure. A literal CR in a shell script is always an accident - anyone who
    # wants one writes it as an escape - so it is dropped here, at the one place
    # everything is stored through, and what the box shows afterwards is what
    # will actually run.
    $script =~ s/\r\n/\n/g if defined($script);

    # The limit is pmxcfs', so it is a limit on BYTES - and a script full of
    # umlauts is longer as bytes than as characters.
    my $bytes = to_utf8($script);

    die "update script is too large (max $MAX_SCRIPT_SIZE bytes)\n"
        if length($bytes) > $MAX_SCRIPT_SIZE;

    # Storing nothing is refused rather than accepted: it reads as "saved" in the
    # web interface and then silently skips at run time. Removing a target's
    # commands is what DELETE is for, and it says so.
    die "refusing to store an empty update script - use DELETE to remove it\n"
        if $script !~ m/\S/;

    _ensure_base_dir();

    # A save that changes nothing writes nothing - not the file, and not a
    # version of it. Opening the editor and pressing Save is how a target's
    # whole history would otherwise be pushed out by three copies of the text
    # that is already stored.
    #
    # BYTES, not characters: the question is whether the file already holds what
    # is about to be written, and comparing the decoded text answers a different
    # one. A file this addon wrote as Latin-1 before the encoding was fixed
    # decodes to exactly the same characters, so a character comparison called
    # it unchanged and left it Latin-1 for ever.
    #
    # eval: file_get_contents dies on a file above $MAX_SCRIPT_SIZE and on one
    # that is not there, and a target whose stored script somebody made too
    # large by hand has to stay overwritable.
    my $current = eval { PVE::Tools::file_get_contents($file, $MAX_SCRIPT_SIZE) };
    return $file if defined($current) && $current eq $bytes;

    # The text about to be replaced gets a version of its own if the history has
    # none (#33) - BEFORE the file, unlike the version of the new text below:
    # this one was in force, so keeping it can never offer a restore of
    # something that never ran. Not inside an eval: if it cannot be kept, the
    # save is refused and the file stays as it is. A warning would be read by
    # nobody and the text would be just as gone.
    PVE::UpdateManager::Versions::_keep_unversioned($type, $id, $current, (stat($file))[9])
        if defined($current);

    PVE::Tools::file_set_contents($file, $bytes);

    # After the file, never before: a version of a text that then failed to be
    # stored would offer a restore of something that was never in force.
    eval { PVE::UpdateManager::Versions::_store_version($type, $id, $bytes, $user) };
    warn "pve-update-manager: cannot keep a version of the script of $type $id: $@" if $@;

    return $file;
}

# ── the order a run walks its targets in ────────────────────────────────────
#
# A number per target, lower first, and 0 for "no answer given" - which sorts
# after everything that has one. Its own file rather than a key in the
# container's config: this addon does not write to PVE's configs, and a value
# left behind in one after the package is removed would be a key nothing knows
# about any more.

our $MAX_ORDER = 99999;

sub order_file {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    $file =~ s/\.conf\z/.order/;

    return $file;
}

# 0 when nothing is stored, which is also what "goes last" is spelled as.
#
# Never dies, for the same reason has_script does not: this is called once per
# target while building the node and the datacenter list, and an id the path
# builder refuses would otherwise cost the WHOLE list rather than one row's
# number. It is also called while sorting a run, where dying would take the run
# with it.
sub load_order {
    my ($type, $id) = @_;

    my $file = eval { order_file($type, $id) };
    if (my $err = $@) {
        chomp($err);
        warn "pve-update-manager: cannot read the update order of $type $id: $err\n";
        return 0;
    }
    return 0 if !defined($file) || !-f $file;

    my $raw = eval { PVE::Tools::file_get_contents($file, 128) };
    return 0 if !defined($raw);

    my ($value) = $raw =~ m/\Aorder=(\d+)\s*\z/
        or return 0;

    return 0 if $value > $MAX_ORDER;

    return int($value);
}

sub save_order {
    my ($type, $id, $order) = @_;

    my $file = order_file($type, $id);

    $order = 0 if !defined($order) || "$order" !~ m/\A\d+\z/;

    die "invalid update order '$order' - must be between 0 and $MAX_ORDER\n"
        if $order > $MAX_ORDER;

    # Nothing stored IS the "no answer" state, so clearing the field removes the
    # file rather than writing a zero nobody can tell from an unset value.
    # Through delete_order, so a removal that fails says so instead of reporting
    # a cleared value the next run would still act on.
    if (!$order) {
        delete_order($type, $id);
        return 0;
    }

    _ensure_base_dir();

    PVE::Tools::file_set_contents($file, "order=$order\n");

    return $order;
}

sub delete_order {
    my ($type, $id) = @_;

    my $file = order_file($type, $id);
    return 0 if !-f $file;

    unlink($file) or die "unable to delete '$file' - $!\n";

    return 1;
}

# The stored order of every target in a list, read once.
#
# One file per target, and both callers below want the same answer for the same
# target - so it is read here rather than inside a sort block, where the number
# of reads would depend on how the sort happened to walk the list.
sub _order_map {
    my ($targets) = @_;

    my $order = {};
    for my $target (@$targets) {
        my $key = "$target->{type}-$target->{id}";
        $order->{$key} //= eval { load_order($target->{type}, $target->{id}) } // 0;
    }

    return $order;
}

# What a target is sorted AND grouped by.
#
# An unset order is not "0", it is "after everything that has one" - so the
# numbers are compared inside a first key that puts the unset ones last. Two
# targets with the same rank are two targets in the same position, which is what
# sort_targets breaks the tie of and group_targets starts at once.
sub _order_rank {
    my ($order, $t) = @_;

    my $n = $order->{"$t->{type}-$t->{id}"};

    return $n ? [0, $n] : [1, 0];
}

# The targets of a run, in the order they should be walked.
#
# Sorted here and nowhere else, so a scheduled run cannot walk them in a
# different order than the manual run somebody tested with - and so a parallel
# run, which walks the same list in waves, cannot disagree with a serial one
# about what comes first.
sub sort_targets {
    my ($targets, $order) = @_;

    $order //= _order_map($targets);

    my $rank = sub { return _order_rank($order, $_[0]) };

    return [
        sort {
            my ($ra, $rb) = ($rank->($a), $rank->($b));
            $ra->[0] <=> $rb->[0]
                || $ra->[1] <=> $rb->[1]
                # The node goes before its containers on a tie, which is the
                # order the list already had before any of this existed.
                || ($a->{type} eq 'node' ? 0 : 1) <=> ($b->{type} eq 'node' ? 0 : 1)
                # Numerically where both ids are numbers, so CT 9 comes before
                # CT 10. Checked rather than assumed from the type: an id that
                # the path builder would refuse still reaches this, and
                # comparing it as a number would put a warning in the task log
                # of the run it is ordering.
                || (("$a->{id}" =~ m/\A\d+\z/ && "$b->{id}" =~ m/\A\d+\z/)
                    ? $a->{id} <=> $b->{id}
                    : "$a->{id}" cmp "$b->{id}")
        } @$targets
    ];
}

# The same targets, split into the waves a parallel run starts.
#
# One wave per order number: everything that shares a number is started at once,
# and the next number does not start until the LAST target of the wave before it
# is done. That is the point of the number in a parallel run - a database that
# has to be back up before the two containers that talk to it are touched is
# still a database that has to be back up first, whether the run starts one
# target at a time or twelve.
#
# The targets without a number are ONE final wave rather than one wave each. An
# unset order says "after everything that has a number" and says nothing about
# the targets next to it, so there is no reason to hold them apart - and making
# each its own wave would turn a parallel run that nobody has given an order to
# into a serial one, which is the opposite of what the switch was ticked for.
#
# Built on sort_targets and its rank, not on a second reading of the numbers: a
# grouping that could disagree with the sort about what comes first is a run that
# does something the order column does not show.
sub group_targets {
    my ($targets) = @_;

    my $order = _order_map($targets);
    my $sorted = sort_targets($targets, $order);

    my $groups = [];
    my $current;

    for my $target (@$sorted) {
        my $rank = _order_rank($order, $target);
        my $key = "$rank->[0]-$rank->[1]";

        if (!defined($current) || $key ne $current) {
            push @$groups, [];
            $current = $key;
        }

        push @{ $groups->[-1] }, $target;
    }

    return $groups;
}

# Removes the commands and NOTHING else. The recorded last run stays: when a
# target was last updated is a fact about the target, not about the script that
# happened to be stored at the time - and it is the answer to the question the
# grid gets asked most ("when did this last get updated?"). The two columns say
# two different things, and after a delete they still both say something true:
# no commands stored, last updated on such a date.
sub delete_script {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    return 0 if !-f $file;

    unlink($file) or die "unable to delete '$file' - $!\n";

    return 1;
}

# Only for wiping a target's history on purpose. Nothing in the UI calls it -
# purging the package takes the whole directory instead.
sub delete_state {
    my ($type, $id) = @_;

    my $file = state_file($type, $id);
    return 0 if !-f $file;

    unlink($file) or die "unable to delete '$file' - $!\n";

    return 1;
}

# ── last run per target ─────────────────────────────────────────────────────
#
# One file next to the script, same plain-text spirit: `key=value` per line, no
# JSON, `cat` tells you what happened. It records what the grid needs to show a
# target's state without scanning the task archive - and because it lives in
# /etc/pve, a node can show the state of a run that happened on another node,
# which is what the Datacenter view is built on.
#
# Deliberately not the task log itself: task logs rotate away, this does not.

sub state_file {
    my ($type, $id) = @_;

    my $file = script_file($type, $id);
    $file =~ s/\.conf\z/.state/;

    return $file;
}

# Returns a hashref or undef. A corrupt file is treated as "no state" rather
# than an error: a broken bookkeeping file must not stop an update from running.
sub load_state {
    my ($type, $id) = @_;

    my $file = state_file($type, $id);
    return undef if !-f $file;

    my $raw = eval { PVE::Tools::file_get_contents($file, 8192) };
    return undef if !defined($raw);

    my $state = {};
    for my $line (split(/\n/, $raw)) {
        next if $line !~ m/\A([a-z_]+)=(.*)\z/;
        $state->{$1} = $2;
    }

    return undef if !defined($state->{state});

    return $state;
}

# The schema half of last_run(), so the node API and the cluster API describe
# the same fields without drifting apart.
sub last_run_schema {
    return {
        last_state => {
            type => 'string',
            optional => 1,
            enum => ['running', 'ok', 'not_fixed', 'failed', 'skipped', 'unknown'],
            description => "State of the last run. Absent when the target was never run."
                . " 'not_fixed': the script exited 0 but security updates pending before the run"
                . " are still not installed (#73)."
                . " 'unknown' means the run ended without recording a result - its worker"
                . " was killed, or the state file is unreadable.",
        },
        last_upid => {
            type => 'string',
            optional => 1,
            description => "UPID of the task that produced that state - open it for the log.",
        },
        last_started => { type => 'integer', optional => 1 },
        last_finished => { type => 'integer', optional => 1 },
        last_exit => { type => 'integer', optional => 1 },
        last_note => {
            type => 'string',
            optional => 1,
            description => "Why a run was skipped.",
        },
    };
}

our @KNOWN_STATES = qw(running ok not_fixed failed skipped unknown);

# Is the worker that wrote a "running" state still alive?
#
# A worker that is killed - node reboot, SIGKILL, an out-of-memory kill - never
# reaches the line that records its result. Without this check the row spins
# forever, the grid polls it every few seconds for ever, and the Update button
# stays disabled because the target looks busy: a dead end that can only be left
# by deleting the state file by hand.
#
# Only the local node can be judged. A worker on another node has a /proc we
# cannot read, so an unverifiable run is left alone rather than declared dead.
sub _worker_gone {
    my ($state) = @_;

    my $upid = $state->{upid};
    # Nothing to check against, and nothing that could still write a result.
    return 1 if !defined($upid) || $upid eq '';

    my $task = eval { PVE::Tools::upid_decode($upid, 1) };
    return 0 if !$task || !defined($task->{pid});

    my $localnode = eval { PVE::INotify::nodename() };
    return 0 if !defined($localnode) || ($task->{node} // '') ne $localnode;

    return PVE::ProcFSTools::check_process_running($task->{pid}, $task->{pstart}) ? 0 : 1;
}

# The same state, flattened into the `last_*` properties the API returns and the
# grids render. Keys with nothing behind them are left out rather than sent as
# null, so the schema stays honest about what is actually known.
sub last_run {
    my ($type, $id) = @_;

    my $state = load_state($type, $id);
    return {} if !$state;

    my $res = {};

    $res->{last_upid} = $state->{upid} if defined($state->{upid});
    $res->{last_note} = $state->{note} if defined($state->{note});

    my $reported = $state->{state};

    if (!grep { $_ eq $reported } @KNOWN_STATES) {
        # A state nobody wrote on purpose - a hand-edited or truncated file. Say
        # so instead of passing a value the schema does not allow up to the grid.
        $res->{last_note} = "unreadable state in the state file";
        $reported = 'unknown';
    } elsif ($reported eq 'running' && _worker_gone($state)) {
        $res->{last_note} = "the task ended without recording a result";
        $reported = 'unknown';
    }

    $res->{last_state} = $reported;

    for my $key (qw(started finished exit)) {
        next if !defined($state->{$key});
        next if $state->{$key} !~ m/\A-?\d+\z/;
        $res->{"last_$key"} = int($state->{$key});
    }

    return $res;
}

sub save_state {
    my ($type, $id, $state) = @_;

    my $raw = '';
    for my $key (sort keys %$state) {
        my $value = $state->{$key};
        next if !defined($value);
        # One record per line, so a note carrying a newline cannot forge a field.
        $value =~ s/[\r\n]+/ /g;
        $raw .= "$key=$value\n";
    }

    _ensure_base_dir();

    PVE::Tools::file_set_contents(state_file($type, $id), $raw);

    return;
}

# Is any of these targets mid-run right now?
#
# The timer asks every few minutes and a scheduled run can outlive its own
# schedule - so without this a second run would be started on top of the first,
# two apt processes fighting over one dpkg lock. The per-target state already
# knows, including the case where a previous worker was killed and only looks
# busy.
sub any_target_running {
    my ($targets) = @_;

    for my $target (@$targets) {
        return $target if target_is_running($target->{type}, $target->{id});
    }

    return undef;
}

sub target_is_running {
    my ($type, $id) = @_;

    # Deliberately last_run and not the raw state file: that is where a worker
    # which was killed rather than finished stops counting as busy, so a crash
    # cannot make a container un-updatable until somebody deletes a file.
    return (last_run($type, $id)->{last_state} // '') eq 'running' ? 1 : 0;
}

# Serialises "is this target busy?" with "mark it busy", which otherwise are two
# steps with a gap - and two clicks on Update land in that gap easily. Measured
# before this existed: two workers ran apt in the same container at the same
# time, and the second one's UPID overwrote the first one's in the row.
#
# The lock is node-local on purpose. A run only ever happens on the node that
# owns the target (every run endpoint is proxied there), so /run is the right
# scope - and it is a real flock, unlike anything /etc/pve could offer.
#
# Not /run/lock (#71). That directory is 1777: any local account could create
# /run/lock/pve-update-manager-lxc-101.lck first and hold a flock on it, and
# every run of CT 101 was then refused as "already being updated". A directory
# of our own below /run, which only root can write, leaves nobody else a name
# to take.
our $LOCK_DIR = '/run/pve-update-manager';

sub _lock_dir {
    mkdir($LOCK_DIR, 0700) or $!{EEXIST} or die "unable to create lock directory '$LOCK_DIR' - $!\n";

    # lstat, not stat: a symlink would put the locks wherever it points. And a
    # directory this process did not make for itself - another owner, or
    # writable by others - is refused rather than used, because whoever can
    # create files in it can take the lock first again.
    my @st = lstat($LOCK_DIR);
    die "lock directory '$LOCK_DIR' is not a private directory of uid $>\n"
        if !@st || !Fcntl::S_ISDIR($st[2]) || $st[4] != $> || ($st[2] & 022);

    return $LOCK_DIR;
}

sub lock_target {
    my ($type, $id, $code) = @_;

    # Reuses the id validation of script_file: a lock path is a path too.
    my $file = script_file($type, $id);
    $file =~ s|\A.*/||;
    $file =~ s|\.conf\z||;

    return PVE::Tools::lock_file(_lock_dir() . "/$file.lck", 10, $code);
}

1;
