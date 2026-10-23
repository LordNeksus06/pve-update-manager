#!/usr/bin/perl
# PVE::UpdateManager::SecRead - reading the files of a target for the security
# scan, in a forked child, against fake root directories.
#
# Most of this runs without root: $ENTER_ROOT is replaced by a plain chdir,
# which keeps every relative path and every refusal real but cannot hold an
# absolute symlink inside the tree. That part - the reason for the chroot,
# measured in #36 V1 - runs at the bottom with a real chroot under
# `unshare -r`, and says SKIP with its reason where the kernel does not allow
# an unprivileged user namespace.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use Fcntl ();
use File::Temp qw(tempdir);
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use POSIX ();
use Time::HiRes qw(time);
use Test::More tests => 77;

use PVE::LXC;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor;
use PVE::Storage;
use PVE::UpdateManager::QemuRunner;
use PVE::UpdateManager::SecRead;

# Alive means not gone and not a zombie (#52). kill(0) answers for a zombie
# too, and an orphan stays one where nobody reaps it: in a CI container the
# test itself can be PID 1. There sec-fetch.t's "the grandchild died" was red
# 3 of 3 times with the grandchild in state Z, and green on a host with
# systemd as PID 1.
sub alive {
    my ($pid) = @_;
    return 0 if !kill(0, $pid);
    open(my $st, '<', "/proc/$pid/stat") or return 0;
    my $line = <$st> // '';
    return $line =~ m/\) Z / ? 0 : 1;
}

$PVE::UpdateManager::QemuRunner::AGENT_TIMEOUT = 2;

my $tmp = tempdir(CLEANUP => 1);
my $NODE = { type => 'node', id => 'pve-test' };

sub put {
    my ($root, $rel, $text) = @_;

    my $path = "$root/$rel";
    (my $dir = $path) =~ s{/[^/]+\z}{};
    make_path($dir);
    open(my $fh, '>', $path) or die "$path: $!";
    print $fh $text;
    close($fh) or die "$path: $!";

    return $path;
}

my $STATUS = "Package: bash\nStatus: install ok installed\nArchitecture: amd64\nVersion: 5.2.37-2\n\n";

# A small Debian: os-release as the symlink it is on every Debian, a dpkg
# status, a sources.list, both .d directories with names apt reads and names
# it does not, and a file nobody asked for.
my $n = 0;
sub debian {
    my $root = "$tmp/root" . $n++;
    put($root, 'usr/lib/os-release', qq{PRETTY_NAME="Debian"\nID=debian\nVERSION_CODENAME=trixie\n});
    make_path("$root/etc");
    symlink('../usr/lib/os-release', "$root/etc/os-release") or die $!;
    put($root, 'var/lib/dpkg/status', $STATUS);
    put($root, 'etc/apt/sources.list', "deb http://deb.debian.org/debian trixie main\n");
    put($root, 'etc/apt/sources.list.d/extra.list', "deb http://example.invalid/ x main\n");
    put($root, 'etc/apt/sources.list.d/debian.sources', "Types: deb\n");
    put($root, 'etc/apt/sources.list.d/notes.txt', "not a source\n");
    put($root, 'etc/apt/apt.conf.d/99local', "APT::Get::Assume-Yes \"true\";\n");
    put($root, 'etc/apt/apt.conf.d/50old.dpkg-old', "old\n");
    put($root, "etc/apt/apt.conf.d/bad\tname", "x\n");
    put($root, 'etc/shadow', "root:secret\n");
    return $root;
}

sub in_root {
    my ($root, $mode) = @_;
    $PVE::UpdateManager::SecRead::ROOT_OF = sub { return ('root', $root, undef, $mode) };
}

$PVE::UpdateManager::SecRead::ENTER_ROOT = sub { return chdir($_[0]) };

sub timed {
    my ($target, $opts) = @_;
    my $t0 = time();
    my $res = PVE::UpdateManager::SecRead::read_target($target, $opts);
    return ($res, time() - $t0);
}

# ── what is read ────────────────────────────────────────────────────────────

my $root = debian();
in_root($root);
my $res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });

is($res->{status}, 'ok', 'a readable Debian root is ok') or diag(explain($res));
is($res->{files}->{'/var/lib/dpkg/status'}, $STATUS, 'the dpkg status arrives byte for byte');
like($res->{files}->{'/etc/os-release'}, qr/ID=debian/, 'a relative symlink inside the root is followed');
is_deeply($res->{os}, { id => 'debian', version_codename => 'trixie' }, 'os-release gives id and codename');
ok(exists($res->{files}->{'/etc/apt/sources.list.d/extra.list'}), 'a .list in sources.list.d is read');
ok(exists($res->{files}->{'/etc/apt/sources.list.d/debian.sources'}), 'a .sources in sources.list.d is read');
ok(exists($res->{files}->{'/etc/apt/apt.conf.d/99local'}), 'a file in apt.conf.d is read');
ok(!exists($res->{files}->{'/etc/shadow'}), 'a file nobody asked for is not read');
ok(!exists($res->{files}->{'/etc/apt/sources.list.d/notes.txt'}), 'a name apt does not read is not read');
is($res->{skipped}->{'/etc/apt/sources.list.d/notes.txt'}, 'a name apt does not read', '... and is named');
ok(exists($res->{skipped}->{"/etc/apt/apt.conf.d/bad?name"}), 'a control character in a name is not passed on');
ok(!grep({ m/dpkg-old/ } keys(%{ $res->{files} }), keys(%{ $res->{skipped} })), 'a dpkg backup is passed over silently');
ok(!exists($res->{files}->{'/etc/apt/apt.conf'}), 'a missing optional file is simply absent');
ok(!exists($res->{skipped}->{'/etc/apt/apt.conf'}), '... and not reported as skipped');
is_deeply($res->{unlisted}, [], 'a root can be listed, so nothing is unlisted');

# ── what is refused ─────────────────────────────────────────────────────────

# A FIFO in place of the dpkg status. A plain open waits for a writer forever
# (#36 V1); the timeout is long so that a hang shows as 'timeout', not as a
# fast refusal.
$root = debian();
unlink("$root/var/lib/dpkg/status");
POSIX::mkfifo("$root/var/lib/dpkg/status", 0600) or die $!;
POSIX::mkfifo("$root/etc/apt/sources.list.d/pipe.list", 0600) or die $!;
in_root($root);
my $took;
($res, $took) = timed($NODE, { timeout => 5 });
is($res->{skipped}->{'/var/lib/dpkg/status'}, 'not a regular file', 'a FIFO as dpkg status is refused as not a regular file');
cmp_ok($took, '<', 2, 'the refusal does not wait for a writer');
is($res->{status}, 'error', 'a refused dpkg status is never ok');
like($res->{reason}, qr/not read: not a regular file/, '... and the reason says why');
is($res->{skipped}->{'/etc/apt/sources.list.d/pipe.list'}, 'not a regular file', 'a FIFO among the sources is refused too');

# Refused without being opened (#68). The open is the action: on a FIFO it
# releases a writer waiting for a reader, on a device node in a privileged
# container it is a node root open() outside the container's device cgroup.
# A writer blocked in open(O_WRONLY) is what tells the two apart - it returns
# the moment anything opens the other end.
$root = debian();
unlink("$root/etc/apt/apt.conf");
POSIX::mkfifo("$root/etc/apt/apt.conf", 0600) or die $!;
my $writer = fork() // die "fork: $!";
if (!$writer) {
    sysopen(my $fh, "$root/etc/apt/apt.conf", Fcntl::O_WRONLY()) or POSIX::_exit(1);
    POSIX::_exit(0);
}
in_root($root);
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 5 });
is($res->{skipped}->{'/etc/apt/apt.conf'}, 'not a regular file', 'a FIFO behind a known name is refused');
Time::HiRes::sleep(0.3);
is(waitpid($writer, POSIX::WNOHANG()), 0, 'a non-regular file is refused without being opened - a writer waiting on it stays blocked');
kill('KILL', $writer);
waitpid($writer, 0);

# A directory in place of a file.
$root = debian();
unlink("$root/etc/apt/sources.list");
make_path("$root/etc/apt/sources.list");
in_root($root);
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });
is($res->{skipped}->{'/etc/apt/sources.list'}, 'not a regular file', 'a directory where a file belongs is refused');
is($res->{status}, 'ok', '... and costs only that file');

# Sizes.
$root = debian();
put($root, 'var/lib/dpkg/status', $STATUS x 20);
in_root($root);
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10, max_file => length($STATUS) * 10 });
like($res->{skipped}->{'/var/lib/dpkg/status'}, qr/more than the \d+ bytes left/, 'a file over max_file is refused');
ok(!exists($res->{files}->{'/var/lib/dpkg/status'}), '... and not one byte of it is passed on');
is($res->{status}, 'error', '... which makes the target not ok');

$root = debian();
in_root($root);
my $os_len = -s "$root/usr/lib/os-release";
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10, max_total => $os_len + 10 });
ok(exists($res->{files}->{'/etc/os-release'}), 'the first file fits into max_total');
like($res->{skipped}->{'/var/lib/dpkg/status'}, qr/bytes left to read/, 'the next one no longer does');

# More entries than are read.
$root = debian();
put($root, "etc/apt/apt.conf.d/$_", "x\n") for 1 .. 5;
in_root($root);
{
    local $PVE::UpdateManager::SecRead::MAX_ENTRIES = 3;
    $res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });
}
like($res->{skipped}->{'/etc/apt/apt.conf.d'}, qr/more than the 3 read/, 'a directory with too many entries is refused whole');
ok(!grep({ m{apt\.conf\.d/} } keys(%{ $res->{files} })), '... and none of its files is read');

# ── what the dpkg status decides ────────────────────────────────────────────

$root = debian();
unlink("$root/var/lib/dpkg/status");
in_root($root);
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });
is($res->{status}, 'unsupported', 'no dpkg status on a running system is unsupported, not ok');

in_root($root, 'stopped');
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });
is($res->{status}, 'stopped', 'no dpkg status in a stopped root is stopped (an unmounted dataset looks like that)');

put($root, 'var/lib/dpkg/status', '');
in_root($root);
$res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });
is($res->{status}, 'error', 'an empty dpkg status is never ok');

# ── the time limit ──────────────────────────────────────────────────────────

$root = debian();
in_root($root);
my $pidfile = "$tmp/child.pid";
my $sleeper = sub {
    my ($ignore_term) = @_;
    return sub {
        $SIG{TERM} = 'IGNORE' if $ignore_term;
        open(my $fh, '>', $pidfile) or die $!;
        print $fh $$;
        close($fh);
        sleep(30);
    };
};
sub child_pid { open(my $fh, '<', $pidfile) or return undef; my $p = <$fh>; return $p; }

{
    local $PVE::UpdateManager::SecRead::CHILD_HOOK = $sleeper->(0);
    ($res, $took) = timed($NODE, { timeout => 1 });
}
my $pid = child_pid();
ok(defined($pid), 'premise: the reader started and hung');
is($res->{status}, 'timeout', 'a reader that hangs ends as timeout');
cmp_ok($took, '<', 1 + 0.5 + 0.5, "the call returns within the limit plus the reap grace (took ${took}s)");
ok(!alive($pid), 'the hung reader was killed and reaped');
is_deeply(\%PVE::UpdateManager::SecRead::STUCK, {}, '... so nothing is left as stuck');

# A reader the kill does not end - in production one in state D, which not
# even SIGKILL ends (#36 V9); here one that ignores the signal it gets.
unlink($pidfile);
{
    local $PVE::UpdateManager::SecRead::KILL_SIGNAL = 'TERM';
    local $PVE::UpdateManager::SecRead::CHILD_HOOK = $sleeper->(1);
    ($res, $took) = timed($NODE, { timeout => 1 });
}
$pid = child_pid();
ok(defined($pid) && alive($pid), 'premise: the reader survived the kill');
is($res->{status}, 'timeout', 'an unkillable reader still ends as timeout');
cmp_ok($took, '<', 2.5, "the parent does not wait for it (took ${took}s)");
like($res->{reason}, qr/left behind/, '... and the reason says it was left behind');
is($PVE::UpdateManager::SecRead::STUCK{'node:pve-test'}, $pid, 'the reader is remembered as stuck');
# %STUCK ends with this process; the scan calls this from a fresh child per
# target, so the pid has to reach the caller to be remembered across rounds.
is($res->{stuck}, $pid, 'and the result hands its pid to the caller');

unlink($pidfile);
{
    # A second reader, if one were started, would leave its pid file.
    local $PVE::UpdateManager::SecRead::CHILD_HOOK = $sleeper->(0);
    ($res, $took) = timed($NODE, { timeout => 1 });
}
is($res->{status}, 'timeout', 'the next round for that target is timeout again');
like($res->{reason}, qr/still running - no second one/, '... because the old reader is still there');
cmp_ok($took, '<', 0.3, '... decided at once');
ok(!-e $pidfile && alive($pid), 'no second reader was started');

kill('KILL', $pid);
waitpid($pid, 0);
($res) = timed($NODE, { timeout => 10 });
is($res->{status}, 'ok', 'once the old reader is gone, the target is read again');
is_deeply(\%PVE::UpdateManager::SecRead::STUCK, {}, '... and is no longer stuck');

# A reader that dies half way leaves no end record.
{
    local $PVE::UpdateManager::SecRead::CHILD_HOOK = sub { POSIX::_exit(0) };
    $res = PVE::UpdateManager::SecRead::read_target($NODE, { timeout => 10 });
}
is($res->{status}, 'error', 'a reader that ends without its end record is an error');
like($res->{reason}, qr/without finishing/, '... saying so');

# ── where a target is read from ─────────────────────────────────────────────

$PVE::UpdateManager::SecRead::ROOT_OF = \&PVE::UpdateManager::SecRead::_root_of;

is(PVE::UpdateManager::SecRead::read_target({ type => 'lxc', id => '1; rm' })->{status}, 'error', 'a malformed vmid is refused');
is(PVE::UpdateManager::SecRead::read_target({ type => 'disk', id => 101 })->{status}, 'error', 'an unknown type is refused');

$res = PVE::UpdateManager::SecRead::read_target({ type => 'node', id => 'other' }, { timeout => 10 });
is($res->{status}, 'error', 'another node is not read');

$PVE::LXC::RUNNING{101} = 1;
$PVE::LXC::PID{101} = $$;
my ($how, $dir, $keep) = PVE::UpdateManager::SecRead::_root_of({ type => 'lxc', id => 101 });
is($how, 'root', 'a running container is read through a root directory');
like($dir, qr{\A/proc/self/fd/(\d+)/root\z}, '... through the pid descriptor, not the pid number');
is(abs_path("/proc/self/fd/" . fileno($keep)), "/proc/$$", '... which is the container init found by open_lxc_pid');

$PVE::LXC::RUNNING{102} = 0;
$PVE::Storage::PATH{'teststore:subvol-102-disk-0'} = $tmp;
($how, $dir, $keep, my $mode) = PVE::UpdateManager::SecRead::_root_of({ type => 'lxc', id => 102 });
is_deeply([$how, $dir, $mode], ['root', $tmp, 'stopped'], 'a stopped container on a directory is read there, marked stopped');

$PVE::Storage::PATH{'teststore:subvol-103-disk-0'} = '/dev/null';
($how, my $st) = PVE::UpdateManager::SecRead::_root_of({ type => 'lxc', id => 103 });
is_deeply([$how, $st], ['status', 'stopped'], 'a stopped container on a block device is stopped, never mounted');

($how, $st) = PVE::UpdateManager::SecRead::_root_of({ type => 'qemu', id => 9001 });
is_deeply([$how, $st], ['status', 'stopped'], 'a stopped VM is stopped');

# ── a VM through its agent ──────────────────────────────────────────────────

$PVE::QemuServer::Helpers::RUNNING{9001} = 1;

sub fake_agent {
    my (%o) = @_;
    my %files = %{ $o{files} };
    my %open;
    my $next = 7;
    return sub {
        my ($vmid, $cmd, %a) = @_;
        die "got timeout\n" if $o{dead};
        return {} if $cmd eq 'guest-ping';
        return { id => $o{os} // 'ubuntu' } if $cmd eq 'guest-get-osinfo';
        if ($cmd eq 'guest-file-open') {
            return { error => { desc => "failed to open file '$a{path}' (mode: 'r'): No such file or directory" } }
                if !exists($files{ $a{path} });
            $open{$next} = { data => $files{ $a{path} }, pos => 0 };
            return $next++;
        }
        if ($cmd eq 'guest-file-read') {
            my $h = $open{ $a{handle} };
            my $chunk = substr($h->{data}, $h->{pos}, $a{count});
            $h->{pos} += length($chunk);
            return { count => length($chunk), 'buf-b64' => encode_base64($chunk, ''), eof => $h->{pos} >= length($h->{data}) ? JSON::PP::true : JSON::PP::false };
        }
        return {} if $cmd eq 'guest-file-close' && delete($open{ $a{handle} });
        die "unexpected $cmd\n";
    };
}

my $VM = { type => 'qemu', id => 9001 };
$PVE::QemuServer::Monitor::HANDLER = fake_agent(files => {
    '/etc/os-release' => "ID=ubuntu\nVERSION_CODENAME=noble\n",
    '/var/lib/dpkg/status' => $STATUS,
    '/etc/apt/sources.list.d/ubuntu.sources' => '',      # what a FIFO reads as (#36 V3)
});
{
    local $PVE::UpdateManager::SecReadVM::AGENT_CHUNK = 16;    # several reads per file
    $res = PVE::UpdateManager::SecRead::read_target($VM, { timeout => 10 });
}
is($res->{status}, 'ok', 'a VM with an agent and a dpkg status is ok') or diag(explain($res));
is($res->{files}->{'/var/lib/dpkg/status'}, $STATUS, 'the dpkg status arrives whole across several reads');
is_deeply($res->{os}, { id => 'ubuntu', version_codename => 'noble' }, 'os-release is read from the VM too');
is($res->{skipped}->{'/etc/apt/sources.list.d/ubuntu.sources'}, '0 bytes read - not usable', '0 bytes through the agent is not content');
ok(!exists($res->{files}->{'/etc/apt/sources.list'}) && !exists($res->{skipped}->{'/etc/apt/sources.list'}), 'a missing file in the VM is simply absent');
is_deeply($res->{unlisted}, ['/etc/apt/sources.list.d', '/etc/apt/apt.conf.d'], 'the two directories are reported as not listed');

$res = PVE::UpdateManager::SecRead::read_target($VM, { timeout => 10, max_file => 20 });
like($res->{skipped}->{'/var/lib/dpkg/status'}, qr/more than the 20 bytes/, 'a VM file over max_file is refused');

$PVE::QemuServer::Monitor::HANDLER = fake_agent(files => {}, os => 'mswindows');
$res = PVE::UpdateManager::SecRead::read_target($VM, { timeout => 10 });
is($res->{status}, 'unsupported', 'a Windows guest is unsupported');
like($res->{reason}, qr/Windows/, '... recognised by its agent, not by a missing file');

$PVE::QemuServer::Monitor::HANDLER = fake_agent(files => {}, dead => 1);
is(PVE::UpdateManager::SecRead::read_target($VM, { timeout => 10 })->{status}, 'no-agent', 'a VM whose agent does not answer is no-agent');

# ── a real chroot ───────────────────────────────────────────────────────────
#
# An absolute symlink in the target pointing at a file the node has too. With
# the chroot it reads the target's copy; without it, the node's (#36 V1). And a
# module planted inside the root, which a `require` after the chroot would load
# and run - it must not, because @INC is emptied.

SKIP: {
    my $why = qx(unshare -r true 2>&1);
    if ($? != 0) {
        chomp($why);
        diag("SKIP: unshare -r failed here ($why) - the real chroot is NOT tested in this run");
        skip('no unprivileged user namespace', 5);
    }

    # The symlink target exists twice: on the node at $outside, and inside the
    # target at the same absolute path. Which copy is read says which root the
    # kernel resolved it in.
    $root = debian();
    unlink("$root/etc/apt/sources.list");
    my $outside = put($tmp, 'outside/marker-file', "ON THE NODE\n");
    put($root, substr($outside, 1), "inside the target\n");
    symlink($outside, "$root/etc/apt/sources.list") or die $!;
    put($root, "$_/SecReadPlanted.pm", "open(my \$f, '>', '/planted-ran'); 1;\n")
        for grep { m{\A/} } @INC;

    my @inc = map { ('-I', abs_path($_)) } grep { -d $_ && !m{\A/} } @INC;
    my $code = <<'EOS';
use JSON::PP;
use PVE::UpdateManager::SecRead;
my $root = shift;
$PVE::UpdateManager::SecRead::ROOT_OF = sub { return ('root', $root) };
$PVE::UpdateManager::SecRead::CHILD_HOOK = sub { eval { require SecReadPlanted } };
my $res = PVE::UpdateManager::SecRead::read_target({ type => 'node', id => 'pve-test' }, { timeout => 10 });
print JSON::PP->new->canonical->encode($res);
EOS
    open(my $ph, '-|', 'unshare', '-r', 'perl', @inc, '-e', $code, $root) or die "unshare: $!";
    my $out = do { local $/; <$ph> };
    close($ph);
    is($?, 0, 'premise: the helper under unshare exited 0');
    my $real = eval { decode_json($out) } // {};
    is($real->{status}, 'ok', 'premise: the read under a real chroot went through') or diag($out);
    is($real->{files}->{'/etc/apt/sources.list'}, "inside the target\n", 'an absolute symlink reads the TARGET file, not the node one');
    is($real->{files}->{'/etc/os-release'}, "PRETTY_NAME=\"Debian\"\nID=debian\nVERSION_CODENAME=trixie\n", 'a relative one still works');
    ok(!-e "$root/planted-ran", 'a module planted in the target is never loaded');
}
