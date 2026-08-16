package PVE::RESTHandler;

# Test stub. `use base qw(PVE::RESTHandler)` runs at compile time, so the class
# has to exist for `perl -c`.
#
# It also KEEPS what is registered, in %METHODS keyed by "class/name". Proxmox'
# own RESTHandler builds a route table a test cannot reach without a running
# API, and without this the `code` sub of an endpoint - where the decisions are
# made - could only ever be read, not run. A test asks for one by name:
#
#     my $run = PVE::RESTHandler::registered('PVE::UpdateManager::LXCAPI', 'run');
#     is($run->({ node => 'pve', vmid => 101 }), '', 'nothing stored, no task');

use strict;
use warnings;

our %METHODS;

sub register_method {
    my ($class, $def) = @_;

    return if !defined($def) || !defined($def->{name});

    $METHODS{"$class/$def->{name}"} = $def;

    return;
}

# The `code` sub of a registered method, or undef. Dies on a name that was never
# registered rather than returning undef quietly - a test asking for the wrong
# endpoint should say so, not pass because nothing ran.
sub registered {
    my ($class, $name) = @_;

    my $def = $METHODS{"$class/$name"}
        or die "no method '$name' registered by $class\n";

    return $def->{code};
}

# The whole definition, for tests that check the schema rather than the code.
sub registered_def {
    my ($class, $name) = @_;

    return $METHODS{"$class/$name"};
}

1;
