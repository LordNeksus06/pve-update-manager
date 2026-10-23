#!/usr/bin/perl -T
# The severity download (#44) under taint mode, the way pvedaemon runs it.
#
#   perl -T -I tests/stubs -I perl tests/taint/severity.t
#
# A check started with "Check now" runs in a worker forked from pvedaemon,
# which runs with -T. The codenames the refresh is asked for come from each
# guest's /etc/os-release, passed through meta.json - read from a file, so
# tainted - and each one names a file: severity-<codename>.list. Checking a
# name against a pattern does not untaint it; only a capture does. So every
# refresh started from the web UI died writing its first list, and every
# update counted as unrated. The input here is read from a file and asserted
# tainted first, as in security.t: a literal never is.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Scalar::Util qw(tainted);
use Test::More;

use PVE::UpdateManager::SecSeverity;

$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

ok(${^TAINT}, 'premise: this runs with -T');

my $tmp = tempdir(CLEANUP => 1);
my $dir = "$tmp/severity";

# The codenames as the round hands them over: out of a guest's os-release,
# through meta.json - a file either way.
open(my $fh, '>', "$tmp/codenames") or die;
print {$fh} "trixie\nbookworm\n";
close($fh);
open($fh, '<', "$tmp/codenames") or die;
my @codenames = map { chomp; $_ } <$fh>;
close($fh);
ok(tainted($codenames[0]), 'premise: a codename read from a file is tainted');

my $doc = <<'EOF';
{ "openssl": {
    "CVE-2026-0001": {"releases": {
        "trixie":   {"status": "resolved", "fixed_version": "3.5.1-1+deb13u1", "urgency": "medium"},
        "bookworm": {"status": "resolved", "fixed_version": "3.0.17-1~deb12u2", "urgency": "low"}}}}}
EOF

# The download replaced, as in tests/perl/sec-severity.t: no network here.
{
    no warnings 'redefine';
    *PVE::UpdateManager::SecSeverity::_fetch = sub {
        my ($url, $file) = @_;
        open(my $out, '>', $file) or die "cannot write $file: $!\n";
        print {$out} $doc;
        close($out);
        return { code => 200, message => 'OK', encoding => '', last_modified => 'x', date => 1, max_age => 0 };
    };
}

my $r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => \@codenames });
is($r->{error}, undef, 'a refresh for codenames read from a file runs under -T') or diag("error: $r->{error}");
ok(-s "$dir/severity-trixie.list", 'and stores the list of the first codename');
ok(-s "$dir/severity-bookworm.list", 'and of the second');
is(PVE::UpdateManager::SecSeverity::lookup('trixie', 'openssl', '3.5.1-1', '3.5.1-1+deb13u1', $dir), 'medium',
    'control: what was stored is read back');

# A codename no target uses any more is removed - and its file name comes out
# of glob(), which is tainted as well.
$r = PVE::UpdateManager::SecSeverity::refresh({ state_dir => $dir, codenames => [$codenames[0]] });
is($r->{error}, undef, 'a refresh that drops a codename runs under -T') or diag("error: $r->{error}");
ok(!-e "$dir/severity-bookworm.list", 'and removes the list nobody uses');
ok(-s "$dir/severity-trixie.list", 'control: the one still used stays');

done_testing();
