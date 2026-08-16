package PVE::ProcFSTools;

# Test stub. $ALIVE decides whether a recorded worker still exists, which is what
# separates a run that is genuinely in flight from one whose process is gone.

use strict;
use warnings;

our $ALIVE = 1;

sub check_process_running { return $ALIVE ? 4711 : undef; }

1;
