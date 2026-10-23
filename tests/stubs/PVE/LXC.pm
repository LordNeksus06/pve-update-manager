package PVE::LXC;

# Test stub. The lists are settable so a test can pretend containers exist.

use strict;
use warnings;

use Fcntl qw(O_RDONLY O_DIRECTORY);

our %RUNNING;
our %CONFIG_LIST;

# vmid => pid of the container's init, for the two lookups below.
our %PID;

sub check_running { my ($vmid) = @_; return $RUNNING{$vmid}; }
sub config_list { return { %CONFIG_LIST }; }

# The real one runs `lxc-info -n <vmid> -p` and dies when no pid comes back.
sub find_lxc_pid {
    my ($vmid) = @_;

    my $pid = $PID{$vmid};
    die "unable to get PID for CT $vmid (not running?)\n" if !$pid;

    return $pid;
}

# The real one (LXC.pm on 9.2.4): pid, open /proc/<pid>, pid again, and an
# empty list when the two lookups disagree.
sub open_lxc_pid {
    my ($vmid) = @_;

    my $pid = find_lxc_pid($vmid);
    sysopen(my $fd, "/proc/$pid", O_RDONLY | O_DIRECTORY)
        or die "failed to open /proc/$pid pid fd\n";

    return () if $pid != find_lxc_pid($vmid);
    return ($pid, $fd);
}

1;
