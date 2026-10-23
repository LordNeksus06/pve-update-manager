#!/usr/bin/perl
# Fetching security indices with a private apt configuration (#37).
#
# The claims: one apt-get per source, components merged; the configuration it
# gets reads nothing of the node's apt setup and follows no redirect; the
# environment is clean; a refused address never reaches apt-get; a Signed-By
# path the node does not have is an error, not a fallback; a source that hangs
# is killed with its whole process group at its own time limit and costs
# nothing more; the round never runs more jobs at once than asked; and the
# Release file decides what is a security archive, not the address.
#
# apt-get itself is a fake here (tests/stubs run_command only records, and the
# process handling is the part to exercise). It acts by host name of the
# source and writes what the real one would leave in the lists directory.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Socket qw(inet_pton AF_INET);
use Test::More;
use Time::HiRes qw(time sleep);

use PVE::UpdateManager::SecFetch;

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

my $tmp = tempdir(CLEANUP => 1);
my $state = "$tmp/state";

# ── the fake apt-get ────────────────────────────────────────────────────────
my $fake = "$tmp/apt-get";
open(my $fh, '>', $fake) or die;
print {$fh} <<'EOF';
#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw(sleep);
my $conf_path = $ENV{APT_CONFIG} // die "no APT_CONFIG\n";
open(my $c, '<', $conf_path) or die; my $conf = do { local $/; <$c> }; close($c);
my ($lists) = $conf =~ m/^Dir::State::Lists "([^"]+)";/m;
my ($srcl) = $conf =~ m/^Dir::Etc::SourceList "([^"]+)";/m;
(my $dir = $conf_path) =~ s{/[^/]+\z}{};
(my $state = $dir) =~ s{/[^/]+\z}{};
open(my $s, '<', $srcl) or die; my $line = <$s>; close($s);
my ($uri, $suite, @comps) = $line =~ m/\Adeb (?:\[[^\]]*\] )?(\S+) (\S+) (.*)\n\z/ ? ($1, $2, split(/ /, $3)) : die "bad line";
my ($host) = $uri =~ m{//([^/:]+)};
# What the run saw, for the test to read.
open(my $o, '>>', "$state/calls") or die;
print {$o} join("\t", $host, join(',', map { "$_=$ENV{$_}" } sort keys %ENV), "@ARGV", "@comps"), "\n";
close($o);
# Concurrency: a marker per running fake, the highest count seen.
open(my $m, '>', "$state/run.$$") or die; close($m);
opendir(my $dh, $state); my $n = grep { /\Arun\./ } readdir($dh); closedir($dh);
open($o, '>>', "$state/concurrency"); print {$o} "$n\n"; close($o);
sleep(0.3) if $host =~ m/\Aslow/;
my $done = sub { unlink("$state/run.$$"); exit($_[0]) };
if ($host eq 'hang.test') {
    my $kid = fork();
    if (!$kid) { exec('sleep', '300') }
    open($o, '>', "$state/hang.pids"); print {$o} "$$ $kid\n"; close($o);
    $SIG{TERM} = 'IGNORE';    # apt that does not stop on TERM: KILL has to follow
    sleep(300);
}
if ($host eq 'fail.test' || ($host eq 'flaky.test' && -e "$state/flaky.fail")) {
    print "Err:1 $uri $suite InRelease\n  404  Not Found\n";
    print "E: Failed to fetch $uri/dists/$suite/InRelease  404  Not Found \x1b[31m\n";
    $done->(100);
}
my %rel = (
    'debian.test' => "Origin: Debian\nLabel: Debian-Security\nSuite: stable-security\nCodename: trixie-security\n",
    'ubuntu.test' => "Origin: Ubuntu\nLabel: Ubuntu\nSuite: noble-security\nCodename: noble\n",
    'other.test' => "Origin: Example\nLabel: Example\nSuite: trixie-security\nCodename: trixie-security\n",
);
my $r = $rel{$host} // $rel{'debian.test'};
(my $base = "$uri/dists/$suite") =~ s{\A\w+://}{};
$base =~ s{/}{_}g;
open($o, '>', "$lists/${base}_InRelease") or die;
print {$o} "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n${r}Date: Thu, 22 Oct 2026 14:46:03 UTC\n"
    . "SHA256:\n 0123 12 main/binary-amd64/Packages\n-----BEGIN PGP SIGNATURE-----\n\nabc=\n-----END PGP SIGNATURE-----\n";
close($o);
for my $comp (@comps) {
    open($o, '>', "$lists/${base}_${comp}_binary-amd64_Packages") or die;
    print {$o} "Package: openssl\nVersion: 3.5.1-1+deb13u1\nArchitecture: amd64\n\n";
    close($o);
}
$done->(0);
EOF
close($fh);
chmod(0755, $fake);
$PVE::UpdateManager::SecFetch::APT_GET = $fake;

# Name resolution answers from a table, so no test asks the network.
my %dns = map { $_ => '192.0.2.10' } qw(debian.test ubuntu.test other.test fail.test flaky.test hang.test
    slow1.test slow2.test slow3.test slow4.test slow5.test slow6.test proxy.test);
$dns{'loop.test'} = '127.0.0.1';
$PVE::UpdateManager::SecAddress::RESOLVE = sub {
    my $ip = $dns{ $_[0] } // return ();
    return ([AF_INET, inet_pton(AF_INET, $ip)]);
};
$PVE::UpdateManager::SecAddress::FIB_TRIE = "$tmp/none";
$PVE::UpdateManager::SecAddress::IF_INET6 = "$tmp/none";

# Keyring directories of the "node": one real key, one link to it, one link out.
mkdir("$tmp/keyrings") or die;
open($fh, '>', "$tmp/keyrings/debian.pgp") or die;
close($fh);
symlink('debian.pgp', "$tmp/keyrings/debian.gpg") or die;
symlink('/etc/passwd', "$tmp/keyrings/out.gpg") or die;
@PVE::UpdateManager::SecFetch::KEYRING_DIRS = ("$tmp/keyrings");

my $calls = sub {
    open(my $c, '<', "$state/calls") or return [];
    my @l = map { chomp; [split(/\t/)] } <$c>;
    close($c);
    return \@l;
};
my $job = sub {
    my ($host, %o) = @_;
    return { uri => "http://$host/debian-security", suite => 'trixie-security', components => ['main'], %o };
};
my $fetch = sub { PVE::UpdateManager::SecFetch::fetch(@_) };
my $key = \&PVE::UpdateManager::SecFetch::job_key;

# ── a good source ───────────────────────────────────────────────────────────
my $j1 = $job->('debian.test', signed_by => "$tmp/keyrings/debian.gpg");
my $j2 = $job->('debian.test/', signed_by => "$tmp/keyrings/debian.gpg", components => ['non-free-firmware']);
$j2->{uri} = 'http://debian.test/debian-security/';
is($key->($j1), $key->($j2), 'a trailing slash and other components are the same job');
my $res = $fetch->([$j1, $j2], { state_dir => $state, timeout => 10 });
my $r = $res->{ $key->($j1) };
is(scalar(@{ $calls->() }), 1, 'premise: apt-get ran, and once for the two');
is($r->{error}, undef, 'no error');
is_deeply([@{$r}{qw(origin label suite codename date)}],
    ['Debian', 'Debian-Security', 'stable-security', 'trixie-security', 'Thu, 22 Oct 2026 14:46:03 UTC'],
    'the Release fields are read past the clearsign header');
is($r->{is_security}, 1, 'Label Debian-Security is a security archive');
is(scalar(@{ $r->{packages} }), 2, 'both components fetched in the one run');
ok(!grep({ !m{\A\Q$state\E/} || !-f } @{ $r->{packages} }), 'Packages paths are absolute files under the state dir');
my $c = $calls->()->[0];
is($c->[1], "APT_CONFIG=$state/" . $key->($j1) . '/apt.conf,LC_ALL=C,PATH=/usr/sbin:/usr/bin:/sbin:/bin',
    'the environment is exactly APT_CONFIG, LC_ALL and PATH');
is($c->[2], '-q --error-on=any update', 'apt-get update fails on any failed fetch');
is($c->[3], 'main non-free-firmware', 'components merged and sorted');

my $dir = "$state/" . $key->($j1);
my $conf = do { local (@ARGV, $/) = ("$dir/apt.conf"); <> };
for my $want ('Dir::Etc::Parts "' . "$dir/empty", 'Dir::Etc::main "' . "$dir/empty.conf",
    'Dir::Etc::SourceParts "' . "$dir/empty", 'Dir::State::status "' . "$dir/status",
    'Dir::Cache "' . "$dir/cache", 'Acquire::http::AllowRedirect "false"', 'Acquire::https::AllowRedirect "false"',
    'Acquire::MaxReleaseFileSize "', 'Acquire::Languages "none"', 'Acquire::http::Timeout "10"') {
    ok(index($conf, $want) >= 0, "apt.conf: $want");
}
unlike($conf, qr/Proxy/, 'no proxy configured, none written');
my $sl = do { local (@ARGV, $/) = ("$dir/sources.list"); <> };
is($sl, "deb [signed-by=$tmp/keyrings/debian.pgp] http://debian.test/debian-security trixie-security main non-free-firmware\n",
    "the node's own key file, the symlink resolved");

# ── Ubuntu and a foreign archive ────────────────────────────────────────────
$res = $fetch->([$job->('ubuntu.test'), $job->('other.test')], { state_dir => $state, timeout => 10 });
is($res->{ $key->($job->('ubuntu.test')) }->{is_security}, 1, 'Origin Ubuntu with a -security suite is one');
is($res->{ $key->($job->('other.test')) }->{is_security}, 0, 'a foreign archive with a -security suite name is not');

# ── refused before apt-get ──────────────────────────────────────────────────
unlink("$state/calls");
my @bad = (
    [$job->('loop.test'), qr/\Anot fetched: 'loop.test' is a loopback address\z/],
    [{ %{ $job->('debian.test') }, uri => 'file:/srv/mirror' }, qr/usable address/],
    [{ %{ $job->('debian.test') }, suite => 'trixie' }, qr/not a security suite/],
    [$job->('debian.test', signed_by => "$tmp/keyrings/missing.gpg"), qr/is not on this node/],
    [$job->('debian.test', signed_by => '/home/x/key.gpg'), qr/not in a keyring directory/],
    [$job->('debian.test', signed_by => "$tmp/keyrings/out.gpg"), qr/not a file in a keyring directory/],
    [$job->('debian.test', proxy => { http => 'http://loop.test:3128' }), qr/\Anot fetched: proxy 'loop.test' is a loopback/],
    # apt reads these hosts as 127.0.0.1: user "debian.test?" / "debian.test#", and that user part is what refuses them (#58).
    [{ %{ $job->('debian.test') }, uri => 'http://debian.test?@127.0.0.1/debian-security' }, qr/\Anot fetched: an address with credentials is not fetched\z/],
    [{ %{ $job->('debian.test') }, uri => 'http://debian.test#@127.0.0.1/debian-security' }, qr/\Anot fetched: an address with credentials is not fetched\z/],
    [$job->('debian.test', proxy => { http => 'http://proxy.test?@127.0.0.1:3128' }), qr/\Anot fetched: proxy an address with credentials is not fetched\z/],
    [{ %{ $job->('debian.test') }, components => ['../x'] }, qr/component/],
);
$res = $fetch->([map { $_->[0] } @bad], { state_dir => $state, timeout => 10 });
for my $b (@bad) {
    like($res->{ $key->($b->[0]) }->{error} // 'no error', $b->[1], "refused: " . ($res->{ $key->($b->[0]) }->{error} // ''));
}
is_deeply($calls->(), [], 'and apt-get never ran for any of them');

# ── proxy ───────────────────────────────────────────────────────────────────
my $pj = $job->('debian.test', proxy => { http => 'http://proxy.test:3128', hosts => {} });
$pj->{uri} = 'https://debian.test/debian-security';
is(PVE::UpdateManager::SecFetch::effective_proxy($pj), 'http://proxy.test:3128', 'https falls back to the http proxy, as apt does');
isnt($key->($pj), $key->({ %$pj, proxy => {} }), 'and a different proxy is a different job');
is(PVE::UpdateManager::SecFetch::effective_proxy({ %$pj, proxy => { http => 'http://proxy.test:3128',
    hosts => { 'debian.test' => 'DIRECT' } } }), undef, 'a per-host DIRECT wins');
$res = $fetch->([$pj], { state_dir => $state, timeout => 10 });
$conf = do { local (@ARGV, $/) = ("$state/" . $key->($pj) . '/apt.conf'); <> };
like($conf, qr/^Acquire::https::Proxy "http:\/\/proxy.test:3128";$/m, 'the proxy is written for https');

# #54: apt also reads credentials from Dir::Etc::netrc/netrcparts, and left
# alone those are the node's /etc/apt/auth.conf{,.d} - the node's login for a
# host would go out on a fetch a guest asked for. apt itself is asked, not the
# file grepped: the default is what the file does NOT say.
SKIP: {
    skip('apt-config is not installed here - the netrc paths are not checked', 2) if !-x '/usr/bin/apt-config';
    my $d = "$state/" . $key->($pj);
    my $out = `APT_CONFIG='$d/apt.conf' /usr/bin/apt-config shell N Dir::Etc::netrc/f P Dir::Etc::netrcparts/d`;
    unlike($out, qr{/etc/apt/auth\.conf}, 'apt does not read the node\'s credentials (auth.conf, auth.conf.d)')
        or diag($out);
    like($out, qr{\AN='\Q$d\E/[^']*'\nP='\Q$d\E/[^']*'\n\z}, 'control: both name the private, empty places');
}

# ── failure keeps the last good lists, with their date ──────────────────────
my $fj = $job->('fail.test');
$res = $fetch->([$fj], { state_dir => $state, timeout => 10 });
is($res->{ $key->($fj) }->{error}, 'Failed to fetch http://fail.test/debian-security/dists/trixie-security/InRelease  404  Not Found ?[31m',
    'the E: line is the reason, control characters replaced');
is_deeply($res->{ $key->($fj) }->{packages}, [], 'nothing fetched before, nothing returned');

my $flj = $job->('flaky.test');
$res = $fetch->([$flj], { state_dir => $state, timeout => 10 });
is($res->{ $key->($flj) }->{error}, undef, 'premise: the source worked once');
open($fh, '>', "$state/flaky.fail") or die;
close($fh);
$res = $fetch->([$flj], { state_dir => $state, timeout => 10 });
like($res->{ $key->($flj) }->{error}, qr/Failed to fetch/, 'then it fails');
is(scalar(@{ $res->{ $key->($flj) }->{packages} }), 1, 'and the last good Packages file is still returned');
is($res->{ $key->($flj) }->{date}, 'Thu, 22 Oct 2026 14:46:03 UTC', 'with the date of its Release file');

# ── a source that hangs ─────────────────────────────────────────────────────
my $hj = $job->('hang.test');
my $t0 = time();
$res = $fetch->([$hj, $job->('ubuntu.test')], { state_dir => $state, timeout => 1, parallel => 2 });
my $took = time() - $t0;
like($res->{ $key->($hj) }->{error}, qr/\Atimed out after 1 s\z/, 'a hanging source times out');
is($res->{ $key->($job->('ubuntu.test')) }->{error}, undef, 'and the other source of the round is unaffected');
cmp_ok($took, '<', 1 + $PVE::UpdateManager::SecFetch::KILL_GRACE + 1.5, sprintf('the round ends at limit plus grace (%.1f s)', $took));
my ($leader, $kid) = do { local (@ARGV, $/) = ("$state/hang.pids"); split(' ', <>) };
ok($kid, 'premise: the fake left a grandchild');
sleep(0.2);
ok(!alive($kid), 'the grandchild died with the group');
ok(!alive($leader), 'and so did apt-get, though it ignored SIGTERM');

# ── the deadline of the whole round, and the parallel cap ───────────────────
# The killed fake of the hang case never removed its marker.
unlink("$state/concurrency", glob("$state/run.*"));
my @slow = map { $job->("slow$_.test") } 1 .. 6;
$res = $fetch->(\@slow, { state_dir => $state, timeout => 10, parallel => 2 });
my @conc = do { local @ARGV = ("$state/concurrency"); map { 0 + $_ } <> };
is(scalar(@conc), 6, 'premise: six jobs ran');
cmp_ok((sort { $b <=> $a } @conc)[0], '<=', 2, 'never more than two at once');
cmp_ok((sort { $b <=> $a } @conc)[0], '==', 2, 'control: and two at once did happen');

$res = $fetch->([$job->('debian.test')], { state_dir => $state, timeout => 10 });
is($res->{ $key->($job->('debian.test')) }->{error}, undef, 'premise: a good fetch of the second source first');
$res = $fetch->([$hj, $job->('debian.test')], { state_dir => $state, timeout => 30, parallel => 1, deadline => time() + 1 });
like($res->{ $key->($hj) }->{error}, qr/deadline of the round/, 'the deadline stops a running job');
like($res->{ $key->($job->('debian.test')) }->{error}, qr/not started before the deadline/,
    'and a job not yet started is not started');
is_deeply($res->{ $key->($job->('debian.test')) }->{packages}, [glob("$state/" . $key->($job->('debian.test')) . '/lists/*_Packages')],
    'but its last good lists are still returned');
ok(scalar(@{ $res->{ $key->($job->('debian.test')) }->{packages} }), 'premise: there were some');

done_testing();
