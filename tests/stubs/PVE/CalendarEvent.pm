package PVE::CalendarEvent;

# Test stub. Enough of the calendar parser for the settings tests: a bare
# "HH:MM" (optionally with a weekday prefix) parses, anything else does not, and
# compute_next_event returns the next occurrence of that time of day.
#
# DELIBERATELY narrower than the real parser, which is systemd's syntax and
# accepts `*/8:00` and `*:0/5` as well - both verified against a real PVE 9.2.
# Reimplementing that here would be the second implementation this project keeps
# out of the tests on purpose. What it means for a test: never assert that a
# spec is REFUSED unless it is refused by the real one too, or the claim is
# about this file rather than about the addon.

use strict;
use warnings;

sub parse_calendar_event {
    my ($spec) = @_;

    die "unable to parse calendar event '$spec'\n"
        if !defined($spec) || $spec !~ m/\A(?:[a-z][a-z.,\-]*\s+)?(\d{1,2}):(\d{2})\z/;

    return { hour => int($1), minute => int($2) };
}

sub compute_next_event {
    my ($event, $last) = @_;

    my @t = localtime($last);
    my $today = $last - ($t[2] * 3600 + $t[1] * 60 + $t[0]);
    my $next = $today + $event->{hour} * 3600 + $event->{minute} * 60;

    $next += 24 * 3600 while $next <= $last;

    return $next;
}

1;
