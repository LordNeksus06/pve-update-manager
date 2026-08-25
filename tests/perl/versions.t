#!/usr/bin/perl
# The saved versions of a target's update script.
#
# What matters here is that a save can be undone: the text that was stored last
# week is still on disk, it is readable, it is attributed to whoever saved it,
# and the retention count really does drop the oldest one rather than the wrong
# one. And that the two ways of removing a target's commands differ - a delete
# keeps the history, a purge takes it.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 81;

use POSIX ();
use PVE::INotify;
use PVE::Tools;
use PVE::UpdateManager::Config;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# ── the first save is version one ───────────────────────────────────────────
is_deeply(
    PVE::UpdateManager::Config::list_versions('lxc', 101),
    [],
    'a target nobody has saved has no history - and asking does not die on the missing directory',
);

PVE::UpdateManager::Config::save_script('lxc', 101, "first\n", 'root@pam');

my $versions = PVE::UpdateManager::Config::list_versions('lxc', 101);
is(scalar(@$versions), 1, 'the first save is recorded');
is($versions->[0]->{user}, 'root@pam', 'together with who made it');
like(
    $versions->[0]->{version},
    qr/\A[0-9]{4}(-[0-9]{2}){5}\z/,
    'and when, as the local second that stands in its filename',
);
ok($versions->[0]->{time} > 0, 'with the same moment as a second, for rendering');
is($versions->[0]->{size}, length("first\n"), 'and how big it is');

is(
    PVE::UpdateManager::Config::load_version('lxc', 101, $versions->[0]->{version}),
    "first\n",
    'the version reads back byte for byte',
);

# The newest version IS the current text. That is the claim the History menu
# makes when it labels the top entry "latest save".
my ($current) = PVE::UpdateManager::Config::load_script('lxc', 101);
is(
    PVE::UpdateManager::Config::load_version('lxc', 101, $versions->[0]->{version}),
    $current,
    'and it is the text that is stored now',
);

# ── a save that changes nothing writes nothing ──────────────────────────────
PVE::UpdateManager::Config::save_script('lxc', 101, "first\n", 'root@pam');
is(
    scalar(@{ PVE::UpdateManager::Config::list_versions('lxc', 101) }),
    1,
    'pressing Save without changing anything does not push the history out',
);

# ── retention ───────────────────────────────────────────────────────────────
#
# Version stamps are seconds, and a test that saved four times would have all
# four in the same second. _store_version moves a colliding stamp forward, which
# is what makes the ordering below meaningful rather than luck.
PVE::UpdateManager::Config::save_script('lxc', 101, "second\n", 'root@pam');
PVE::UpdateManager::Config::save_script('lxc', 101, "third\n", 'alice@pve');
PVE::UpdateManager::Config::save_script('lxc', 101, "fourth\n");

$versions = PVE::UpdateManager::Config::list_versions('lxc', 101);
is(scalar(@$versions), 3, 'the default keeps three');
is(
    PVE::UpdateManager::Config::load_version('lxc', 101, $versions->[0]->{version}),
    "fourth\n",
    'the newest first',
);
is(
    PVE::UpdateManager::Config::load_version('lxc', 101, $versions->[2]->{version}),
    "second\n",
    'and the oldest of the three that are left is the second save',
);
ok(!defined($versions->[0]->{user}), 'a save with no user recorded says nothing rather than lying');
is($versions->[1]->{user}, 'alice@pve', 'and the others still name theirs');

my @stamps = map { $_->{version} } @$versions;
my @times = map { $_->{time} } @$versions;
ok($times[0] > $times[1] && $times[1] > $times[2], 'the list is strictly newest first');
# The identifiers are timestamps in a fixed, zero-padded shape, so the order the
# list comes in is the order `ls` shows in the directory. That is the whole reason
# for the shape - a history somebody has to sort by hand is a history nobody reads.
ok($stamps[0] gt $stamps[1] && $stamps[1] gt $stamps[2], 'and the names sort the same way');

# ── restoring is a normal save ──────────────────────────────────────────────
my $old = PVE::UpdateManager::Config::load_version('lxc', 101, $stamps[2]);
PVE::UpdateManager::Config::save_script('lxc', 101, $old, 'root@pam');

($current) = PVE::UpdateManager::Config::load_script('lxc', 101);
is($current, "second\n", 'the older text is stored again');
$versions = PVE::UpdateManager::Config::list_versions('lxc', 101);
is(
    PVE::UpdateManager::Config::load_version('lxc', 101, $versions->[0]->{version}),
    "second\n",
    'and the restore is itself the newest version',
);
is(scalar(@$versions), 3, 'still three, so a restore does not grow the history');

# ── the retention count is a setting ────────────────────────────────────────
is(
    PVE::UpdateManager::Config::load_settings('pve-test')->{script_versions},
    3,
    'three by default',
);

PVE::UpdateManager::Config::save_settings('pve-test', { script_versions => 1 });
PVE::UpdateManager::Config::save_script('lxc', 101, "only-one\n", 'root@pam');

$versions = PVE::UpdateManager::Config::list_versions('lxc', 101);
is(scalar(@$versions), 1, 'lowering it drops the rest on the next save');
is(
    PVE::UpdateManager::Config::load_version('lxc', 101, $versions->[0]->{version}),
    "only-one\n",
    'and what is kept is the newest, not the oldest',
);

# A hand-edited settings file must not be able to disarm this: 0 would delete
# the version of the save being made.
PVE::UpdateManager::Config::_write_settings(
    'pve-test',
    { %{ PVE::UpdateManager::Config::load_settings('pve-test') }, script_versions => 0 },
);
is(
    PVE::UpdateManager::Config::load_settings('pve-test')->{script_versions},
    1,
    'a zero in the settings file is clamped to one, not obeyed',
);

ok(
    !defined(eval {
        PVE::UpdateManager::Config::save_settings('pve-test', { script_versions => 0 });
        1;
    }),
    'and the API refuses it outright',
);
ok(
    !defined(eval {
        PVE::UpdateManager::Config::save_settings('pve-test', { script_versions => 51 });
        1;
    }),
    'as it does a count above the maximum',
);

PVE::UpdateManager::Config::save_settings('pve-test', { script_versions => 3 });

# ── the name a save is stored under ─────────────────────────────────────────
#
# Readable without decoding anything, which is the point: `ls` answers "when was
# this saved" by itself.
is(
    PVE::UpdateManager::Config::version_file('lxc', 101, '2026-08-21-13-21-12', 'root@pam'),
    "$dir/store/lxc-101\@2026-08-21-13-21-12-root\@pam.conf",
    'the file is named after the local second and the user, and ends in .conf',
);
is(
    PVE::UpdateManager::Config::version_file('lxc', 101, '2026-08-21-13-21-12'),
    "$dir/store/lxc-101\@2026-08-21-13-21-12.conf",
    'and without a user where the API knew none',
);
is(
    PVE::UpdateManager::Config::version_file('node', 'pve-test', '2026-08-21-13-21-12', 'root@pam'),
    "$dir/store/node-pve-test\@2026-08-21-13-21-12-root\@pam.conf",
    'the host is named the same way',
);

# The shape a version was saved under BEFORE this one existed. Still built, so a
# node that was updated can still open and prune what is already on its disk.
is(
    PVE::UpdateManager::Config::version_file('lxc', 101, 1755690000, 'root@pam'),
    "$dir/store/lxc-101.conf.1755690000.root\@pam",
    'an epoch identifier still builds the old name it belongs to',
);

# ── a user id may never become a path ───────────────────────────────────────
is(
    PVE::UpdateManager::Config::version_file('lxc', 101, '2026-08-21-13-21-12', '../../etc/passwd'),
    "$dir/store/lxc-101\@2026-08-21-13-21-12.conf",
    'a user id that would walk out of the directory is dropped, not used',
);
is(
    PVE::UpdateManager::Config::version_file('lxc', 101, '2026-08-21-13-21-12', "root\@pam\nx"),
    "$dir/store/lxc-101\@2026-08-21-13-21-12.conf",
    'and so is one carrying a newline',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::version_file('lxc', 101, '1;rm -rf /') }),
    'a version that is neither shape is refused',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::version_file('lxc', 101, '2026-08-21-13-21') }),
    'and so is a timestamp with a field missing - it would sort against the others wrongly',
);
ok(
    !defined(eval {
        PVE::UpdateManager::Config::version_file('lxc', 101, '../../2026-08-21-13-21-12');
    }),
    'and one that tries to climb out of the directory',
);
ok(
    !defined(eval { PVE::UpdateManager::Config::load_version('lxc', 101, '../lxc-102.conf') }),
    'and so is one that tries to read another target',
);

# A version that is not there is not an error either - it is an empty answer the
# API turns into a 400 with a name on it.
ok(
    !defined(PVE::UpdateManager::Config::load_version('lxc', 101, 1)),
    'asking for a version that does not exist answers with nothing',
);

# ── the history is per target ───────────────────────────────────────────────
PVE::UpdateManager::Config::save_script('lxc', 102, "other\n", 'root@pam');
is(
    scalar(@{ PVE::UpdateManager::Config::list_versions('lxc', 102) }),
    1,
    'a second container has its own history',
);
is(
    PVE::UpdateManager::Config::load_version(
        'lxc', 102, PVE::UpdateManager::Config::list_versions('lxc', 102)->[0]->{version},
    ),
    "other\n",
    'and it is not the first one\'s',
);

PVE::UpdateManager::Config::save_script('node', 'pve-test', "host\n", 'root@pam');
is(
    scalar(@{ PVE::UpdateManager::Config::list_versions('node', 'pve-test') }),
    1,
    'the host has one too',
);

# ── delete keeps the history, purge takes it ────────────────────────────────
PVE::UpdateManager::Config::delete_script('lxc', 102);
is(
    scalar(@{ PVE::UpdateManager::Config::list_versions('lxc', 102) }),
    1,
    'removing the commands leaves the history - it is what makes that undoable',
);

is(PVE::UpdateManager::Config::delete_versions('lxc', 102), 1, 'a purge removes it');
is_deeply(
    PVE::UpdateManager::Config::list_versions('lxc', 102),
    [],
    'and then there is nothing left to restore',
);
is(
    PVE::UpdateManager::Config::load_version(
        'lxc', 101, PVE::UpdateManager::Config::list_versions('lxc', 101)->[0]->{version},
    ),
    "only-one\n",
    'and the other container keeps its own, which is what per-target storage means',
);

# ── who saved it, for every kind of user PVE has ────────────────────────────
#
# An API token is a userid like any other - `user@realm!token` - and a name may
# carry characters a hand-written charset would not think of. Dropping the
# author of every save made by a token is not a safe default, it is a feature
# that quietly does not work.
{
    my %expected = (
        'root@pam' => 'root@pam',
        'root@pam!ci' => 'root@pam!ci',
        'us+er@pve' => 'us+er@pve',
        # A dot in the name, a realm, a token. Deliberately NOT a realm
        # with a dot in it: that reads as an e-mail address to the
        # publishing tool's scanner, and a fixture is not worth a tree
        # that cannot be published.
        'a.b@pve-local!tok-1' => 'a.b@pve-local!tok-1',
        # What may never reach a path. A userid cannot contain these anyway -
        # this is the second lock on the door.
        '../../etc/passwd' => undef,
        "root\@pam\nx" => undef,
        '.hidden@pve' => undef,
        'a:b@pve' => undef,
        '' => undef,
    );

    for my $user (sort keys %expected) {
        my $want = $expected{$user};
        my $got = PVE::UpdateManager::Config::_version_user($user);
        my $shown = ($user =~ s/\n/\\n/gr);
        if (defined($want)) {
            is($got, $want, "'$shown' is kept as the author");
        } else {
            ok(!defined($got), "'$shown' is dropped rather than used as a path");
        }
    }
}

# And it survives the round trip, not just the pattern.
{
    PVE::UpdateManager::Config::save_script('lxc', 105, "by a token\n", 'root@pam!ci');

    my $versions = PVE::UpdateManager::Config::list_versions('lxc', 105);
    is($versions->[0]->{user}, 'root@pam!ci', 'a token save is listed with its token');
    is(
        PVE::UpdateManager::Config::load_version('lxc', 105, $versions->[0]->{version}),
        "by a token\n",
        'and the text reads back',
    );
}

# ── the shape that was on disk before this one ──────────────────────────────
#
# An upgrade that made every saved version vanish from the History menu would be
# a worse trade than any filename, so the old shape is still listed, still
# readable and still pruned. Only the new one is written; old files age out
# through the retention count on their own.
{
    my $keep = "$dir/store/lxc-777.conf";
    PVE::UpdateManager::Config::save_script('lxc', 777, "current\n", 'root@pam');

    # Exactly what an update leaves behind, written by hand because nothing
    # writes it any more.
    PVE::Tools::file_set_contents("$dir/store/lxc-777.conf.1700000000.root\@pam", "ancient\n");
    PVE::Tools::file_set_contents("$dir/store/lxc-777.conf.1700000001", "ancient too\n");

    my $mixed = PVE::UpdateManager::Config::list_versions('lxc', 777);
    is(scalar(@$mixed), 3, 'both shapes are listed together');
    is(
        scalar(grep { $_->{version} =~ m/\A[0-9]{4}(-[0-9]{2}){5}\z/ } @$mixed),
        1,
        'the one this version wrote, by its timestamp',
    );
    is(
        scalar(grep { $_->{version} =~ m/\A[0-9]+\z/ } @$mixed),
        2,
        'and the two older ones by their epoch',
    );
    is(
        $mixed->[-1]->{version},
        '1700000000',
        'the oldest is last, whichever shape it happens to have',
    );
    is(
        PVE::UpdateManager::Config::load_version('lxc', 777, '1700000000'),
        "ancient\n",
        'an old version still opens by the identifier it was listed under',
    );
    is($mixed->[-1]->{user}, 'root@pam', 'and still names who saved it');
    is($mixed->[-2]->{user}, undef, 'while one saved without a user still says nothing');

    # And they are the ones the retention count drops, because they are the
    # oldest - which is how a node grows out of the old shape without anybody
    # moving a file.
    is(PVE::UpdateManager::Config::prune_versions('lxc', 777, 1), 2, 'the two oldest go');
    my $left = PVE::UpdateManager::Config::list_versions('lxc', 777);
    is(scalar(@$left), 1, 'one is left');
    like(
        $left->[0]->{version},
        qr/\A[0-9]{4}(-[0-9]{2}){5}\z/,
        'and it is the newest, which is the one in the new shape',
    );
    ok(-f $keep, 'the script itself was never a version and is still there');
}

# ── the local clock in a name, and the one hour it is ambiguous in ──────────
#
# The timestamp is local time, which is what makes it readable and what makes one
# hour a year ambiguous: when a DST change repeats an hour, two instants an hour
# apart produce the SAME name. That is measured here rather than argued about,
# because it is the reason _store_version refuses to write a name that already
# exists - without that, the older file would be overwritten and the history
# would lose an entry once a year, quietly.
{
    local $ENV{TZ} = 'Europe/Berlin';
    POSIX::tzset();

    my $stamp = PVE::UpdateManager::Config::version_stamp(1787310000);
    like($stamp, qr/\A[0-9]{4}(-[0-9]{2}){5}\z/, 'a stamp is the fixed, padded shape');
    is(
        PVE::UpdateManager::Config::stamp_epoch($stamp),
        1787310000,
        'and it converts back to the second it came from',
    );

    # 2026-10-25 is the last Sunday of October: 03:00 CEST becomes 02:00 CET, so
    # 02:30 local happens at 00:30 UTC and again at 01:30 UTC.
    # Found by walking the clock on this machine, not by arithmetic: the first
    # attempt was a day out.
    my $first = 1792888220;   # 2026-10-25 02:30:20 CEST
    my $second = $first + 3600;
    is(
        PVE::UpdateManager::Config::version_stamp($first),
        PVE::UpdateManager::Config::version_stamp($second),
        'two instants an hour apart in the repeated hour want the same name',
    );
    isnt($first, $second, 'and they are genuinely different seconds');

    # One impossible field at a time, and every one of them on its own: mktime
    # NORMALISES an out-of-range field instead of refusing it, so a single
    # combined case passes as soon as any one check is left standing. Measured:
    # with the range check removed, '2026-99-99-99-99-99' converted to a
    # perfectly good epoch in 2034.
    is(
        PVE::UpdateManager::Config::stamp_epoch('2026-13-01-01-01-01'),
        undef,
        'a thirteenth month is not a date, and not a sort key either',
    );
    is(
        PVE::UpdateManager::Config::stamp_epoch('2026-08-32-01-01-01'),
        undef,
        'nor is a thirty-second day',
    );
    is(
        PVE::UpdateManager::Config::stamp_epoch('2026-08-21-24-01-01'),
        undef,
        'nor a twenty-fourth hour',
    );
    is(
        PVE::UpdateManager::Config::stamp_epoch('2026-08-21-01-60-01'),
        undef,
        'nor a sixtieth minute',
    );
    is(
        PVE::UpdateManager::Config::stamp_epoch('2026-08-21-00-00-00'),
        PVE::UpdateManager::Config::stamp_epoch('2026-08-21-00-00-00'),
        'while a date that IS one converts, and converts the same way twice',
    );
    ok(
        defined(PVE::UpdateManager::Config::stamp_epoch('2026-12-31-23-59-60')),
        'and a leap second is a local time localtime() will print, so it is kept',
    );
    is(
        PVE::UpdateManager::Config::stamp_epoch('nonsense'),
        undef,
        'and neither is something that is not a date at all',
    );

    delete $ENV{TZ};
    POSIX::tzset();
}

# The order comes from the SECOND, not from the identifier - and the two disagree
# the moment an old epoch-named version is newer than a new stamp-named one. It
# reads like a corner until you remember that '2026-08-21-...' and '1900000000'
# are both strings starting with a digit: sorted as text, the 2026 name wins
# because '2' beats '1', and the newer version would be listed last.
{
    PVE::UpdateManager::Config::save_script('lxc', 779, "new shape\n", 'root@pam');
    PVE::Tools::file_set_contents("$dir/store/lxc-779.conf.1900000000.root\@pam", "later\n");

    my $list = PVE::UpdateManager::Config::list_versions('lxc', 779);
    is(scalar(@$list), 2, 'both are listed');
    is(
        $list->[0]->{version},
        '1900000000',
        'and the one with the later SECOND is first, whatever its name sorts as',
    );
    is(
        PVE::UpdateManager::Config::load_version('lxc', 779, $list->[0]->{version}),
        "later\n",
        'so the newest version is the one that opens as the newest',
    );
}

# A file whose name carries an impossible date is not offered at all: it has no
# place in the order, and a menu entry that cannot be opened is worse than none.
{
    PVE::UpdateManager::Config::save_script('lxc', 778, "real\n", 'root@pam');
    PVE::Tools::file_set_contents("$dir/store/lxc-778\@2026-99-99-99-99-99-root\@pam.conf", "no\n");

    my $list = PVE::UpdateManager::Config::list_versions('lxc', 778);
    is(scalar(@$list), 1, 'the impossible one is left out');
    like($list->[0]->{version}, qr/\A2026-/, 'and the real one is still there');
}
