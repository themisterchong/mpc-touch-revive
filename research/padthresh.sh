#!/bin/sh
# padthresh.sh <67> <68> <69> : sets the three pad settings, then counts note-ons for 20 s (soft taps + 1 hard hit at the end)
cd "$(dirname "$0")"
./livetest 20 "F0 47 7F 37 67 00 01 $1 F7" "F0 47 7F 37 68 00 01 $2 F7" "F0 47 7F 37 69 00 01 $3 F7" | grep 'IN 99' | python3 -c "
import sys; v=[int(l.split()[3],16) for l in sys.stdin]; print('67=$1 68=$2 69=$3  hits:', len(v), ' velocities:', v)"
