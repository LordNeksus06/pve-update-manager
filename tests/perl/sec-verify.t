#!/usr/bin/perl
# After every run: are the security updates that were pending before it
# installed (#73)? The owner's decisions of 2026-10-23, as claims:
# - OK only when all of them are; otherwise NOT FIXED - red, no rollback;
# - for every run, as long as the security check is on;
# - the ones pending before the run, from the stored result of the last check;
# - a guest that cannot be read: 3 attempts, 30 s apart, then NOT FIXED;
# - the security notification about it, at most every cooldown per node.

use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Job;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::Runner;
use PVE::UpdateManager::SecReact;
use PVE::INotify;
use PVE::UpdateManager::SecScan;
use PVE::UpdateManager::SecSummary;
use PVE::UpdateManager::SecVerify;
use PVE::UpdateManager::Target;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/store";
$PVE::UpdateManager::Config::LOCK_DIR = "$dir/locks";
$PVE::UpdateManager::Runner::CGROUP_FILE = "$dir/no-such-cgroup";
$PVE::UpdateManager::SecScan::STATE_DIR = "$dir/sec";
$PVE::UpdateManager::Logs::LOG_DIR = "$dir/logs";

my $T = { type => 'lxc', id => 101, name => 'web' };
PVE::UpdateManager::Config::save_script('lxc', 101, "apt-get dist-upgrade\n");
$PVE::LXC::RUNNING{101} = 4711;

sub status_with {
    my (%v) = @_;
    return join("\n", map { "Package: $_\nStatus: install ok installed\nArchitecture: amd64\nVersion: $v{$_}\n" }
        sort keys %v);
}

sub stored_result {
    my (@pending) = @_;
    make_path("$dir/sec/results");
    PVE::Tools::file_set_contents(PVE::UpdateManager::SecScan::result_file($T),
        JSON::PP->new->encode({ type => 'lxc', id => 101, status => 'ok', pending => [@pending] }));
}

my $openssl = { name => 'openssl', arch => 'amd64', installed => '3.5.1-1', fixed => '3.5.1-1+deb13u1' };
my $libc = { name => 'libc6', arch => 'amd64', installed => '2.41-12', fixed => '2.41-12+deb13u1' };

# What the guest says after the run, and how often it was asked.
my (@answers, $reads, @slept);
$PVE::UpdateManager::SecVerify::READ = sub {
    $reads++;
    my $a = @answers > 1 ? shift(@answers) : $answers[0];
    return $a;
};
$PVE::UpdateManager::SecVerify::SLEEP = sub { push @slept, $_[0] };
sub guest_has { @answers = ({ status => 'ok', files => { '/var/lib/dpkg/status' => status_with(@_) } }) }

# ── the comparison ──────────────────────────────────────────────────────────
{
    my $exp = [$openssl, $libc];

    guest_has(openssl => '3.5.1-1+deb13u1', libc6 => '2.41-12+deb13u2');
    is_deeply(PVE::UpdateManager::SecVerify::verify($T, $exp)->{missing}, [],
        'installed at the fixed version or newer: nothing missing');

    guest_has(openssl => '3.5.1-1', libc6 => '2.41-12+deb13u1');
    my $v = PVE::UpdateManager::SecVerify::verify($T, $exp);
    is_deeply([map { $_->{name} } @{ $v->{missing} }], ['openssl'], 'an older version is missing');
    is($v->{missing}->[0]->{installed}, '3.5.1-1', 'with the version it still has');
    like(PVE::UpdateManager::SecVerify::describe($v), qr/\Aopenssl 3\.5\.1-1, expected >= 3\.5\.1-1\+deb13u1\z/,
        'and is described for the row');

    guest_has(libc6 => '2.41-12+deb13u1');
    is_deeply(PVE::UpdateManager::SecVerify::verify($T, $exp)->{missing}, [],
        'a package that was removed counts as done');

    $reads = 0;
    is_deeply(PVE::UpdateManager::SecVerify::verify($T, [])->{missing}, [], 'nothing expected, nothing to check');
    is($reads, 0, 'and the guest is not even read');
}

# ── a guest that cannot be read: 3 attempts, 30 s apart ────────────────────
{
    @answers = ({ status => 'timeout', reason => 'agent did not answer' });
    ($reads, @slept) = (0);
    my $v = PVE::UpdateManager::SecVerify::verify($T, [$openssl]);
    is($reads, 3, 'three attempts');
    is_deeply(\@slept, [30, 30], '30 s apart, none after the last');
    like($v->{reason}, qr/verification not possible: agent did not answer/, 'then the reason');
    is(scalar(@{ $v->{missing} }), 1, 'and what was expected counts as missing - not shown is not installed');

    @answers = ({ status => 'timeout', reason => 'x' },
        { status => 'ok', files => { '/var/lib/dpkg/status' => status_with(openssl => '3.5.1-1+deb13u1') } });
    ($reads, @slept) = (0);
    $v = PVE::UpdateManager::SecVerify::verify($T, [$openssl]);
    ok(!$v->{reason} && !@{ $v->{missing} }, 'a second attempt that reads it is the answer');
    is($reads, 2, 'after two reads');
}

# ── which list: the stored result, only with the check on ──────────────────
{
    stored_result($openssl);
    is_deeply(PVE::UpdateManager::SecVerify::expected($T, { security_verify => 1 }), [$openssl],
        'the pending list of the stored result');
    is_deeply(PVE::UpdateManager::SecVerify::expected($T, { security_verify => 0 }), [],
        'nothing with the security check off');
    PVE::Tools::file_set_contents(PVE::UpdateManager::SecScan::result_file($T),
        encode_json({ status => 'timeout', pending => [$openssl] }));
    is_deeply(PVE::UpdateManager::SecVerify::expected($T, { security_verify => 1 }), [],
        'nothing from a result that is not a finished check');
}

# ── a whole run ─────────────────────────────────────────────────────────────
sub capture {
    my ($code) = @_;
    my $out = '';
    open(my $saved, '>&', \*STDOUT) or die;
    close(STDOUT);
    open(STDOUT, '>', \$out) or die;
    my $err;
    eval { $code->(); 1 } or $err = $@;
    close(STDOUT);
    open(STDOUT, '>&', $saved) or die;
    return ($out, $err);
}

my @mails;
$PVE::UpdateManager::SecReact::SEND_UNFIXED = sub { push @mails, $_[1]; 1 };
my $now = 1_800_000_000;
$PVE::UpdateManager::SecReact::NOW = sub { $now };

my $OPTS = { snapshot_before => 1, snapshot_keep => 3, rollback_on_failure => 1, run_logs => 3,
    security_verify => 1, security_notify => 1, security_unfixed_cooldown => 300 };

{
    stored_result($openssl);
    guest_has(openssl => '3.5.1-1');
    local $PVE::Tools::RUN_RC = 0;
    delete $PVE::LXC::Config::CONFIGS{101}->{snapshots};

    my ($out, $err) = capture(sub { PVE::UpdateManager::Job::run_all([$T], 60, $OPTS) });

    like($out, qr/NOT FIXED: openssl 3\.5\.1-1, expected >= 3\.5\.1-1\+deb13u1/, 'the run says what is not installed');
    like($out, qr/0 ok, 1 not fixed, 0 failed, 0 skipped, 1 total/, 'the summary counts it as not fixed');
    like($err // '', qr/1 of 1 update targets are NOT FIXED/, 'and the task ends red, naming it');
    is(PVE::UpdateManager::Config::last_run('lxc', 101)->{last_state}, 'not_fixed', 'the row is NOT FIXED');
    like(PVE::UpdateManager::Config::last_run('lxc', 101)->{last_note} // '', qr/NOT FIXED: openssl/,
        'with the packages in its note');
    is(PVE::UpdateManager::Config::last_run('lxc', 101)->{last_exit}, 0, 'and the exit code stays the script\'s 0');
    unlike($out, qr/rolling the container back/, 'no rollback, although rollback_on_failure is on');
    is(scalar(@{ [keys %{ $PVE::LXC::Config::CONFIGS{101}->{snapshots} // {} }] }), 1,
        'premise: there was a snapshot to roll back to');

    my ($log) = @{ PVE::UpdateManager::Logs::list_logs('lxc', 101) };
    is($log->{state}, 'not_fixed', 'the run log is read back as not_fixed, not as "no result"');

    is(scalar(@mails), 1, 'the security notification about it was sent');
    like($mails[0]->{'status-text'}, qr/1 target NOT FIXED/, 'saying what');
    like($mails[0]->{targets}->[0]->{packages}, qr/openssl/, 'and which package');
}

{
    # Within the cooldown: the run is the same, the mail is not sent again.
    $now += 60 * 60;
    capture(sub { PVE::UpdateManager::Job::run_all([$T], 60, $OPTS) });
    is(scalar(@mails), 1, 'an hour later, within 5 h: no second mail');
    $now += 4 * 60 * 60 + 1;
    capture(sub { PVE::UpdateManager::Job::run_all([$T], 60, $OPTS) });
    is(scalar(@mails), 2, 'after 5 h: the next one');
}

{
    guest_has(openssl => '3.5.1-1+deb13u1');
    my ($out, $err) = capture(sub { PVE::UpdateManager::Job::run_all([$T], 60, $OPTS) });
    ok(!defined($err), 'installed afterwards: the run is OK') or diag($err);
    is(PVE::UpdateManager::Config::last_run('lxc', 101)->{last_state}, 'ok', 'and so is the row');
    like($out, qr/all of them are installed/, 'the log says it checked');
}

{
    guest_has(openssl => '3.5.1-1');
    local $PVE::Tools::RUN_RC = 100;
    $reads = 0;
    my ($out, $err) = capture(sub { PVE::UpdateManager::Job::run_all([$T], 60, $OPTS) });
    is(PVE::UpdateManager::Config::last_run('lxc', 101)->{last_state}, 'failed', 'a script that fails is FAILED');
    is($reads, 0, 'and nothing is verified after it');
    like($out, qr/rolling the container back/, 'control: that one IS rolled back');
}

{
    guest_has(openssl => '3.5.1-1');
    local $PVE::Tools::RUN_RC = 0;
    $reads = 0;
    my ($out, $err) = capture(sub {
        PVE::UpdateManager::Job::run_all([$T], 60, { %$OPTS, security_verify => 0 }) });
    ok(!defined($err) && !$reads, 'with the security check off nothing is verified') or diag($err);
}

# ── #76: the stored result learns what the run installed ───────────────────
sub stored { PVE::UpdateManager::SecScan::load_result($T) }
sub summary_count {
    my $e = PVE::UpdateManager::SecSummary::load(PVE::INotify::nodename())->{targets}->{'lxc-101'};
    return $e ? $e->{count} : undef;
}
my $curl = { name => 'curl', arch => 'amd64', installed => '8.14.1-2', fixed => '8.14.1-2+deb13u7' };
$PVE::UpdateManager::SecVerify::NOW = sub { 1_900_000_000 };

{
    my $old_libc = { %$libc, installed => '2.41-11' };
    PVE::Tools::file_set_contents(PVE::UpdateManager::SecScan::result_file($T), encode_json({ status => 'ok',
        pending => [$openssl, $old_libc], cache => 'abc', computed => 1, checked => 2, warning => 'w' }));
    guest_has(openssl => '3.5.1-1+deb13u1', libc6 => '2.41-12');
    my $v = PVE::UpdateManager::SecVerify::verify($T, [$openssl, $old_libc]);
    is_deeply([map { $_->{name} } @{ $v->{missing} }], ['libc6'], 'premise: openssl is installed, libc6 is not');

    my @said;
    PVE::UpdateManager::SecVerify::record($T, $v, sub { push @said, $_[0] });
    my $r = stored();
    is_deeply([map { $_->{name} } @{ $r->{pending} }], ['libc6'], 'the installed one leaves the stored result');
    is($r->{pending}->[0]->{installed}, '2.41-12', 'the one still pending carries the version it has now');
    ok(!exists($r->{cache}), 'the cache key goes, so the next round compares afresh');
    is_deeply([@$r{qw(computed checked refreshed warning)}], [1, 2, 1_900_000_000, 'w'],
        'computed and checked stay, refreshed is set, the warning stays while something is pending');
    like($said[0] // '', qr/now lists 1 pending update\(s\), was 2/, 'and the task log says so');
}

{
    # A round wrote a newer result between the verification and the write:
    # the run edits that one, it does not put back what it saw before.
    stored_result($openssl);
    guest_has(openssl => '3.5.1-1+deb13u1', curl => '8.14.1-2');
    my $v = PVE::UpdateManager::SecVerify::verify($T, [$openssl]);
    stored_result($openssl, $curl);
    PVE::UpdateManager::SecVerify::record($T, $v);
    is_deeply([map { $_->{name} } @{ stored()->{pending} }], ['curl'],
        'a newer result is edited, not replaced - curl from the newer round stays');
}

{
    stored_result($openssl, $curl);
    guest_has(openssl => '3.5.1-1+deb13u1');
    PVE::UpdateManager::SecVerify::record($T, PVE::UpdateManager::SecVerify::verify($T, [$openssl]));
    is_deeply(stored()->{pending}, [], 'a package removed from the guest leaves the result as well');
    is(summary_count(), undef, 'control: a target the summary does not have is not added to it');
    ok(!exists(stored()->{warning}), '- and with nothing pending, so does the warning');
}

{
    stored_result($openssl);
    @answers = ({ status => 'timeout', reason => 'agent did not answer' });
    my $v = PVE::UpdateManager::SecVerify::verify($T, [$openssl]);
    PVE::UpdateManager::SecVerify::record($T, $v);
    is_deeply([map { $_->{name} } @{ stored()->{pending} }], ['openssl'],
        'control: a guest that could not be read changes nothing - not shown is not installed');
}

{
    stored_result($openssl);
    guest_has(openssl => '3.5.1-1+deb13u1');
    my $v = PVE::UpdateManager::SecVerify::verify($T, [$openssl]);
    open(my $lock, '>>', "$dir/sec/scan.lock") or die;
    flock($lock, 2) or die;   # LOCK_EX: a round is running
    my @said;
    PVE::UpdateManager::SecVerify::record($T, $v, sub { push @said, $_[0] });
    close($lock);
    is_deeply([map { $_->{name} } @{ stored()->{pending} }], ['openssl'],
        'control: while a round holds the lock the run leaves the result to it');
    like($said[0] // '', qr/a security check is running right now/, '- and says so');
}

{
    PVE::Tools::file_set_contents(PVE::UpdateManager::SecScan::result_file($T),
        encode_json({ status => 'timeout', pending => [$openssl] }));
    guest_has(openssl => '3.5.1-1+deb13u1');
    PVE::UpdateManager::SecVerify::record($T, PVE::UpdateManager::SecVerify::verify($T, [$openssl]));
    is(stored()->{status}, 'timeout', 'control: a result that is not a finished check is left alone');
    is(scalar(@{ stored()->{pending} }), 1, '- pending list included');
}

{
    # The whole way, as the owner saw it: a run installs, and what the UI
    # reads - the node's summary, not the result - agrees.
    stored_result($openssl);
    PVE::UpdateManager::SecSummary::write(PVE::INotify::nodename(),
        [{ %{ stored() }, type => 'lxc', id => 101 }]);
    is(summary_count(), 1, 'premise: the summary the UI reads says 1 pending');
    guest_has(openssl => '3.5.1-1+deb13u1');
    $PVE::LXC::RUNNING{101} = 4711;   # the rollback above left it stopped
    local $PVE::Tools::RUN_RC = 0;
    my ($out, $err) = capture(sub { PVE::UpdateManager::Job::run_all([$T], 60, $OPTS) });
    ok(!defined($err) && $out =~ m/all of them are installed/, 'premise: the run is OK and verified')
        or diag($err // $out);
    is_deeply(stored()->{pending}, [], 'after the run the stored result lists nothing pending');
    is(summary_count(), 0, 'and the summary the UI reads says 0');
    like($out, qr/now lists 0 pending update\(s\), was 1/, '- and the run log says so');
}

done_testing();
