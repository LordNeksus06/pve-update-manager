package PVE::UpdateManager::Versions;

# the saved earlier versions of a target's update script: listing them, loading one, keeping the newest few.
#
# Split out of Config.pm (#21), which was 1705 lines. What stays there is the
# storage under /etc/pve that everything else builds on - the base directory,
# the scripts, the update order and the per-target state - and the target lock.

use strict;
use warnings;

use POSIX ();
use PVE::INotify;
use PVE::Tools;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Settings;

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
# a save never writes a name that already exists (see _free_stamp), so the
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

    my $script = PVE::UpdateManager::Config::script_file($type, $id);
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

    my $file = eval { PVE::UpdateManager::Config::script_file($type, $id) };
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

    return PVE::UpdateManager::Config::from_utf8(PVE::Tools::file_get_contents($file, $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE));
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
    my $keep = eval { PVE::UpdateManager::Settings::load_settings(PVE::INotify::nodename())->{script_versions} };

    return $DEFAULT_SCRIPT_VERSIONS if !defined($keep) || $keep !~ m/\A\d+\z/;

    return $keep;
}

# The stamp a version saved at $epoch is written under: past every version that
# is already there, and past every name that is already taken.
sub _free_stamp {
    my ($type, $id, $epoch, $user) = @_;

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

    return $stamp;
}

sub _store_version {
    my ($type, $id, $script, $user) = @_;

    my $stamp = _free_stamp($type, $id, time(), $user);

    PVE::Tools::file_set_contents(version_file($type, $id, $stamp, $user), $script);

    prune_versions($type, $id, _version_retention());

    return $stamp;
}

# Keeps the text a save is about to replace, when the history has no copy of it
# (#33). Called before the script file is overwritten; dies if the text cannot
# be kept, and the caller then does not overwrite.
#
# The history otherwise only records what a save WROTE, and its newest entry is
# the text in force only as long as every write goes through a save. A text that
# reached the file some other way - by hand, by cp, from before versions existed
# - had no copy anywhere, and was measured gone after the next save: a 53765-byte
# script, replaced through pvesh, with nothing of it left in /etc/pve. A guest
# snapshot does not cover /etc/pve, so a rollback would not have returned it.
#
# Compared against the NEWEST version only, by bytes: that one is what the
# history claims is in force. A file matching an older version is still a text
# the newest entry does not describe, and the older copy is the first one the
# retention count drops.
#
# Dated by the file's mtime, which is the best answer there is to "since when
# was this in force" - but never before the newest version: the text differs
# from that save, so it came after it, and an mtime left behind by `cp -p` or a
# backup restore would otherwise date it into the middle of the history, list
# it as something it was not and make it the first one pruned.
#
# No author: who wrote a file by hand is not known, and the save that displaces
# it is not who wrote it.
#
# No pruning here: the save that follows prunes once, with both texts in place,
# and the kept text counts against the retention like any other version. With
# script_versions=1 that means it is dropped again by that same save - one kept
# version is what the setting asks for, and it is the new text.
sub _keep_unversioned {
    my ($type, $id, $current, $mtime) = @_;

    # Nothing to run is nothing to lose - and an empty file is what save_script
    # would refuse to store anyway.
    return undef if !defined($current) || $current !~ m/\S/;

    my $newest = list_versions($type, $id)->[0];
    if ($newest) {
        my $text = eval {
            PVE::Tools::file_get_contents(
                version_file($type, $id, $newest->{version}, $newest->{user}),
                $PVE::UpdateManager::Config::MAX_SCRIPT_SIZE,
            );
        };
        return undef if defined($text) && $text eq $current;
    }

    my $stamp = _free_stamp($type, $id, $mtime // time(), undef);

    PVE::Tools::file_set_contents(version_file($type, $id, $stamp, undef), $current);

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

1;
