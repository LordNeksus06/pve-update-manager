package PVE::UpdateManager::SecRead;

# Reading what the security scan needs out of a target - the dpkg status file,
# os-release and apt's sources and configuration - without executing anything
# in it (#38).
#
# Every read happens in a forked child in its own process group, and the parent
# only waits on a pipe until a deadline. Three measured reasons (#36):
#
#   - A plain open() of a FIFO in a container hangs (V1: killed by `timeout`
#     after 3 s, rc 124). O_NONBLOCK and an S_ISREG check refuse it at once,
#     but a file on a mount that stops answering hangs inside the kernel no
#     matter how it is opened.
#   - Such a reader is in state D and does not die even of SIGKILL (V9). The
#     parent therefore never waits for it: it kills the group, reaps without
#     blocking, and a child that is still there afterwards is remembered in
#     %STUCK - no second reader is started for that target while it exists,
#     or every round would add one more hung process.
#   - The web interface has three workers (V8). This runs from the background
#     round only, but the same rule holds there: one bad target may cost its
#     own time limit, never the scan.
#
# A container is read through chroot("/proc/<pid>/root"), not by prefixing
# paths: measured (V1), an absolute symlink inside the container made the naive
# read return the NODE's /etc/hostname. After the chroot the kernel resolves
# every link inside the container's tree, its own mounts included.

use strict;
use warnings;

# Everything the child needs AFTER chroot is loaded here, before it: once the
# root is the container's, a lazy `require` would load Perl code out of the
# container and run it as root on the node. The child empties @INC as well, so
# a module that was forgotten here fails to load instead of loading theirs.
use Errno qw(ENOENT EAGAIN EINTR);
use Fcntl qw(O_RDONLY O_NONBLOCK O_NOCTTY S_ISREG);
use POSIX ();
use Time::HiRes ();

use PVE::INotify;
use PVE::LXC;
use PVE::LXC::Config;
use PVE::QemuServer::Helpers;
use PVE::Storage;

use PVE::UpdateManager::SecReadVM;
use PVE::UpdateManager::SecSources;

our $TIMEOUT = 60;                    # seconds per target, unless the caller says
our $MAX_FILE = 16 * 1024 * 1024;     # the same cap PVE's own agent file-read has
our $MAX_TOTAL = 32 * 1024 * 1024;
our $MAX_ENTRIES = 200;               # per listed directory
our $REAP_GRACE = 0.5;                # how long a killed child is waited for

# Test hooks. Each one can only make a run worse or replace the part that needs
# root or a real guest - none can make a refused file readable.
our $ROOT_OF = \&_root_of;            # (target) -> ('root', dir, keep, mode) | ('agent', vmid) | ('status', s, why)
our $ENTER_ROOT = \&_enter_root;      # (dir) -> true or false with $!
our $KILL_SIGNAL = 'KILL';
our $CHILD_HOOK;                      # (target) in the child, just before reading

# Readers that outlived their deadline: "type:id" => pid.
our %STUCK;

our @FILES = qw(/etc/os-release /var/lib/dpkg/status /etc/apt/sources.list /etc/apt/apt.conf);

# apt reads only names of these characters from its .d directories and ignores
# the rest; a name that apt would not read is not read here either.
our @DIRS = (
    ['/etc/apt/sources.list.d', qr/\A[A-Za-z0-9_.-]+\.(?:list|sources)\z/],
    ['/etc/apt/apt.conf.d', qr/\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/],
);

# ── the parent ──────────────────────────────────────────────────────────────

sub _result {
    my ($status, $reason) = @_;

    return { files => {}, status => $status, reason => $reason, os => {}, skipped => {}, unlisted => [] };
}

# A pid from %STUCK is gone once it can be reaped, or when it is not our child
# any more (ECHILD: somebody else reaped it, or SIGCHLD is ignored).
sub _gone {
    my ($pid) = @_;

    my $r = waitpid($pid, POSIX::WNOHANG());

    return $r == $pid || $r == -1 ? 1 : 0;
}

sub _reap {
    my ($pid) = @_;

    my $until = Time::HiRes::time() + $REAP_GRACE;
    while (1) {
        return 1 if _gone($pid);
        return 0 if Time::HiRes::time() >= $until;
        Time::HiRes::sleep(0.01);
    }
}

sub read_target {
    my ($target, $opts) = @_;

    $opts //= {};
    my %o = (
        timeout => $opts->{timeout} // $TIMEOUT,
        max_file => $opts->{max_file} // $MAX_FILE,
        max_total => $opts->{max_total} // $MAX_TOTAL,
    );

    my $type = $target->{type} // '';
    my $id = $target->{id} // '';
    return _result('error', 'unknown target type') if $type !~ m/\A(?:lxc|qemu|node)\z/;
    return _result('error', 'malformed target id')
        if ($type eq 'node' ? $id !~ m/\A[A-Za-z0-9][A-Za-z0-9.-]{0,62}\z/ : $id !~ m/\A[1-9][0-9]{2,8}\z/);

    my $key = "$type:$id";
    if (my $old = $STUCK{$key}) {
        return _result('timeout', "the reader started for this target in an earlier round (pid $old)"
            . " is still running - no second one is started until it ends")
            if !_gone($old);
        delete $STUCK{$key};
    }

    pipe(my $r, my $w) or return _result('error', "pipe: $!");
    my $pid = fork();
    if (!defined($pid)) {
        my $err = "$!";
        close($r);
        close($w);
        return _result('error', "fork: $err");
    }

    if ($pid == 0) {
        close($r);
        _child($w, $target, \%o);
        POSIX::_exit(0);    # no END blocks, no destructors of the parent's objects
    }

    close($w);

    # What the child may send: the files within their budget plus paths and
    # sentences. More than that means something is wrong with the child.
    my $cap = $o{max_total} + 1024 * 1024;
    my $buf = '';
    my $deadline = Time::HiRes::time() + $o{timeout};
    my ($eof, $why, $late);

    while (1) {
        my $left = $deadline - Time::HiRes::time();
        if ($left <= 0) {
            ($why, $late) = ("no answer within $o{timeout} s", 1);
            last;
        }

        my $rin = '';
        vec($rin, fileno($r), 1) = 1;
        my $n = select(my $rout = $rin, undef, undef, $left);
        if ($n < 0) {
            next if $! == EINTR;
            $why = "select: $!";
            last;
        }
        next if $n == 0;

        my $got = sysread($r, $buf, 65536, length($buf));
        if (!defined($got)) {
            next if $! == EINTR || $! == EAGAIN;
            $why = "reading from the reader: $!";
            last;
        }
        if ($got == 0) {
            $eof = 1;
            last;
        }
        if (length($buf) > $cap) {
            $why = "the reader sent more than " . $cap . " bytes";
            last;
        }
    }
    close($r);

    if (!$eof) {
        # The group first: anything the child started goes with it. The pid on
        # its own covers a child killed before its setpgid() ran.
        kill($KILL_SIGNAL, -$pid) or kill($KILL_SIGNAL, $pid);
        if (!_reap($pid)) {
            $STUCK{$key} = $pid;
            $why .= " - the reader (pid $pid) did not end when killed and is left behind";
        }
        my $res = _result($late ? 'timeout' : 'error', $why);
        # Handed to the caller as well: %STUCK only lives as long as this
        # process, and the security scan calls this from a fresh child for
        # every target, so only the scan's own state can remember the reader
        # into the next round (#40).
        $res->{stuck} = $pid if $STUCK{$key} && $STUCK{$key} == $pid;
        return $res;
    }

    # A child that closed its end but does not exit is stuck in the same way.
    my $stuck = !_reap($pid);
    $STUCK{$key} = $pid if $stuck;

    my $res = _assemble($buf);
    $res->{stuck} = $pid if $stuck;
    return $res;
}

# Splits the records and decides the status. The framing is length-prefixed,
# so no byte of a file can be taken for the end of one.
sub _assemble {
    my ($buf) = @_;

    my $res = _result('ok', undef);
    my ($done, $mode, $status, $reason, $agent_os);
    my $pos = 0;

    while ($pos < length($buf)) {
        my $kind = substr($buf, $pos++, 1);
        my ($k, $v);
        for my $field (\$k, \$v) {
            return _result('error', 'the reader sent a malformed record') if $pos + 4 > length($buf);
            my $len = unpack('N', substr($buf, $pos, 4));
            return _result('error', 'the reader sent a malformed record') if $pos + 4 + $len > length($buf);
            $$field = substr($buf, $pos + 4, $len);
            $pos += 4 + $len;
        }

        if ($kind eq 'F') {
            $res->{files}->{$k} = $v;
        } elsif ($kind eq 'S') {
            $res->{skipped}->{$k} = $v;
        } elsif ($kind eq 'U') {
            push @{ $res->{unlisted} }, $k;
        } elsif ($kind eq 'T') {
            ($status, $reason) = ($k, $v);
        } elsif ($kind eq 'M') {
            $mode = $k;
        } elsif ($kind eq 'O') {
            $agent_os = $k;
        } elsif ($kind eq 'E') {
            $done = 1;
        } else {
            return _result('error', 'the reader sent a malformed record');
        }
    }

    return _result('error', 'the reader ended without finishing') if !$done;
    return _result($status, $reason) if defined($status);

    # The parser SecSources has and sec-sources.t tests: the first ID= wins and
    # a value must be a word (#70). A second one here took the last ID= and
    # passed ".." as a codename, and no test held it.
    $res->{os} = PVE::UpdateManager::SecSources::parse_os_release($res->{files}->{'/etc/os-release'});
    $res->{os}->{id} //= $agent_os if defined($agent_os);

    my $dpkg = '/var/lib/dpkg/status';
    if (defined(my $text = $res->{files}->{$dpkg})) {
        @{$res}{qw(status reason)} = ('error', "$dpkg is empty") if $text eq '';
    } elsif (defined($res->{skipped}->{$dpkg})) {
        @{$res}{qw(status reason)} = ('error', "$dpkg not read: $res->{skipped}->{$dpkg}");
    } elsif (($mode // '') eq 'stopped') {
        # A ZFS dataset of a stopped container need not be mounted; its mount
        # point is then an empty directory, which is not a system without dpkg.
        @{$res}{qw(status reason)} = ('stopped', "stopped, and its root directory holds no $dpkg");
    } else {
        @{$res}{qw(status reason)} = ('unsupported', "no $dpkg - not a system managed by dpkg");
    }

    return $res;
}

# ── the child ───────────────────────────────────────────────────────────────

sub _send {
    my ($w, $kind, $k, $v) = @_;

    my $rec = $kind . pack('N/a* N/a*', $k // '', $v // '');
    my $off = 0;
    while ($off < length($rec)) {
        my $n = syswrite($w, $rec, length($rec) - $off, $off);
        if (!defined($n)) {
            next if $! == EINTR;
            POSIX::_exit(1);    # the parent is gone or gave up on us
        }
        $off += $n;
    }

    return;
}

sub _child {
    my ($w, $target, $o) = @_;

    eval {
        # Its own group, so the parent's kill reaches whatever this starts
        # (lxc-info under open_lxc_pid, the agent's socket client).
        defined(POSIX::setpgid(0, 0)) or die "setpgid: $!\n";

        my ($how, @rest) = $ROOT_OF->($target);
        if ($how eq 'status') {
            _send($w, 'T', $rest[0], $rest[1]);
        } elsif ($how eq 'agent') {
            $CHILD_HOOK->($target) if $CHILD_HOOK;
            PVE::UpdateManager::SecReadVM::read_vm($rest[0], $o, sub { _send($w, @_) });
        } else {
            my ($dir, $keep, $mode) = @rest;
            $ENTER_ROOT->($dir) or die "cannot enter the root directory: $!\n";
            @INC = ();
            _send($w, 'M', $mode) if defined($mode);
            $CHILD_HOOK->($target) if $CHILD_HOOK;
            _read_tree($w, $o);
        }
        1;
    } or _send($w, 'T', 'error', PVE::UpdateManager::SecReadVM::clean("$@"));

    _send($w, 'E');
    close($w);

    return;
}

sub _enter_root {
    my ($dir) = @_;

    return chroot($dir) && chdir('/');
}

# Where a target's files are, decided in the child: loading a container config
# reads /etc/pve, and a hanging pmxcfs is as much a reason for the deadline as a
# hanging mount.
sub _root_of {
    my ($target) = @_;

    my ($type, $id) = @{$target}{qw(type id)};

    if ($type eq 'node') {
        my $here = PVE::INotify::nodename();
        return ('status', 'error', "'$id' is not this node ($here) - a node only reads itself")
            if $id ne $here;
        return ('root', '/');
    }

    if ($type eq 'qemu') {
        return ('status', 'stopped', 'the VM is not running - its disks are not read')
            if !PVE::QemuServer::Helpers::vm_running_locally($id);
        return ('agent', $id);
    }

    if (PVE::LXC::check_running($id)) {
        # open_lxc_pid looks the pid up twice around opening /proc/<pid>, so
        # the descriptor is the container's init and not a recycled pid; the
        # chroot then goes through that descriptor rather than through the
        # number, which another process could have by now.
        my ($pid, $fd) = PVE::LXC::open_lxc_pid($id);
        die "the container's init process changed while it was being opened\n" if !defined($pid);
        return ('root', '/proc/self/fd/' . fileno($fd) . '/root', $fd);
    }

    my $conf = PVE::LXC::Config->load_config($id);
    my $volid;
    PVE::LXC::Config->foreach_volume($conf, sub {
        my ($key, $mp) = @_;
        $volid = $mp->{volume} if $key eq 'rootfs' && ($mp->{type} // 'volume') eq 'volume';
    });
    return ('status', 'stopped', 'stopped, and its root disk is not a storage volume') if !defined($volid);

    # Never mounted: mounting takes the container's lock and can hang, and a
    # block device (LVM-thin, a raw image) is all most storages give back.
    my $path = PVE::Storage::path(PVE::Storage::config(), $volid);
    return ('status', 'stopped', 'stopped, and its root disk is not a directory - it would have to be mounted')
        if !defined($path) || !-d $path;

    return ('root', $path, undef, 'stopped');
}

# Inside the target's root, cwd '/'. Paths are opened relative to it so that
# nothing here depends on the chroot having taken an absolute path along.
sub _read_tree {
    my ($w, $o) = @_;

    my $budget = $o->{max_total};
    my @paths = @FILES;

    for my $d (@DIRS) {
        my ($dir, $ok) = @$d;
        my $dh;
        if (!opendir($dh, substr($dir, 1))) {
            _send($w, 'S', $dir, "cannot be listed: $!") if $! != ENOENT;
            next;
        }
        my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir($dh);

        if (scalar(@names) > $MAX_ENTRIES) {
            _send($w, 'S', $dir, scalar(@names) . " entries, more than the $MAX_ENTRIES read");
            next;
        }
        for my $name (@names) {
            # apt's Dir::Ignore-Files-Silently: backups it passes over without
            # reading - checked first, "50x.dpkg-old" is a valid name otherwise.
            next if $name =~ m/\.(?:dpkg-[a-z]+|ucf-[a-z]+|save|disabled|bak)\z|~\z/;
            if ($name =~ $ok) {
                push @paths, "$dir/$name";
            } else {
                _send($w, 'S', "$dir/" . PVE::UpdateManager::SecReadVM::clean($name), 'a name apt does not read');
            }
        }
    }

    for my $path (@paths) {
        my ($data, $why) = _read_file(substr($path, 1), $o->{max_file}, $budget);
        if (defined($data)) {
            $budget -= length($data);
            _send($w, 'F', $path, $data);
        } elsif (defined($why)) {
            _send($w, 'S', $path, $why);
        }
    }

    return;
}

# (content) or (undef, reason) or () for a file that does not exist.
sub _read_file {
    my ($rel, $max, $budget) = @_;

    # O_NONBLOCK so a FIFO does not wait for a writer (measured: a plain open
    # hangs); O_NOCTTY so a terminal device cannot become ours. Symlinks are
    # followed on purpose - /etc/os-release is one on every Debian - which is
    # safe only because of the chroot.
    #
    # The type is checked BEFORE the open as well, not only after it (#68).
    # Opening is itself an action: it releases a writer waiting on a FIFO, and
    # on a device node in a privileged container it is an open() by a node
    # root process that the container's device cgroup never sees - a watchdog
    # arms on open, a serial line raises DTR. The check after the open stays:
    # in a running container the file can be swapped between the two calls,
    # and then at least nothing is read from it.
    my @pre = stat($rel);
    if (!@pre) {
        return () if $! == ENOENT;
        # The same words the open would have said: a symlink loop or a
        # refused directory fails here now, where it used to fail there.
        return (undef, "cannot be opened: $!");
    }
    return (undef, 'not a regular file') if !S_ISREG($pre[2]);

    my $fh;
    if (!sysopen($fh, $rel, O_RDONLY | O_NONBLOCK | O_NOCTTY)) {
        return () if $! == ENOENT;
        return (undef, "cannot be opened: $!");
    }

    my @st = stat($fh);
    return (undef, "stat: $!") if !@st;
    return (undef, 'not a regular file') if !S_ISREG($st[2]);

    my $limit = $max < $budget ? $max : $budget;
    return (undef, "$st[7] bytes, more than the $limit bytes left to read") if $st[7] > $limit;

    # Read to the limit plus one rather than to the size stat gave: the file
    # can grow between the two, and a file that does is not trusted for more.
    my $data = '';
    while (1) {
        my $n = sysread($fh, $data, 65536, length($data));
        if (!defined($n)) {
            next if $! == EINTR;
            return (undef, "read: $!");
        }
        last if $n == 0;
        return (undef, "grew past the $limit bytes left to read") if length($data) > $limit;
    }

    return ($data);
}

1;
