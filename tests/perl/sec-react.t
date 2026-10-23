#!/usr/bin/perl
# What a security check round leads to: the notification (#42) and the
# immediate update (#43).
#
# The claims: a notification names what is new and only that, once per
# package and fixed version when security_notify_once is on; an immediate
# update starts only inside its window, not shortly before the scheduled run,
# only for the targets it may touch, never for one that is updating already,
# and in mode 'security' runs an upgrade of exactly the pending packages.

use strict;
use warnings;

use File::Temp qw(tempdir);
use POSIX qw(tzset);
use Test::More;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::SecReact;
use PVE::UpdateManager::SecScan;

BEGIN {
    $ENV{TZ} = 'UTC';
    POSIX::tzset();
}

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/etc";
$PVE::UpdateManager::SecScan::STATE_DIR = "$dir/state";
mkdir("$dir/state");

# Quiet: the worker prints to its task log.
open(my $null, '>', '/dev/null') or die;
select($null);

my @sent;
$PVE::UpdateManager::SecReact::SEND = sub { push @sent, $_[1]; 1 };
my @started;
$PVE::UpdateManager::SecReact::START = sub { push @started, [@_]; 'UPID:x' };

my %running;
no warnings 'redefine';
*PVE::UpdateManager::Config::target_is_running = sub { $running{"$_[0]-$_[1]"} ? 1 : 0 };
use warnings 'redefine';

PVE::UpdateManager::Config::save_script($_->[0], $_->[1], "apt-get dist-upgrade\n")
    for ['lxc', 101], ['lxc', 102], ['node', 'pve-test'];

sub pkg { my ($n, $f) = @_; { name => $n, arch => 'amd64', installed => '1.0-1', fixed => $f // '1.0-1+deb13u1', urgency => 'unknown' } }
my @results = (
    { type => 'lxc', id => '101', name => 'web', status => 'ok', pending => [pkg('openssl'), pkg('libc6')] },
    { type => 'lxc', id => '102', name => 'db', status => 'ok', pending => [pkg('curl')] },
    { type => 'lxc', id => '103', name => 'noscript', status => 'ok', pending => [pkg('curl')] },
    { type => 'node', id => 'pve-test', name => 'pve-test', status => 'ok', pending => [pkg('bash')] },
    { type => 'lxc', id => '104', name => 'clean', status => 'ok', pending => [] },
    { type => 'lxc', id => '105', name => 'busy', status => 'ok', busy => 1, pending => [pkg('curl')] },
    { type => 'lxc', id => '106', name => 'gone', status => 'timeout', pending => [] },
);

# ── which targets count ─────────────────────────────────────────────────────
my @found = PVE::UpdateManager::SecReact::found(\@results);
is_deeply([map { $_->{id} } @found], [qw(101 102 103 pve-test)],
    'only checked targets with something pending; not a clean one, a busy one or a timed-out one');

# ── the notification ────────────────────────────────────────────────────────
my $s = { security_notify => 1, security_notify_once => 1 };
ok(PVE::UpdateManager::SecReact::notify('pve-test', $s, \@found), 'the first round notifies');
is(scalar(@sent), 1, 'with ONE notification for all targets');
is($sent[0]->{count}, 5, 'naming all five pending packages');
is(scalar(@{ $sent[0]->{targets} }), 4, 'on four targets');
like($sent[0]->{'status-text'}, qr/5 pending security updates on 4 targets/, 'and says so in its subject line');
is($sent[0]->{targets}->[0]->{packages}->[0]->{fixed}, '1.0-1+deb13u1', 'with the fixed versions');

@sent = ();
ok(!PVE::UpdateManager::SecReact::notify('pve-test', $s, \@found), 'the same findings again are not news');
is(scalar(@sent), 0, 'so nothing is sent');

my @newer = map { { %$_, pending => [map { { %$_ } } @{ $_->{pending} }] } } @found;
$newer[0]->{pending}->[0]->{fixed} = '1.0-1+deb13u2';
PVE::UpdateManager::SecReact::notify('pve-test', $s, \@newer);
is(scalar(@sent), 1, 'a newer fix for a package is news again');
is($sent[0]->{count}, 1, 'and only that one is named');
is($sent[0]->{targets}->[0]->{packages}->[0]->{name}, 'openssl', '- the package with the new fix');

@sent = ();
PVE::UpdateManager::SecReact::notify('pve-test', { %$s, security_notify_once => 0 }, \@found);
is($sent[0]->{count}, 5, 'control: with notify_once off, every round names everything');

# #53: a source whose package files are gone is a warning in the notification,
# sent once - like a package - even when no package is new.
my @warned = map { { %$_ } } @newer;
$warned[1]->{warning} = 'http://mirror.test bullseye-security ... answer HTTP 404';
@sent = ();
PVE::UpdateManager::SecReact::notify('pve-test', $s, \@warned);
is(scalar(@sent), 1, 'a new warning is news, though no package is');
is($sent[0]->{count}, 0, 'premise: no package is new in that round');
is($sent[0]->{targets}->[0]->{warning}, "WARNING: $warned[1]->{warning}", 'the target carries the warning');
like($sent[0]->{'status-text'}, qr/on 1 of them the updates cannot be installed from the configured source/,
    'and the subject line says it');
@sent = ();
PVE::UpdateManager::SecReact::notify('pve-test', $s, \@warned);
is(scalar(@sent), 0, 'the same warning again is not news');
$warned[1]->{warning} .= ' (moved)';
PVE::UpdateManager::SecReact::notify('pve-test', $s, \@warned);
is(scalar(@sent), 1, 'a changed warning is news again');

# ── the immediate update ────────────────────────────────────────────────────
my $noon = 86400 * 1000 + 12 * 3600;
my $base = {
    security_install => 1, security_install_mode => 'script', security_install_vmids => '',
    security_install_window => '', security_install_gap => 60, security_install_parallel_max => 1,
    security_reboot => 0, schedule_enabled => 0, schedule_time => '03:00', last_run => 0, timeout => 3600,
    start_stopped => 0, reboot_vms => 0, snapshot_before => 1, snapshot_keep => 3, snapshot_shutdown => 0,
    rollback_on_failure => 0, rollback_remove_newer => 1, notify_failure => 1, run_logs => 3,
};

my $run = sub {
    my ($over) = @_;
    @started = ();
    my $t = PVE::UpdateManager::SecReact::install('pve-test', { %$base, %$over }, \@found, $noon);
    return [map { "$_->{type}-$_->{id}" } @$t];
};

is_deeply($run->({}), [qw(lxc-101 lxc-102 node-pve-test)],
    'every target with pending updates and a script is updated; one without a script is not');
is(scalar(@started), 1, 'in ONE update task');
is($started[0]->[3]->{parallel}, 0, 'one at a time by default (security_install_parallel_max 1)');
ok(!defined($started[0]->[1]->[0]->{script}), "mode 'script' runs the stored script");

is_deeply($run->({ security_install_vmids => '102' }), ['lxc-102'],
    'with a vmid list only those guests - and not the node');

# A vmid list names guests. A node whose name happens to be a number is still
# not one of them.
PVE::UpdateManager::Config::save_script('node', '102', "apt-get dist-upgrade\n");
{
    my @withnode = (@found, { type => 'node', id => '102', name => '102', status => 'ok', pending => [pkg('bash')] });
    @started = ();
    my $u = PVE::UpdateManager::SecReact::install('pve-test', { %$base, security_install_vmids => '102' },
        \@withnode, $noon);
    is_deeply([map { "$_->{type}-$_->{id}" } @$u], ['lxc-102'], 'a node named like a listed vmid is not updated');
}

$running{'lxc-101'} = 1;
is_deeply($run->({}), [qw(lxc-102 node-pve-test)], 'a target that is updating right now is left alone');
delete $running{'lxc-101'};

is_deeply($run->({ security_install_window => '22:00-06:00' }), [], 'outside the window nothing starts');
is(scalar(@started), 0, '- not even an empty task');
is_deeply($run->({ security_install_window => '06:00-22:00' }), [qw(lxc-101 lxc-102 node-pve-test)],
    'control: inside it, it does');

# The scheduled run at 13:00 is 60 min away at noon: within a gap of 61, not 59.
is_deeply($run->({ schedule_enabled => 1, schedule_time => '13:00', last_run => $noon - 60,
    security_install_gap => 61 }), [], 'the scheduled run within the gap picks it up instead');
is_deeply($run->({ schedule_enabled => 1, schedule_time => '13:00', last_run => $noon - 60,
    security_install_gap => 59 }), [qw(lxc-101 lxc-102 node-pve-test)],
    'control: one further away does not hold it back');

my $t = $run->({ security_install_mode => 'security' });
my %script = map { ("$_->{type}-$_->{id}" => $_->{script}) } @{ $started[0]->[1] };
like($script{'lxc-101'}, qr/apt-get install -y --only-upgrade .* openssl libc6\n\z/,
    "mode 'security' upgrades exactly the pending packages");
unlike($script{'lxc-101'}, qr/dist-upgrade/, 'and not the stored script');
# #74: the stored script is not used in this mode, so a guest without one is
# updated as well - it used to be skipped with "has no update script".
is_deeply($t, [qw(lxc-101 lxc-102 lxc-103 node-pve-test)],
    "mode 'security' also updates a guest that has no script stored");
like($script{'lxc-103'} // '', qr/--only-upgrade .*\bcurl\n\z/, '- with its own pending package');
{
    # #75: the host as well - the owner's decision. Who may switch this on is
    # guarded when the settings are saved (an empty vmid list takes root@pam).
    my @f = ({ type => 'node', id => 'pve-bare', name => 'pve-bare', status => 'ok', pending => [pkg('bash')] });
    ok(!PVE::UpdateManager::Config::has_script('node', 'pve-bare'), 'premise: the host has no host script');
    @started = ();
    my $u = PVE::UpdateManager::SecReact::install('pve-test', { %$base, security_install_mode => 'security' },
        \@f, $noon);
    is_deeply([map { "$_->{type}-$_->{id}" } @$u], ['node-pve-bare'],
        "mode 'security' also updates a host that has no host script");
    like($started[0]->[1]->[0]->{script} // '', qr/--only-upgrade .*\bbash\n\z/, '- with its own pending package');
    @started = ();
    $u = PVE::UpdateManager::SecReact::install('pve-test', $base, \@f, $noon);
    is_deeply($u, [], "control: in mode 'script' a host without a host script is not updated");
    @started = ();
    $u = PVE::UpdateManager::SecReact::install('pve-test',
        { %$base, security_install_mode => 'security', security_install_vmids => '102' }, \@f, $noon);
    is_deeply($u, [], 'control: with a vmid list the host is not updated, script or not');
}

my @evil = ({ %{ $found[0] }, pending => [pkg('openssl; reboot'), pkg('libc6')] });
$run = sub {
    my ($over, $f) = @_;
    @started = ();
    PVE::UpdateManager::SecReact::install('pve-test', { %$base, %$over }, $f, $noon);
};
$run->({ security_install_mode => 'security' }, \@evil);
unlike($started[0]->[1]->[0]->{script}, qr/reboot|;/, 'a package name that is not one never reaches the shell line');

$run->({ security_install_parallel_max => 3, security_reboot => 1 }, \@found);
is($started[0]->[3]->{parallel}, 1, 'more than one at a time switches the run to parallel');
is($started[0]->[3]->{parallel_max}, 3, 'with that cap');
is($started[0]->[3]->{reboot_vms}, 1, 'security_reboot reboots VMs through the run');
is($started[0]->[4], 1, 'and is handed on for the containers');

done_testing();
