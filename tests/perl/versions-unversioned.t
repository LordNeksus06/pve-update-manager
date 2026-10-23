#!/usr/bin/perl
# A script text that is in force but not in the history survives a save (#33).
#
# The history only ever recorded what a save wrote. A text that reached the
# script file some other way - written by hand, copied in, left over from before
# versions existed - was the one text nobody had a copy of, and the next save
# replaced it without one. Measured on a real container: a 53765-byte script
# written straight into the file, then a save through pvesh, and the history
# listed the new text and an older 49173-byte one - the text that had actually
# been in force was gone. /etc/pve is not in a guest's snapshot, so a rollback
# does not bring it back either.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 17;

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Versions;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

sub texts {
    my ($id) = @_;
    return [
        map { PVE::UpdateManager::Versions::load_version('lxc', $id, $_->{version}) }
            @{ PVE::UpdateManager::Versions::list_versions('lxc', $id) }
    ];
}

# ── a file nobody saved through the API ─────────────────────────────────────
#
# The upgrade case and the hand-written case at once: there is no history at
# all, and the text in the file is the one that runs.
PVE::UpdateManager::Config::save_script('lxc', 201, "placeholder\n");
PVE::UpdateManager::Versions::delete_versions('lxc', 201);
my $file = PVE::UpdateManager::Config::script_file('lxc', 201);
PVE::Tools::file_set_contents($file, "by hand\n");
my $mtime = time() - 3600;
utime($mtime, $mtime, $file) or die "utime: $!";

is_deeply(texts(201), [], 'premise: the hand-written text has no version');

PVE::UpdateManager::Config::save_script('lxc', 201, "new\n", 'root@pam');

is_deeply(
    texts(201),
    ["new\n", "by hand\n"],
    'a save keeps the text it replaces when that text had no version, behind the new one',
);
my $kept = PVE::UpdateManager::Versions::list_versions('lxc', 201)->[1];
is($kept && $kept->{time}, $mtime, 'dated by the file it came from, not by the save that displaced it');
# `$kept &&` first: without the entry, "has no user" would hold of nothing at all.
ok($kept && !exists($kept->{user}), 'and not attributed to anybody - nobody knows who wrote it');

# ── a file changed by hand after a save ─────────────────────────────────────
#
# The measured case: a history exists, but its newest entry is no longer the
# text in the file.
PVE::UpdateManager::Config::save_script('lxc', 202, "first\n", 'root@pam');
$file = PVE::UpdateManager::Config::script_file('lxc', 202);
PVE::Tools::file_set_contents($file, "edited by hand\n");
utime(time() + 5, time() + 5, $file) or die "utime: $!";

is_deeply(texts(202), ["first\n"], 'premise: the hand edit is not in the history');

PVE::UpdateManager::Config::save_script('lxc', 202, "second\n", 'root@pam');

is_deeply(
    texts(202),
    ["second\n", "edited by hand\n", "first\n"],
    'the hand edit is kept between the save before it and the save after it',
);
my ($current) = PVE::UpdateManager::Config::load_script('lxc', 202);
is($current, "second\n", 'and the save itself still went through');

# ── a hand edit whose mtime claims it is older than the newest version ───────
#
# `cp -p`, `touch -d`, a restore from a backup: the mtime is whatever the tool
# left. The text was put there after the newest save - it differs from it - so
# it is placed after that save, not dated into the middle of the history where
# it would be pruned first and listed as something it was not.
PVE::UpdateManager::Config::save_script('lxc', 203, "first\n", 'root@pam');
$file = PVE::UpdateManager::Config::script_file('lxc', 203);
PVE::Tools::file_set_contents($file, "restored from a backup\n");
utime(1_000_000_000, 1_000_000_000, $file) or die "utime: $!";

PVE::UpdateManager::Config::save_script('lxc', 203, "second\n", 'root@pam');

is_deeply(
    texts(203),
    ["second\n", "restored from a backup\n", "first\n"],
    'an mtime from the past does not sort the kept text below the save it followed',
);

# ── the controls: nothing extra where nothing was missing ───────────────────
PVE::UpdateManager::Config::save_script('lxc', 204, "one\n", 'root@pam');
PVE::UpdateManager::Config::save_script('lxc', 204, "two\n", 'root@pam');

is_deeply(
    texts(204),
    ["two\n", "one\n"],
    'saves through the API record each text exactly once - the file always matched the newest version',
);

# A version whose bytes match the file is the same text, whatever its mtime:
# touching the file must not turn into a copy.
$file = PVE::UpdateManager::Config::script_file('lxc', 204);
utime(time() + 60, time() + 60, $file) or die "utime: $!";
PVE::UpdateManager::Config::save_script('lxc', 204, "three\n", 'root@pam');
is_deeply(texts(204), ["three\n", "two\n", "one\n"], 'a touched but unchanged file is not kept twice');

# A first save has nothing to keep.
PVE::UpdateManager::Config::save_script('lxc', 205, "only\n", 'root@pam');
is_deeply(texts(205), ["only\n"], 'the very first save of a target records one version');

# A save that changes nothing writes nothing - and that includes not rescuing:
# the text is not being replaced.
PVE::UpdateManager::Config::save_script('lxc', 206, "a\n", 'root@pam');
PVE::UpdateManager::Versions::delete_versions('lxc', 206);
PVE::UpdateManager::Config::save_script('lxc', 206, "a\n", 'root@pam');
is_deeply(texts(206), [], 'an unchanged save keeps nothing, because nothing is replaced');

# A file with nothing to run in it is nothing to lose.
PVE::UpdateManager::Config::save_script('lxc', 207, "x\n");
PVE::UpdateManager::Versions::delete_versions('lxc', 207);
PVE::Tools::file_set_contents(PVE::UpdateManager::Config::script_file('lxc', 207), "  \n");
PVE::UpdateManager::Config::save_script('lxc', 207, "y\n", 'root@pam');
is_deeply(texts(207), ["y\n"], 'a blank file is not kept as a version');

# ── the retention count still counts both ───────────────────────────────────
#
# The kept text is a version like any other: with three kept, a fourth save
# pushes the oldest out, whichever kind it is.
PVE::UpdateManager::Config::save_script('lxc', 202, "third\n", 'root@pam');
is_deeply(
    texts(202),
    ["third\n", "second\n", "edited by hand\n"],
    'the default retention of three counts the kept text and drops the oldest',
);

# ── a text that cannot be kept is not overwritten ───────────────────────────
#
# Refusing the save is the only answer that does not lose the text: the user
# sees an error and the file is untouched. A warning would have been read by
# nobody, and the text would be just as gone.
PVE::UpdateManager::Config::save_script('lxc', 208, "first\n", 'root@pam');
$file = PVE::UpdateManager::Config::script_file('lxc', 208);
PVE::Tools::file_set_contents($file, "precious\n");
{
    no warnings 'redefine';
    local *PVE::UpdateManager::Versions::_keep_unversioned = sub { die "disk full\n" };
    my $ok = eval { PVE::UpdateManager::Config::save_script('lxc', 208, "second\n", 'root@pam'); 1 };
    ok(!$ok, 'a save whose displaced text cannot be kept is refused');
    like($@ // '', qr/disk full/, 'naming why');
}
($current) = PVE::UpdateManager::Config::load_script('lxc', 208);
is($current, "precious\n", 'and the file still holds the text that could not be kept');
