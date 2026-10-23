#!/usr/bin/perl
# Which installed packages have a pending security update (#39).
#
# The claims: a package counts when, and only when, the security index has a
# higher version for the same name and architecture; a status file is read
# strictly, so a malformed entry is skipped and counted instead of compared;
# and nothing a guest can put into its status file makes the parser die or run
# away - the fuzz section at the end.

use strict;
use warnings;

use Test::More;

use PVE::UpdateManager::SecCompare;

my $C = 'PVE::UpdateManager::SecCompare';

# ── the version comparison itself ───────────────────────────────────────────
ok(defined(&{"${C}::version_compare"}), 'premise: the module loads');
cmp_ok($C->can('version_compare')->('1.0~rc1', '1.0'), '<', 0, 'a tilde sorts before the release');
cmp_ok($C->can('version_compare')->('1:0.9', '2.0'), '>', 0, 'an epoch outweighs the upstream version');
cmp_ok($C->can('version_compare')->('3.5.1-1+deb13u1', '3.5.1-1'), '>', 0, 'a security revision is newer');
is($C->can('version_compare')->('1.0-1', '1.0-1'), 0, 'equal is equal');
like($PVE::UpdateManager::SecCompare::BACKEND, qr/\A(?:AptPkg|Dpkg::Version)\z/,
    "a backend was chosen ($PVE::UpdateManager::SecCompare::BACKEND)");

# ── what counts as a version, a name ────────────────────────────────────────
ok(PVE::UpdateManager::SecCompare::valid_version($_), "'$_' is a version")
    for ('1.0', '2:1.2.3-4ubuntu0.24.04.1', '9.20.30-1~deb13u1', '0.9+dfsg-1');
ok(!PVE::UpdateManager::SecCompare::valid_version($_), "'" . ($_ // 'undef') . "' is not")
    for (undef, '', 'abc', '1.0 2', ':1', '1.0/../x', '1' x 300);
ok(!PVE::UpdateManager::SecCompare::valid_name($_), "'$_' is not a package name")
    for ('A', 'x', '../etc', 'foo bar', 'Foo');

# ── reading a status file ───────────────────────────────────────────────────
my $status = <<'EOF';
Package: openssl
Status: install ok installed
Architecture: amd64
Version: 3.5.1-1
Description: TLS
 a continuation line: Version: 99

Package: libc6
Status: install ok installed
Architecture: amd64
Source: glibc (2.41-12)
Version: 2.41-12

Package: tzdata
Status: install ok installed
Architecture: all
Version: 2025b-1

Package: removed-thing
Status: deinstall ok config-files
Architecture: amd64
Version: 1.0-1

Package: broken
Status: install ok installed
Architecture: amd64
Version: not-a-version

Package: curl
Status: install ok installed
Architecture: amd64
Version: 8.14.1-2
Version: 99.0
EOF

my ($inst, $skipped) = PVE::UpdateManager::SecCompare::installed_packages($status);
my %by = map { $_->{name} => $_ } @$inst;
is_deeply([sort keys %by], [qw(curl libc6 openssl tzdata)],
    'installed packages are read; config-files is not installed; a malformed one is left out');
is($skipped, 1, 'and the malformed one is counted, not silently lost');
is($by{openssl}->{version}, '3.5.1-1', 'a continuation line cannot inject a field');
is($by{curl}->{version}, '8.14.1-2', 'a field given twice keeps the first, as dpkg wrote it');
is($by{libc6}->{source}, 'glibc', 'the source package is taken from Source:, version stripped');
is($by{openssl}->{source}, 'openssl', 'and defaults to the package name');

my ($cr) = PVE::UpdateManager::SecCompare::installed_packages(
    "Package: x1\nStatus: install ok installed\rinstall ok installed\nArchitecture: amd64\nVersion: 1\n");
is(scalar(@$cr), 0, 'a carriage return is not a line break');

# ── the security index ──────────────────────────────────────────────────────
my %index;
my $added = PVE::UpdateManager::SecCompare::add_index(\%index, <<'EOF');
Package: openssl
Architecture: amd64
Version: 3.5.1-1+deb13u1

Package: openssl
Architecture: amd64
Version: 3.5.1-1+deb13u2

Package: openssl
Architecture: i386
Version: 3.5.1-1+deb13u9

Package: curl
Architecture: amd64
Version: 8.14.1-1

Package: tzdata
Architecture: all
Version: 2025c-0+deb13u1

Package: libc6
Architecture: all
Version: 2.41-13
EOF
ok($added >= 5, 'premise: the index has entries');
is($index{'openssl:amd64'}, '3.5.1-1+deb13u2', 'the highest of several listed versions is kept');

# ── the comparison ──────────────────────────────────────────────────────────
my $pending = PVE::UpdateManager::SecCompare::pending($inst, \%index, []);
my %p = map { $_->{name} => $_ } @$pending;

ok($p{openssl}, 'an older installed version is pending');
is($p{openssl}->{fixed}, '3.5.1-1+deb13u2', 'against the amd64 build, not the newer i386 one');
is($p{openssl}->{installed}, '3.5.1-1', 'with the installed version beside it');
ok(!$p{curl}, 'an installed version newer than the index is not pending');
ok($p{tzdata}, 'an Architecture: all package is matched as all');
ok($p{libc6}, 'and an amd64 package falls back to an all entry of the same name');

# Controls: the same data with nothing to fix, and an empty index.
my %same = ('openssl:amd64' => '3.5.1-1');
is(scalar(@{ PVE::UpdateManager::SecCompare::pending($inst, \%same, []) }), 0,
    'control: an equal version is not pending');
is(scalar(@{ PVE::UpdateManager::SecCompare::pending($inst, {}, []) }), 0,
    'control: an empty index reports nothing');

# ── leaving packages out ────────────────────────────────────────────────────
my $ex = PVE::UpdateManager::SecCompare::parse_exclude('lib*, open?sl');
my %px = map { $_->{name} => 1 } @{ PVE::UpdateManager::SecCompare::pending($inst, \%index, $ex) };
ok(!$px{openssl} && !$px{libc6}, 'excluded patterns do not count');
ok($px{tzdata}, 'and everything else still does');
ok(!defined(eval { PVE::UpdateManager::SecCompare::parse_exclude('(a|b)'); 1 }),
    'a pattern with regex characters is refused, not compiled');

# ── fuzz: nothing in a status file may kill or stall the parser ─────────────
#
# Mutations of the status file above (bytes flipped, lines dropped and
# doubled) and plain random bytes. Asserted: never dies, every result passes
# the field checks, and the whole loop ends - a regex that backtracks
# exponentially on some input would show up as this test not finishing.
my $seed = 4242;
srand($seed);
my @lines = split(/\n/, $status, -1);
my ($runs, $died, $bad) = (0, 0, 0);
for my $i (1 .. 3000) {
    my $text;
    if ($i % 3 == 0) {
        $text = join('', map { chr(int(rand(256))) } 1 .. int(rand(2000)));
    } else {
        my @l = @lines;
        for (1 .. 1 + int(rand(6))) {
            my $op = int(rand(3));
            my $at = int(rand(scalar(@l) || 1));
            if ($op == 0 && @l) { splice(@l, $at, 1) }
            elsif ($op == 1 && @l) { splice(@l, $at, 0, $l[$at]) }
            elsif (@l) {
                my $s = $l[$at] // '';
                substr($s, int(rand(length($s) || 1)), 1, chr(int(rand(256)))) if length($s);
                $l[$at] = $s;
            }
        }
        $text = join("\n", @l);
    }
    $runs++;
    my ($r) = eval { PVE::UpdateManager::SecCompare::installed_packages($text) };
    if (!$r) { $died++; next }
    for my $pk (@$r) {
        $bad++ if !PVE::UpdateManager::SecCompare::valid_name($pk->{name})
            || !PVE::UpdateManager::SecCompare::valid_version($pk->{version});
    }
    my %idx;
    eval { PVE::UpdateManager::SecCompare::add_index(\%idx, $text); 1 } or $died++;
}
is($runs, 3000, 'premise: every fuzz case ran');
is($died, 0, "no mutated or random input made the parser die (seed $seed)");
is($bad, 0, 'and nothing that came out of one failed the field checks');

done_testing();
