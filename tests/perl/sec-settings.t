#!/usr/bin/perl
# The settings of the security scan (#41): that they are part of the node's
# settings like every other key, that the defaults are the ones the owner
# confirmed, that a save refuses a bad value with its name, and that a file
# edited by hand into nonsense falls back instead of switching anything on.

use strict;
use warnings;

use File::Temp qw(tempdir);
use POSIX qw(tzset);
use Test::More;

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Settings;
use PVE::UpdateManager::SecSettings;

BEGIN {
    $ENV{TZ} = 'UTC';
    POSIX::tzset();
}

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";

my $defaults = PVE::UpdateManager::SecSettings::defaults();
my $schema = PVE::UpdateManager::SecSettings::schema();

# ── the set of keys ─────────────────────────────────────────────────────────
is(scalar(keys %$defaults), 17, 'seventeen security settings: the sixteen of #41 and the NOT FIXED cooldown of #73');
is_deeply([sort keys %$schema], [sort keys %$defaults], 'and every one of them has a schema entry');

my %all_schema = %{ PVE::UpdateManager::Settings::settings_schema() };
ok(!grep({ !exists($all_schema{$_}) } keys %$defaults), 'they are part of the node settings schema');
ok(!exists(PVE::UpdateManager::Settings::global_settings_schema()->{security_install_vmids}),
    'except in the datacenter-wide save: the vmid list belongs to one node');
ok(exists(PVE::UpdateManager::Settings::global_settings_schema()->{security_scan}),
    'control: the other security keys are in the datacenter-wide save');

# ── the defaults the owner confirmed ────────────────────────────────────────
my $set = PVE::UpdateManager::Settings::load_settings('pve-a');
my %want = (
    security_scan => 0, security_interval => 30, security_parallel => 4,
    security_targets => 'all', security_source => 'configured', security_exclude => '',
    security_min_severity => '', security_notify => 1, security_notify_once => 1,
    security_install => 0, security_install_mode => 'script', security_install_vmids => '',
    security_install_window => '', security_install_gap => 60,
    security_install_parallel_max => 1, security_reboot => 0,
);
is($set->{$_}, $want{$_}, "default $_ = '$want{$_}'") for sort keys %want;

# ── a save, and reading it back ─────────────────────────────────────────────
my %new = (
    security_scan => 1, security_interval => 45, security_parallel => 8,
    security_targets => 'script', security_source => 'debian',
    security_exclude => 'linux-image-*, firmware-?', security_min_severity => 'high',
    security_notify => 0, security_notify_once => 0, security_install => 1,
    security_install_mode => 'security', security_install_vmids => '101,102',
    security_install_window => '22:00-06:00', security_install_gap => 0,
    security_install_parallel_max => 3, security_reboot => 1,
);
PVE::UpdateManager::Settings::save_settings('pve-a', \%new);
$set = PVE::UpdateManager::Settings::load_settings('pve-a');
is($set->{$_}, $new{$_}, "$_ survives a save") for sort keys %new;
is($set->{schedule_time}, '03:00', 'control: a security save leaves the older keys alone');

# ── a save refuses what does not fit, naming the key ────────────────────────
my @bad = (
    [security_interval => 4], [security_interval => 'x'], [security_parallel => 0],
    [security_targets => 'some'], [security_source => 'file:///'], [security_exclude => '(a|b)'],
    [security_min_severity => 'critical'], [security_install_mode => 'rm'],
    [security_install_vmids => '101;reboot'], [security_install_window => '25:00-06:00'],
    [security_install_window => '06:00-06:00'], [security_install_gap => 99999],
    [security_install_parallel_max => 0], [security_scan => 2],
);
for my $b (@bad) {
    my ($k, $v) = @$b;
    my $ok = eval { PVE::UpdateManager::Settings::save_settings('pve-a', { $k => $v }); 1 };
    like($ok ? '' : $@, qr/\Q$k\E/, "a save with $k='$v' is refused and says which key");
}
is(PVE::UpdateManager::Settings::load_settings('pve-a')->{security_interval}, 45,
    'and a refused save wrote nothing');

# ── a file edited by hand falls back, it does not switch anything on ────────
my $file = PVE::UpdateManager::Settings::settings_file('pve-b');
PVE::UpdateManager::Config::_ensure_base_dir();
PVE::Tools::file_set_contents($file, join('', map { "$_\n" }
    'security_scan=yes', 'security_install=7', 'security_interval=1',
    'security_parallel=999999', 'security_targets=everything',
    'security_install_window=always', 'security_exclude=[a-z]+',
    'security_install_vmids=1,,2'));
$set = PVE::UpdateManager::Settings::load_settings('pve-b');
is($set->{security_scan}, 0, "'yes' is not a boolean - the check stays off");
is($set->{security_install}, 0, 'and 7 does not switch immediate updates on');
is($set->{security_interval}, 5, 'an interval below the floor is clamped up');
is($set->{security_parallel}, 64, 'a count above the ceiling is clamped down');
is($set->{security_targets}, 'all', 'an unknown choice falls back to the default');
is($set->{security_install_window}, '', 'so does a window that is not one');
is($set->{security_exclude}, '', 'and a pattern list with regex characters');
is($set->{security_install_vmids}, '', 'and a malformed vmid list');

# A full settings file is larger than the 8 KiB the reader used to accept.
my $long = join(',', 100000 .. 100000 + 600);
PVE::UpdateManager::Settings::save_settings('pve-c', {
    schedule_vmids => substr($long, 0, 4090) =~ s/,\d*\z//r,
    security_install_vmids => substr($long, 0, 4090) =~ s/,\d*\z//r,
    security_exclude => join(',', ('linux-image-*') x 70),
    security_scan => 1,
});
ok(-s $file > 0 && -s PVE::UpdateManager::Settings::settings_file('pve-c') > 8192,
    'premise: the stored file is larger than 8 KiB');
is(PVE::UpdateManager::Settings::load_settings('pve-c')->{security_scan}, 1,
    'and it still reads back instead of falling back to every default');

# ── the install window ──────────────────────────────────────────────────────
my $at = sub { my ($h, $m) = @_; 86400 * 100 + $h * 3600 + $m * 60 };
ok(PVE::UpdateManager::SecSettings::in_window('', $at->(3, 0)), 'no window is any time');
ok(PVE::UpdateManager::SecSettings::in_window('06:00-22:00', $at->(12, 0)), 'noon is inside 06-22');
ok(!PVE::UpdateManager::SecSettings::in_window('06:00-22:00', $at->(22, 0)), '22:00 is the end, not inside');
ok(PVE::UpdateManager::SecSettings::in_window('22:00-06:00', $at->(23, 30)), 'a window across midnight holds 23:30');
ok(PVE::UpdateManager::SecSettings::in_window('22:00-06:00', $at->(5, 59)), 'and 05:59');
ok(!PVE::UpdateManager::SecSettings::in_window('22:00-06:00', $at->(12, 0)), 'but not noon');
ok(!PVE::UpdateManager::SecSettings::in_window('nonsense', $at->(12, 0)), 'an unreadable window is never');

done_testing();
