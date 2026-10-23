package PVE::UpdateManager::SecScan;

# One security check round over a node's targets (#40): when one is due, the
# lock that keeps two from overlapping, the worker pool that reads and compares
# the targets, and where the results are kept.
#
# The owner's requirement for all of it, verbatim (#35): "das alles non
# blocking sein muss und das wenn sich was aufhängt das proxmox webui noch
# funktionieren muss". What follows from it here:
#
#   * a round runs only in a background worker task, never in an API call - the
#     API reads the files this writes. pvedaemon and pveproxy have three workers
#     each (#36 V8), so three API calls waiting on a guest are a dead web UI;
#   * every target is handled in its own child process with its own deadline,
#     and the parent never waits for a child past that deadline - a reader stuck
#     in the kernel cannot be killed at all (#36 V9), so it is left behind and
#     reaped later instead of waited for;
#   * the whole round has a deadline too, and stops cleanly at it with what it
#     has; a round that outlives its interval does not get a second one started
#     on top of it - the lock below;
#   * results go to /var/lib on this node and one small summary per node to
#     /etc/pve, written only when it changed.

use strict;
use warnings;

use Digest::SHA ();
use Fcntl qw(:flock O_RDWR O_CREAT);
use File::Path ();
use JSON::PP ();
use POSIX ();
use Time::HiRes ();

use PVE::Tools;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;
use PVE::UpdateManager::SecCompare;
use PVE::UpdateManager::SecJobs;
use PVE::UpdateManager::SecPool;
use PVE::UpdateManager::SecSummary;
use PVE::UpdateManager::SecUtil;

our $STATE_DIR = '/var/lib/pve-update-manager/security';

# Per target, for reading AND comparing. The slowest measured read was a VM
# through its guest agent, about 1.2 s for a 781 KB status file (#36 V3); a
# guest agent that does not answer costs exactly its own command limit of 10 s
# (#36 V10). A minute leaves room for both and for a slow disk.
our $TARGET_TIMEOUT = 60;

# What a target may hand over. The largest status file measured was 781 KB; a
# node with many packages reaches a few MB. Above this a target is "not
# checkable", not a reason to fill the memory of a hypervisor.
our $MAX_FILE = 16 * 1024 * 1024;
our $MAX_TOTAL = 24 * 1024 * 1024;


# The other parts of the scan, called through this table and nothing else: the
# reader (#38), the sources and lists (#37), the severity data (#44). Tests
# replace entries; the defaults are filled in by _default_hooks once those
# modules exist, so a missing one is a clear error and not a half-run round.
our %HOOK;

sub _hook {
    my ($name) = @_;

    my $code = $HOOK{$name} // _default_hooks()->{$name}
        or die "security scan: no implementation for '$name'\n";

    return $code;
}

sub _default_hooks {
    my %h;

    $h{now} = sub { time() };

    if (eval { require PVE::UpdateManager::SecRead; 1 }) {
        $h{read_target} = \&PVE::UpdateManager::SecRead::read_target;
    }
    if (eval { require PVE::UpdateManager::SecSources; 1 }) {
        $h{parse_sources} = \&PVE::UpdateManager::SecSources::parse_sources;
        $h{parse_proxy} = \&PVE::UpdateManager::SecSources::parse_proxy;
        $h{is_security_suite} = \&PVE::UpdateManager::SecSources::is_security_suite;
    }
    if (eval { require PVE::UpdateManager::SecFetch; 1 }) {
        $h{fetch} = \&PVE::UpdateManager::SecFetch::fetch;
        $h{job_key} = \&PVE::UpdateManager::SecFetch::job_key;
    }
    if (eval { require PVE::UpdateManager::SecProbe; 1 }) {
        $h{probe} = \&PVE::UpdateManager::SecProbe::probe;
    }
    if (eval { require PVE::UpdateManager::SecSeverity; 1 }) {
        $h{severity_refresh} = \&PVE::UpdateManager::SecSeverity::refresh;
        $h{severity_lookup} = \&PVE::UpdateManager::SecSeverity::lookup;
    }

    return \%h;
}

# ── where things are kept ───────────────────────────────────────────────────

sub _key {
    my ($t) = @_;

    my ($type) = ($t->{type} // '') =~ m/\A(lxc|qemu|node)\z/ or die "invalid target type\n";
    my ($id) = ($t->{id} // '') =~ m/\A([A-Za-z0-9][A-Za-z0-9.-]{0,62})\z/ or die "invalid target id\n";

    return "$type-$id";
}

sub result_file {
    my ($t) = @_;

    return "$STATE_DIR/results/" . _key($t) . '.json';
}

sub _state_file { "$STATE_DIR/scan.state" }
sub _lock_file { "$STATE_DIR/scan.lock" }

# Root's alone, what a round keeps about a guest (#67) - see SecUtil::private_dir.
my ($PRIVATE_DIR_MODE, $PRIVATE_FILE_MODE) = (0700, 0600);

sub _read_json {
    my ($file, $max) = @_;

    my $raw = eval { PVE::Tools::file_get_contents($file, $max // 4 * 1024 * 1024) };
    return undef if !defined($raw);

    my $data = eval { JSON::PP->new->utf8->decode($raw) };

    return ref($data) eq 'HASH' ? $data : undef;
}

sub _write_json {
    my ($file, $data) = @_;

    my ($dir) = $file =~ m{\A(.*)/[^/]+\z};
    File::Path::make_path($dir, { mode => $PRIVATE_DIR_MODE }) if !-d $dir;

    # file_set_contents writes a temporary file and renames it, so a reader
    # never sees half a result.
    PVE::Tools::file_set_contents($file, JSON::PP->new->utf8->canonical->encode($data), $PRIVATE_FILE_MODE);
}

sub load_state { _read_json(_state_file()) // {} }

sub load_result {
    my ($t) = @_;

    return _read_json(result_file($t));
}

# ── when a round is due ─────────────────────────────────────────────────────

sub is_due {
    my ($settings, $now) = @_;

    return 0 if !$settings->{security_scan};

    $now //= time();
    my $last = load_state()->{last_scan} // 0;

    return $now - $last >= 60 * ($settings->{security_interval} // 30) ? 1 : 0;
}

# Is a round running right now? Asked by the timer before it starts a task,
# so a long round does not leave an empty "busy" task in the list every five
# minutes. Takes the lock without waiting and gives it back at once.
sub busy {
    sysopen(my $fh, _lock_file(), O_RDWR | O_CREAT, 0600) or return 0;
    my $free = flock($fh, LOCK_EX | LOCK_NB);
    close($fh);

    return $free ? 0 : 1;
}

# Changes a stored result outside a round - after an update run, which knows
# which pending packages it installed (#76). $fn gets the result as it is on
# disk NOW and returns the new one, or undef to leave it alone.
#
# Under the round's lock, and read inside it: a round that wrote a newer result
# between the run's verification and this call must not be overwritten with
# what the run saw before. Without waiting - a round holds the lock for
# minutes, and an update task should not sit there that long; a running round
# writes every target's result itself. The other way round costs one round at
# most: a round that finds the lock taken for these few milliseconds is
# skipped like any busy one, and the timer starts the next.
sub update_result {
    my ($t, $fn) = @_;

    my $file = result_file($t);
    return 'unchanged' if !-f $file;

    sysopen(my $lock, _lock_file(), O_RDWR | O_CREAT, 0600) or die "cannot open the scan lock: $!\n";
    if (!flock($lock, LOCK_EX | LOCK_NB)) {
        close($lock);
        return 'busy';
    }

    my $prev = load_result($t);
    my $next = $prev ? $fn->($prev) : undef;
    if ($next) {
        _write_json($file, $next);
        # The summary the UI reads, under the same lock a round writes it in.
        require PVE::INotify;
        PVE::UpdateManager::SecSummary::update_one(PVE::INotify::nodename(), $t, $next);
    }
    close($lock);

    return $next ? 'written' : 'unchanged';
}

# ── which targets ───────────────────────────────────────────────────────────

# Which targets a round checks - see SecUtil::collect_targets. A name of its
# own here because the tests replace it.
sub collect_targets { PVE::UpdateManager::SecUtil::collect_targets(@_) }

# ── one round ───────────────────────────────────────────────────────────────

# Pass 1, in a child per target: read its files (#38), keep its status file
# on disk for pass 2, and reduce its sources to the security suites it names
# (#37). Written to "$work/<key>/" - a status file can be megabytes, and ten
# thousand of them do not belong in the parent's memory.
sub _read_one {
    my ($t, $work, $settings, $stuck) = @_;

    my $dir = "$work/" . _key($t);
    File::Path::make_path($dir, { mode => $PRIVATE_DIR_MODE });

    # A reader an earlier round left behind - stuck in the kernel, where not
    # even SIGKILL ends it (#36 V9) - is still there: starting another one
    # would only add a second stuck process every round.
    if ($stuck && PVE::UpdateManager::SecUtil::alive($stuck->{pid}, $stuck->{start})) {
        _write_json("$dir/meta.json", { status => 'timeout', stuck => $stuck,
            reason => "the reader started in an earlier round (pid $stuck->{pid}) is still"
                . " running - no new one is started until it ends" });
        return;
    }

    my $r = _hook('read_target')->($t, {
        timeout => $TARGET_TIMEOUT - 5, max_file => $MAX_FILE, max_total => $MAX_TOTAL,
    });
    my $files = $r->{files} // {};
    my $meta = { status => $r->{status} // 'error', reason => $r->{reason}, os => $r->{os} // {} };
    $meta->{stuck} = { pid => $r->{stuck}, start => PVE::UpdateManager::SecUtil::start_time($r->{stuck}) } if $r->{stuck};

    if ($meta->{status} eq 'ok') {
        my $status = $files->{'/var/lib/dpkg/status'} // '';
        PVE::Tools::file_set_contents("$dir/status", $status, $PRIVATE_FILE_MODE);
        $meta->{status_sha} = Digest::SHA::sha256_hex($status);

        my %src = map { $_ => $files->{$_} } grep { m{\A/etc/apt/sources\.list} } keys %$files;
        my %conf = map { $_ => $files->{$_} } grep { m{\A/etc/apt/apt\.conf} } keys %$files;
        my ($entries) = _hook('parse_sources')->(\%src);
        my $proxy = _hook('parse_proxy')->(\%conf);

        $meta->{jobs} = PVE::UpdateManager::SecJobs::security_jobs($entries, lc($meta->{os}->{id} // ''),
            $proxy, $settings, _hook('is_security_suite'));
        # Kept for the severity download as well, which a guest without a
        # security source still takes part in (#49).
        $meta->{proxy} = $proxy;
    }

    _write_json("$dir/meta.json", $meta);
}

# Pass 2, in a child per target: compare (#39), rate (#44), write the result.
sub _compare_one {
    my ($t, $work, $ctx) = @_;

    my $dir = "$work/" . _key($t);
    my $meta = _read_json("$dir/meta.json");
    my $res = {
        type => $t->{type}, id => $t->{id}, name => $t->{name},
        checked => $ctx->{now}, pending => [],
    };

    if (!$meta) {
        _write_json(result_file($t), { %$res, status => 'timeout',
            reason => 'reading the target did not finish in time' });
        return;
    }
    $res->{os} = $meta->{os};
    if ($meta->{status} ne 'ok') {
        _write_json(result_file($t), { %$res, status => $meta->{status}, reason => $meta->{reason} });
        return;
    }

    my (@sec, @failed);
    for my $job (@{ $meta->{jobs} // [] }) {
        my $l = $ctx->{lists}->{ _hook('job_key')->($job) } // next;
        if ($l->{error}) { push @failed, "$job->{uri} $job->{suite}: $l->{error}"; next }
        push @sec, $l if $l->{is_security};
    }
    if (!@sec) {
        my $reason = @failed ? join('; ', @failed) : 'no security suite in the configured sources';
        _write_json(result_file($t), { %$res,
            status => @failed ? 'source-unreachable' : 'no-security-source', reason => $reason });
        return;
    }

    # Not part of the cached answer: a source can lose its packages while
    # its lists, and so the answer, stay the same (#53).
    my @gone = map { $_->{pool_error} // () } @sec;
    # Only where something is pending: with nothing to install, no run fails.
    my $warn = sub {
        my ($r) = @_;
        delete $r->{warning};
        $r->{warning} = join('; ', @gone) if @gone && @{ $r->{pending} // [] };
        return $r;
    };

    # The same status file against the same lists with the same filters gives
    # the same answer: nothing to compute when none of the four changed.
    my $cache = Digest::SHA::sha256_hex(join("\0", $meta->{status_sha},
        sort(map { join(',', $_->{date} // '', @{ $_->{packages} // [] }) } @sec),
        $ctx->{exclude_spec}, $ctx->{min_severity}, $ctx->{severity_stamp}));
    my $prev = load_result($t);
    if ($prev && ($prev->{cache} // '') eq $cache && ($prev->{status} // '') eq 'ok') {
        _write_json(result_file($t), $warn->({ %$prev, checked => $ctx->{now} }));
        return;
    }

    # An index that cannot be read is an error of the whole result. Skipping
    # it - as this did with a 16 MiB limit (#62) - turned "main was not read"
    # into "ok", listing only what the smaller components had.
    my %index;
    for my $l (@sec) {
        for my $p (@{ $l->{packages} // [] }) {
            my $text = eval { PVE::Tools::file_get_contents($p, $PVE::UpdateManager::SecCompare::MAX_INDEX) };
            if (!defined($text)) {
                my $err = $@ || 'no content';
                chomp($err);
                _write_json(result_file($t), { %$res, status => 'error',
                    reason => "security index $p not read: $err" });
                return;
            }
            PVE::UpdateManager::SecCompare::add_index(\%index, $text);
        }
    }

    my $status = PVE::Tools::file_get_contents("$dir/status", $MAX_FILE);
    my ($installed, $skipped) = PVE::UpdateManager::SecCompare::installed_packages($status);
    my $pending = PVE::UpdateManager::SecCompare::pending($installed, \%index, $ctx->{exclude});

    my $lookup = $HOOK{severity_lookup} // _default_hooks()->{severity_lookup};
    my $codename = $meta->{os}->{version_codename} // '';
    my @kept;
    for my $p (@$pending) {
        $p->{urgency} = $lookup
            ? (eval { $lookup->($codename, $p->{source}, $p->{installed}, $p->{fixed}) } // 'unknown')
            : 'unknown';
        push @kept, $p if !$ctx->{min_severity} || _meets($p->{urgency}, $ctx->{min_severity});
    }

    # `computed` moves only here; a reused result keeps the time it was made.
    _write_json(result_file($t), $warn->({ %$res, status => 'ok', cache => $cache, computed => $ctx->{now},
        pending => \@kept, skipped_entries => $skipped,
        lists_date => (sort { $a <=> $b } map { PVE::UpdateManager::SecUtil::release_epoch($_->{date}) // 0 } @sec)[0] }));
}

sub _meets {
    my ($urgency, $min) = @_;

    my $meets = $HOOK{severity_meets} // eval {
        require PVE::UpdateManager::SecSeverity;
        \&PVE::UpdateManager::SecSeverity::meets;
    };

    # Without the severity module a threshold cannot be applied, and dropping
    # an update because its rating could not be read is the one wrong answer.
    return $meets ? $meets->($urgency, $min) : 1;
}

# The whole round. Returns { busy => 1 } when another round holds the lock,
# else { results => [...], elapsed => seconds, timed_out => n }.
sub run_round {
    my ($node, $settings, $log) = @_;

    $log //= sub { };

    File::Path::make_path($STATE_DIR) if !-d $STATE_DIR;
    sysopen(my $lock, _lock_file(), O_RDWR | O_CREAT, 0600) or die "cannot open the scan lock: $!\n";
    # Not waited for: a round that is still running is the answer, and a
    # second one queued behind it would only repeat it.
    return { busy => 1 } if !flock($lock, LOCK_EX | LOCK_NB);

    my $now = _hook('now')->();
    my $state = load_state();
    # Stamped before the work, like the update schedule: a round that outlives
    # the next ticks must not have them start it again.
    $state->{last_scan} = $now;
    _write_json(_state_file(), $state);

    my $deadline = $now + 60 * ($settings->{security_interval} // 30);
    my $parallel = $settings->{security_parallel} // 4;

    my $targets = collect_targets($node, $settings);
    my (@todo, @busy);
    for my $t (@$targets) {
        if ($t->{type} ne 'node' && PVE::UpdateManager::Config::target_is_running($t->{type}, $t->{id})) {
            push @busy, $t;    # its packages are changing right now (#40, case 2)
        } else {
            push @todo, $t;
        }
    }
    $log->(sprintf('checking %d target(s), %d at a time; %d skipped while updating',
        scalar(@todo), $parallel, scalar(@busy)));

    my $work = "$STATE_DIR/work";
    File::Path::remove_tree($work);
    PVE::UpdateManager::SecUtil::private_dir($_) for $work, "$STATE_DIR/results";

    my $stuck = $state->{stuck} // {};
    # Every child closes its copy of the lock first. A flock belongs to the
    # open file, not to the process: a child that kept the descriptor would
    # hold the lock for as long as it lives - and a reader stuck in the kernel
    # never ends (#36 V9), so every later round would find the lock taken and
    # do nothing, for good. Found by sec-scan.t, where a round right after a
    # deliberately hung child reported "busy".
    my $read = PVE::UpdateManager::SecPool::run(\@todo, $parallel, $TARGET_TIMEOUT, $deadline,
        sub { close($lock); _read_one($_[0], $work, $settings, $stuck->{ _key($_[0]) }) });

    # Remembered into the next round: every reader that is still stuck, and
    # nothing else - one that ended since is forgotten.
    my %still;
    for my $t (@todo) {
        my $meta = _read_json("$work/" . _key($t) . '/meta.json') // next;
        my $s = $meta->{stuck} // next;
        $still{ _key($t) } = $s if PVE::UpdateManager::SecUtil::alive($s->{pid}, $s->{start});
    }
    $state->{stuck} = \%still;
    _write_json(_state_file(), $state);

    my %jobs;
    for my $t (@todo) {
        my $meta = _read_json("$work/" . _key($t) . '/meta.json') // next;
        $jobs{ _hook('job_key')->($_) } //= $_ for @{ $meta->{jobs} // [] };
    }
    $log->(sprintf('fetching %d security list(s)', scalar(keys %jobs)));
    # fetch dies only when its own state directory is unusable. That costs
    # this round its lists - every target then says its source could not be
    # reached - but not the round itself, and not the results of the targets
    # that have nothing to fetch.
    my $lists = {};
    if (scalar(keys %jobs)) {
        $lists = eval {
            _hook('fetch')->([values %jobs], {
                state_dir => "$STATE_DIR/lists", timeout => 120, parallel => $parallel, deadline => $deadline,
            });
        };
        if (my $err = $@) {
            chomp($err);
            $log->("fetching the security lists failed: $err");
            $lists = { map {; $_ => { error => $err } } keys %jobs };
        }
        # A list whose package files are gone (#53). A probe that dies costs
        # the warning, never the round.
        eval { _hook('probe')->(\%jobs, $lists, $log) };
        $log->("checking the package files failed: $@") if $@;
    }

    # refresh writes and lookup reads SecSeverity's own STATE_DIR - lookup has
    # no directory argument in the hook. Pointed below this round's directory
    # here, before the compare children are forked, so they inherit it.
    # Without this refresh would fill one directory and lookup read another,
    # and every rating would come out 'unknown'.
    my $sev_dir = "$STATE_DIR/severity";
    # Loaded FIRST: its body sets `our $STATE_DIR = ...`, so a require that
    # came after the local below would overwrite it - which is exactly what
    # happened while it was loaded lazily from inside the compare children.
    eval { require PVE::UpdateManager::SecSeverity };
    no warnings 'once';
    local $PVE::UpdateManager::SecSeverity::STATE_DIR = $sev_dir;
    use warnings 'once';

    if ($settings->{security_min_severity}) {
        my (%codenames, @metas);
        for my $t (@todo) {
            my $meta = _read_json("$work/" . _key($t) . '/meta.json') // next;
            next if !$meta->{os}->{version_codename};
            $codenames{ $meta->{os}->{version_codename} }++;
            push @metas, $meta;
        }
        # 120 s fits JSON::XS, which PVE always has (qemu-server depends on
        # libjson-xs-perl): parsing the tracker data takes 5.6 s there. With
        # JSON::PP it takes 221-227 s and the refresh times out - left so on
        # purpose (#50): a timeout means "updates count as unrated", which
        # reports too much rather than too little, and a longer deadline would
        # hold every round of a node without JSON::XS for four minutes.
        my $refresh = $HOOK{severity_refresh} // _default_hooks()->{severity_refresh};
        my $r = $refresh ? eval { $refresh->({ state_dir => $sev_dir, timeout => 120,
            codenames => [sort keys %codenames],
            proxies => PVE::UpdateManager::SecJobs::severity_proxies(\@metas, $settings) }) } : undef;
        $log->('severity data: ' . ($r && $r->{ok} ? 'current' : 'not available - updates count as unrated'));
    }

    my $ctx = {
        now => $now, lists => $lists,
        exclude_spec => $settings->{security_exclude} // '',
        exclude => PVE::UpdateManager::SecCompare::parse_exclude($settings->{security_exclude} // ''),
        min_severity => $settings->{security_min_severity} // '',
        # Part of the reuse key: new ratings must reach a target whose packages
        # did not change - a rating can cross the threshold on its own.
        severity_stamp => PVE::UpdateManager::SecUtil::dir_stamp($sev_dir),
    };
    my $cmp = PVE::UpdateManager::SecPool::run(\@todo, $parallel, $TARGET_TIMEOUT, $deadline,
        sub { close($lock); _compare_one($_[0], $work, $ctx) });

    my @results;
    my $timed_out = 0;
    for my $i (0 .. $#todo) {
        my $t = $todo[$i];
        my $r = load_result($t);
        if (!$r || ($r->{checked} // 0) != $now) {
            $timed_out++;
            my $why = ($cmp->{$i} // '') eq 'round-deadline' || ($read->{$i} // '') eq 'round-deadline'
                ? 'the round reached its time limit before this target' : 'checking this target took too long';
            $r = { type => $t->{type}, id => $t->{id}, name => $t->{name}, checked => $now,
                status => 'timeout', reason => $why, pending => [] };
            _write_json(result_file($t), $r);
        }
        push @results, $r;
    }
    for my $t (@busy) {
        my $r = load_result($t) // { type => $t->{type}, id => $t->{id}, name => $t->{name}, pending => [] };
        push @results, { %$r, busy => 1 };
    }

    File::Path::remove_tree($work);
    PVE::UpdateManager::SecSummary::write($node, \@results);

    $state = load_state();
    $state->{last_done} = _hook('now')->();
    _write_json(_state_file(), $state);

    return { results => \@results, elapsed => $state->{last_done} - $now, timed_out => $timed_out };
}

1;
