#!/usr/bin/perl
# One security check round (#40), with the reader, the sources and the fetch
# replaced by stand-ins - those are tested on their own (#37, #38).
#
# The claims: a target with an old package comes out with it pending; a
# target that hangs and cannot be killed costs its own time limit and nothing
# else - the round still ends and every other target has its answer; a target
# that is being updated is not read; a second round cannot start while one
# runs; the summary every node reads is written, and not rewritten when
# nothing changed; and an unchanged target is not compared again.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes ();

# Bounded on its own: a round that never ends must turn this test red, not
# hang the suite (#40 mutant M2 hung it until an outer timeout).
$SIG{ALRM} = sub { print "not ok - the test did not finish within 90 s\n"; POSIX::_exit(1) };
alarm(90);
use POSIX ();

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::SecScan;
use PVE::UpdateManager::SecSummary;
use PVE::UpdateManager::SecAddress;
use Socket qw(inet_pton AF_INET);

# Alive means not gone and not a zombie (#52). kill(0) answers for a zombie
# too, and an orphan stays one where nobody reaps it: in a CI container the
# test itself can be PID 1. There sec-fetch.t's "the grandchild died" was red
# 3 of 3 times with the grandchild in state Z, and green on a host with
# systemd as PID 1.
sub alive {
    my ($pid) = @_;
    return 0 if !kill(0, $pid);
    open(my $st, '<', "/proc/$pid/stat") or return 0;
    my $line = <$st> // '';
    return $line =~ m/\) Z / ? 0 : 1;
}

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/etc";
$PVE::UpdateManager::SecScan::STATE_DIR = "$dir/state";
$PVE::UpdateManager::SecScan::TARGET_TIMEOUT = 3;
# Name resolution for the address checks (#56): never the network. 127.x
# is loopback, every other name a documentation address (TEST-NET-1).
$PVE::UpdateManager::SecAddress::RESOLVE = sub {
    return ([AF_INET, inet_pton(AF_INET, $_[0] =~ m/\A127\./ ? $_[0] : '192.0.2.10')]);
};
$PVE::UpdateManager::SecAddress::FIB_TRIE = "$dir/none";
$PVE::UpdateManager::SecAddress::IF_INET6 = "$dir/none";

my $status_old = "Package: openssl\nStatus: install ok installed\nArchitecture: amd64\nVersion: 3.5.1-1\n\n"
    . "Package: curl\nStatus: install ok installed\nArchitecture: amd64\nVersion: 8.14.1-2\n";
my $index = "Package: openssl\nArchitecture: amd64\nVersion: 3.5.1-1+deb13u1\n\n"
    . "Package: curl\nArchitecture: amd64\nVersion: 8.14.1-1\n";
my $index_file = "$dir/Packages";
PVE::Tools::file_set_contents($index_file, $index);

my $sec_list = "deb http://mirror.example/debian-security trixie-security main\n";
my $no_sec = "deb http://mirror.example/debian trixie main\n";
# Named like a security suite, but its Release file says otherwise.
my $fake_sec = "deb http://other.example/debian trixie-security main\n";

# What each target "has". 102 hangs and ignores every signal it can.
my %guest = (
    'node-pve-test' => { status => 'ok', files => { '/var/lib/dpkg/status' => $status_old,
        '/etc/apt/sources.list' => $sec_list } },
    'lxc-101' => { status => 'ok', files => { '/var/lib/dpkg/status' => $status_old,
        '/etc/apt/sources.list' => $sec_list } },
    'lxc-102' => { hang => 1 },
    'lxc-103' => { status => 'unsupported', reason => 'no dpkg status' },
    'lxc-104' => { status => 'ok', files => { '/var/lib/dpkg/status' => $status_old,
        '/etc/apt/sources.list' => $no_sec } },
    'lxc-105' => { status => 'ok', files => { '/var/lib/dpkg/status' => $status_old,
        '/etc/apt/sources.list' => $sec_list } },
    'lxc-106' => { status => 'ok', files => { '/var/lib/dpkg/status' => $status_old,
        '/etc/apt/sources.list' => $fake_sec } },
);
my @targets = (
    { type => 'node', id => 'pve-test', name => 'pve-test' },
    map { { type => 'lxc', id => "$_", name => "ct$_" } } 101 .. 106,
);
my $fetches = 0;
my $reads_file = "$dir/reads";

%PVE::UpdateManager::SecScan::HOOK = (
    now => sub { time() },
    read_target => sub {
        my ($t) = @_;
        my $g = $guest{"$t->{type}-$t->{id}"};
        open(my $fh, '>>', $reads_file) or die; print $fh "$t->{type}-$t->{id}\n"; close $fh;
        if ($g->{hang}) {
            $SIG{$_} = 'IGNORE' for qw(TERM INT HUP);
            sleep(3600);
        }
        return { %$g, os => { id => 'debian', version_codename => 'trixie' } };
    },
    parse_sources => sub {
        my ($files) = @_;
        my @e;
        for my $text (values %$files) {
            for (split(/\n/, $text)) {
                my (undef, $uri, $suite, @c) = split(/ /);
                push @e, { uri => $uri, suite => $suite, components => \@c };
            }
        }
        return (\@e, 0);
    },
    parse_proxy => sub { {} },
    is_security_suite => sub { $_[0] =~ m/-security\z/ ? 1 : 0 },
    job_key => sub { "$_[0]->{uri}|$_[0]->{suite}" },
    # Never the network from a test; the #53 block below replaces it.
    probe => sub { },
    fetch => sub {
        my ($jobs) = @_;
        $fetches++;
        return { map {; "$_->{uri}|$_->{suite}" => {
            is_security => ($_->{uri} =~ m/other\.example/ ? 0 : 1), date => 'Thu, 22 Oct 2026 08:24:15 UTC',
            packages => [$index_file] } } @$jobs };
    },
    severity_lookup => sub { 'unknown' },
);

no warnings 'redefine';
*PVE::UpdateManager::SecScan::collect_targets = sub { [@targets] };
*PVE::UpdateManager::Config::target_is_running = sub { $_[1] eq '105' ? 1 : 0 };
use warnings 'redefine';

my $settings = { security_scan => 1, security_interval => 30, security_parallel => 2,
    security_exclude => '', security_min_severity => '' };

# ── is a round due ──────────────────────────────────────────────────────────
ok(PVE::UpdateManager::SecScan::is_due($settings), 'a round is due when none ever ran');
ok(!PVE::UpdateManager::SecScan::is_due({ %$settings, security_scan => 0 }), 'and never when the check is off');

# ── the round ───────────────────────────────────────────────────────────────
my $t0 = Time::HiRes::time();
my $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
my $took = Time::HiRes::time() - $t0;
my %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };

is(scalar(keys %r), 7, 'premise: every target has a result');
cmp_ok($took, '<', 3 * 2 + 3, sprintf('the round ends although one target never does (%.1f s)', $took));

is($r{'lxc-101'}->{status}, 'ok', 'a readable target is checked');
is_deeply([map { $_->{name} } @{ $r{'lxc-101'}->{pending} }], ['openssl'],
    'its old openssl is pending, its newer curl is not');
is($r{'lxc-101'}->{pending}->[0]->{fixed}, '3.5.1-1+deb13u1', 'with the fixed version');
is($r{'lxc-101'}->{lists_date}, 1792657455, 'and the date of the list, from its Release file, as an epoch');
is($r{'node-pve-test'}->{status}, 'ok', 'the node itself is checked too');

is($r{'lxc-102'}->{status}, 'timeout', 'the hanging target is reported as such');
is($r{'lxc-103'}->{status}, 'unsupported', 'a target without dpkg says so');
is($r{'lxc-104'}->{status}, 'no-security-source', 'a target without a security suite says so');
is(scalar(@{ $r{'lxc-104'}->{pending} }), 0, 'and does not claim to be clean in numbers');
is($r{'lxc-106'}->{status}, 'no-security-source',
    'a suite named like a security suite whose Release says otherwise is not one');

ok($r{'lxc-105'}->{busy}, 'a target that is updating right now is skipped');
my @reads = split(/\n/, PVE::Tools::file_get_contents($reads_file));
ok(!grep({ $_ eq 'lxc-105' } @reads), 'and was not read at all');
is($fetches, 1, 'one fetch for all targets that share a source');

# ── the summary ─────────────────────────────────────────────────────────────
my $sum = PVE::UpdateManager::SecSummary::load('pve-test');
is($sum->{targets}->{'lxc-101'}->{count}, 1, 'the summary every node reads has the count');
is_deeply($sum->{targets}->{'lxc-101'}->{packages}, ['openssl'], 'and the package names');
my $sum_file = PVE::UpdateManager::SecSummary::file('pve-test');
like($sum_file, qr{\Q$dir/etc\E/security-pve-test\.json\z}, 'it lives beside the settings in the cluster store');

# ── a second round with nothing changed ─────────────────────────────────────
delete $guest{'lxc-102'}->{hang};
%{ $guest{'lxc-102'} } = %{ $guest{'lxc-103'} };
sleep(1);
my $first = $r{'lxc-101'};
ok($first->{computed}, 'premise: the first round computed the result');
$res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
%r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
is($r{'lxc-101'}->{computed}, $first->{computed}, 'an unchanged target is not compared again');
cmp_ok($r{'lxc-101'}->{checked}, '>', $first->{checked}, 'but it is marked as checked now');
is($r{'lxc-102'}->{status}, 'unsupported', 'control: a target whose answer changed gets the new one');
isnt((stat($sum_file))[9], undef, 'premise: the summary still exists');
ok(PVE::UpdateManager::SecSummary::write('pve-test', $res->{results}) == 0,
    'writing the same summary again is skipped');

# ── two rounds cannot overlap ───────────────────────────────────────────────
open(my $lk, '>>', "$dir/state/scan.lock") or die;
flock($lk, 2) or die;
my $busy = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
ok($busy->{busy}, 'a round while another holds the lock does nothing and says so');
close($lk);
ok(!PVE::UpdateManager::SecScan::run_round('pve-test', $settings)->{busy},
    'control: once the lock is free a round runs');

# ── ratings, with the real lookup (#44) ─────────────────────────────────────
#
# refresh is replaced (no network); the rating file it would have written is
# put where the round says it belongs. Two claims: the round's lookup reads
# the directory the round's refresh writes, and new ratings reach a target
# whose packages did not change.
{
    my $sev = "$dir/state/severity";
    mkdir($sev);
    my $list = "$sev/severity-trixie.list";
    PVE::Tools::file_set_contents($list, "openssl\t3.5.1-1+deb13u1\thigh\n");
    delete local $PVE::UpdateManager::SecScan::HOOK{severity_lookup};
    local $PVE::UpdateManager::SecScan::HOOK{severity_refresh} = sub { { ok => 1 } };
    my $high = { %$settings, security_min_severity => 'high' };

    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $high);
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    is_deeply([map { "$_->{name}=$_->{urgency}" } @{ $r{'lxc-101'}->{pending} }], ['openssl=high'],
        'a rated update is looked up where the round stores the ratings, and kept at "high"');

    sleep(1);    # a new mtime, as a real refresh gives
    PVE::Tools::file_set_contents($list, "openssl\t3.5.1-1+deb13u1\tlow\n");
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $high);
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    is(scalar(@{ $r{'lxc-101'}->{pending} }), 0,
        'new ratings reach a target whose packages did not change - "low" is now below the threshold');

    # #49: the round hands the refresh the proxy its guests' apt would use.
    my $seen;
    local $PVE::UpdateManager::SecScan::HOOK{severity_refresh} = sub { $seen = $_[0]; { ok => 1 } };
    local $PVE::UpdateManager::SecScan::HOOK{parse_proxy} = sub { { http => 'http://p.test:3128' } };
    PVE::UpdateManager::SecScan::run_round('pve-test', $high);
    ok($seen, 'premise: the round refreshed the severity data');
    is_deeply($seen && $seen->{proxies}, ['http://p.test:3128'], 'through the proxy the guests\' apt uses');
}

# ── a source whose package files are gone (#53) ───────────────────────────
{
    my $gone = sub {
        my ($jobs, $lists) = @_;
        for my $k (keys %$jobs) {
            $lists->{$k}->{pool_error} = 'answers HTTP 404' if $jobs->{$k}->{uri} =~ m/mirror\.example/;
        }
    };
    local $PVE::UpdateManager::SecScan::HOOK{probe} = $gone;
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    ok(scalar(@{ $r{'lxc-101'}->{pending} }), 'premise: lxc-101 has pending updates from that source');
    like($r{'lxc-101'}->{warning} // '', qr/answers HTTP 404/, 'it carries the warning that they cannot be installed');
    is($r{'lxc-101'}->{status}, 'ok', 'and is still counted - the updates are pending all the same');
    ok(!exists($r{'lxc-103'}->{warning}), 'control: a target that needed no list has no warning');

    # Same source, nothing pending: no run will fetch a package, none fails.
    # The node: lxc-105 would do, but it is "updating" in this file and so
    # never checked - a premise of "0 pending" would hold for nothing.
    my $was = $guest{'node-pve-test'};
    (my $current = $status_old) =~ s/Version: 3\.5\.1-1\n/Version: 3.5.1-1+deb13u1\n/;
    $guest{'node-pve-test'} = { status => 'ok', files => { '/var/lib/dpkg/status' => $current,
        '/etc/apt/sources.list' => $sec_list } };
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    my $n = $r{'node-pve-test'};
    ok($n->{status} eq 'ok' && !$n->{busy} && !@{ $n->{pending} },
        'premise: a CHECKED target of that source with nothing pending');
    ok(!exists($n->{warning}), 'has no warning - nothing of it would fail');
    $guest{'node-pve-test'} = $was;

    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    like($r{'lxc-101'}->{warning} // '', qr/answers HTTP 404/, 'a reused result carries it as well');

    local $PVE::UpdateManager::SecScan::HOOK{probe} = sub { };
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    ok(!exists($r{'lxc-101'}->{warning}), 'and loses it once the files are there again, reused or not');

    local $PVE::UpdateManager::SecScan::HOOK{probe} = sub { die "boom\n" };
    my @log;
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings, sub { push @log, @_ });
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    is($r{'lxc-101'}->{status}, 'ok', 'a probe that dies costs the warning, not the round');
    ok(grep({ m/checking the package files failed: boom/ } @log), 'and says so in the log');
}

# ── a fetch that dies costs the lists, not the round ───────────────────────
{
    local $PVE::UpdateManager::SecScan::HOOK{fetch} = sub { die "state dir unusable\n" };
    my @log;
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings, sub { push @log, @_ });
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    is($r{'lxc-101'}->{status}, 'source-unreachable', 'a dying fetch leaves the targets without their lists');
    like($r{'lxc-101'}->{reason}, qr/state dir unusable/, 'with the reason');
    is($r{'lxc-103'}->{status}, 'unsupported', 'control: a target that needed no list has its answer');
    ok(grep({ /fetching the security lists failed/ } @log), 'and the round says so in its log');
}

# ── a child that cannot be killed at all (#36 V9) ───────────────────────────
#
# Signals are switched off, so the hanging child really outlives its deadline
# - the stand-in for a reader stuck in the kernel. The round must still end
# on time, and must not have waited for it.
$guest{'lxc-102'} = { hang => 1 };
my @kills;
{
    local $PVE::UpdateManager::SecPool::KILL = sub { push @kills, $_[1]; 1 };
    my $t1 = Time::HiRes::time();
    $res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
    my $t2 = Time::HiRes::time() - $t1;
    %r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
    ok(scalar(@kills), 'premise: the deadline was reached and a kill was attempted');
    my $alive = grep { $_ > 0 && alive($_) } @kills;
    ok($alive, 'premise: the child really survived it');
    cmp_ok($t2, '<', 3 * 2 + 3, sprintf('the round ended anyway (%.1f s)', $t2));
    is($r{'lxc-102'}->{status}, 'timeout', 'and reported that target as timed out');
    is($r{'lxc-101'}->{status}, 'ok', 'control: the others were checked');

    # The hung child is still alive here. It must not hold the round's lock:
    # a flock follows the open file into a forked child, and one that never
    # ends would block every round after it.
    my ($hung) = grep { $_ > 0 && alive($_) } @kills;
    ok($hung, 'premise: the hung child is still alive');
    $guest{'lxc-102'} = { status => 'unsupported', reason => 'next round' };
    ok(!PVE::UpdateManager::SecScan::run_round('pve-test', $settings)->{busy},
        'and the next round runs anyway - the child does not hold the lock');
}
kill('KILL', -$_, $_) for grep { $_ > 0 } @kills;

# ── a reader left behind is remembered into the next round ──────────────────
#
# SecRead reports a reader it could not end (`stuck`). That process outlives
# the child that called SecRead, so only the round's state file can stop the
# next round from starting a second one beside it.
my $sleeper = fork();
if (!$sleeper) { exec('sleep', '300') or POSIX::_exit(1) }
$guest{'lxc-102'} = { status => 'timeout', reason => 'stuck', stuck => $sleeper };
unlink($reads_file);
PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
ok(-d "/proc/$sleeper", 'premise: the left-behind reader is alive');
unlink($reads_file);
$guest{'lxc-102'} = { status => 'unsupported', reason => 'read again' };
$res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
%r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
@reads = split(/\n/, PVE::Tools::file_get_contents($reads_file));
ok(!grep({ $_ eq 'lxc-102' } @reads), 'the next round does not start a reader beside it');
like($r{'lxc-102'}->{reason}, qr/earlier round \(pid $sleeper\)/, 'and says why, with the pid');
ok(grep({ $_ eq 'lxc-101' } @reads), 'control: the other targets are read');

kill('KILL', $sleeper);
waitpid($sleeper, 0);
unlink($reads_file);
$res = PVE::UpdateManager::SecScan::run_round('pve-test', $settings);
%r = map { ("$_->{type}-$_->{id}" => $_) } @{ $res->{results} };
@reads = split(/\n/, PVE::Tools::file_get_contents($reads_file));
ok(grep({ $_ eq 'lxc-102' } @reads), 'once it has ended, the target is read again');
is($r{'lxc-102'}->{reason}, 'read again', 'and gets its new answer');

# ── the key an Ubuntu source without Signed-By is checked against (#47) ──────
{
    my $ukey = '/usr/share/keyrings/ubuntu-archive-keyring.gpg';
    my $u = { uri => 'http://archive.ubuntu.com/ubuntu', suite => 'noble-security', components => ['main'] };
    my $jobs = sub { PVE::UpdateManager::SecJobs::security_jobs(@_, sub { $_[0] =~ m/-security\z/ }) };

    is(scalar(@{ $jobs->([$u], 'ubuntu', {}, {}) }), 1, 'premise: an Ubuntu security entry becomes a job');
    is($jobs->([$u], 'ubuntu', {}, {})->[0]->{signed_by}, $ukey,
        'an Ubuntu source without Signed-By is checked against the Ubuntu archive key, not the node trust store');
    is($jobs->([{ %$u, signed_by => '/etc/apt/keyrings/own.gpg' }], 'ubuntu', {}, {})->[0]->{signed_by},
        '/etc/apt/keyrings/own.gpg', 'control: a Signed-By the guest names is kept');
    is($jobs->([{ %$u, uri => 'http://deb.debian.org/debian-security', suite => 'trixie-security' }], 'debian', {}, {})
        ->[0]->{signed_by}, undef, 'control: Debian keeps the node trust store, which is Debian\'s');
    my $direct = $jobs->([$u], 'ubuntu', {}, { security_source => 'debian' })->[0];
    is_deeply([$direct->{uri}, $direct->{signed_by}], ['http://security.ubuntu.com/ubuntu', $ukey],
        'and the distribution\'s own address gets the same key');
}

# ── the proxies for the severity download (#49) ─────────────────────────────
{
    my $sp = sub { PVE::UpdateManager::SecJobs::severity_proxies(@_) };
    my $m = sub { { proxy => $_[0] } };
    is_deeply($sp->([$m->({ http => 'http://p.test:3128' })], {}), ['http://p.test:3128'],
        'the proxy a guest\'s apt uses is the one the download uses');
    is_deeply($sp->([$m->({ http => 'http://p.test:3128', https => 'http://s.test:3128' })], {}), ['http://s.test:3128'],
        'for the https tracker its https proxy wins, as in apt');
    is_deeply($sp->([$m->({ http => 'http://p.test:3128',
            hosts => { 'security-tracker.debian.org' => 'DIRECT' } })], {}), [],
        'a per-host DIRECT for the tracker is a direct download');
    is_deeply($sp->([$m->({ http => 'http://b.test:3128' }), $m->({ http => 'http://a.test:3128' }),
            $m->({}), $m->({ http => 'http://a.test:3128' })], {}),
        ['http://a.test:3128', 'http://b.test:3128', undef],
        'several guests: each proxy once, sorted, and direct last because one guest has none');
    is_deeply($sp->([$m->({}), $m->(undef)], {}), [], 'control: no guest with a proxy is direct');
    is_deeply($sp->([$m->({ http => 'http://p.test:3128' })], { security_source => 'debian' }), [],
        'security_source=debian ignores the guests\' proxies, as it does for their lists');
    is_deeply($sp->([$m->({ http => 'not a url' })], {}), [], 'a proxy that is no usable address is not tried');
    is_deeply($sp->([$m->({ http => 'http://127.0.0.1:3128' }), $m->({ http => 'http://p.test:3128' })], {}),
        ['http://p.test:3128'],
        'a proxy on the node\'s own loopback is not used - the same rule as for a source (#56)');
    is_deeply($sp->([$m->({ http => 'http://user:pw@[2001:db8::1]:3128' })], {}), [],
        'nor one with credentials in it');
}

done_testing();
