#!/usr/bin/perl
# How large a security Packages index the compare step reads, and what a
# target is told when one cannot be read (#62).
#
# The claims: an index of the size Ubuntu's security archive really publishes
# is read - jammy-security main/binary-amd64/Packages is 20 698 557 bytes and
# restricted 37 850 959 (their InRelease, 2026-10-23), both above the 16 MiB a
# guest's own status file may have; and an index that cannot be read makes
# the target's result an error that names it, never "ok" with whatever the
# other indices happened to list.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;
use POSIX ();

$SIG{ALRM} = sub { print "not ok - the test did not finish within 120 s\n"; POSIX::_exit(1) };
alarm(120);

use PVE::Tools;
use PVE::UpdateManager::Config;
use PVE::UpdateManager::SecCompare;
use PVE::UpdateManager::SecScan;

my $dir = tempdir(CLEANUP => 1);
$PVE::UpdateManager::Config::BASE_DIR = "$dir/etc";
$PVE::UpdateManager::SecScan::STATE_DIR = "$dir/state";
$PVE::UpdateManager::SecScan::TARGET_TIMEOUT = 60;

my $status = "Package: openssl\nStatus: install ok installed\nArchitecture: amd64\nVersion: 3.0.2-0ubuntu1.18\n\n"
    . "Package: curl\nStatus: install ok installed\nArchitecture: amd64\nVersion: 7.81.0-1ubuntu1.20\n";

# A real index is mostly packages the target does not have; the two it does
# have sit at the END, where a reader that stops early never gets.
sub index_of_size {
    my ($path, $size, $tail) = @_;
    my $filler = "Package: filler-%06d\nArchitecture: amd64\nVersion: 1.0-1\n"
        . "Description: " . ('x' x 900) . "\n\n";
    open(my $fh, '>', $path) or die "$path: $!\n";
    my ($n, $len) = (0, 0);
    while ($len < $size) {
        my $s = sprintf($filler, $n++);
        print {$fh} $s;
        $len += length($s);
    }
    print {$fh} $tail;
    close($fh) or die "$path: $!\n";
}

my $tail_main = "Package: openssl\nArchitecture: amd64\nVersion: 3.0.2-0ubuntu1.19\n\n";
my $tail_univ = "Package: curl\nArchitecture: amd64\nVersion: 7.81.0-1ubuntu1.21\n";

my $main = "$dir/main_Packages";
my $univ = "$dir/universe_Packages";
index_of_size($main, 20_698_557, $tail_main);
PVE::Tools::file_set_contents($univ, $tail_univ);

my $lists = { packages => [$main, $univ] };

%PVE::UpdateManager::SecScan::HOOK = (
    now => sub { time() },
    read_target => sub {
        return { status => 'ok', os => { id => 'ubuntu', version_codename => 'jammy' },
            files => { '/var/lib/dpkg/status' => $status,
                '/etc/apt/sources.list' => "deb http://mirror.example/ubuntu jammy-security main universe\n" } };
    },
    parse_sources => sub {
        return ([{ uri => 'http://mirror.example/ubuntu', suite => 'jammy-security',
            components => [qw(main universe)] }], 0);
    },
    parse_proxy => sub { {} },
    is_security_suite => sub { $_[0] =~ m/-security\z/ ? 1 : 0 },
    job_key => sub { "$_[0]->{uri}|$_[0]->{suite}" },
    probe => sub { },
    fetch => sub {
        my ($jobs) = @_;
        return { map {; "$_->{uri}|$_->{suite}" => { is_security => 1,
            date => 'Thu, 22 Oct 2026 08:24:15 UTC', %$lists } } @$jobs };
    },
    severity_lookup => sub { 'unknown' },
);

no warnings 'redefine';
*PVE::UpdateManager::SecScan::collect_targets = sub { [{ type => 'lxc', id => '101', name => 'ct101' }] };
*PVE::UpdateManager::Config::target_is_running = sub { 0 };
use warnings 'redefine';

my $settings = { security_scan => 1, security_interval => 30, security_parallel => 1,
    security_exclude => '', security_min_severity => '' };

my $round = sub { PVE::UpdateManager::SecScan::run_round('pve-test', $settings)->{results}->[0] };

# ── an index as large as Ubuntu's ───────────────────────────────────────────
cmp_ok(-s $main, '>', 16 * 1024 * 1024, 'premise: the main index is above 16 MiB, like jammy-security main');

my $r = $round->();
is($r->{status}, 'ok', 'a target whose security index is as large as Ubuntu publishes is checked');
is_deeply([sort map { $_->{name} } @{ $r->{pending} }], [qw(curl openssl)],
    'and the update listed at the end of the 20 MB index is pending');

# ── an index that cannot be read ────────────────────────────────────────────
# A path of its own, so the result of the round above is not reused.
my $big = "$dir/restricted_Packages";
index_of_size($big, 2000, $tail_main);
$lists = { packages => [$big, $univ] };
cmp_ok(-s $univ, '<', 1000, 'premise: the other index is within the lowered limit');
cmp_ok(-s $big, '>', 1000, 'premise: this one is not');
{
    no warnings 'once';
    local $PVE::UpdateManager::SecCompare::MAX_INDEX = 1000;
    $r = $round->();
}
is($r->{status}, 'error', 'an index that cannot be read makes the result an error, not "ok"');
like($r->{reason} // '', qr/\Q$big\E/, 'naming the index');
is(scalar(@{ $r->{pending} // [] }), 0, 'and lists nothing pending as if it were complete');

# Control: the same files with the limit back are read and the result is ok.
$r = $round->();
is($r->{status}, 'ok', 'control: the same index within the limit is read');
is_deeply([sort map { $_->{name} } @{ $r->{pending} }], [qw(curl openssl)], 'control: with both updates');

done_testing();
