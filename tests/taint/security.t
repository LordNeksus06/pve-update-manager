#!/usr/bin/perl -T
# The security scan under taint mode, the way pvedaemon runs it.
#
#   perl -T -I tests/stubs -I perl tests/taint/security.t
#
# Found on PVE 9.2.4 (#40/#37): a check started from the web UI failed for
# every source with "Insecure dependency in mkdir while running with -T" -
# a digest of a guest's sources named a directory - while the same check run
# through pvesh, which has no -T, worked. No unit test could see it: their
# inputs are literals, and a literal is never tainted. Here the input is READ
# FROM A FILE, as a guest's sources are, and that is asserted first.

use strict;
use warnings;

use File::Temp qw(tempdir);
use JSON::PP ();
use Scalar::Util qw(tainted);
use Socket qw(inet_pton AF_INET);
use Test::More;

use PVE::UpdateManager::SecFetch;
use PVE::UpdateManager::SecSources;

$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

ok(${^TAINT}, 'premise: this runs with -T');

my $tmp = tempdir(CLEANUP => 1);

# A guest's sources, as the reader hands them over: read from a file.
open(my $fh, '>', "$tmp/sources.list") or die;
print {$fh} "deb http://debian.test/debian-security trixie-security main\n";
close($fh);
open($fh, '<', "$tmp/sources.list") or die;
my $text = do { local $/; <$fh> };
close($fh);
ok(tainted($text), 'premise: what is read from a guest file is tainted');

my ($entries) = PVE::UpdateManager::SecSources::parse_sources({ '/etc/apt/sources.list' => $text });
is(scalar(@$entries), 1, 'premise: the source is parsed');

# The round does not hand the parsed job on directly: the child that read the
# guest writes it to meta.json and the parent reads it back - and what comes
# out of that file is tainted again, even though the parser's regex captures
# had cleaned it. That round trip is where the measured failure came from, so
# it is made here the same way.
my $json = JSON::PP->new->utf8->canonical;
open($fh, '>', "$tmp/meta.json") or die;
print {$fh} $json->encode({ jobs => [{ %{ $entries->[0] }, proxy => {} }] });
close($fh);
open($fh, '<', "$tmp/meta.json") or die;
my $meta = $json->decode(do { local $/; <$fh> });
close($fh);
my $job = $meta->{jobs}->[0];
ok(tainted($job->{uri}), 'premise: a job read back from meta.json is tainted');

my $key = PVE::UpdateManager::SecFetch::job_key($job);
ok(!tainted($key), 'the job key, which names a directory, is not tainted');
like($key, qr/\A[0-9a-f]{32}\z/, 'and is the hex digest it was before');

# A fake apt-get that writes one verified-looking list and exits 0.
my $fake = "$tmp/apt-get";
open($fh, '>', $fake) or die;
print {$fh} <<'EOF';
#!/usr/bin/perl
my $conf = do { local $/; open(my $c, '<', $ENV{APT_CONFIG}) or die; <$c> };
my ($lists) = $conf =~ m/^Dir::State::Lists "([^"]+)";/m;
open(my $o, '>', "$lists/debian.test_debian-security_dists_trixie-security_InRelease") or die;
print {$o} "Origin: Debian\nLabel: Debian-Security\nSuite: stable-security\nCodename: trixie-security\n"
    . "Date: Thu, 22 Oct 2026 14:46:03 UTC\n";
close($o);
open($o, '>', "$lists/debian.test_debian-security_dists_trixie-security_main_binary-amd64_Packages") or die;
print {$o} "Package: openssl\nVersion: 3.5.1-1+deb13u1\nArchitecture: amd64\n\n";
close($o);
exit(0);
EOF
close($fh);
chmod(0755, $fake);
$PVE::UpdateManager::SecFetch::APT_GET = $fake;
$PVE::UpdateManager::SecAddress::RESOLVE = sub { return ([AF_INET, inet_pton(AF_INET, '192.0.2.10')]) };
$PVE::UpdateManager::SecAddress::FIB_TRIE = "$tmp/none";
$PVE::UpdateManager::SecAddress::IF_INET6 = "$tmp/none";
@PVE::UpdateManager::SecFetch::NICE = ();

my $res = PVE::UpdateManager::SecFetch::fetch([$job], { state_dir => "$tmp/state", timeout => 20 });
my $r = $res->{$key} // {};
is($r->{error}, undef, 'the fetch runs under -T') or diag("error: " . ($r->{error} // ''));
is($r->{is_security}, 1, 'and recognises the security archive');
is(scalar(@{ $r->{packages} // [] }), 1, 'with its Packages file');

done_testing();
