#!/usr/bin/perl
# The lock that serialises "is this target busy?" with "mark it busy" lives
# where only root can create files (#71).
#
# It used to be /run/lock/pve-update-manager-<target>.lck. /run/lock is 1777:
# any local account could create that file first and hold a flock on it, and
# every run of that target - by hand, by schedule, by the security reaction -
# was then refused as "already being updated by another task". With
# fs.protected_regular (2, measured on the development machine) root cannot
# even open a file another user created there.
#
# lock_file is replaced by one that does what pve-common's does - open ">>",
# flock - without its 10 s wait, so the path and the lock are real.

use strict;
use warnings;

use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Test::More;

use PVE::Tools;
use PVE::UpdateManager::Config;

my $taken;
{
    no warnings 'redefine';
    *PVE::Tools::lock_file = sub {
        my ($file, $timeout, $code) = @_;
        $taken = $file;
        open(my $fh, '>>', $file) or die "can't open file - $!\n";
        flock($fh, LOCK_EX | LOCK_NB) or die "can't lock file '$file' - got timeout\n";
        return $code->();
    };
}

sub mode { my @st = lstat($_[0]); return @st ? $st[2] & 07777 : undef }

# ── where it lives by default ───────────────────────────────────────────────
my $default = $PVE::UpdateManager::Config::LOCK_DIR;
ok(defined($default) && $default !~ m{\A/(?:run/lock|var/lock|tmp|var/tmp|dev/shm)(?:/|\z)},
    'the lock directory is not one every local user may write to (' . ($default // 'none') . ')');
my $parent = defined($default) ? dirname($default) : '/run/lock';
my $pm = mode($parent);
ok(defined($pm) && !($pm & 0002), sprintf('and its parent %s is not world-writable here (mode %s)', $parent,
    defined($pm) ? sprintf('%04o', $pm) : 'missing'));

# ── taking it ───────────────────────────────────────────────────────────────
my $dir = tempdir(CLEANUP => 1);
local $PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";

my $ran = PVE::UpdateManager::Config::lock_target('lxc', 101, sub { 'claimed' });
is($ran, 'claimed', 'control: with a directory of its own the lock is taken and the code runs');
is($taken, "$dir/locks/lxc-101.lck", 'at a path inside that directory');
is(mode("$dir/locks"), 0700, 'which it created for root alone');

# A directory somebody else made writable for everyone is not one to lock in:
# whoever can create the file first can hold the lock.
chmod(01777, "$dir/locks") or die;
$taken = undef;
$ran = eval { PVE::UpdateManager::Config::lock_target('lxc', 101, sub { 'claimed' }) };
ok(!defined($ran), 'a lock directory others may write to is refused');
like($@ // '', qr/lock directory/, 'with the reason');
is($taken, undef, 'and no lock file is opened in it');
chmod(0700, "$dir/locks") or die;

# Nor a symlink to one: the check is on the directory itself, not where it points.
mkdir("$dir/elsewhere", 0700) or die;
local $PVE::UpdateManager::Config::LOCK_DIR = "$dir/link";
symlink("$dir/elsewhere", "$dir/link") or die;
$ran = eval { PVE::UpdateManager::Config::lock_target('lxc', 101, sub { 'claimed' }) };
ok(!defined($ran), 'a lock directory that is a symlink is refused');

# Control: the lock still serialises - one holder at a time.
local $PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";
my $inner = PVE::UpdateManager::Config::lock_target('lxc', 102, sub {
    my $pid = fork() // die;
    if (!$pid) {
        my $r = eval { PVE::UpdateManager::Config::lock_target('lxc', 102, sub { 1 }) };
        POSIX::_exit($r ? 0 : 1);
    }
    waitpid($pid, 0);
    return $? >> 8;
});
is($inner, 1, 'control: a second taker of the same target lock does not get it');

done_testing();
