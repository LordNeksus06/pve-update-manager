package PVE::Notify;

# Test stub. Records what would have been sent instead of sending it: the real
# one needs a cluster filesystem, a notifications.cfg, the Rust notification
# library and something to deliver with - none of which exists in CI, and none of
# which is what the tests are about. Never installed.

use strict;
use warnings;

our @SENT;

# Lets a test take the path where the notification system is there and refuses.
# A run that has already happened must not be turned into a failed task by the
# mail about it not going out.
our $DIE;

# The real one adds the node's hostname, its fqdn and the cluster name. Fixed
# values here, so a claim about the template data is a claim about what this
# addon puts in it.
sub common_template_data {
    return { hostname => 'pve-test', fqdn => 'pve-test.example.invalid' };
}

sub notify {
    my ($severity, $template_name, $template_data, $fields, $config) = @_;

    die "$DIE\n" if defined($DIE);

    push @SENT, {
        severity => $severity,
        template => $template_name,
        data => $template_data,
        fields => $fields,
    };

    return;
}

sub error {
    my ($template_name, $template_data, $fields, $config) = @_;

    return notify('error', $template_name, $template_data, $fields, $config);
}

sub info {
    my ($template_name, $template_data, $fields, $config) = @_;

    return notify('info', $template_name, $template_data, $fields, $config);
}

1;
