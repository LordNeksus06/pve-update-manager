#!/usr/bin/perl
# Which sources a target has configured, through which proxy, and whether the
# node may fetch from there (#37).
#
# The claims: both source formats give the same entries for the same source;
# a line that is not one is skipped and counted; Signed-By is a path or it is
# ignored and marked; the proxy that wins in the guest wins here; an address
# that resolves to loopback, link-local or the node itself is refused, private
# ones are not; and nothing a guest writes into these files makes a parser die
# or return a field that fails its own check - the fuzz section at the end.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Socket qw(inet_pton AF_INET AF_INET6);
use Test::More;
use Time::HiRes qw(time);

use PVE::UpdateManager::SecSources;

my $S = 'PVE::UpdateManager::SecSources';
my $parse = \&PVE::UpdateManager::SecSources::parse_sources;
my $proxy = \&PVE::UpdateManager::SecSources::parse_proxy;
my $allowed = \&PVE::UpdateManager::SecSources::uri_allowed;

# ── os-release ──────────────────────────────────────────────────────────────
is_deeply(PVE::UpdateManager::SecSources::parse_os_release(
    qq{PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nID=debian\nVERSION_CODENAME=trixie\n}),
    { id => 'debian', version_codename => 'trixie' }, 'Debian os-release: id and codename');
is_deeply(PVE::UpdateManager::SecSources::parse_os_release(
    qq{ID="ubuntu"\nVERSION_CODENAME='noble'\nID_LIKE=debian\n}),
    { id => 'ubuntu', version_codename => 'noble' }, 'quoted values are unquoted');
is_deeply(PVE::UpdateManager::SecSources::parse_os_release(
    qq{ID=debian\nVERSION_CODENAME=../../etc\nID=alpine\n}),
    { id => 'debian', version_codename => undef }, 'a codename that is no word is undef, the first ID wins');
is_deeply(PVE::UpdateManager::SecSources::parse_os_release(undef),
    { id => undef, version_codename => undef }, 'no file, no values');

# ── one-line format ─────────────────────────────────────────────────────────
my $list = <<'EOF';
# the trixie defaults
deb http://deb.debian.org/debian trixie main contrib
deb [arch=amd64 signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian-security/ trixie-security main # comment
deb-src http://deb.debian.org/debian trixie main
deb cdrom:[Debian GNU/Linux 13]/ trixie main
deb http://example.org/flat ./
deb [signed-by=ABCDEF0123456789ABCDEF0123456789ABCDEF01] http://deb.example.org/x trixie-security main
this is not a source line
deb http://ok.example/debian-security trixie-security non-free-firmware/x/y
EOF
my ($e, $skipped) = $parse->({ '/etc/apt/sources.list' => $list });
is(scalar(@$e), 3, 'one-line: three deb entries kept (cdrom, flat, garbage and a bad component are not)');
is($skipped, 4, 'and four lines are counted as skipped (deb-src and comments are not skipped, they are not sources)');
is_deeply($e->[1], {
    uri => 'http://deb.debian.org/debian-security', suite => 'trixie-security', components => ['main'],
    signed_by => '/usr/share/keyrings/debian-archive-keyring.gpg', signed_by_ignored => undef,
    file => '/etc/apt/sources.list',
}, 'options are read, the trailing slash and the comment are dropped');
is($e->[2]->{signed_by}, undef, 'a fingerprint is not used as a key');
is($e->[2]->{signed_by_ignored}, 'fingerprint', 'and the entry says why');

# ── deb822 ──────────────────────────────────────────────────────────────────
my $sources = <<'EOF';
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# a comment between stanzas
types: deb
uris: http://deb.debian.org/debian-security/
suites: trixie-security
components: main
signed-by: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://off.example/debian
Suites: trixie-security
Components: main
Enabled: no

Types: deb
URIs: http://inline.example/debian
Suites: trixie-security
Components: main
Signed-By:
 -----BEGIN PGP PUBLIC KEY BLOCK-----
 .
 mQINBGQ=
 -----END PGP PUBLIC KEY BLOCK-----

Types: deb
URIs: http://a.example/x
this line is no field
Suites: trixie-security
Components: main
EOF
($e, $skipped) = $parse->({ '/etc/apt/sources.list.d/debian.sources' => $sources });
is(scalar(@$e), 4, 'deb822: two suites of the first stanza, the security one, the inline one');
is($skipped, 1, 'the stanza with a line that is no field is skipped and counted');
is_deeply([map { $_->{suite} } @$e], [qw(trixie trixie-updates trixie-security trixie-security)],
    'one entry per suite, in file order; Enabled: no is left out');
my ($one) = $parse->({ '/etc/apt/sources.list' =>
    "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian-security trixie-security main\n" });
is_deeply({ %{ $e->[2] }, file => 'x' }, { %{ $one->[0] }, file => 'x' },
    'the same source gives the same entry in both formats (field names case-insensitive)');
is($e->[3]->{signed_by}, undef, 'an inline key is not used');
is($e->[3]->{signed_by_ignored}, 'inline key', 'and marked as such');

($e) = $parse->({ '/etc/apt/sources.list.d/x.save' => "deb http://a.example/x trixie-security main\n",
    '/etc/apt/sources.list.d/y.list' => "deb http://b.example/x trixie-security main\n" });
is_deeply([map { $_->{uri} } @$e], ['http://b.example/x'], 'a file apt would not read is not read');

($e, $skipped) = $parse->({ '/etc/apt/sources.list' => 'x' x ($PVE::UpdateManager::SecSources::MAX_FILE + 1) });
is_deeply([scalar(@$e), $skipped], [0, 1], 'a file over the size limit is skipped whole');
($e, $skipped) = $parse->({ '/etc/apt/sources.list' => "deb http://a.example/x trixie-security main\n" x 5000 });
is(scalar(@$e), $PVE::UpdateManager::SecSources::MAX_ENTRIES, 'a repeated line yields at most MAX_ENTRIES entries');
is($skipped, 5000 - $PVE::UpdateManager::SecSources::MAX_ENTRIES, 'and the rest are counted');

# ── security suites by name ─────────────────────────────────────────────────
ok(PVE::UpdateManager::SecSources::is_security_suite($_), "$_ is a security suite")
    for qw(trixie-security noble-security buster/updates);
ok(!PVE::UpdateManager::SecSources::is_security_suite($_), ($_ // 'undef') . ' is not')
    for ('trixie', 'trixie-updates', 'noble-updates', 'security', undef);

# ── proxy ───────────────────────────────────────────────────────────────────
my $p = $proxy->({
    '/etc/apt/apt.conf.d/01proxy' => qq{Acquire::http::Proxy "http://p1.example:3128";\nAcquire::https::Proxy "http://p0.example";\n},
    '/etc/apt/apt.conf.d/02proxy' => qq{// override\nAcquire { http { Proxy "http://p2.example:3128/"; }; https { Proxy "http://p5.example"; }; };\n}
        . qq{/* a block comment with Acquire::https::Proxy "http://no.example"; inside */\n}
        . qq{Acquire::http::Proxy::deb.debian.org "DIRECT";\n#include "/etc/shadow";\n}
        . qq{Acquire::https::Proxy::secure.example "http://p3.example:8080";\n}
        . qq{Acquire::https::Proxy-Auto-Detect "http://evil.example";\n},
    '/etc/apt/apt.conf.d/02proxy.dpkg-old' => qq{Acquire::https::Proxy "http://old.example";\n},
    '/etc/apt/apt.conf' => qq{acquire::http::proxy "http://p4.example";\n},
});
is($p->{https}, 'http://p5.example', 'the later apt.conf.d file wins, scoped form read, comments and a .dpkg-old file skipped');
is($p->{http}, 'http://p4.example', 'apt.conf is read after apt.conf.d, keys case-insensitive');
is_deeply($p->{hosts}, { 'deb.debian.org' => 'DIRECT', 'secure.example' => 'http://p3.example:8080' },
    'per-host entries; Proxy-Auto-Detect and #include are not taken');
is_deeply($proxy->({}), { http => undef, https => undef, hosts => {} }, 'no files, no proxy');
is($proxy->({ '/etc/apt/apt.conf' => qq{Acquire::http::Proxy "http://a.example";\nAcquire::http::Proxy "";\n} })->{http},
    undef, 'an empty value unsets the proxy again');

# ── which addresses the node fetches from ───────────────────────────────────
my $tmp = tempdir(CLEANUP => 1);
{
    open(my $fh, '>', "$tmp/fib") or die;
    print {$fh} "Local:\n  +-- 0.0.0.0/0 3 0 5\n     |-- 172.20.0.7\n        /32 host LOCAL\n"
        . "     |-- 172.20.0.255\n        /32 link BROADCAST\n";
    close($fh);
    open($fh, '>', "$tmp/if6") or die;
    print {$fh} "fd000000000000000000000000000042 02 40 00 80     vmbr0\n";
    close($fh);
}
$PVE::UpdateManager::SecAddress::FIB_TRIE = "$tmp/fib";
$PVE::UpdateManager::SecAddress::IF_INET6 = "$tmp/if6";
my $real_resolve = $PVE::UpdateManager::SecAddress::RESOLVE;
my %dns = (
    'mirror.lan' => [[AF_INET, inet_pton(AF_INET, '172.16.5.10')]],
    'public.example' => [[AF_INET, inet_pton(AF_INET, '198.51.100.7')], [AF_INET6, inet_pton(AF_INET6, '2001:db8::7')]],
    'sneaky.example' => [[AF_INET, inet_pton(AF_INET, '198.51.100.8')], [AF_INET, inet_pton(AF_INET, '127.0.0.1')]],
    'self.example' => [[AF_INET, inet_pton(AF_INET, '172.20.0.7')]],
    'self6.example' => [[AF_INET6, inet_pton(AF_INET6, 'fd00::42')]],
    'll.example' => [[AF_INET6, inet_pton(AF_INET6, 'fe80::1')]],
    'mapped.example' => [[AF_INET6, inet_pton(AF_INET6, '::ffff:172.20.0.7')]],
);
$PVE::UpdateManager::SecAddress::RESOLVE = sub { @{ $dns{ $_[0] } // [] } };

ok(($allowed->('http://mirror.lan/debian-security'))[0], 'a private mirror is allowed (owner, 2026-10-22)');
ok(($allowed->('https://public.example:8443/x'))[0], 'a public address with a port is allowed');
my @refused = (
    ['ftp://public.example/x', qr/only http and https/],
    ['file:/srv/mirror', qr/only http and https/],
    ["http://user:pw\@public.example/x", qr/credentials/],
    ['http://sneaky.example/x', qr/loopback/],
    ['http://self.example/x', qr/address of this node/],
    ['http://self6.example/x', qr/address of this node/],
    ['http://mapped.example/x', qr/address of this node/],
    ['http://ll.example/x', qr/link-local/],
    ['http://nowhere.example/x', qr/does not resolve/],
    ['http://public.example:99999/x', qr/port/],
    ["http://public.example/x\n", qr/usable address/],
    ['http://a b/x', qr/usable address/],
    # apt ends the host at the first "/" and splits at the last "@" before it:
    # these three connect to 127.0.0.1, measured with apt-helper 3.0.3 (#58).
    ['http://public.example?@127.0.0.1/x', qr/credentials/],
    ['http://public.example#@127.0.0.1/x', qr/credentials/],
    ['http://public.example?@127.0.0.1:3128', qr/credentials/],
);
ok(($allowed->('http://public.example/debian-security?x@127.0.0.1'))[0],
    'control: a "?" and "@" after the first "/" are path, apt connects to the host before it');
ok(($allowed->('http://public.example'))[0], 'control: a proxy address without a path is allowed');
for my $r (@refused) {
    my ($ok, $why) = $allowed->($r->[0]);
    ok(!$ok, 'refused: ' . ($r->[0] =~ s/\n/\\n/gr));
    like($why // '', $r->[1], '  with the reason');
}

# The literal forms go through the real resolver - numeric, so no DNS query -
# because the point is that the check reads the address, not the text.
$PVE::UpdateManager::SecAddress::RESOLVE = $real_resolve;
for my $u ('http://127.0.0.1/', 'http://127.1/', 'http://2130706433/', 'http://0x7f.1/',
    'http://[::1]/', 'http://[::ffff:127.0.0.1]/', 'http://0.0.0.0/', 'http://169.254.169.254/',
    'http://[fe80::1]/', 'http://224.0.0.1/') {
    my ($ok, $why) = $allowed->($u);
    ok(!$ok, "refused through the real resolver: $u (" . ($why // 'allowed') . ')');
}
ok(($allowed->('http://172.16.5.10/'))[0], 'control: a private literal passes the real resolver');
ok(($allowed->('http://[2001:db8::1]/'))[0], 'control: and a global IPv6 literal');

# ── fuzz ────────────────────────────────────────────────────────────────────
#
# Random bytes and mutated real files through all three parsers. Each must
# return, without dying, only fields that pass the same checks the parser
# applies - a field that escapes them would reach a sources.list line or a
# file name in SecFetch.
srand(37);
my @seeds = ($list, $sources, qq{Acquire { http { Proxy "http://p.example"; }; };\nAcquire::http::Proxy::h.example "DIRECT";\n});
my $mutate = sub {
    my ($t) = @_;
    for (1 .. 1 + int(rand(8))) {
        my $pos = int(rand(length($t) + 1));
        my $op = int(rand(4));
        if ($op == 0) {
            substr($t, $pos, 0, chr(int(rand(256))));
        } elsif ($op == 1) {
            substr($t, $pos, 1 + int(rand(5)), '');
        } elsif ($op == 2) {
            substr($t, $pos, 0, ('{', '}', ';', '"', '[', ']', '/', '*', '#', ':', '=', "\n", ' ', "\t", "\r", "\0")[int(rand(16))]);
        } else {
            my $l = int(rand(40));
            substr($t, $pos, 0, substr($t, int(rand(length($t) || 1)), $l));
        }
    }
    return $t;
};
# No DNS from a test: every host the fuzzer invents resolves to a documentation
# address, so uri_allowed runs its whole path without asking the network.
$PVE::UpdateManager::SecAddress::RESOLVE = sub { ([AF_INET, inet_pton(AF_INET, '198.51.100.9')]) };
my ($runs, $died, $bad) = (0, 0, 0);
my $t0 = time();
for my $i (1 .. 3000) {
    my $text = $i % 5 == 0 ? join('', map { chr(int(rand(256))) } 1 .. int(rand(400)))
        : $mutate->($seeds[$i % 3]);
    $runs++;
    my $ok = eval {
        my ($ents, $sk) = $parse->({ '/etc/apt/sources.list' => $text, '/etc/apt/sources.list.d/f.sources' => $text });
        $bad++ if $sk !~ m/\A\d+\z/;
        for my $x (@$ents) {
            $bad++ if PVE::UpdateManager::SecSources::_norm_uri($x->{uri}) ne $x->{uri}
                || !PVE::UpdateManager::SecSources::_valid_suite($x->{suite})
                || !@{ $x->{components} }
                || grep { !PVE::UpdateManager::SecSources::_valid_component($_) } @{ $x->{components} };
            $bad++ if defined($x->{signed_by}) && $x->{signed_by} !~ m{\A/[A-Za-z0-9._+/,-]+\z};
        }
        my $px = $proxy->({ '/etc/apt/apt.conf' => $text });
        for my $v ($px->{http}, $px->{https}, values %{ $px->{hosts} }) {
            next if !defined($v) || $v eq 'DIRECT';
            $bad++ if ($v =~ m/["\\\s]/);
        }
        $bad++ if grep { !m/\A[a-z0-9][a-z0-9.-]*\z/ } keys %{ $px->{hosts} };
        my $os = PVE::UpdateManager::SecSources::parse_os_release($text);
        $bad++ if grep { defined($_) && !m/\A[a-z0-9][a-z0-9._-]*\z/ } values %$os;
        my @a = $allowed->($text);
        1;
    };
    $died++ if !$ok;
}
my $took = time() - $t0;
is($runs, 3000, 'fuzz: premise - 3000 inputs ran');
is($died, 0, 'fuzz: no parser died');
is($bad, 0, 'fuzz: every field returned passes its own check');
cmp_ok($took, '<', 60, sprintf('fuzz: bounded time (%.1f s for 3000 inputs)', $took));

done_testing();
