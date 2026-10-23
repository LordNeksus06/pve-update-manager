package PVE::UpdateManager::SecUtil;

# Small helpers of the security scan (#40): a Release file's date, a
# directory's stamp, and whether a process is still the one that was seen.
#
# Out of SecScan.pm, which went past 500 lines with them in.

use strict;
use warnings;

use File::Path ();
use PVE::Tools;

use PVE::UpdateManager::Config;
use PVE::UpdateManager::Guest;

# The Date: line of a Release file - "Thu, 22 Oct 2026 08:24:15 UTC" - as an
# epoch, or undef. Only UTC/GMT/+0000 is accepted: that is what Debian and
# Ubuntu write, and a zone this does not know is better unknown than wrong.
my %MON = (Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5,
    Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11);

sub release_epoch {
    my ($date) = @_;

    my ($d, $mon, $y, $h, $m, $s) = ($date // '') =~
        m/\A(?:[A-Z][a-z]{2},\s+)?(\d{1,2})\s+([A-Z][a-z]{2})\s+(\d{4})\s+(\d\d):(\d\d):(\d\d)\s+(?:UTC|GMT|\+0000)\z/
        or return undef;
    return undef if !exists($MON{$mon});

    require Time::Local;
    return eval { Time::Local::timegm($s, $m, $h, $d, $MON{$mon}, $y) };
}


# Name, size and mtime of every file in a directory, as one string: changes
# whenever SecSeverity stores new data there.
sub dir_stamp {
    my ($dir) = @_;

    opendir(my $dh, $dir) or return '';
    my @f = sort grep { !m/\A\./ } readdir($dh);
    closedir($dh);

    return join(';', map { my @st = stat("$dir/$_"); "$_:" . ($st[7] // '') . ':' . ($st[9] // '') } @f);
}

# The start time of a process, from /proc/<pid>/stat field 22 - what tells a
# process that still exists from a new one that got its pid.
sub start_time {
    my ($pid) = @_;

    return undef if !defined($pid) || $pid !~ m/\A\d+\z/;
    my $stat = eval { PVE::Tools::file_get_contents("/proc/$pid/stat", 4096) } // return undef;
    # The command name is in parentheses and may contain anything, spaces and
    # parentheses included - so the fields are counted from its LAST ')'.
    my ($rest) = $stat =~ m/\)\s(.*)\z/s or return undef;
    my @f = split(/\s+/, $rest);

    return $f[19];    # field 22 overall; field 3 is $f[0]
}

# A directory of the scan that only root may enter (#67). What a round keeps
# about a guest - a copy of its dpkg status, its apt proxy with any password in
# it, its pending updates - was 0644 in 0755 directories, the mode
# file_set_contents gives when it is not told one, and readable by every local
# account of the node. The state directory itself cannot be private: the
# fetch jobs' lists below it are downloaded by the _apt user.
sub private_dir {
    my ($dir) = @_;

    File::Path::make_path($dir, { mode => 0700 }) if !-d $dir;
    # Also when it exists: an older version left results/ at 0755.
    chmod(0700, $dir) or die "cannot restrict $dir: $!\n";
}

sub alive {
    my ($pid, $start) = @_;

    return 0 if !defined($pid) || !defined($start);
    my $now = start_time($pid);

    return defined($now) && $now eq $start ? 1 : 0;
}

# The node itself and every guest on it that is not a template - or with
# security_targets=script only the ones that have an update script.
sub collect_targets {
    my ($node, $settings) = @_;

    my @t = ({ type => 'node', id => $node, name => $node });

    # Errors are said, not swallowed: a list that fails here is a round that
    # checks the node alone and reports nothing about every guest - which on
    # the lab PVE looked exactly like a node without guests until the error
    # was printed (#40).
    for my $type (@PVE::UpdateManager::Guest::TYPES) {
        my $list = eval { PVE::UpdateManager::Guest::config_list($type) };
        if (!$list) {
            warn "security check: cannot list the guests of type $type - $@";
            next;
        }
        for my $vmid (sort { $a <=> $b } grep { m/\A\d+\z/ } keys %$list) {
            my $conf = eval { PVE::UpdateManager::Guest::load_config($type, $vmid) };
            if (!$conf) {
                # Migrated away between the list and now, typically.
                warn "security check: $type $vmid skipped - $@";
                next;
            }
            next if PVE::UpdateManager::Guest::is_template($type, $conf);
            push @t, {
                type => $type,
                id => "$vmid",
                name => PVE::UpdateManager::Guest::name($type, $conf, $vmid),
            };
        }
    }

    if (($settings->{security_targets} // 'all') eq 'script') {
        @t = grep { PVE::UpdateManager::Config::has_script($_->{type}, $_->{id}) } @t;
    }

    return \@t;
}

1;
