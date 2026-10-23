package PVE::UpdateManager::SecReadVM;

# The VM half of SecRead (#38): the files of a VM, read through its guest agent
# with guest-file-open/read/close and nothing else. Runs inside SecRead's forked
# child, under the same deadline; each agent command has QemuRunner's 10 s limit
# on top (measured on a silent agent, #36 V10: 10.01 s).
#
# A VM cannot be listed without running something in it (guest-exec), and
# nothing is run in a guest. So only known names are asked for, and the two .d
# directories are reported as not listed rather than as empty.

use strict;
use warnings;

use MIME::Base64 qw(decode_base64);

use PVE::UpdateManager::QemuRunner;

our $AGENT_CHUNK = 1024 * 1024;       # PVE's own agent file-read uses 1 MiB blocks

our @FILES = qw(
    /etc/os-release /var/lib/dpkg/status /etc/apt/sources.list
    /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/ubuntu.sources
    /etc/apt/apt.conf
);

our @UNLISTED = qw(/etc/apt/sources.list.d /etc/apt/apt.conf.d);

# One printable line: an error text can carry what the guest named.
sub clean {
    my ($text) = @_;

    $text =~ s/\s+\z//;
    $text =~ s/[^\x20-\x7e]/?/g;

    return length($text) > 300 ? substr($text, 0, 300) . '...' : $text;
}

sub _agent { return PVE::UpdateManager::QemuRunner::_agent(@_); }

# $send->(kind, key, value) emits one of SecRead's records.
sub read_vm {
    my ($vmid, $o, $send) = @_;

    if (!PVE::UpdateManager::QemuRunner::agent_running($vmid)) {
        $send->('T', 'no-agent', 'the guest agent does not answer');
        return;
    }

    # guest-get-osinfo is optional: agents before qemu-guest-agent 2.10 do not
    # have it, and such a guest is still read by its files. What it costs to
    # go on without it is the early answer for a Windows guest: such a guest
    # then ends on the dpkg status it does not have, as 'unsupported' or
    # 'error' depending on how its agent refuses the open (not measured).
    my $info = eval { _agent($vmid, 'guest-get-osinfo') } // {};
    my $os_id = ref($info) eq 'HASH' ? $info->{id} // '' : '';
    if ($os_id eq 'mswindows') {
        $send->('T', 'unsupported', 'a Windows guest - there is no apt to check');
        return;
    }
    $send->('O', $os_id) if $os_id =~ m/\A[a-z0-9._-]{1,64}\z/;

    my $budget = $o->{max_total};
    for my $path (@FILES) {
        my ($data, $why) = _file($vmid, $path, $o->{max_file} < $budget ? $o->{max_file} : $budget);
        if (defined($data)) {
            $budget -= length($data);
            $send->('F', $path, $data);
        } elsif (defined($why)) {
            $send->('S', $path, $why);
        }
    }

    $send->('U', $_) for @UNLISTED;

    return;
}

# (content) or (undef, reason) or () for a file the guest does not have.
sub _file {
    my ($vmid, $path, $limit) = @_;

    my $handle = eval { _agent($vmid, 'guest-file-open', path => $path, mode => 'r') };
    if (my $err = $@) {
        return () if $err =~ m/No such file or directory/;
        return (undef, 'cannot be opened: ' . clean($err));
    }

    my $data = '';
    my $why;
    eval {
        while (1) {
            my $res = _agent($vmid, 'guest-file-read', handle => int($handle), count => int($AGENT_CHUNK));
            my $count = $res->{count} // 0;
            $data .= decode_base64($res->{'buf-b64'} // '') if $count;
            if (length($data) > $limit) {
                $why = "more than the $limit bytes left to read";
                last;
            }
            last if $res->{eof} || !$count;
        }
        1;
    } or $why = 'read: ' . clean("$@");

    # Not in an eval: a handle left open stays open in the agent until it
    # restarts, and an agent that cannot close one is broken - the die ends
    # this target as an error.
    _agent($vmid, 'guest-file-close', handle => int($handle));

    return (undef, $why) if defined($why);

    # Measured (#36 V3): a FIFO read through the agent comes back as 0 bytes,
    # no hang. An empty file cannot be told from that, so it is never content.
    return (undef, '0 bytes read - not usable') if $data eq '';

    return ($data);
}

1;
