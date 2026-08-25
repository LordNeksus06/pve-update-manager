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

use File::Path ();
use POSIX ();

use Encode qw(decode encode);

use PVE::CalendarEvent;
use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;

use PVE::UpdateManager::Runner;

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

    die "unknown target type '$type'\n" if $type ne 'lxc' && $type ne 'node';
    die "missing target id\n" if !defined($id) || $id eq '';

    my $safe;
    if ($type eq 'lxc') {
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

    PVE::Tools::file_set_contents($file, $bytes);

    # After the file, never before: a version of a text that then failed to be
    # stored would offer a restore of something that was never in force.
    eval { _store_version($type, $id, $bytes, $user) };
    warn "pve-update-manager: cannot keep a version of the script of $type $id: $@" if $@;

    return $file;
}

# ── the previous versions of a script ───────────────────────────────────────
#
# One file per save, named after the LOCAL TIME it was saved at and - where the
# API knew one - the user who saved it:
#
#   lxc-101@2026-08-21-13-21-12-root@pam.conf
#
# Readable without decoding anything, which is the whole reason for the shape:
# `ls` answers "when was this saved" by itself. It used to be an epoch
# (`lxc-101.conf.1755690000.root@pam`) and that read as a serial number.
#
# The OLD shape is still listed, opened and pruned. An upgrade that made every
# saved version vanish from the History menu would be a worse trade than any
# filename, so both are read and only the new one is written - old files age out
# through the retention count on their own.
#
# The time in the name is local, as asked for, and that has one measured cost:
# in the hour a DST change repeats, two different instants format to the same
# string. Two things are done about it rather than assumed away - the sort key is
# an epoch derived from the name (so ordering only wobbles inside that hour), and
# a save never writes a name that already exists (see _store_version), so the
# older file cannot be silently overwritten by the newer one.
#
# Plain files beside the script itself, so the history is as readable with `cat`
# as the script is, and it replicates across the cluster with everything else in
# /etc/pve.
#
# The newest version holds the same text as the script itself. That is on
# purpose: what is recorded is a save, with its time and its author, and a
# history whose newest entry was the text BEFORE the save could name neither -
# the author of a text is not known at the moment it is replaced.

our $DEFAULT_SCRIPT_VERSIONS = 3;
our $MIN_SCRIPT_VERSIONS = 1;
our $MAX_SCRIPT_VERSIONS = 50;

# What may stand in a filename after the timestamp.
#
# PVE's own rule, read off Auth::Plugin rather than guessed: the name part is
# `[^\s:/]+`, the realm `[A-Za-z][A-Za-z0-9.\-_]+`, and an API token adds
# `!<token>` on the end - so `root@pam!ci` is a userid like any other and a name
# may legitimately carry a `+` or a `%`. A charset narrower than that does not
# make anything safer, it just drops the author of every save made with a token.
#
# What IS excluded is what must never reach a path: whitespace, a colon and a
# slash are already impossible in a userid, and the first character has to be a
# letter or a digit, which is what keeps `.`, `..` and a dotfile out. The value
# never reaches a shell - it is opened, unlinked and matched, never globbed.
sub _version_user {
    my ($user) = @_;

    return undef if !defined($user);

    my ($safe) = $user =~ m/\A([A-Za-z0-9][^\s:\/]{0,127})\z/
        or return undef;

    return $safe;
}

# The two shapes a version is identified by. The new one is what a save writes;
# the old one is only ever met on disk, on a node that was updated.
our $STAMP_RE = qr/[0-9]{4}(?:-[0-9]{2}){5}/;
our $EPOCH_RE = qr/[0-9]{1,12}/;

# The local second, as it stands in a name. Zero-padded throughout, so the string
# sorts the way the clock runs.
sub version_stamp {
    my ($epoch) = @_;

    my @t = localtime($epoch);

    return sprintf(
        '%04d-%02d-%02d-%02d-%02d-%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0],
    );
}

# Back to an epoch, for sorting and for the time the web interface renders.
#
# Through mktime with isdst left at -1, which is what asks the system which of
# the two answers a repeated hour has rather than picking one here. Undef for
# anything that is not a stamp, so a hand-made name cannot become a sort key of 0
# and jump to the end of the list.
sub stamp_epoch {
    my ($stamp) = @_;

    my ($year, $mon, $day, $hour, $min, $sec) =
        "$stamp" =~ m/\A([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})\z/
        or return undef;

    # Range-checked BEFORE mktime, because mktime does not refuse an impossible
    # date - it normalises it. Month 99 comes back as a real second some years
    # later, which would give a hand-made or half-written name a sort key and a
    # place in the History menu. Measured: '2026-99-99-99-99-99' converted to a
    # perfectly good epoch in 2034.
    return undef if $mon < 1 || $mon > 12;
    return undef if $day < 1 || $day > 31;
    return undef if $hour > 23 || $min > 59;
    # 60 is allowed: a leap second is a real local time and localtime() will
    # print one, so a name carrying it is a name this wrote.
    return undef if $sec > 60;

    my $epoch = eval {
        POSIX::mktime($sec, $min, $hour, $day, $mon - 1, $year - 1900);
    };

    return defined($epoch) ? $epoch : undef;
}

# The path of one version, from the identifier the listing handed out.
#
# Both shapes, because both are on disk. Which one it is decides the whole name,
# not just the middle of it - an old file is `<script>.<epoch>[.<user>]` and a new
# one is `<stem>@<stamp>[-<user>].conf`.
sub version_file {
    my ($type, $id, $stamp, $user) = @_;

    my $script = script_file($type, $id);
    my $safe_user = _version_user($user);

    if ("$stamp" =~ m/\A($STAMP_RE)\z/) {
        my $safe_stamp = $1;

        # The stem, not the script file: the version's own `.conf` goes on the
        # end, so `ls *.conf` lists the history beside the script it belongs to.
        my $stem = $script;
        $stem =~ s/\.conf\z//;

        my $file = "$stem\@$safe_stamp";
        $file .= "-$safe_user" if defined($safe_user);

        return "$file.conf";
    }

    my ($safe_epoch) = "$stamp" =~ m/\A($EPOCH_RE)\z/
        or die "invalid version '$stamp'\n";

    my $file = "$script.$safe_epoch";
    $file .= ".$safe_user" if defined($safe_user);

    return $file;
}

# Every stored version of a target's script, newest first.
#
# Never dies: this is read while building an editor, and a directory that cannot
# be listed may cost the history menu - it may not cost the text box.
sub list_versions {
    my ($type, $id) = @_;

    my $file = eval { script_file($type, $id) };
    return [] if !defined($file);

    my ($dir, $base) = $file =~ m{\A(.*)/([^/]+)\z};
    return [] if !defined($dir) || !defined($base);

    opendir(my $dh, $dir) or return [];
    my @names = readdir($dh);
    closedir($dh);

    my $stem = $base;
    $stem =~ s/\.conf\z//;

    my $res = [];
    for my $name (@names) {
        my ($stamp, $user, $epoch);

        if (my @new = $name =~ m/\A\Q$stem\E\@($STAMP_RE)(?:-(.+))?\.conf\z/) {
            ($stamp, $user) = @new;
            $epoch = stamp_epoch($stamp);
            # A name whose date is not a date the system knows is not a version
            # this can order, so it is not offered at all.
            next if !defined($epoch);
        } elsif (my @old = $name =~ m/\A\Q$base\E\.($EPOCH_RE)(?:\.(.+))?\z/) {
            ($stamp, $user) = @old;
            $epoch = int($stamp);
        } else {
            next;
        }

        # Only what can be read back again: version_file() builds the path from
        # this listing, and it refuses a user part that does not validate - so a
        # hand-made file with one would be offered and then fail to open.
        next if defined($user) && !defined(_version_user($user));

        my $size = (stat("$dir/$name"))[7];

        push @$res, {
            # The identifier IS what stands in the name, so the URL that asks for
            # a version reads like the file that answers it.
            version => $stamp,
            # And the second behind it, for whoever has to render a time. Kept
            # apart from the identifier on purpose: an epoch is not what somebody
            # reading `ls` wants, and a formatted local time is not something to
            # do arithmetic on.
            time => $epoch,
            (defined($user) ? (user => $user) : ()),
            size => defined($size) ? int($size) : 0,
        };
    }

    # By the second, newest first - and by the identifier where two land in the
    # same second, which is the one thing that makes the order of a listing
    # repeatable rather than whatever readdir felt like.
    return [sort { $b->{time} <=> $a->{time} || ($b->{version} cmp $a->{version}) } @$res];
}

# The text of one version, or undef. The version is looked up in the listing
# rather than built into a path: the author is part of the name and the caller
# only has the timestamp.
sub load_version {
    my ($type, $id, $stamp) = @_;

    my ($wanted) = "$stamp" =~ m/\A($STAMP_RE|$EPOCH_RE)\z/
        or die "invalid version '$stamp'\n";

    # String comparison, because the identifier is a string now - and `==` on
    # "2026-08-21-13-21-12" is a numeric 2026 that matches every version saved
    # that year.
    my ($entry) = grep { $_->{version} eq $wanted } @{ list_versions($type, $id) };
    return undef if !$entry;

    my $file = version_file($type, $id, $entry->{version}, $entry->{user});

    return from_utf8(PVE::Tools::file_get_contents($file, $MAX_SCRIPT_SIZE));
}

sub delete_versions {
    my ($type, $id) = @_;

    my $removed = 0;
    for my $entry (@{ list_versions($type, $id) }) {
        my $file = version_file($type, $id, $entry->{version}, $entry->{user});
        $removed++ if unlink($file);
    }

    return $removed;
}

# How many versions this node keeps. A container has no settings of its own and
# every write reaches this through the node that owns it, which is the node
# whose retention applies.
sub _version_retention {
    my $keep = eval { load_settings(PVE::INotify::nodename())->{script_versions} };

    return $DEFAULT_SCRIPT_VERSIONS if !defined($keep) || $keep !~ m/\A\d+\z/;

    return $keep;
}

sub _store_version {
    my ($type, $id, $script, $user) = @_;

    my $epoch = time();

    # The second is also the sort key, so it has to be past every version that is
    # already there. Two saves in the same second would otherwise collide on the
    # name and the older one would win silently; a save into a second that an
    # earlier version was pruned out of would be listed as the OLDEST entry and
    # restore the wrong text. Both were measured. The cost is a timestamp up to
    # a few seconds early, which is the cheaper of the two lies.
    my $newest = list_versions($type, $id)->[0];
    $epoch = $newest->{time} + 1 if $newest && $epoch <= $newest->{time};

    # And then past any NAME that is already taken, which is not the same
    # condition: the name carries local time, so in the hour a DST change repeats
    # an epoch an hour later formats to the same string. Without this the older
    # file would be overwritten by the newer one and the history would lose an
    # entry once a year, quietly. Bounded, because a loop that cannot end has no
    # business between a Save button and a file.
    #
    # A structural brake with no trigger a test can pull: reaching it needs the
    # clock to be inside that repeated hour, and removing it reddens nothing.
    # What IS measured is the reason it exists - versions.t proves that two
    # instants an hour apart in that hour ask for the same name.
    my $stamp = version_stamp($epoch);
    for (1 .. 120) {
        last if !-e version_file($type, $id, $stamp, $user);
        $epoch++;
        $stamp = version_stamp($epoch);
    }

    PVE::Tools::file_set_contents(version_file($type, $id, $stamp, $user), $script);

    prune_versions($type, $id, _version_retention());

    return $stamp;
}

# Keeps the newest $keep versions and removes the rest. Returns how many went.
sub prune_versions {
    my ($type, $id, $keep) = @_;

    # The floor is one, not zero: keeping none would delete the version of the
    # save that has just been made, which is the opposite of what this is for.
    $keep = $DEFAULT_SCRIPT_VERSIONS
        if !defined($keep) || "$keep" !~ m/\A\d+\z/;
    $keep = $MIN_SCRIPT_VERSIONS if $keep < $MIN_SCRIPT_VERSIONS;
    $keep = $MAX_SCRIPT_VERSIONS if $keep > $MAX_SCRIPT_VERSIONS;

    my $versions = list_versions($type, $id);
    return 0 if scalar(@$versions) <= $keep;

    my $removed = 0;
    for my $entry (@$versions[$keep .. $#$versions]) {
        my $file = version_file($type, $id, $entry->{version}, $entry->{user});
        if (!unlink($file)) {
            warn "pve-update-manager: cannot remove the old version '$file' - $!\n";
            next;
        }
        $removed++;
    }

    return $removed;
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

sub _ensure_log_dir {
    return if -d $LOG_DIR;

    # mkpath rather than mkdir: /var/lib/pve-update-manager exists on an
    # installed node, but not in a test tmpdir - and a log that fails to be
    # written must not depend on which of the two this is.
    File::Path::make_path($LOG_DIR);

    die "unable to create '$LOG_DIR'\n" if !-d $LOG_DIR;

    return;
}

# The path of one run log. Built from the same validated target name the script
# file is built from, so a vmid that could walk out of a directory is refused in
# one place for both.
sub log_file {
    my ($type, $id, $stamp) = @_;

    my $stem = script_file($type, $id);
    $stem =~ s{\A.*/}{};
    $stem =~ s/\.conf\z//;

    my ($safe_stamp) = "$stamp" =~ m/\A($STAMP_RE)\z/
        or die "invalid run log '$stamp'\n";

    return "$LOG_DIR/$stem\@$safe_stamp.log";
}

# Every stored log of a target's runs, newest first. Never dies: this is read
# while building a menu.
sub list_logs {
    my ($type, $id) = @_;

    my $stem = eval { script_file($type, $id) };
    return [] if !defined($stem);
    $stem =~ s{\A.*/}{};
    $stem =~ s/\.conf\z//;

    opendir(my $dh, $LOG_DIR) or return [];
    my @names = readdir($dh);
    closedir($dh);

    my $res = [];
    for my $name (@names) {
        my ($stamp) = $name =~ m/\A\Q$stem\E\@($STAMP_RE)\.log\z/
            or next;

        my $epoch = stamp_epoch($stamp);
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
    # shape last_run() hands the grid, so the same renderer draws both.
    if ($raw =~ m/^result:\s+(\S+)(?:\s+\((.*)\))?\s*$/m) {
        $res->{state} = lc($1);
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

    return from_utf8(PVE::Tools::file_get_contents($file, $MAX_LOG_SIZE));
}

# Writes one, then drops the oldest above the retention count. Returns the stamp
# it was stored under, or undef when nothing was stored.
sub save_log {
    my ($type, $id, $text, $keep, $when) = @_;

    $keep = log_retention($keep);
    return undef if $keep < 1;

    my $epoch = $when // time();
    my $stamp = version_stamp($epoch);

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
        $stamp = version_stamp($epoch);
    }

    _ensure_log_dir();

    PVE::Tools::file_set_contents(log_file($type, $id, $stamp), to_utf8($text));

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
            enum => ['running', 'ok', 'failed', 'skipped', 'unknown'],
            description => "State of the last run. Absent when the target was never run."
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

our @KNOWN_STATES = qw(running ok failed skipped unknown);

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

# ── the node's settings ─────────────────────────────────────────────────────
#
# Offered on a node's tab only. A container knows nothing about when it should
# be updated, and a cluster-wide schedule would have to decide which node runs
# it - so the node that owns the targets owns its settings too.
#
# Two separate parallel switches on purpose - a manual run and a scheduled one
# are different situations and deserve their own answer. Both start OFF: a dozen
# dist-upgrades at once on one node is a decision, and a default that quietly
# saturates a host's disk is not one to make on somebody's behalf. Turning either
# on is a click, and it is remembered.
#
# The schedule is a systemd calendar event - the same syntax and the same parser
# Proxmox backup jobs use ("03:00", "mon..fri 02:30", "*/8:00"), so a time of day
# is expressible and "every N seconds" no longer has to stand in for one.
#
# `last_run` is written by the scheduler, never by the web interface, so saving
# settings cannot accidentally make a run look overdue (or not).

sub settings_file {
    my ($node) = @_;

    # Reuse script_file's validation of the node name, then move the prefix.
    my $file = script_file('node', $node);
    $file =~ s{/node-([^/]+)\.conf\z}{/settings-$1.conf};

    return $file;
}

our $DEFAULT_SNAPSHOT_KEEP = 3;

# One is the floor and not zero: keeping none would delete the snapshot the run
# had just taken, which is the opposite of what the setting is for.
our $MIN_SNAPSHOT_KEEP = 1;
our $MAX_SNAPSHOT_KEEP = 100;

# snapshot_before and notify_failure are the two switches here that start ON.
# Every other one changes what a run DOES and so has to be asked for; these two
# do not. snapshot_before only adds something to undo a run with, and it does
# nothing at all where the storage cannot snapshot. notify_failure only says out
# loud what already happened - and the run it reports on is an unattended one at
# 03:00, where the alternative to a notification is nobody finding out. So for
# once the cautious default and the useful one are the same value.
sub default_settings {
    return {
        parallel_manual => 0,
        timeout => $PVE::UpdateManager::Runner::DEFAULT_TIMEOUT,
        start_stopped => 0,
        snapshot_before => 1,
        snapshot_keep => $DEFAULT_SNAPSHOT_KEEP,
        snapshot_shutdown => 0,
        rollback_on_failure => 0,
        notify_failure => 1,
        script_versions => $DEFAULT_SCRIPT_VERSIONS,
        run_logs => $DEFAULT_RUN_LOGS,
        schedule_enabled => 0,
        schedule_time => '03:00',
        schedule_parallel => 0,
        schedule_host => 0,
        schedule_vmids => '',
        last_run => 0,
    };
}

# The API's description of the settings, in ONE place. The node's endpoint and
# the datacenter-wide one both describe the same switches, and two copies of a
# minimum, a pattern or a sentence of documentation drift apart the first time
# one of them is corrected.
sub settings_schema {
    return {
        parallel_manual => {
            type => 'boolean',
            description => "Start all targets at once when Update Selected is pressed.",
        },
        timeout => {
            type => 'integer',
            minimum => $PVE::UpdateManager::Runner::MIN_TIMEOUT,
            maximum => $PVE::UpdateManager::Runner::MAX_TIMEOUT,
            description => "Kill a target's update after this many seconds. Applies to manual"
                . " and scheduled runs alike. This really does kill the process tree, so it"
                . " must sit above anything a real upgrade takes.",
        },
        start_stopped => {
            type => 'boolean',
            description => "Start a stopped container for its update and shut it down again"
                . " afterwards. Off by default: a stopped container is skipped, because"
                . " starting one runs its services for as long as the update takes.",
        },
        snapshot_before => {
            type => 'boolean',
            description => "Take a snapshot of a container before updating it. On by default,"
                . " because it is the one thing that makes a bad dist-upgrade undoable - and it"
                . " does nothing at all where the storage cannot snapshot, in which case the"
                . " container is updated exactly as it was before this setting existed.",
        },
        snapshot_keep => {
            type => 'integer',
            minimum => $MIN_SNAPSHOT_KEEP,
            maximum => $MAX_SNAPSHOT_KEEP,
            description => "How many of these snapshots to keep per container. The oldest ones"
                . " above this are removed after each run. Only snapshots this addon took are"
                . " ever touched.",
        },
        snapshot_shutdown => {
            type => 'boolean',
            description => "Shut a running container down before its snapshot is taken and"
                . " start it again afterwards. Off by default. An LXC snapshot never carries"
                . " memory - that exists for VMs only - so a running container is snapshotted"
                . " as if it had lost power, and a database mid-transaction is caught that"
                . " way. Stopping it first is the only way to a consistent one, and it costs"
                . " the downtime of a shutdown and a start.",
        },
        rollback_on_failure => {
            type => 'boolean',
            description => "Roll a container back to the snapshot this run took when its"
                . " update fails. Off by default, and not a small switch: a rollback throws"
                . " away everything that happened since the snapshot, not only what the"
                . " update did - anything a service wrote in the meantime goes with it. PVE"
                . " stops the container to roll it back; one that was running is started"
                . " again afterwards. Only a snapshot this addon took in this run is ever"
                . " rolled back to.",
        },
        notify_failure => {
            type => 'boolean',
            description => "Send a notification when a run had a target fail. On by default."
                . " It goes out through Proxmox' own notification system, so it lands wherever"
                . " this node already sends its backup and package notifications and needs no"
                . " address of its own here; the notification targets and matchers under"
                . " Datacenter -> Notifications decide where that is. One notification per"
                . " run, once the whole run is over, listing the targets that failed with"
                . " their exit code and the time they finished. Nothing is sent for a run in"
                . " which everything worked, and a target that was skipped is not a failure.",
        },
        run_logs => {
            type => 'integer',
            minimum => $MIN_RUN_LOGS,
            maximum => $MAX_RUN_LOGS,
            description => "How many logs of past runs to keep per target. Each run writes"
                . " one, and the oldest above this are removed after it. 0 keeps none."
                . " They are kept on the node that ran them, under"
                . " /var/lib/pve-update-manager/logs, because a run log can be far larger"
                . " than the 1 MiB a file in /etc/pve may be - and because Proxmox' own task"
                . " log stays on disk but stops being reachable once its entry falls out of"
                . " the task index.",
        },
        script_versions => {
            type => 'integer',
            minimum => $MIN_SCRIPT_VERSIONS,
            maximum => $MAX_SCRIPT_VERSIONS,
            description => "How many saved versions of a target's update script to keep."
                . " Every save that changes something writes one; the oldest above this are"
                . " removed. The newest is what is stored now, so 3 means the current text"
                . " and the two before it.",
        },
        schedule_enabled => {
            type => 'boolean',
            description => "Run the selected targets on a schedule.",
        },
        schedule_time => {
            type => 'string',
            maxLength => 128,
            description => "When to run, as a systemd calendar event - the same syntax as a"
                . " backup job's schedule: '03:00', 'mon..fri 02:30', '*/8:00'.",
        },
        schedule_parallel => {
            type => 'boolean',
            description => "Start all targets at once on a scheduled run too.",
        },
        schedule_host => {
            type => 'boolean',
            description => "Include the node's own update script in scheduled runs.",
        },
        schedule_vmids => {
            type => 'string',
            # The empty string has to be allowed: it is how "no containers" is
            # expressed, and without it the settings window could never have its last
            # container unticked - Save would fail on the pattern.
            pattern => '(\d+(,\d+)*)?',
            maxLength => 4096,
            description => "Comma separated container ids for scheduled runs. Empty for none.",
        },
    };
}

# The keys a datacenter-wide save may write: everything that means the same
# thing on every node.
#
# schedule_vmids is the one that does not, and it is why "apply to all nodes"
# cannot simply be a loop over this whole hash: a vmid lives on exactly one
# node, so broadcasting one node's list would point every other node at
# containers it does not have - and un-tick the ones it does.
#
# last_run is not here either: it belongs to the scheduler, like everywhere else.
our @PER_NODE_SETTINGS = qw(schedule_vmids last_run);

sub global_settings_schema {
    my $schema = settings_schema();

    delete $schema->{$_} for @PER_NODE_SETTINGS;

    return $schema;
}

sub load_settings {
    my ($node) = @_;

    my $res = default_settings();

    my $file = settings_file($node);
    return $res if !-f $file;

    my $raw = eval { PVE::Tools::file_get_contents($file, 8192) };
    if (!defined($raw)) {
        warn "pve-update-manager: cannot read the settings of node $node: $@";
        return $res;
    }

    for my $line (split(/\n/, $raw)) {
        next if $line !~ m/\A([a-z_]+)=(.*)\z/;
        my ($key, $value) = ($1, $2);
        next if !exists($res->{$key});

        if ($key eq 'timeout') {
            # Clamped rather than rejected: a settings file edited by hand into
            # nonsense should not disarm the one limit that stops a hung run.
            my $secs = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $secs = $PVE::UpdateManager::Runner::MIN_TIMEOUT
                if $secs < $PVE::UpdateManager::Runner::MIN_TIMEOUT;
            $secs = $PVE::UpdateManager::Runner::MAX_TIMEOUT
                if $secs > $PVE::UpdateManager::Runner::MAX_TIMEOUT;
            $res->{$key} = $secs;
        } elsif ($key eq 'snapshot_keep') {
            # Clamped rather than rejected, same reason as the timeout: a file
            # edited by hand into a 0 would delete the snapshot the run had just
            # taken, which is the opposite of what the setting is for.
            my $keep = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $keep = $MIN_SNAPSHOT_KEEP if $keep < $MIN_SNAPSHOT_KEEP;
            $keep = $MAX_SNAPSHOT_KEEP if $keep > $MAX_SNAPSHOT_KEEP;
            $res->{$key} = $keep;
        } elsif ($key eq 'run_logs') {
            # Clamped rather than rejected, like the counts above. Zero is a
            # legitimate answer here and needs no floor of its own.
            $res->{$key} = log_retention($value);
        } elsif ($key eq 'script_versions') {
            # Clamped rather than rejected, like the two above: a hand-edited 0
            # would throw away the version of the save being made.
            my $keep = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
            $keep = $MIN_SCRIPT_VERSIONS if $keep < $MIN_SCRIPT_VERSIONS;
            $keep = $MAX_SCRIPT_VERSIONS if $keep > $MAX_SCRIPT_VERSIONS;
            $res->{$key} = $keep;
        } elsif ($key eq 'schedule_vmids') {
            $res->{$key} = ($value =~ m/\A\d+(?:,\d+)*\z/) ? $value : '';
        } elsif ($key eq 'schedule_time') {
            # A calendar event nobody can parse would make the timer silently
            # never fire. Fall back to the default rather than to "never".
            $res->{$key} = parse_schedule_time($value) ? $value : $res->{$key};
        } else {
            $res->{$key} = ($value =~ m/\A\d+\z/) ? int($value) : $res->{$key};
        }
    }

    return $res;
}

sub _write_settings {
    my ($node, $settings) = @_;

    my $raw = '';
    for my $key (sort keys %{ default_settings() }) {
        $raw .= "$key=" . ($settings->{$key} // 0) . "\n";
    }

    _ensure_base_dir();

    PVE::Tools::file_set_contents(settings_file($node), $raw);

    return $settings;
}

sub save_settings {
    my ($node, $settings) = @_;

    # Merge FIRST, then validate. Every field of the API is optional, so a
    # request that only flips one switch carries nothing else - and validating
    # the raw input would reject it for values the caller never sent and the
    # stored settings already answer.
    #
    # last_run belongs to the scheduler. A save from the web interface keeps
    # whatever is on disk, so changing the time does not reset the clock - and
    # cannot be used to force a run either.
    my $current = load_settings($node);
    my $merged = { %$current, %$settings };
    $merged->{last_run} = $current->{last_run};

    # The one exception: switching a schedule on for the first time starts its
    # clock now. Due-ness is measured from last_run, so leaving it at 0 would
    # measure from 1970 and fire the moment the box is ticked - which is not what
    # "every day at 03:00" says, and not what anyone expects to happen while they
    # are still looking at the dialog.
    $merged->{last_run} = time()
        if $merged->{schedule_enabled} && !$current->{schedule_enabled} && !$current->{last_run};

    my $vmids = $merged->{schedule_vmids};
    die "invalid vmid list '$vmids'\n"
        if defined($vmids) && length($vmids) && $vmids !~ m/\A\d+(?:,\d+)*\z/;

    die "invalid schedule '$merged->{schedule_time}'\n"
        if !parse_schedule_time($merged->{schedule_time});

    my $secs = $merged->{timeout};
    die "invalid timeout '$secs' - must be between $PVE::UpdateManager::Runner::MIN_TIMEOUT"
        . " and $PVE::UpdateManager::Runner::MAX_TIMEOUT seconds\n"
        if !defined($secs)
        || $secs !~ m/\A\d+\z/
        || $secs < $PVE::UpdateManager::Runner::MIN_TIMEOUT
        || $secs > $PVE::UpdateManager::Runner::MAX_TIMEOUT;

    my $keep = $merged->{snapshot_keep};
    die "invalid snapshot count '$keep' - must be between $MIN_SNAPSHOT_KEEP"
        . " and $MAX_SNAPSHOT_KEEP\n"
        if !defined($keep)
        || $keep !~ m/\A\d+\z/
        || $keep < $MIN_SNAPSHOT_KEEP
        || $keep > $MAX_SNAPSHOT_KEEP;

    my $versions = $merged->{script_versions};
    die "invalid script version count '$versions' - must be between $MIN_SCRIPT_VERSIONS"
        . " and $MAX_SCRIPT_VERSIONS\n"
        if !defined($versions)
        || $versions !~ m/\A\d+\z/
        || $versions < $MIN_SCRIPT_VERSIONS
        || $versions > $MAX_SCRIPT_VERSIONS;

    return _write_settings($node, $merged);
}

sub mark_schedule_run {
    my ($node, $when) = @_;

    my $settings = load_settings($node);
    $settings->{last_run} = $when // time();

    return _write_settings($node, $settings);
}

# Wrapped so the one place that knows about PVE::CalendarEvent is here, and so a
# rejected event is a false rather than an exception at every call site.
sub parse_schedule_time {
    my ($spec) = @_;

    return undef if !defined($spec) || $spec !~ m/\S/;

    my $parsed = eval { PVE::CalendarEvent::parse_calendar_event($spec) };

    return $@ ? undef : $parsed;
}

# When the schedule would next fire after $since. Undef when it never would.
sub next_schedule_run {
    my ($settings, $since) = @_;

    my $event = parse_schedule_time($settings->{schedule_time})
        or return undef;

    $since //= $settings->{last_run} || time();

    my $next = eval { PVE::CalendarEvent::compute_next_event($event, $since) };

    return $@ ? undef : $next;
}

# What a run does, taken from the node's settings, in ONE place.
#
# There are three callers - the node's run endpoint, a container's, and the
# timer - and an option added to two of them is a scheduled run that quietly
# behaves differently from the manual one somebody tested with. That has
# happened once already, which is why this exists rather than three literals.
sub run_opts {
    my ($settings, $parallel) = @_;

    return {
        start_stopped => $settings->{start_stopped},
        snapshot_before => $settings->{snapshot_before},
        snapshot_keep => $settings->{snapshot_keep},
        snapshot_shutdown => $settings->{snapshot_shutdown},
        rollback_on_failure => $settings->{rollback_on_failure},
        notify_failure => $settings->{notify_failure},
        # Carried into the run rather than read again per target: forty targets
        # would otherwise be forty reads of the same settings file, and a setting
        # changed mid-run would apply to half the batch.
        run_logs => $settings->{run_logs},
        # An argument rather than a settings key, because there is no single key
        # to read: a manual run and a scheduled one have separate parallel
        # switches on purpose, and a single container's run has no list to spread
        # out at all. Passing it makes every caller answer the question instead
        # of one of them quietly inheriting the other one's answer.
        parallel => $parallel ? 1 : 0,
    };
}

# Is a scheduled run due? Kept here rather than in the timer's script so the API
# can report the same answer the timer will act on.
sub schedule_is_due {
    my ($settings, $now) = @_;

    return 0 if !$settings->{schedule_enabled};

    $now //= time();

    # Measured from the last run, so a node that was switched off through 03:00
    # still updates once it is back - and one that already ran at 03:00 does not
    # run again at 03:01.
    my $next = next_schedule_run($settings, $settings->{last_run} || 0);

    return 0 if !defined($next);

    return $now >= $next ? 1 : 0;
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
sub lock_target {
    my ($type, $id, $code) = @_;

    # Reuses the id validation of script_file: a lock path is a path too.
    my $file = script_file($type, $id);
    $file =~ s|\A.*/||;
    $file =~ s|\.conf\z||;

    return PVE::Tools::lock_file("/run/lock/pve-update-manager-$file.lck", 10, $code);
}

1;
