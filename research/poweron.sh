#!/bin/sh
# Switches the MPC Touch's touch panel on (MPC's startup sequence) and keeps it alive for $1 seconds.
cd "$(dirname "$0")"
exec ./mpcctl "${1:-60}" "BF 02 00" "BF 02 00" "F0 7E 00 06 01 F7" "F0 47 7F 37 62 00 01 61 F7" "F0 47 7F 37 64 00 03 00 01 01 F7" "F0 47 7F 37 64 00 03 01 01 01 F7" "F0 47 7F 37 64 00 03 02 00 00 F7" "F0 47 7F 37 64 00 03 03 00 00 F7" "F0 47 7F 37 63 00 03 00 00 00 F7" "F0 47 7F 37 63 00 03 01 00 00 F7" "F0 47 7F 37 5A 00 20 00 00 02 09 00 00 04 03 00 00 00 01 02 0A 03 0F 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 F7" "F0 47 00 37 52 00 04 08 45 70 55 F7"
