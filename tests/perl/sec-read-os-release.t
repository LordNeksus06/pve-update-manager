#!/usr/bin/perl
# The os-release a target's result is built from is read by the one parser
# whose rules sec-sources.t tests (#70).
#
# The claims: the first ID= wins, as the rule in SecSources says - a line
# appended by hand does not override what the distribution wrote; and a
# codename that is no word ("..") is not one. Both through SecRead's own
# assembly of what the reader child sent, which is where the scan takes them.

use strict;
use warnings;

use Test::More;

use PVE::UpdateManager::SecRead;

# What the reader child sends: one record per file, then the end mark.
sub assembled {
    my ($os_release) = @_;
    my $rec = sub { $_[0] . pack('N/a* N/a*', $_[1] // '', $_[2] // '') };
    return PVE::UpdateManager::SecRead::_assemble(join('',
        $rec->('F', '/etc/os-release', $os_release),
        $rec->('F', '/var/lib/dpkg/status', "Package: x\n"),
        $rec->('E')));
}

my $res = assembled("ID=debian\nVERSION_CODENAME=trixie\nID=ubuntu\n");
is($res->{status}, 'ok', 'premise: the records are assembled');
is($res->{os}->{id}, 'debian', 'the first ID= wins over one appended later');
is($res->{os}->{version_codename}, 'trixie', 'control: the codename is read');

$res = assembled("ID=debian\nVERSION_CODENAME=..\n");
ok(!defined($res->{os}->{version_codename}), 'a codename ".." is not a codename');

$res = assembled(qq{PRETTY_NAME="Ubuntu 24.04"\nID="ubuntu"\nVERSION_CODENAME='noble'\n});
is_deeply([@{ $res->{os} }{qw(id version_codename)}], [qw(ubuntu noble)], 'control: quoted values are unquoted');

done_testing();
