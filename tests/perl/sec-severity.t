#!/usr/bin/perl
# How severe a pending security update is (#44).
#
# The claims: meets() lets an unrated update through every threshold and an
# unimportant one only through the empty threshold; reduce() keeps exactly the
# resolved entries of the codenames asked for, whatever the chunk boundaries;
# lookup() answers with the highest urgency fixed in (installed, fixed] and
# 'unknown' where it has nothing; refresh() never dies, keeps the old data
# when anything fails, and only downloads when it has to. No network: the
# download is replaced, and the fuzz section at the end throws mutated and
# random documents at the parser.

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);

use PVE::UpdateManager::SecSeverity;

my $S = 'PVE::UpdateManager::SecSeverity';
my $meets = \&PVE::UpdateManager::SecSeverity::meets;
my $lookup = \&PVE::UpdateManager::SecSeverity::lookup;

# ── the threshold ───────────────────────────────────────────────────────────
my %expect = (
    #                    ''  low  medium  high
    'unimportant'      => [1, 0, 0, 0],
    'low'              => [1, 1, 0, 0],
    'medium'           => [1, 1, 1, 0],
    'high'             => [1, 1, 1, 1],
    'not yet assigned' => [1, 1, 1, 1],
    'end-of-life'      => [1, 1, 1, 1],
    'unknown'          => [1, 1, 1, 1],
    'critical'         => [1, 1, 1, 1],
);
my @mins = ('', 'low', 'medium', 'high');
for my $u (sort keys %expect) {
    for my $i (0 .. 3) {
        is($meets->($u, $mins[$i]), $expect{$u}->[$i],
            "an update rated '$u' " . ($expect{$u}->[$i] ? 'reaches' : 'does not reach')
            . " the threshold '$mins[$i]'");
    }
}
is($meets->(undef, 'high'), 1, 'an update without any rating reaches every threshold');
is($meets->('unimportant', 'bogus'), 1, 'a threshold that is not one of the three counts everything');
is($meets->('unimportant', undef), 1, 'so does no threshold at all');

# ── the fixture: the tracker's format, every case in one document ───────────
my $doc = <<'EOF';
{ "openssl": {
    "CVE-2026-0001": {"description": "x", "releases": {
        "trixie":   {"status": "resolved", "fixed_version": "3.5.1-1+deb13u1", "urgency": "medium"},
        "bookworm": {"status": "resolved", "fixed_version": "3.0.17-1~deb12u2", "urgency": "low"},
        "sid":      {"status": "resolved", "fixed_version": "3.5.2-1", "urgency": "high"}}},
    "CVE-2026-0002": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "3.5.1-1+deb13u1", "urgency": "high"}}},
    "CVE-2026-0003": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "3.5.1-1+deb13u2", "urgency": "not yet assigned"}}},
    "CVE-2026-0004": {"releases": {
        "trixie": {"status": "open", "repositories": {"trixie": "3.5.1-1"}, "urgency": "high"}}},
    "CVE-2026-0006": {"releases": {
        "trixie": {"status": "undetermined", "fixed_version": "3.5.1-1+deb13u1", "urgency": "high"},
        "bookworm": {"status": "open", "fixed_version": "3.0.17-1~deb12u2", "urgency": "high"}}},
    "CVE-2026-0005": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "0", "urgency": "unimportant"}}},
    "TEMP-0000000-ABCDEF": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "3.0.0-1", "urgency": "low"}}}
  },
  "curl": {
    "CVE-2026-0100": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "8.14.1-2+deb13u1", "urgency": "low**"},
        "forky":  {"status": "resolved", "fixed_version": "8.15.0-1", "urgency": "end-of-life"}}}
  },
  "Bad Name": {
    "CVE-2026-0200": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "1.0-1", "urgency": "high"}}}
  },
  "esc\"aped": {"CVE-2026-0201": {"releases": {}}},
  "badver": {
    "CVE-2026-0300": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": "not a version", "urgency": "high"}}},
    "CVE-2026-0301": {"releases": {
        "trixie": {"status": "resolved", "fixed_version": ["1.0"], "urgency": "high"}}},
    "CVE-2026-0303": {"releases": "neither"}
  },
  "empty": {}
}
EOF

sub reduce_text {
    my ($text, $codenames, %o) = @_;
    open(my $fh, '<', \$text) or die;
    return PVE::UpdateManager::SecSeverity::reduce($fh, $codenames, $o{max} // 1e9, $o{deadline} // 0);
}

my $all = reduce_text($doc, ['trixie', 'bookworm', 'forky', 'noble']);
is_deeply($all->{trixie}, {
    openssl => {
        '3.5.1-1+deb13u1' => 'high',               # two CVEs, the higher one wins
        '3.5.1-1+deb13u2' => 'not yet assigned',
        '3.0.0-1' => 'low',                         # a TEMP- entry is a CVE like any other
    },
    curl => { '8.14.1-2+deb13u1' => 'unknown' },    # a rating the module does not know
}, 'trixie keeps the resolved entries: open, "0", bad names and bad versions are left out');
is_deeply($all->{bookworm}, { openssl => { '3.0.17-1~deb12u2' => 'low' } }, 'bookworm has its own entries');
is_deeply($all->{forky}, { curl => { '8.15.0-1' => 'end-of-life' } }, 'end-of-life is kept as it is');
ok(!exists($all->{sid}), 'a codename nobody asked for is not kept');
ok(!exists($all->{noble}), 'an Ubuntu codename finds nothing in Debian\'s data');

# The result must not depend on where a read ends: the same document in chunks
# of 1 to 13 bytes, which puts a boundary inside every key, every brace and
# every value somewhere.
my $same = 0;
for my $chunk (1 .. 13) {
    local $PVE::UpdateManager::SecSeverity::CHUNK = $chunk;
    $same++ if eq_deeply_hash(reduce_text($doc, ['trixie', 'bookworm', 'forky']), $all);
}
is($same, 13, 'the same result for every chunk size from 1 to 13 bytes');

sub eq_deeply_hash {
    my ($a, $b) = @_;
    require Data::Dumper;
    no warnings 'once';
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Indent = 0;
    return Data::Dumper::Dumper($a) eq Data::Dumper::Dumper($b);
}

# ── what the parser refuses ─────────────────────────────────────────────────
sub refused {
    my ($text, $like, $name, %o) = @_;
    my $r = eval { reduce_text($text, ['trixie'], %o) };
    like($@, $like, $name);
}
refused('', qr/ends in the middle/, 'an empty document is refused');
refused('[1,2]', qr/malformed/, 'an array is not the tracker\'s format');
refused('{"a": {"CVE-1": {"releases": {}}', qr/ends in the middle/, 'a document cut off is refused');
refused('{"a": {"CVE-1": {}}} trailing', qr/text after its end/, 'text after the end is refused');
refused('{"a": {"CVE-1": {}} "b": {}}', qr/malformed/, 'two members without a comma are refused');
refused('{"a": {"CVE-1": 12}}', qr/must be an object or array/, 'a bare number where a CVE belongs is refused');
refused('{"a": {"CVE-1": "x"}}', qr/must be an object or array/, 'so is a string: the same rule, whatever the chunks');
refused($doc, qr/larger than 100 bytes/, 'a document over max_bytes is refused', max => 100);
refused($doc, qr/took too long/, 'a deadline in the past ends the reduce', deadline => time() - 1);
refused('{"' . ('a' x 200000) . '": {}}', qr/malformed near byte/, 'a key longer than any the format has is refused');
my ($at_byte) = $@ =~ m/near byte ([0-9]+)/;
cmp_ok($at_byte // 1e9, '<=', 131072, 'after at most 128 KiB, not after reading all 200 000 bytes');
is_deeply(reduce_text('{}', ['trixie']), {}, 'control: an empty object is valid and empty');

# ── refresh, with the download replaced ─────────────────────────────────────
my $dir = tempdir(CLEANUP => 1);
my @calls;
my %next;    # what the fake server answers next
my $real_fetch = \&PVE::UpdateManager::SecSeverity::_fetch;

{
    no warnings 'redefine';
    *PVE::UpdateManager::SecSeverity::_fetch = sub {
        my ($url, $file, $since, $max, $deadline, $proxy) = @_;
        push @calls, { since => $since, proxy => $proxy };
        die "$next{die}\n" if $next{die};
        die "$next{die_via}{$proxy}\n" if defined($proxy) && $next{die_via} && $next{die_via}{$proxy};
        die "$next{die_direct}\n" if !defined($proxy) && $next{die_direct};
        open(my $fh, '>', $file) or die;
        my $body = $next{body} // '';
        if (($next{encoding} // '') eq 'gzip' && !$next{raw}) {
            require IO::Compress::Gzip;
            IO::Compress::Gzip::gzip(\$body => \my $gz) or die;
            $body = $gz;
        }
        print {$fh} $body;
        close($fh);
        return { code => $next{code} // 200, message => 'x', encoding => $next{encoding} // '',
            last_modified => 'Thu, 22 Oct 2026 16:46:07 GMT', date => 1792687567, max_age => $next{max_age} };
    };
}

sub fresh {
    %next = @_;
    @calls = ();
}

# max_age as LWP hands it over: a string out of a header.
fresh(body => $doc, encoding => 'gzip', max_age => '3600');
my $r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'noble'] });
is_deeply($r, { ok => 1, error => undef, date => 1792687567 }, 'a first refresh succeeds and reports the date');
is(scalar(@calls), 1, 'premise: it downloaded');
ok(-s "$dir/severity-trixie.list", 'trixie is stored');
ok(!-e "$dir/severity-noble.list", 'noble is not: Debian has nothing for it');
open(my $stf, '<', "$dir/severity.state") or die;
like(do { local $/; <$stf> }, qr/"max_age":3600[,}]/, 'max-age is stored as a number');
ok(!grep({ -e $_ } glob("$dir/*.tmp*")), 'no temporary file is left behind');

# lookup: the range is (installed, fixed].
my @L = ('trixie', 'openssl');
is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u1', $dir), 'high', 'an update over two CVEs takes the higher urgency');
is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u2', $dir), 'high', 'the range covers every fix up to the new version');
is($lookup->(@L, '3.5.1-1+deb13u1', '3.5.1-1+deb13u2', $dir), 'not yet assigned',
    'a fix already installed does not count');
is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u0', $dir), 'unknown', 'a fix above the new version does not count');
is($lookup->(@L, '2.9-1', '3.0.0-1', $dir), 'low', 'a fix exactly at the new version counts');
is($lookup->('trixie', 'curl', '8.14.1-2', '8.14.1-2+deb13u1', $dir), 'unknown', 'an unknown rating stays unknown');
is($lookup->('trixie', 'zlib', '1.0', '2.0', $dir), 'unknown', 'a package the tracker does not list is unknown');
is($lookup->('noble', 'openssl', '3.0.13-0ubuntu3', '3.0.13-0ubuntu3.5', $dir), 'unknown', 'Ubuntu is unknown');
is($lookup->('trixie', 'openssl', 'garbage', '3.5.1-1+deb13u1', $dir), 'unknown', 'a bad version is unknown');
is($lookup->('../etc', 'openssl', '1', '2', $dir), 'unknown', 'a codename that is not one is unknown');

# Within max-age the tracker is not asked again.
fresh(body => $doc, encoding => 'gzip', max_age => 3600);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie'] });
is($r->{ok}, 1, 'a refresh within max-age succeeds');
is(scalar(@calls), 0, 'without asking the tracker');

# A codename the data was not reduced for forces a full download.
fresh(body => $doc, encoding => 'gzip', max_age => 0);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'] });
is(scalar(@calls), 1, 'a new codename is downloaded even within max-age');
ok(!defined($calls[0]->{since}), 'and unconditionally, because a 304 would leave it missing');
is($lookup->('bookworm', 'openssl', '3.0.17-1~deb12u1', '3.0.17-1~deb12u2', $dir), 'low', 'bookworm is there now');

# After max-age: a conditional request, and a 304 changes nothing.
fresh(code => 304, max_age => 0);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'] });
fresh(code => 304, max_age => 0);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['bookworm', 'trixie'] });
is(scalar(@calls), 1, 'with max-age 0 the tracker is asked every time');
is($calls[0]->{since}, 'Thu, 22 Oct 2026 16:46:07 GMT', 'with the stored Last-Modified');
is_deeply($r, { ok => 1, error => undef, date => 1792687567 }, 'a 304 is a success with the stored date');
is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u1', $dir), 'high', 'and the data is still there');

# A 304 to a request that asked for nothing conditional has no data behind it.
fresh(code => 304, max_age => 0);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm', 'sid'] });
ok(!defined($calls[0]->{since}), 'premise: a new codename asks unconditionally');
ok(!$r->{ok} && $r->{error} =~ m/answered 304/, 'and a 304 to that is an error, not a success without data');

# Failures keep the old data and say why, without dying.
for my $case (
    [{ die => 'connect: Connection refused' }, qr/\ASeverity data not updated: connect: Connection refused\z/,
        'a download that fails'],
    [{ code => 500, body => 'x' }, qr/answered 500/, 'an HTTP error'],
    [{ body => '{"openssl": {"CVE-1": ' }, qr/ends in the middle/, 'a truncated document'],
    [{ body => $doc, encoding => 'br' }, qr/unknown encoding/, 'an encoding nobody asked for'],
    [{ body => 'not gzip', encoding => 'gzip', raw => 1 }, qr/cannot unpack/, 'a body that is not gzip'],
) {
    fresh(%{ $case->[0] });
    $r = eval { PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'] }) };
    ok($r && !$r->{ok}, "$case->[2] does not die and reports ok 0");
    like($r && $r->{error}, $case->[1], "$case->[2] says why");
    is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u1', $dir), 'high', "$case->[2] keeps the previous data");
}
ok(!grep({ -e $_ } glob("$dir/*.tmp*")), 'no temporary file is left behind by a failure');

# #49: the download goes through the proxy the guests' apt would use; with
# several, each in turn until one answers.
fresh(body => $doc, encoding => 'gzip', max_age => 0);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'],
    proxies => ['http://proxy.test:3128'] });
is($r->{ok}, 1, 'premise: a refresh through a proxy succeeds');
is_deeply([map { $_->{proxy} } @calls], ['http://proxy.test:3128'], 'and the download went through that proxy');

fresh(body => $doc, encoding => 'gzip', max_age => 0, die_via => { 'http://a.test:3128' => 'connect: timeout' });
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'],
    proxies => ['http://a.test:3128', 'http://b.test:3128', undef] });
is($r->{ok}, 1, 'a proxy that fails is followed by the next one');
is_deeply([map { $_->{proxy} } @calls], ['http://a.test:3128', 'http://b.test:3128'],
    'and the first that answers ends it - direct is not tried');

fresh(die_via => { 'http://a.test:3128' => 'connect: timeout' }, die_direct => 'connect: no route');
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'],
    proxies => ['http://a.test:3128', undef] });
ok(!$r->{ok}, 'all of them failing is a failure');
like($r->{error}, qr/via http:\/\/a\.test:3128: connect: timeout; direct: connect: no route/,
    'and it says, for each, how it went');

fresh(body => $doc, encoding => 'gzip', max_age => 0);
PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['trixie', 'bookworm'] });
is_deeply([map { $_->{proxy} } @calls], [undef], 'control: no proxies given is a direct download, as before');

# A codename no target uses any more is removed; one Debian dropped is too.
fresh(body => $doc, encoding => '', max_age => 0);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['bookworm'] });
is($r->{ok}, 1, 'an uncompressed answer is read as well');
ok(!-e "$dir/severity-trixie.list", 'a codename no longer asked for is removed');
is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u1', $dir), 'unknown', 'so its lookups are unknown, not stale');
fresh(body => '{"curl": {}}', max_age => 0);
PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['bookworm'] });
ok(!-e "$dir/severity-bookworm.list", 'a codename the new data does not carry is removed');

# A codename becomes a file name: one that is not a codename is dropped.
fresh(body => $doc);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => ['../evil', 'Trixie', 'a/b'] });
is_deeply([$r->{ok}, scalar(@calls)], [1, 0], 'codenames that could leave the directory are dropped before use');

# Everything else refresh() is given.
fresh(body => $doc);
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => [] });
is_deeply([$r->{ok}, scalar(@calls)], [1, 0], 'no codenames: nothing to download');
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => "$dir/new/sub", codenames => ['trixie'] });
is($r->{ok}, 1, 'a state directory that does not exist yet is created');
open(my $blk, '>', "$dir/afile") or die;
close($blk);
$r = eval { PVE::UpdateManager::SecSeverity::refresh({ state_dir => "$dir/afile/sub", codenames => ['trixie'] }) };
ok($r && !$r->{ok} && $r->{error} =~ m/cannot create/, 'a state directory that cannot be created is an error, not a death');

# The stored list is our file but is read strictly all the same.
open(my $lf, '>', "$dir/severity-trixie.list") or die;
print {$lf} "openssl\t3.5.1-1+deb13u1\thigh\nBad\t1.0\thigh\nopenssl\tx y\thigh\nopenssl\t3.5.1-1+deb13u3\tworst\n";
close($lf);
utime(time() + 5, time() + 5, "$dir/severity-trixie.list");
is($lookup->(@L, '3.5.1-1', '3.5.1-1+deb13u2', $dir), 'high', 'premise: the good line of the stored list is read');
is($lookup->(@L, '3.5.1-1+deb13u2', '3.5.1-1+deb13u3', $dir), 'unknown', 'a line with an unknown urgency is skipped');

# ── the real download, where LWP is installed (not on the CI runner) ────────
SKIP: {
    skip 'LWP::UserAgent is not installed', 4 if !eval { require LWP::UserAgent; 1 };
    my $src = "$dir/served.json";
    open(my $sf, '>', $src) or die;
    print {$sf} $doc;
    close($sf);
    my $orig = $real_fetch;
    my $rd = "$dir/real";
    mkdir($rd);
    my $u = "file://$src";
    $r = $orig->($u, "$rd/x", undef, 1e9, time() + 30);
    is($r->{code}, 200, 'file:// through LWP: 200');
    $r = $orig->($u, "$rd/x", $r->{last_modified}, 1e9, time() + 30);
    is($r->{code}, 304, 'and a conditional request for the same file: 304');
    ok(!defined(eval { $orig->($u, "$rd/x", undef, 100, time() + 30) }), 'a body over max_bytes is cut off');
    like($@, qr/larger than 100 bytes/, 'and says so');
}

# ── fuzz: nothing in the document may kill refresh or stall the parser ──────
#
# Mutations of the fixture (bytes flipped, inserted, deleted; slices
# duplicated) and plain random bytes, through refresh() exactly as a download
# would arrive. Asserted: refresh never dies, every stored entry passes the
# field checks, and the loop ends - a regex that backtracked badly on some
# input would show up as this test not finishing.
my @stored = ('unimportant', 'low', 'medium', 'high', 'not yet assigned', 'end-of-life', 'unknown');
my $seed = 4444;
srand($seed);
my ($runs, $died, $bad, $okc) = (0, 0, 0, 0);
my $fdir = "$dir/fuzz";
for my $i (1 .. 1500) {
    my $text;
    if ($i % 4 == 0) {
        $text = join('', map { chr(int(rand(256))) } 1 .. int(rand(3000)));
    } elsif ($i % 4 == 1) {
        # Letters and digits swapped for characters a name or version may or
        # may not hold: the document stays JSON, the fields are what change.
        $text = $doc;
        for (1 .. 1 + int(rand(4))) {
            my @at = grep { substr($text, $_, 1) =~ m/[a-z0-9]/ } 0 .. length($text) - 1;
            substr($text, $at[int(rand(@at))], 1, substr('a0.~+-:_ A', int(rand(10)), 1));
        }
    } else {
        $text = $doc;
        for (1 .. 1 + int(rand(8))) {
            my $at = int(rand(length($text) || 1));
            my $op = int(rand(4));
            if ($op == 0) { substr($text, $at, 1, chr(int(rand(256)))) }
            elsif ($op == 1) { substr($text, $at, 0, substr('{}[],:"\\ 0aZ', int(rand(13)), 1)) }
            elsif ($op == 2) { substr($text, $at, 1 + int(rand(20)), '') }
            else { substr($text, $at, 0, substr($text, int(rand(length($text))), int(rand(200)))) }
        }
    }
    fresh(body => $text, encoding => ($i % 2 ? 'gzip' : ''), max_age => 0);
    local $PVE::UpdateManager::SecSeverity::CHUNK = 1 + int(rand(64));
    $runs++;
    my $res = eval { PVE::UpdateManager::SecSeverity::refresh({ state_dir => $fdir, codenames => ['trixie', 'bookworm'] }) };
    if (!$res) { $died++; next }
    $okc++ if $res->{ok};
    for my $f (glob("$fdir/severity-*.list")) {
        open(my $fh, '<', $f) or next;
        while (my $l = <$fh>) {
            my ($s, $v, $u) = split(/\t/, $l);
            chomp($u) if defined($u);
            $bad++ if !PVE::UpdateManager::SecCompare::valid_name($s)
                || !PVE::UpdateManager::SecCompare::valid_version($v)
                || !grep { defined($u) && $u eq $_ } @stored;
        }
    }
}
is($runs, 1500, 'premise: every fuzz case ran');
cmp_ok($okc, '>', 0, "premise: some mutated documents still parsed ($okc)");
is($died, 0, "no mutated or random document made refresh die (seed $seed)");
is($bad, 0, 'and nothing stored from one failed the field checks');

done_testing();
