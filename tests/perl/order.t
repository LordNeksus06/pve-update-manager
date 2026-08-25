#!/usr/bin/perl
# The order a run walks its targets in, serial or parallel.
#
# The rule is small and the consequences are not: a database container that is
# updated after the two that talk to it is the case this exists for, so what is
# pinned here is the sort itself - lower first, ties by id, unset last - the fact
# that a list nobody has given an order to comes out exactly as it went in, and
# the waves a parallel run splits the same list into.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More tests => 40;

use PVE::Tools;
use PVE::UpdateManager::Config;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

# ── storage ─────────────────────────────────────────────────────────────────
is(
    PVE::UpdateManager::Config::order_file('lxc', 101),
    "$dir/store/lxc-101.order",
    'the order sits beside the script, not in the container config',
);
is(
    PVE::UpdateManager::Config::order_file('node', 'pve-test'),
    "$dir/store/node-pve-test.order",
    'and the host has one too',
);

is(PVE::UpdateManager::Config::load_order('lxc', 101), 0, 'nothing stored reads as 0');

is(PVE::UpdateManager::Config::save_order('lxc', 101, 20), 20, 'a number is stored');
is(PVE::UpdateManager::Config::load_order('lxc', 101), 20, 'and comes back');
ok(-f "$dir/store/lxc-101.order", 'as a plain file');

# 0 is how "no answer given" is spelled, and it has to be indistinguishable from
# never having been set - otherwise clearing the field would leave a row that
# claims an order the sort does not act on.
is(PVE::UpdateManager::Config::save_order('lxc', 101, 0), 0, 'clearing it is a 0');
ok(!-f "$dir/store/lxc-101.order", 'which removes the file');
is(PVE::UpdateManager::Config::load_order('lxc', 101), 0, 'and reads back as unset');

ok(
    !defined(eval { PVE::UpdateManager::Config::save_order('lxc', 101, 100000); 1 }),
    'a number above the maximum is refused',
);
is(
    PVE::UpdateManager::Config::save_order('lxc', 101, 'abc'),
    0,
    'and something that is not a number at all is taken as unset rather than written',
);

# A file edited by hand into nonsense must not make the sort die in the middle
# of a run it is ordering.
PVE::Tools::file_set_contents("$dir/store/lxc-101.order", "order=nonsense\n");
is(PVE::UpdateManager::Config::load_order('lxc', 101), 0, 'a broken file reads as unset');
PVE::Tools::file_set_contents("$dir/store/lxc-101.order", "order=999999999\n");
is(PVE::UpdateManager::Config::load_order('lxc', 101), 0, 'and so does one out of range');
unlink("$dir/store/lxc-101.order");

# An id the path builder refuses must not take a list down with it. This is
# called once per target while the node and datacenter grids are built, exactly
# where has_script already learned that one broken target may not cost the whole
# list.
{
    my $got = eval { PVE::UpdateManager::Config::load_order('lxc', '../etc/passwd') };
    is($got, 0, 'an impossible id reads as unset rather than dying');

    my $versions = eval { PVE::UpdateManager::Config::list_versions('lxc', '../etc/passwd') };
    is_deeply($versions, [], 'and asking for its history answers with nothing');
}

# ── the sort ────────────────────────────────────────────────────────────────
my $targets = [
    { type => 'lxc', id => 103, name => 'web' },
    { type => 'lxc', id => 101, name => 'db' },
    { type => 'lxc', id => 102, name => 'cache' },
];

is_deeply(
    [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($targets) }],
    [101, 102, 103],
    'with no orders set the list is walked by ascending vmid, as it always was',
);

PVE::UpdateManager::Config::save_order('lxc', 101, 10);
PVE::UpdateManager::Config::save_order('lxc', 103, 1);

is_deeply(
    [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($targets) }],
    [103, 101, 102],
    'a number pulls a target forward, and the one without goes last',
);

PVE::UpdateManager::Config::save_order('lxc', 102, 1);

is_deeply(
    [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($targets) }],
    [102, 103, 101],
    'two targets with the same number go by ascending vmid',
);

# The host is a target like any other here: it is never picked by Select All, so
# without a number of its own it would always be updated last - which is not
# what somebody who ticks it and two containers means.
my $mixed = [
    { type => 'lxc', id => 101, name => 'db' },
    { type => 'node', id => 'pve-test', name => 'pve-test' },
];

is_deeply(
    [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($mixed) }],
    [101, 'pve-test'],
    'the host has no number, so it goes after the container that has one',
);

PVE::UpdateManager::Config::save_order('node', 'pve-test', 5);

is_deeply(
    [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($mixed) }],
    ['pve-test', 101],
    'and with one it goes first',
);

PVE::UpdateManager::Config::save_order('node', 'pve-test', 10);

is_deeply(
    [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($mixed) }],
    ['pve-test', 101],
    'a host and a container on the same number put the host first',
);

# Nothing about the targets themselves may change on the way through: the sort
# hands back the same hashrefs, names included, because run_all logs from them.
my $sorted = PVE::UpdateManager::Config::sort_targets($mixed);
is(scalar(@$sorted), 2, 'nothing is lost');
is($sorted->[1]->{name}, 'db', 'and nothing is rewritten');

is_deeply(PVE::UpdateManager::Config::sort_targets([]), [], 'an empty list is an empty list');

my $one = [{ type => 'lxc', id => 999, name => 'lonely' }];
is_deeply(
    PVE::UpdateManager::Config::sort_targets($one),
    $one,
    'and a single target does not need an order to survive the sort',
);

# An id the path builder refuses must not take the whole run down - the sort is
# the last thing between a list of targets and a dist-upgrade.
my $bad = [
    { type => 'lxc', id => '../etc/passwd', name => 'nasty' },
    { type => 'lxc', id => 102, name => 'cache' },
];
my $survived = eval { PVE::UpdateManager::Config::sort_targets($bad) };
ok(defined($survived), 'a target with an impossible id does not kill the sort');
is(scalar(@$survived), 2, 'and it is still in the list, to be refused where it is run');

unlink("$dir/store/lxc-102.order");
unlink("$dir/store/lxc-103.order");
unlink("$dir/store/lxc-101.order");
is(PVE::UpdateManager::Config::delete_order('node', 'pve-test'), 1, 'an order can be deleted');
is(PVE::UpdateManager::Config::delete_order('node', 'pve-test'), 0, 'twice is not an error');

# ── the waves a parallel run starts ─────────────────────────────────────────
#
# The number means the same thing in a parallel run as in a serial one, and this
# is where that is pinned: everything sharing a number goes at once, the next
# number waits for the last of them, and the targets without a number are one
# final wave rather than one wave each. That last part is the whole feature's
# hinge - one wave each would turn a parallel run that nobody has given an order
# to into a serial one.
sub ids_of {
    my ($groups) = @_;
    return [map { [map { $_->{id} } @$_] } @$groups];
}

{
    my $four = [
        { type => 'lxc', id => 104, name => 'four' },
        { type => 'lxc', id => 101, name => 'one' },
        { type => 'lxc', id => 103, name => 'three' },
        { type => 'lxc', id => 102, name => 'two' },
    ];

    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($four)),
        [[101, 102, 103, 104]],
        'with no orders set the whole selection is ONE wave - a parallel run stays parallel',
    );

    PVE::UpdateManager::Config::save_order('lxc', 101, 1);
    PVE::UpdateManager::Config::save_order('lxc', 102, 1);
    PVE::UpdateManager::Config::save_order('lxc', 103, 2);

    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($four)),
        [[101, 102], [103], [104]],
        'the same number is one wave, the next number is the next, and no number goes last',
    );

    PVE::UpdateManager::Config::save_order('lxc', 104, 2);

    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($four)),
        [[101, 102], [103, 104]],
        'giving the last one a number moves it into that number\'s wave',
    );

    # The gap is not a wave. 1 and 500 with nothing in between is two waves, not
    # five hundred - the number says what comes first, not how long to wait.
    PVE::UpdateManager::Config::save_order('lxc', 103, 500);
    PVE::UpdateManager::Config::save_order('lxc', 104, 500);

    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($four)),
        [[101, 102], [103, 104]],
        'a gap between two numbers is not a wave of its own',
    );

    # Every target that went in comes out, exactly once. A grouping that loses
    # one is a container that is never updated and never reported either, which
    # is the worst outcome this function has available to it.
    my $flat = [map { @$_ } @{ PVE::UpdateManager::Config::group_targets($four) }];
    is(scalar(@$flat), 4, 'nothing is lost on the way into the waves');
    is($flat->[0]->{name}, 'one', 'and the targets themselves are handed through, names included');

    # The waves must agree with the sort. Two functions reading the same numbers
    # and disagreeing about what comes first would mean the order column shows
    # one run and the parallel run does another.
    is_deeply(
        [map { $_->{id} } @$flat],
        [map { $_->{id} } @{ PVE::UpdateManager::Config::sort_targets($four) }],
        'and they come out in exactly the order sort_targets walks',
    );

    unlink("$dir/store/lxc-$_.order") for (101, 102, 103, 104);
}

is_deeply(PVE::UpdateManager::Config::group_targets([]), [], 'no targets are no waves');

{
    my $one = [{ type => 'lxc', id => 999, name => 'lonely' }];
    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($one)),
        [[999]],
        'and one target is one wave of one',
    );
}

# The host is a target like any other here too: ticked together with a container
# on the same number, the two go at once - and the sort's tie-break decides which
# is named first, not which runs first.
{
    my $mixed_wave = [
        { type => 'lxc', id => 101, name => 'db' },
        { type => 'node', id => 'pve-test', name => 'pve-test' },
    ];
    PVE::UpdateManager::Config::save_order('lxc', 101, 7);
    PVE::UpdateManager::Config::save_order('node', 'pve-test', 7);

    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($mixed_wave)),
        [['pve-test', 101]],
        'a host and a container on the same number are one wave',
    );

    PVE::UpdateManager::Config::save_order('node', 'pve-test', 8);

    is_deeply(
        ids_of(PVE::UpdateManager::Config::group_targets($mixed_wave)),
        [[101], ['pve-test']],
        'and on different numbers they are two',
    );

    unlink("$dir/store/lxc-101.order");
    PVE::UpdateManager::Config::delete_order('node', 'pve-test');
}
