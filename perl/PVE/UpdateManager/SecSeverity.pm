package PVE::UpdateManager::SecSeverity;

# How severe a pending security update is (#44): the Debian security tracker's
# urgency for the CVEs a security update fixes, reduced to what a lookup needs,
# and the threshold setting security_min_severity.
#
# The source: one JSON object, source package => CVE => releases => codename =>
# { status, fixed_version, urgency }. Measured 2026-10-22 in a lab container:
# 14 130 756 B gzip, 85 745 541 B unpacked, 4 111 source packages, served with
# Last-Modified and "Cache-Control: max-age=3600". The debsecan feed is smaller
# but has no fixed version per suite, so it cannot say what an update fixes.
#
# All of it comes off the network and is treated as hostile: a field is used
# only after a strict check, download and unpacked text are bounded by
# max_bytes, the refresh by a deadline. The result goes to small per-codename
# files that lookup() reads without touching the network.

use strict;
use warnings;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

use PVE::UpdateManager::SecCompare;

our $URL = 'https://security-tracker.debian.org/tracker/data/json';

# 85.7 MB unpacked today, so three times that before the data is called broken
# rather than grown. Bounds the download and the unpacked text alike: a gzip
# body that unpacks past it is refused the moment it does.
our $DEFAULT_MAX_BYTES = 256 * 1024 * 1024;

# Measured in the lab container: a whole refresh took 6.7 s, unpacking and
# reducing 5.6 s of it with JSON::XS - and 221-227 s with JSON::PP, which is
# why PVE's JSON::XS (qemu-server depends on libjson-xs-perl) is used first.
our $DEFAULT_TIMEOUT = 300;

# LWP's own timeout is per read, not per request, so a server that trickles a
# byte every few seconds would never trip it. The overall deadline is checked
# in the content callback; this caps how long a single silent read may take
# past it.
our $READ_TIMEOUT = 30;

# Between two values the format has a key (a package name or a CVE id), a
# colon, a comma and whitespace. 64 KiB of text without a match is not it.
my $MAX_GAP = 65536;

our $CHUNK = 65536;    # a variable so the test can read a few bytes at a time

# ── urgencies ───────────────────────────────────────────────────────────────
#
# Values present in the data on 2026-10-22, over all four codenames:
#   not yet assigned 217 256, unimportant 40 493, low 10 912, medium 2 686,
#   high 577, end-of-life 484.
# No "**" suffixes and nothing else. Anything that is not one of these becomes
# 'unknown' rather than being guessed at.
#
# The rank picks the "highest" urgency of an update that fixes several CVEs;
# the level decides meets(). The three without a level count against every
# threshold: in trixie 52 225 resolved entries are not yet assigned against 133
# high (#36 V6), so dropping them would drop nearly every update. They rank
# below high, so a mixed update shows "openssl high", and above medium, so an
# unrated fix is never hidden behind a rated one.
my %RANK = (
    'unimportant' => 1,
    'low' => 2,
    'medium' => 3,
    'unknown' => 4,
    'end-of-life' => 5,
    'not yet assigned' => 6,
    'high' => 7,
);

my %LEVEL = (unimportant => 0, low => 1, medium => 2, high => 3);
my %MIN_LEVEL = (low => 1, medium => 2, high => 3);

sub _urgency {
    my ($u) = @_;

    return defined($u) && !ref($u) && $RANK{$u} ? $u : 'unknown';
}

# Does an update of $urgency reach the threshold $min ('' | low | medium |
# high)? An empty threshold takes everything, unimportant included. A threshold
# that is not one of the three is treated as empty: the settings schema refuses
# such a value, and if one gets through anyway the safe mistake is reporting
# too much, not too little.
sub meets {
    my ($urgency, $min) = @_;

    my $need = $MIN_LEVEL{ $min // '' } // return 1;
    my $have = $LEVEL{ _urgency($urgency) } // return 1;

    return $have >= $need ? 1 : 0;
}

# ── where the reduced data lives ────────────────────────────────────────────

# A codename becomes part of a file name, so it is checked before it is one.
# Returned as the regex capture and not just approved: the codenames come from
# each guest's os-release through meta.json, so under -T (pvedaemon, and with
# it every "Check now") they are tainted, and a match that only says yes leaves
# them so. Every refresh started from the web UI then died writing its first
# list with "Insecure dependency" (#57), and every update counted as unrated.
sub _clean_codename {
    my ($c) = @_;

    return undef if !defined($c);
    my ($clean) = $c =~ m/\A([a-z][a-z0-9-]{1,31})\z/;

    return $clean;
}

sub _valid_codename { defined(_clean_codename($_[0])) ? 1 : 0 }

our $STATE_DIR = '/var/lib/pve-update-manager/security';

sub _list_file { "$_[0]/severity-$_[1].list" }
sub _state_file { "$_[0]/severity.state" }

sub _json {
    return eval { require JSON::XS; JSON::XS->new } || do { require JSON::PP; JSON::PP->new };
}

sub _read_state {
    my ($dir) = @_;

    open(my $fh, '<', _state_file($dir)) or return {};
    my $s = eval { _json()->utf8->decode(do { local $/; <$fh> } // '') };

    return ref($s) eq 'HASH' ? $s : {};
}

# Through a temporary file and rename, so a reader never sees half a file and a
# refresh that dies half way leaves the previous data in place.
sub _write_file {
    my ($path, $content) = @_;

    my $tmp = "$path.tmp.$$";
    unlink($tmp);
    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644) or die "cannot write $tmp: $!\n";
    # The rename is a statement of its own, not the last link of the chain:
    # under -T one tainted value anywhere in an expression taints all of it,
    # and $content - data downloaded and reduced - always is. In one chain
    # with the print the rename died with "Insecure dependency" although both
    # its paths were clean (#57).
    my $ok = (print {$fh} $content) && close($fh);
    $ok &&= rename($tmp, $path);
    my $err = $!;
    unlink($tmp), die "cannot write $path: $err\n" if !$ok;
}

# ── reducing the tracker's JSON ─────────────────────────────────────────────
#
# Reads the unpacked JSON from $fh and returns
#   { codename => { source => { fixed_version => urgency } } }
# for the codenames asked for, keeping only resolved entries with a real fixed
# version. fixed_version "0" means the release was never affected; on
# 2026-10-22 all 24 323 such entries were 'unimportant' and they can never fall
# between an installed and a fixed version anyway.
#
# One CVE at a time. Measured in the lab container on the 85.7 MB file with
# JSON::XS, peak RSS: whole document 394 MB (3.2 s), one source package at a
# time 160 MB - 'linux' alone is 34 012 035 B, 20 410 CVEs - and one CVE at a
# time 16 MB (5.6 s).
#
# The two outer objects are walked by hand, each CVE's value goes through the
# backend's incremental parser, which in JSON::XS and JSON::PP alike leaves the
# text behind the value in incr_text. Compared line by line with a whole
# decode of the same file: identical, 55 286 entries, with either backend.
my $RE_OPEN = qr/\G\s*(\{)/;
my $RE_FIRST = qr/\G\s*(\}|(?="))/;
my $RE_KEY = qr/\G\s*"((?:[^"\\]|\\.){0,512})"\s*:/;
my $RE_NEXT = qr/\G\s*([,}])/;

sub reduce {
    my ($fh, $codenames, $max_bytes, $deadline) = @_;

    my %want = map { $_ => 1 } @$codenames;
    my %out;
    # allow_nonref off: a CVE's value is an object, and a bare number at the
    # end of a chunk would otherwise be read before its last digit arrived -
    # the result would depend on where the chunks happen to end.
    my $json = _json()->utf8->allow_nonref(0);
    my ($total, $eof) = (0, 0);
    my ($buf, $at) = ('', 0);

    my $more = sub {
        return 0 if $eof;
        my $n = read($fh, my $chunk, $CHUNK);
        die "reading the security tracker data failed: $!\n" if !defined($n);
        if (!$n) { $eof = 1; return 0 }
        $total += $n;
        die "the security tracker data is larger than $max_bytes bytes\n" if $total > $max_bytes;
        die "reducing the security tracker data took too long\n" if $deadline && time() > $deadline;
        $buf .= $chunk;
        return 1;
    };

    # The next token after whitespace, read on until it matches. Each $re is
    # a whole qr// on its own: interpolated into a larger pattern, the one
    # match op compiled a pattern on every call - profiled, 10 s of a 31 s run
    # over 171 111 tokens. Matched at offset $at, not cut off with s///, so
    # the buffer is not rewritten per token either.
    my $tok = sub {
        my ($re) = @_;
        while (1) {
            pos($buf) = $at;
            if ($buf =~ m/$re/gc) {
                $at = pos($buf);
                return $1 // '';
            }
            my $malformed = "the security tracker data is malformed near byte $total\n";
            die $malformed if length($buf) - $at > $MAX_GAP;
            $more->() or die(substr($buf, $at) =~ m/\S/ ? $malformed : "the security tracker data ends in the middle\n");
        }
    };

    # The members of an object whose '{' was read; $member consumes a value.
    my $members = sub {
        my ($member) = @_;
        return if $tok->($RE_FIRST) eq '}';
        while (1) {
            $member->($tok->($RE_KEY));
            return if $tok->($RE_NEXT) eq '}';
        }
    };

    $tok->($RE_OPEN);
    $members->(sub {
        my ($source) = @_;
        $tok->($RE_OPEN);
        $members->(sub {
            my $cve = $json->incr_parse(substr($buf, $at));
            ($buf, $at) = ('', 0);
            while (!defined($cve)) {
                $more->() or die "the security tracker data ends in the middle\n";
                $cve = $json->incr_parse($buf);
                $buf = '';
            }
            $buf = $json->incr_text;
            $json->incr_text = '';
            _add_cve(\%out, \%want, $source, $cve);
        });
    });

    # Nothing but whitespace may follow.
    while (1) {
        die "the security tracker data has text after its end\n" if substr($buf, $at) =~ m/\S/;
        ($buf, $at) = ('', 0);
        $more->() or last;
    }

    return \%out;
}

sub _add_cve {
    my ($out, $want, $source, $cve) = @_;

    return if !PVE::UpdateManager::SecCompare::valid_name($source);
    return if ref($cve) ne 'HASH' || ref($cve->{releases}) ne 'HASH';

    for my $codename (keys %{ $cve->{releases} }) {
        next if !$want->{$codename};
        my $r = $cve->{releases}->{$codename};
        next if ref($r) ne 'HASH' || ($r->{status} // '') ne 'resolved';
        my $fixed = $r->{fixed_version};
        next if ref($fixed) || !PVE::UpdateManager::SecCompare::valid_version($fixed) || $fixed eq '0';
        my $u = _urgency($r->{urgency});
        my $slot = \$out->{$codename}->{$source}->{$fixed};
        $$slot = $u if !defined($$slot) || $RANK{$u} > $RANK{$$slot};
    }
}

# ── downloading ─────────────────────────────────────────────────────────────
#
# LWP rather than curl or wget: pve-manager depends on libwww-perl and
# liblwp-protocol-https-perl, so it is on every node, and it lets the body be
# counted and cut off while it arrives. Loaded here and not at the top because
# the CI runner has no LWP and the tests replace this function.
#
# Returns { code, message, encoding, last_modified (raw header), date (epoch),
# max_age } with the body in $file. Dies with a sentence. https only - no
# redirect to plain http - and file: only when asked for, which is the test.
sub _fetch {
    my ($url, $file, $since, $max_bytes, $deadline, $proxy) = @_;

    require LWP::UserAgent;

    my $left = $deadline - time();
    die "no time left to download the security tracker data\n" if $left <= 0;
    my $ua = LWP::UserAgent->new(
        agent => 'pve-update-manager',
        timeout => $left < $READ_TIMEOUT ? $left : $READ_TIMEOUT,
        max_redirect => 3,
        protocols_allowed => [$url =~ m/\Afile:/ ? 'file' : 'https'],
    );
    # The proxy a guest's apt would use for this address (#49) - undef is a
    # direct connection. LWP tunnels https through it with CONNECT.
    $ua->proxy(['https'], $proxy) if defined($proxy);

    open(my $out, '>', $file) or die "cannot write $file: $!\n";
    my $got = 0;
    my $res = $ua->get(
        $url,
        'Accept-Encoding' => 'gzip',
        (defined($since) ? ('If-Modified-Since' => $since) : ()),
        ':read_size_hint' => 65536,
        ':content_cb' => sub {
            my ($chunk) = @_;
            $got += length($chunk);
            die "the download is larger than $max_bytes bytes\n" if $got > $max_bytes;
            die "the download took too long\n" if time() > $deadline;
            print {$out} $chunk or die "cannot write $file: $!\n";
        },
    );
    close($out) or die "cannot write $file: $!\n";

    # A die inside the callback does not end the request with an error: LWP
    # keeps the status line it had and puts the message in X-Died.
    if (my $died = $res->header('X-Died')) {
        $died =~ s/ at \S+ line \d+.*//s;
        chomp($died);
        die "$died\n";
    }
    die "the download was cut off\n" if $res->header('Client-Aborted');

    my ($max_age) = ($res->header('Cache-Control') // '') =~ m/\bmax-age=([0-9]{1,9})\b/;

    return {
        code => $res->code,
        message => $res->message // '',
        encoding => $res->header('Content-Encoding') // '',
        last_modified => scalar($res->header('Last-Modified')),
        date => scalar($res->last_modified),
        max_age => $max_age,
    };
}

# ── the refresh ─────────────────────────────────────────────────────────────

# Called by the background scan only - never by an API call, which must not
# wait on Debian. Never dies. lookup() reads $STATE_DIR, so a caller that
# passes another state_dir here sets $STATE_DIR to the same or passes the
# directory to lookup() as well. Returns { ok, error, date }, date being the
# Last-Modified time of the data now stored (undef if there is none).
sub refresh {
    my ($opts) = @_;

    my $dir = ($opts //= {})->{state_dir} // $STATE_DIR;
    my $tmp = "$dir/severity-download.tmp.$$";

    my $res = eval { _refresh($opts, $dir, $tmp) };
    my $err = $@ || 'unknown error';
    unlink($tmp);
    return $res if $res;

    chomp($err);
    $err =~ s/ at \S+ line \d+\.?\z//;

    return { ok => 0, error => "Severity data not updated: $err", date => _read_state($dir)->{date} };
}

sub _refresh {
    my ($opts, $dir, $tmp) = @_;

    if (!-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir) };
        die "cannot create $dir\n" if !-d $dir;
    }

    my $max_bytes = $opts->{max_bytes} || $DEFAULT_MAX_BYTES;
    my $timeout = $opts->{timeout} || $DEFAULT_TIMEOUT;
    my $now = time();
    my $deadline = $now + $timeout;

    my %seen;
    my @codenames = sort grep { defined($_) && !$seen{$_}++ } map { _clean_codename($_) } @{ $opts->{codenames} // [] };

    my $state = _read_state($dir);
    return { ok => 1, error => undef, date => $state->{date} } if !@codenames;

    my %have = map { $_ => 1 } @{ ref($state->{codenames}) eq 'ARRAY' ? $state->{codenames} : [] };
    # A codename the stored data was not reduced for - a target moved to a new
    # release - needs the full document even if Debian has not changed it, so
    # neither the max-age shortcut nor If-Modified-Since may apply then.
    my $covered = !grep { !$have{$_} } @codenames;

    # The tracker says how long its answer stays fresh; asking again sooner
    # only costs Debian a request.
    if ($covered && defined($state->{checked}) && defined($state->{max_age})
        && $now >= $state->{checked} && $now < $state->{checked} + $state->{max_age}) {
        return { ok => 1, error => undef, date => $state->{date} };
    }

    my $since = $covered ? $state->{last_modified} : undef;
    # The node downloads this once for all guests, through the proxy their
    # apt would use (owner, 2026-10-23: "der den der lxc bei apt update auch
    # nutzen würde"). Guests can name different proxies, or none: each one is
    # tried in turn, the first answer that is an answer wins. No list means
    # direct, as before.
    my @try = @{ $opts->{proxies} // [] };
    @try = (undef) if !@try;
    my ($r, @failed);
    for my $proxy (@try) {
        # Named only when there is something to tell apart.
        my $how = defined($proxy) ? "via $proxy: " : @try > 1 ? 'direct: ' : '';
        my $got = eval { _fetch($URL, $tmp, $since, $max_bytes, $deadline, $proxy) };
        if (!$got) {
            my $err = $@ || 'unknown error';
            chomp($err);
            $err =~ s/ at \S+ line \d+\.?\z//;
            push @failed, "$how$err";
        } elsif ($got->{code} != 200 && $got->{code} != 304) {
            push @failed, "${how}the security tracker answered $got->{code} $got->{message}";
        } else {
            $r = $got;
            last;
        }
    }
    die join('; ', @failed) . "\n" if !$r;

    my $max_age = 0 + ($r->{max_age} // 0);
    $max_age = 86400 if $max_age > 86400;

    if ($r->{code} == 304 && defined($since)) {
        _write_file(_state_file($dir), _json()->canonical->encode({ %$state, checked => $now, max_age => $max_age }));
        return { ok => 1, error => undef, date => $state->{date} };
    }

    die "the security tracker answered $r->{code} $r->{message}\n" if $r->{code} != 200;

    my $fh;
    if ($r->{encoding} eq 'gzip') {
        require IO::Uncompress::Gunzip;
        no warnings 'once';
        $fh = IO::Uncompress::Gunzip->new($tmp, Transparent => 0)
            or die "cannot unpack the security tracker data: $IO::Uncompress::Gunzip::GunzipError\n";
    } elsif ($r->{encoding} eq '' || $r->{encoding} eq 'identity') {
        open($fh, '<', $tmp) or die "cannot read $tmp: $!\n";
    } else {
        die "the security tracker sent an unknown encoding '$r->{encoding}'\n";
    }

    my $data = reduce($fh, \@codenames, $max_bytes, $deadline);
    close($fh);

    for my $c (@codenames) {
        if (my $src = $data->{$c}) {
            # "source<TAB>fixed version<TAB>urgency", one line each.
            _write_file(_list_file($dir, $c), join('', map {
                my $p = $_;
                map { "$p\t$_\t$src->{$p}->{$_}\n" } sort keys %{ $src->{$p} };
            } sort keys %$src));
        } else {
            # Not in the tracker (an Ubuntu codename, a release Debian dropped):
            # no file, so lookup() answers 'unknown' instead of from old data.
            unlink(_list_file($dir, $c));
        }
    }
    # Codenames no target uses any more.
    my %keep = map { $_ => 1 } @codenames;
    for my $f (glob("$dir/severity-*.list")) {
        my ($c) = $f =~ m{/severity-([a-z][a-z0-9-]{1,31})\.list\z} or next;
        # Rebuilt from the capture rather than unlinking $f: what glob returns
        # is tainted under -T, the capture is not (#57).
        unlink(_list_file($dir, $c)) if !$keep{$c};
    }

    _write_file(_state_file($dir), _json()->utf8->canonical->encode({
        last_modified => $r->{last_modified},
        date => $r->{date},
        checked => $now,
        max_age => $max_age,
        codenames => \@codenames,
    }));

    return { ok => 1, error => undef, date => $r->{date} };
}

# ── the lookup ──────────────────────────────────────────────────────────────

# Loaded once per codename and kept while the file's mtime, size and inode
# stay the same: a scan looks up every pending package of every target, and a
# refresh renames a new file over it.
my %CACHE;

sub _load {
    my ($dir, $codename) = @_;

    my $file = _list_file($dir, $codename);
    my @st = stat($file) or do { delete $CACHE{"$dir\0$codename"}; return undef };
    my $key = "$dir\0$codename";
    my $c = $CACHE{$key};
    return $c->{data} if $c && $c->{mtime} == $st[9] && $c->{size} == $st[7] && $c->{ino} == $st[1];

    open(my $fh, '<', $file) or return undef;
    my %data;
    while (my $line = <$fh>) {
        chomp($line);
        my ($src, $v, $u) = split(/\t/, $line, -1);
        # Our own file, but checked like any other: it sits in a directory a
        # mistake elsewhere could write to, and a bad line costs one entry.
        next if !PVE::UpdateManager::SecCompare::valid_name($src)
            || !PVE::UpdateManager::SecCompare::valid_version($v) || !defined($u) || !$RANK{$u};
        $data{$src}->{$v} = $u;
    }
    close($fh);

    $CACHE{$key} = { mtime => $st[9], size => $st[7], ino => $st[1], data => \%data };

    return \%data;
}

# The highest urgency among the CVEs of $source that $codename fixed in a
# version above $installed and up to $fixed - what installing $fixed over
# $installed repairs. 'unknown' when there is no data for the codename (Ubuntu,
# a release the tracker does not list, no refresh yet) or no entry falls in the
# range: a security update that fixes nothing the tracker knows about is still a
# security update, and it counts.
sub lookup {
    my ($codename, $source, $installed, $fixed, $dir) = @_;

    return 'unknown' if !_valid_codename($codename)
        || !PVE::UpdateManager::SecCompare::valid_name($source)
        || !PVE::UpdateManager::SecCompare::valid_version($installed)
        || !PVE::UpdateManager::SecCompare::valid_version($fixed);

    my $data = _load($dir // $STATE_DIR, $codename) or return 'unknown';
    my $entries = $data->{$source} or return 'unknown';

    my $best;
    for my $v (keys %$entries) {
        next if PVE::UpdateManager::SecCompare::version_compare($v, $installed) <= 0;
        next if PVE::UpdateManager::SecCompare::version_compare($v, $fixed) > 0;
        my $u = $entries->{$v};
        $best = $u if !defined($best) || $RANK{$u} > $RANK{$best};
    }

    return $best // 'unknown';
}

1;
