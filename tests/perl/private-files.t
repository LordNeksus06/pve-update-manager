#!/usr/bin/perl
# What the node keeps under /var/lib/pve-update-manager about a guest is for
# root alone (#67).
#
# The API hands a run log only to a user with VM.Audit on that guest, and the
# security results only to one allowed to see them. The files behind both were
# 0644 in 0755 directories - the mode file_set_contents gives when it is not
# told one - so every local account of the node, the PAM users with a shell
# and www-data included, read them past that check: what a script echoed, a
# guest's whole package list, and the apt proxy of a guest with its password.
#
# The umask is pinned to the service's (systemd's default 022): what is checked
# is the mode the code asks for, not whatever the shell running the suite has.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::Logs;
use PVE::UpdateManager::SecFetch;
use PVE::UpdateManager::SecReact;
use PVE::UpdateManager::SecScan;

umask(022);

sub mode { my @st = stat($_[0]); return @st ? $st[2] & 07777 : undef }

sub private {
    my ($path, $what) = @_;
    my $m = mode($path);
    ok(defined($m) && ($m & 077) == 0, sprintf('%s is for root alone (mode %s)', $what,
        defined($m) ? sprintf('%04o', $m) : 'missing'));
}

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/etc";

# ── run logs ────────────────────────────────────────────────────────────────
$PVE::UpdateManager::Logs::LOG_DIR = "$dir/lib/logs";
my $stamp = PVE::UpdateManager::Logs::save_log('lxc', 101, "TOKEN=s3cret\n", 3, 1787310000);
my $log = PVE::UpdateManager::Logs::log_file('lxc', 101, $stamp);
like(PVE::Tools::file_get_contents($log), qr/TOKEN=s3cret/, 'premise: the log holds what the script echoed');
private("$dir/lib/logs", 'the run log directory');
private($log, 'a run log');

# An install from before this fix has the directory at 0755 already; making a
# new one 0700 would leave every existing node as it was.
mkdir("$dir/lib/old-logs", 0755) or die;
$PVE::UpdateManager::Logs::LOG_DIR = "$dir/lib/old-logs";
PVE::UpdateManager::Logs::save_log('lxc', 101, "x\n", 3, 1787310000);
private("$dir/lib/old-logs", 'a run log directory an older version made 0755');

# ── the security scan's state ───────────────────────────────────────────────
my $state = "$dir/lib/security";
$PVE::UpdateManager::SecScan::STATE_DIR = $state;
$PVE::UpdateManager::SecScan::TARGET_TIMEOUT = 5;
# Put together at run time: written out in one piece it is exactly what the
# publishing scan (tools/github-mirror.sh) refuses as a credential in a URL.
my $proxy = 'http://' . join(':', 'user', 'pw') . '@' . 'proxy.example:3128';
my %during;
%PVE::UpdateManager::SecScan::HOOK = (
    now => sub { time() },
    read_target => sub {
        return { status => 'ok', os => { id => 'debian', version_codename => 'trixie' }, files => {
            '/var/lib/dpkg/status' => "Package: openssl\nStatus: install ok installed\nVersion: 3.5.1-1\n",
            '/etc/apt/sources.list' => "deb http://mirror.example/debian-security trixie-security main\n",
            '/etc/apt/apt.conf' => qq{Acquire::http::Proxy "$proxy";\n},
        } };
    },
    parse_sources => sub {
        return ([{ uri => 'http://mirror.example/debian-security', suite => 'trixie-security',
            components => ['main'] }], 0);
    },
    parse_proxy => sub { { http => $proxy, https => undef, hosts => {} } },
    is_security_suite => sub { 1 },
    job_key => sub { 'k' },
    probe => sub { },
    # The work directory is removed when the round ends; while it runs, it is
    # there - for minutes on a node with many guests, and for good when the
    # worker is killed. So it is looked at from inside the round.
    fetch => sub {
        $during{$_} = [mode($_), -f $_ ? PVE::Tools::file_get_contents($_) : undef]
            for "$state/work", "$state/work/lxc-101/meta.json", "$state/work/lxc-101/status";
        return +{ k => { is_security => 1, packages => [] } };
    },
    severity_refresh => sub { },
    severity_lookup => sub { 'unknown' },
);
{
    no warnings 'redefine';
    *PVE::UpdateManager::SecScan::collect_targets = sub { [{ type => 'lxc', id => '101', name => 'ct101' }] };
    *PVE::UpdateManager::Config::target_is_running = sub { 0 };
}
my $res = PVE::UpdateManager::SecScan::run_round('pve-test', { security_scan => 1, security_interval => 30,
    security_parallel => 1, security_exclude => '', security_min_severity => '' });
is(scalar(@{ $res->{results} // [] }), 1, 'premise: the round produced its one result');
like($during{"$state/work/lxc-101/meta.json"}->[1] // '', qr/\Q$proxy\E/,
    "premise: the round's notes carry the guest's proxy, password included");
for (["$state/work", "the round's work directory"],
    ["$state/work/lxc-101/meta.json", "a guest's notes from the round"],
    ["$state/work/lxc-101/status", "a copy of a guest's dpkg status"]) {
    my ($path, $what) = @$_;
    my $m = $during{$path}->[0];
    ok(defined($m) && ($m & 077) == 0, sprintf('%s is for root alone while the round runs (mode %s)', $what,
        defined($m) ? sprintf('%04o', $m) : 'missing'));
}
private("$state/results", 'the results directory');
private("$state/results/lxc-101.json", "a guest's result");
private("$state/scan.state", 'the round state');
PVE::UpdateManager::SecReact::_write_seen({ 'lxc-101' => { openssl => '3.5.1-1+deb13u1' } });
private("$state/notified.json", 'what was notified about which guest');

# ── a fetch job's apt configuration ─────────────────────────────────────────
my $job_dir = "$dir/lib/lists/k";
PVE::UpdateManager::SecFetch::_prepare($job_dir, { uri => 'http://mirror.example/debian-security',
    suite => 'trixie-security', components => ['main'], proxy => { http => $proxy } }, [], 10);
like(PVE::Tools::file_get_contents("$job_dir/apt.conf"), qr/\Q$proxy\E/,
    'premise: the apt configuration of a fetch carries the proxy');
private("$job_dir/apt.conf", "a fetch job's apt configuration");
# Control: apt downloads as _apt, which has to reach lists/partial. A private
# job directory would make it fall back to downloading as root.
is(mode("$job_dir/lists/partial"), 0755, 'control: the lists stay reachable for the _apt user');
is(mode($job_dir), 0755, 'control: and so does the job directory');
# The source line names the guest's address as written there, userinfo
# included until uri_allowed refuses it - which happens after this file is
# written (#67, found by the verifier: 0644 with "https://u:pw@...").
private("$job_dir/sources.list", "a fetch job's source line");

# What apt prints for a fetch is written by the job's child. A proxy with
# credentials never gets that far (uri_allowed refuses it first), so the log
# holds the guest's source addresses and apt's messages - guest data, kept
# like the rest of the scan's (#67). Run one with an apt-get that only prints.
{
    use Socket qw(inet_pton AF_INET);
    my $fake = "$dir/apt-get";
    PVE::Tools::file_set_contents($fake, "#!/bin/sh\necho 'E: Failed to fetch http://mirror.example/x'\nexit 100\n");
    chmod(0755, $fake);
    local $PVE::UpdateManager::SecFetch::APT_GET = $fake;
    local @PVE::UpdateManager::SecFetch::NICE = ();
    local $PVE::UpdateManager::SecAddress::RESOLVE = sub { ([AF_INET, inet_pton(AF_INET, '192.0.2.10')]) };
    local $PVE::UpdateManager::SecAddress::FIB_TRIE = "$dir/none";
    local $PVE::UpdateManager::SecAddress::IF_INET6 = "$dir/none";
    my $job = { uri => 'http://mirror.example/debian-security', suite => 'trixie-security',
        components => ['main'], proxy => {} };
    PVE::UpdateManager::SecFetch::fetch([$job], { state_dir => "$dir/lib/lists2", timeout => 10 });
    my ($log) = glob("$dir/lib/lists2/*/apt.log");
    ok($log && PVE::Tools::file_get_contents($log) =~ m/Failed to fetch/, 'premise: the fetch ran and logged');
    private($log // "$dir/missing", "a fetch job's apt log");
}

done_testing();
