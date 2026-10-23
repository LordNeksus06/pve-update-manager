package PVE::UpdateManager::SecFetch;

# Fetching the security indices the targets have configured, once per source
# (#37).
#
# apt does the fetching and the checking. PVE 9.2.4 has no gpgv; apt 3.0.3
# verifies with sqv (#36), and with it come the Valid-Until check, the hash of
# every index against InRelease, decompression and the proxy logic. Rebuilding
# any of that here would be a second, weaker copy. So each source gets an
# `apt-get update` with a configuration that points EVERY directory apt reads
# or writes into a directory of its own: the node's sources, lists, cache,
# dpkg status, apt.conf.d (with its Post-Invoke hooks) are never read or
# touched. The result is the verified Packages files apt leaves behind.
#
# One apt-get per source, not one for all: a source that hangs or fails then
# costs only the targets that configured it (#35), and its lists directory is
# its own, so one source's failure cannot roll back another's files.

use strict;
use warnings;

use Cwd ();
use Digest::SHA qw(sha256_hex);
use Fcntl qw(S_ISREG O_WRONLY O_CREAT O_TRUNC);
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

use PVE::UpdateManager::SecCompare;
use PVE::UpdateManager::SecSources;

# Variables so the tests can put a fake apt-get in its place: the stubbed
# run_command of tests/stubs only records, and the process-group handling
# below is the part that has to be exercised for real.
our $APT_GET = '/usr/bin/apt-get';
# Lowest CPU and I/O priority (#35 item 7): a fetch round is background work
# on a hypervisor whose guests come first.
our @NICE = ('/usr/bin/ionice', '-c', '3', '/usr/bin/nice', '-n', '19');

# Where a Signed-By path may point. A guest names a key file; the node uses
# its own file of that name, and only from a directory that holds keyrings -
# otherwise "Signed-By: /etc/shadow" would make apt parse a node file.
our @KEYRING_DIRS = ('/usr/share/keyrings', '/etc/apt/keyrings', '/etc/apt/trusted.gpg.d');

# InRelease of trixie-security is 43 409 B, noble-security's is larger but
# far below this (#36). apt refuses a bigger Release file before reading it.
our $MAX_RELEASE = 4 * 1024 * 1024;
our $MAX_PARALLEL = 16;
# Seconds between SIGTERM and SIGKILL to the job's process group, and how long
# a killed job is waited for before it is left behind: a process in state D
# does not die even of SIGKILL (#36 V9), and the round must not wait for it.
our $KILL_GRACE = 2;
our $REAP_WAIT = 5;
# Exit code of a child that refused its source before starting apt.
my $RC_REFUSED = 3;

sub _host_of {
    my ($uri) = @_;
    my ($auth) = ($uri // '') =~ m{\A[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*)};
    return undef if !defined($auth);
    $auth =~ s/:\d+\z//;
    $auth =~ s/\A\[(.*)\]\z/$1/;
    return lc($auth);
}

# The proxy apt would use for this job's address, from the guest's settings:
# the per-host entry first, then the scheme's own, and for https the http one,
# because apt falls back to Acquire::http::Proxy for https (measured on apt
# 3.0.3). undef is a direct connection.
sub effective_proxy {
    my ($job) = @_;

    my $p = $job->{proxy} // {};
    my $host = _host_of($job->{uri});
    my ($scheme) = ($job->{uri} // '') =~ m{\A(https?)://}i;
    my $val;
    if (defined($host) && exists($p->{hosts}->{$host})) {
        $val = $p->{hosts}->{$host};
    } elsif (defined($scheme) && lc($scheme) eq 'https') {
        $val = $p->{https} // $p->{http};
    } else {
        $val = $p->{http};
    }

    return undef if !defined($val) || $val eq '' || $val eq 'DIRECT';
    return $val;
}

# One key per (address, suite, key file, effective proxy). The components are
# not part of it: two targets that use main and main+non-free-firmware of the
# same source share one fetch of the union, rather than two fetches of one
# InRelease. Same for two different proxy maps that resolve to the same proxy.
sub job_key {
    my ($job) = @_;

    my $uri = PVE::UpdateManager::SecSources::_norm_uri($job->{uri}) // $job->{uri} // '';
    my @t = ($uri, $job->{suite} // '', $job->{signed_by} // '', effective_proxy($job) // '');

    # Untainted here, and only here: the key names a directory, and pvedaemon
    # runs with -T, where a digest of a guest's data is as tainted as the data.
    # Measured on PVE 9.2.4: "Insecure dependency in mkdir while running with -T"
    # for every source, which pvesh (no -T) never showed. 32 hex digits are
    # safe in a path whatever went into them.
    my ($key) = substr(sha256_hex(join("\0", @t)), 0, 32) =~ m/\A([0-9a-f]{32})\z/;

    return $key;
}

# ── checks done before anything starts ──────────────────────────────────────

# The node's own file for each Signed-By path, or an error sentence.
sub _key_files {
    my ($signed_by) = @_;

    my @out;
    for my $p (split(/,/, $signed_by)) {
        my ($dir) = grep { index($p, "$_/") == 0 } @KEYRING_DIRS;
        return (undef, "signing key $p is not in a keyring directory of this node") if !defined($dir);
        return (undef, "signing key $p is not on this node") if !-e $p;
        # A symlink is followed only to a file in a keyring directory too: the
        # Debian keyrings are links to the .pgp beside them, a link elsewhere is
        # not a keyring.
        my $real = Cwd::realpath($p);
        return (undef, "signing key $p is not a file in a keyring directory")
            if !defined($real) || !-f $real || !grep { index($real, "$_/") == 0 } @KEYRING_DIRS;
        push @out, $real;
    }

    return (\@out, undef);
}

sub _precheck {
    my ($job) = @_;

    my $uri = PVE::UpdateManager::SecSources::_norm_uri($job->{uri});
    return 'not a usable address' if !defined($uri) || $uri !~ m{\Ahttps?://};
    return 'not a usable suite' if !PVE::UpdateManager::SecSources::_valid_suite($job->{suite});
    return 'not a security suite, not fetched' if !PVE::UpdateManager::SecSources::is_security_suite($job->{suite});
    my @comps = @{ $job->{components} // [] };
    return 'no usable component'
        if !@comps || grep { !PVE::UpdateManager::SecSources::_valid_component($_) } @comps;
    my $proxy = effective_proxy($job);
    return 'not a usable proxy address'
        if defined($proxy) && !defined(PVE::UpdateManager::SecSources::_norm_uri($proxy));

    return undef;
}

# ── the private apt configuration ───────────────────────────────────────────

sub _write {
    my ($path, $text, $mode) = @_;
    open(my $fh, '>', "$path.tmp") or die "cannot write $path.tmp: $!\n";
    # chmod on the handle before anything is written: a mode set after the
    # rename would leave the content readable for as long as that takes.
    if (defined($mode)) {
        chmod($mode, $fh) or die "cannot restrict $path.tmp: $!\n";
    }
    print {$fh} $text or die "cannot write $path.tmp: $!\n";
    close($fh) or die "cannot write $path.tmp: $!\n";
    rename("$path.tmp", $path) or die "cannot rename $path.tmp: $!\n";
}

sub _prepare {
    my ($dir, $job, $keys, $timeout) = @_;

    # 0755 all the way: apt downloads as the unprivileged _apt user and needs
    # to reach lists/partial. A 0700 directory makes it fall back to fetching
    # as root, with a warning.
    make_path("$dir/empty", "$dir/lists/partial", "$dir/cache/archives/partial", "$dir/log", { mode => 0755 });
    _write("$dir/empty.conf", '');
    _write("$dir/status", '');

    # Without Signed-By apt checks against the node's /etc/apt/trusted.gpg.d,
    # as it would for the node's own sources: Dir::Etc is left alone for that.
    # On PVE 9.2.4 that holds the Debian and Proxmox keys and no Ubuntu key.
    my $opts = @$keys ? '[signed-by=' . join(',', @$keys) . '] ' : '';
    # 0600 like apt.conf (#67): the address is the guest's as written, and a
    # user:password in it is refused only later, by the child.
    _write("$dir/sources.list", "deb $opts$job->{uri} $job->{suite} " . join(' ', @{ $job->{components} }) . "\n", 0600);

    my $t = int($timeout) > 0 ? int($timeout) : 1;
    my @c = (
        # Every directory apt reads configuration or state from, so nothing of
        # the node's apt setup takes part - not its sources, not its proxy,
        # not the Post-Invoke hooks in its apt.conf.d.
        qq{Dir::Etc::SourceList "$dir/sources.list";},
        qq{Dir::Etc::SourceParts "$dir/empty";},
        qq{Dir::Etc::Parts "$dir/empty";},
        qq{Dir::Etc::main "$dir/empty.conf";},
        qq{Dir::Etc::Preferences "$dir/empty.conf";},
        qq{Dir::Etc::PreferencesParts "$dir/empty";},
        # Credentials too (#54): left alone these are the node's
        # /etc/apt/auth.conf and auth.conf.d, and the node's login for a host
        # would be used on a fetch a guest asked for.
        qq{Dir::Etc::netrc "$dir/empty.conf";},
        qq{Dir::Etc::netrcparts "$dir/empty";},
        qq{Dir::State "$dir";},
        qq{Dir::State::Lists "$dir/lists";},
        qq{Dir::State::status "$dir/status";},
        qq{Dir::State::extended_states "$dir/extended_states";},
        qq{Dir::Cache "$dir/cache";},
        qq{Dir::Cache::pkgcache "";},
        qq{Dir::Cache::srcpkgcache "";},
        qq{Dir::Log "$dir/log";},
        # Packages only: no translations, no pdiff chains, no retry.
        qq{Acquire::Languages "none";},
        qq{Acquire::PDiffs "false";},
        qq{Acquire::Retries "0";},
        # A redirect would be a second address that uri_allowed never saw.
        qq{Acquire::http::AllowRedirect "false";},
        qq{Acquire::https::AllowRedirect "false";},
        qq{Acquire::http::Timeout "$t";},
        qq{Acquire::https::Timeout "$t";},
        qq{Acquire::MaxReleaseFileSize "$MAX_RELEASE";},
    );
    my $proxy = effective_proxy($job);
    push @c, qq{Acquire::http::Proxy "$proxy";}, qq{Acquire::https::Proxy "$proxy";} if defined($proxy);
    # 0600 although the directory around it is 0755 for _apt: the proxy is the
    # guest's and may carry its password (#67). apt-get reads this file as
    # root and hands its methods the configuration through their pipe.
    _write("$dir/apt.conf", join("\n", @c) . "\n", 0600);
}

# ── running ─────────────────────────────────────────────────────────────────

sub _start {
    my ($dir, $job) = @_;

    my $pid = fork();
    die "fork failed: $!\n" if !defined($pid);
    return $pid if $pid;

    # The child. Its own process group, so a timeout kills apt AND its
    # methods: run_command's timeout kills only the direct child, and on
    # PVE 9.2 a grandchild was measured to outlive it (Runner.pm).
    eval {
        setpgrp(0, 0);
        open(STDIN, '<', '/dev/null');
        # Guest addresses and apt's messages, private like the rest of the
        # scan's data (#67). Created 0600 rather than a umask for the child:
        # that would reach apt and its _apt download methods as well, which
        # was not measured. chmod for a log an older version left 0644.
        sysopen(my $log, "$dir/apt.log", O_WRONLY | O_CREAT | O_TRUNC, 0600) or POSIX::_exit(126);
        chmod(0600, $log);
        open(STDOUT, '>&', $log) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);

        # The address check resolves names, and DNS can hang: it runs here,
        # inside the job's own time limit, not in the round.
        for my $u ($job->{uri}, effective_proxy($job)) {
            next if !defined($u);
            my ($ok, $why) = PVE::UpdateManager::SecSources::uri_allowed($u);
            next if $ok;
            _write("$dir/refused", ($u eq $job->{uri} ? '' : 'proxy ') . $why);
            POSIX::_exit($RC_REFUSED);
        }

        # A clean environment: no http_proxy of the node, no APT_CONFIG but ours.
        %ENV = (PATH => '/usr/sbin:/usr/bin:/sbin:/bin', LC_ALL => 'C', APT_CONFIG => "$dir/apt.conf");
        exec(@NICE, $APT_GET, '-q', '--error-on=any', 'update');
    };
    POSIX::_exit(127);
}

sub _kill_group {
    my ($sig, $pid) = @_;
    kill($sig, -$pid);
}

# The first E: line of apt's output as the reason, cleaned of anything that is
# not printable: part of it is a server's answer.
sub _apt_error {
    my ($dir, $rc) = @_;

    my $text = '';
    if (open(my $fh, '<', "$dir/apt.log")) {
        read($fh, $text, 65536);
        close($fh);
    }
    my ($e) = $text =~ m/^E: (.+)$/m;
    ($e) = $text =~ m/^W: (.+)$/m if !defined($e);
    return "apt-get exited with $rc" if !defined($e);
    $e =~ s/[^\x20-\x7e]/?/g;
    return substr($e, 0, 300);
}

# What the Release file of the lists directory says, and the Packages files
# beside it. Read whether this run succeeded or not: after a failed run apt
# leaves the last verified set in place, and the caller keeps showing that
# with its date instead of dropping every target to "unknown" (#37).
sub _read_lists {
    my ($dir, $res) = @_;

    my $lists = "$dir/lists";
    opendir(my $dh, $lists) or return;
    my @names = sort grep { m/\A[A-Za-z0-9._~%+-]+\z/ } readdir($dh);
    closedir($dh);

    my ($rel) = grep { m/_InRelease\z/ } @names;
    ($rel) = grep { m/_Release\z/ } @names if !defined($rel);
    if (defined($rel)) {
        my @st = lstat("$lists/$rel");
        if (@st && S_ISREG($st[2]) && $st[7] <= $MAX_RELEASE && open(my $fh, '<', "$lists/$rel")) {
            local $/;
            my $text = <$fh> // '';
            close($fh);
            # Clearsigned: the fields start after the first empty line.
            $text =~ s/\A-----BEGIN PGP SIGNED MESSAGE-----\n.*?\n\n//s;
            my ($f) = @{ PVE::UpdateManager::SecCompare::parse_stanzas($text, [qw(Origin Label Suite Codename Date)]) };
            for my $k (qw(Origin Label Suite Codename Date)) {
                my $v = $f->{$k};
                $res->{ lc($k) } = defined($v) && $v =~ m/\A[\x20-\x7e]{1,256}\z/ ? $v : undef;
            }
        }
    }

    for my $n (grep { m/_Packages\z/ } @names) {
        my @st = lstat("$lists/$n");
        push @{ $res->{packages} }, "$lists/$n" if @st && S_ISREG($st[2]);
    }

    # By content, not by address (#37 item 5, #36 V7): Debian labels its
    # security archive, Ubuntu's carries the plain "Ubuntu" label and is told
    # apart by its suite.
    my ($o, $l, $s) = @{$res}{qw(origin label suite)};
    $res->{is_security} = (defined($l) && $l eq 'Debian-Security')
        || (defined($o) && $o eq 'Ubuntu' && defined($s) && $s =~ m/-security\z/) ? 1 : 0;
}

# fetch(\@jobs, \%opts) -> { job_key($job) => { origin, label, suite, codename,
# date, packages => [absolute paths], is_security => 0|1, error => sentence or
# undef } }.
#
# A job is { uri, suite, components => [...], signed_by, proxy => what
# SecSources::parse_proxy returned for the target }. opts: state_dir, timeout
# (seconds per job), parallel, deadline (epoch seconds for the whole call).
# Never dies for one bad job; dies only when the state directory itself cannot
# be used.
sub fetch {
    my ($jobs, $opts) = @_;

    my $state = $opts->{state_dir} // die "state_dir is required\n";
    die "state_dir must be an absolute path\n" if $state !~ m{\A/};
    my $timeout = $opts->{timeout} // 120;
    my $parallel = $opts->{parallel} // 4;
    $parallel = 1 if $parallel < 1;
    $parallel = $MAX_PARALLEL if $parallel > $MAX_PARALLEL;
    my $deadline = $opts->{deadline} // (time() + 3600);
    make_path($state, { mode => 0755 });
    die "state_dir $state is not a directory\n" if !-d $state || -l $state;

    # One work item per key, components merged.
    my (%items, @order);
    for my $j (@$jobs) {
        my $k = job_key($j);
        if (!$items{$k}) {
            $items{$k} = { job => { %$j, components => [] }, comps => {} };
            push @order, $k;
        }
        $items{$k}->{comps}->{$_} = 1 for @{ $j->{components} // [] };
    }

    my %res;
    my @queue;
    for my $k (@order) {
        my $it = $items{$k};
        my $job = $it->{job};
        $job->{components} = [sort keys %{ $it->{comps} }];
        $job->{uri} = PVE::UpdateManager::SecSources::_norm_uri($job->{uri}) // $job->{uri};
        $res{$k} = { origin => undef, label => undef, suite => undef, codename => undef, date => undef,
            packages => [], is_security => 0, error => undef };

        my $err = _precheck($job);
        my $keys = [];
        if (!defined($err) && defined($job->{signed_by})) {
            ($keys, $err) = _key_files($job->{signed_by});
        }
        my $dir = "$state/$k";
        if (defined($err)) {
            $res{$k}->{error} = $err;
            _read_lists($dir, $res{$k}) if -d $dir;
            next;
        }
        eval { _prepare($dir, $job, $keys, $timeout) };
        if ($@) {
            chomp(my $e = $@);
            $res{$k}->{error} = $e;
            next;
        }
        unlink("$dir/refused");
        push @queue, { key => $k, dir => $dir, job => $job };
    }

    my @running;
    while (@queue || @running) {
        my $now = time();
        while (@queue && @running < $parallel && $now < $deadline) {
            my $it = shift @queue;
            $it->{pid} = _start($it->{dir}, $it->{job});
            $it->{by_deadline} = $now + $timeout >= $deadline ? 1 : 0;
            $it->{end} = $it->{by_deadline} ? $deadline : $now + $timeout;
            push @running, $it;
        }
        last if !@running && (!@queue || $now >= $deadline);

        my @still;
        for my $it (@running) {
            my $w = waitpid($it->{pid}, WNOHANG);
            if ($w == $it->{pid} || $w == -1) {
                # -1: somebody else reaped it (a caller with SIGCHLD ignored).
                my $rc = $w == -1 ? -1 : $? & 127 ? 128 + ($? & 127) : $? >> 8;
                # A group leader that is gone may leave methods behind.
                _kill_group('KILL', $it->{pid});
                $it->{rc} = $rc;
                next;
            }
            if (!$it->{term} && $now >= $it->{end}) {
                _kill_group('TERM', $it->{pid});
                $it->{term} = $now;
            } elsif ($it->{term} && !$it->{killed} && $now >= $it->{term} + $KILL_GRACE) {
                _kill_group('KILL', $it->{pid});
                $it->{killed} = $now;
            } elsif ($it->{killed} && $now >= $it->{killed} + $REAP_WAIT) {
                $it->{abandoned} = 1;
                next;
            }
            push @still, $it;
        }
        my %gone = map { $_->{pid} => $_ } grep { defined($_->{rc}) || $_->{abandoned} } @running;
        for my $it (values %gone) {
            my $r = $res{ $it->{key} };
            if ($it->{abandoned}) {
                $r->{error} = "did not end after SIGKILL, left behind (pid $it->{pid})";
            } elsif ($it->{term}) {
                $r->{error} = $it->{by_deadline} ? 'stopped at the deadline of the round' : "timed out after $timeout s";
            } elsif ($it->{rc} == $RC_REFUSED && open(my $fh, '<', "$it->{dir}/refused")) {
                my $why = <$fh> // '';
                close($fh);
                $r->{error} = "not fetched: $why";
            } elsif ($it->{rc} != 0) {
                $r->{error} = _apt_error($it->{dir}, $it->{rc});
            }
            _read_lists($it->{dir}, $r);
        }
        @running = @still;
        sleep(0.05) if @running;
    }

    for my $it (@queue) {
        $res{ $it->{key} }->{error} = 'not started before the deadline of the round';
        _read_lists($it->{dir}, $res{ $it->{key} });
    }

    return \%res;
}

1;
