#!/usr/bin/perl
# PVE::UpdateManager::SecProbe - does a security source still hand out the
# package files its lists name (#53)? The HEAD request is replaced; what it
# asked for and through which proxy is recorded.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

use PVE::UpdateManager::SecProbe;

my $dir = tempdir(CLEANUP => 1);
sub put {
    my ($name, $text) = @_;
    open(my $fh, '>', "$dir/$name") or die;
    print {$fh} $text;
    close($fh);
    return "$dir/$name";
}

my $pk = put('a_Packages', "Package: dpkg\nVersion: 1.20.14\nFilename: pool/updates/main/d/dpkg/dpkg_1.20.14_amd64.deb\n\n"
    . "Package: libc6\nFilename: pool/updates/main/g/glibc/libc6.deb\n");
my $first = 'pool/updates/main/d/dpkg/dpkg_1.20.14_amd64.deb';

# ── which file is asked for ─────────────────────────────────────────────────
is(PVE::UpdateManager::SecProbe::first_filename([$pk]), $first, 'the first Filename of the index');
is(PVE::UpdateManager::SecProbe::first_filename([put('e_Packages', ''), $pk]), $first,
    'an index without one is passed over for the next');
is(PVE::UpdateManager::SecProbe::first_filename([put('t_Packages', "Filename: ../../etc/passwd\n")]), undef,
    'a path that steps out of the archive is not asked for');
is(PVE::UpdateManager::SecProbe::first_filename([put('q_Packages', "Filename: pool/a?b=c\n")]), undef,
    'nor one with characters a pool path does not have');
is(PVE::UpdateManager::SecProbe::first_filename(["$dir/missing"]), undef, 'a missing index is nothing to ask');

# ── the probe ───────────────────────────────────────────────────────────────
my (@asked, %answer);
$PVE::UpdateManager::SecProbe::HEAD = sub {
    my ($url, $proxy, $timeout) = @_;
    push @asked, [$url, $proxy];
    return $answer{$url};
};

my $job = sub { { uri => $_[0], suite => 'bullseye-security', proxy => $_[1] // {} } };
my %jobs = (
    gone => $job->('http://security.debian.org/', { http => 'http://p.test:3128' }),
    there => $job->('http://deb.example/debian-security'),
    silent => $job->('http://slow.example/debian-security'),
    failed => $job->('http://fail.example/debian-security'),
    plain => $job->('http://plain.example/debian'),
);
my %lists = (
    gone => { is_security => 1, packages => [$pk] },
    there => { is_security => 1, packages => [$pk] },
    silent => { is_security => 1, packages => [$pk] },
    failed => { error => 'Failed to fetch', packages => [$pk] },
    plain => { is_security => 0, packages => [$pk] },
);
%answer = (
    "http://security.debian.org/$first" => 404,
    "http://deb.example/debian-security/$first" => 200,
    "http://slow.example/debian-security/$first" => undef,
);
PVE::UpdateManager::SecProbe::probe(\%jobs, \%lists);

is(scalar(@asked), 3, 'one request per fetched security list - none for a failed or a non-security one');
like($lists{gone}->{pool_error}, qr/HTTP 404 \(e\.g\. \Qhttp:\/\/security.debian.org\/$first\E\)/,
    'a 404 marks the list, with the address that answered it');
ok(!exists($lists{there}->{pool_error}), 'control: a 200 marks nothing');
ok(!exists($lists{silent}->{pool_error}), 'no answer at all is not a finding');
my ($via) = grep { $_->[0] =~ m/security\.debian\.org/ } @asked;
is($via->[1], 'http://p.test:3128', 'asked through the proxy the guest\'s apt would use');
ok(!grep({ $_->[0] =~ m{//pool} } @asked), 'a trailing slash in the source does not double');

%answer = ("http://security.debian.org/$first" => 410);
delete $lists{gone}->{pool_error};
PVE::UpdateManager::SecProbe::probe({ gone => $jobs{gone} }, \%lists);
like($lists{gone}->{pool_error}, qr/HTTP 410/, 'a 410 (gone) counts like a 404');

# A budget that is used up stops asking, and says so.
@asked = ();
my @log;
{
    local $PVE::UpdateManager::SecProbe::BUDGET = 0;
    PVE::UpdateManager::SecProbe::probe(\%jobs, \%lists, sub { push @log, @_ });
}
is(scalar(@asked), 0, 'with no time left nothing is asked');
like($log[0] // '', qr/not checked: 0 s used up/, 'and the log says the rest was not checked');

done_testing();
