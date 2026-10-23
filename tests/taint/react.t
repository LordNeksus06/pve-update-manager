#!/usr/bin/perl -T
# The immediate update after a security check (#43) under taint mode, the way
# pvedaemon runs it.
#
#   perl -T -I tests/stubs -I perl tests/taint/react.t
#
# "Check now" runs SecReact::worker in a worker forked from pvedaemon (-T).
# The targets it hands to the update are the round's results, and run_round
# reads those back from results/<type>-<id>.json - a file, so every field is
# tainted. A target's type and id name its state file, its lock and the
# container `pct exec` runs in. The results here are read from a JSON file
# and asserted tainted first: a literal never is.

use strict;
use warnings;

use File::Temp qw(tempdir);
use JSON::PP ();
use Scalar::Util qw(tainted);
use Test::More;

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::SecReact;
use PVE::UpdateManager::SecScan;

$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

ok(${^TAINT}, 'premise: this runs with -T');

my $tmp = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$tmp/etc";
$PVE::UpdateManager::SecScan::STATE_DIR = "$tmp/state";
mkdir("$tmp/state") or die;

open(my $null, '>', '/dev/null') or die;
select($null);

PVE::UpdateManager::Config::save_script('lxc', '101', "apt-get dist-upgrade\n");

# What the real run_command would refuse: exec checks every argument, list
# form included ("Insecure dependency in exec").
my @tainted_exec;
$PVE::Tools::RUN_HOOK = sub {
    my ($cmd) = @_;
    push @tainted_exec, join(' ', @$cmd) if ref($cmd) eq 'ARRAY' && grep { tainted($_) } @$cmd;
};

# The round's result, as run_round returns it: read back from a file.
my $json = JSON::PP->new->utf8->canonical;
open(my $fh, '>', "$tmp/result.json") or die;
print {$fh} $json->encode({ type => 'lxc', id => '101', name => 'web', status => 'ok',
    pending => [{ name => 'openssl', arch => 'amd64', installed => '1', fixed => '2' }] });
close($fh);
open($fh, '<', "$tmp/result.json") or die;
my $result = $json->decode(do { local $/; <$fh> });
close($fh);
ok(tainted($result->{type}) && tainted($result->{id}), 'premise: a result read from a file is tainted');

my @started;
$PVE::UpdateManager::SecReact::START = sub { push @started, $_[1]; 'UPID:x' };
no warnings 'redefine';
*PVE::UpdateManager::Config::target_is_running = sub { 0 };
*PVE::UpdateManager::Guest::is_running = sub { 1 };
use warnings 'redefine';

PVE::UpdateManager::SecReact::install('pve', {
    security_install => 1, security_install_mode => 'security', security_install_window => '',
    schedule_enabled => 0, security_install_parallel_max => 1, timeout => 3600,
}, [$result]);
is(scalar(@started), 1, 'premise: the immediate update is started for the target');
my $target = $started[0]->[0];

ok(!tainted($target->{type}), 'the type handed to the update is not tainted');
ok(!tainted($target->{id}), 'the id handed to the update is not tainted');

# What the update does first with it: record the target as running.
my $saved = eval { PVE::UpdateManager::Config::save_state($target->{type}, $target->{id}, { state => 'ok' }); 1 };
ok($saved, 'its state file can be written under -T') or diag("error: $@");

# security_reboot: after the update, a container that asks for it is restarted.
no warnings 'redefine';
*PVE::UpdateManager::Config::last_run = sub { { last_state => 'ok' } };
use warnings 'redefine';
@tainted_exec = ();
@PVE::Tools::RUN_CALLS = ();
PVE::UpdateManager::SecReact::restart_containers([$target]);
ok(scalar(@PVE::Tools::RUN_CALLS), 'premise: the restart check runs a command');
is_deeply(\@tainted_exec, [], 'with no tainted argument, which exec would refuse');

# A result that is not a target - a hand-edited results file - is not
# laundered into one.
@started = ();
PVE::UpdateManager::SecReact::install('pve', {
    security_install => 1, security_install_mode => 'script', security_install_window => '',
    schedule_enabled => 0, security_install_parallel_max => 1, timeout => 3600,
}, [{ %$result, id => '101/../102' }]);
is(scalar(@started), 0, 'an id that is not a vmid starts no update');

done_testing();
