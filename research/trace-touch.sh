#!/bin/sh
# Records for 20 s which macOS USB/HID functions MPC calls while you touch the MPC Touch screen.
P=$(pgrep -x MPC) || { echo "MPC is not running"; exit 1; }
echo "Enter your Mac password, then keep tapping and dragging on the MPC Touch screen for 20 seconds..."
sudo dtrace -Z -q -p $P -o /tmp/mpc-dtrace.txt -n '
pid$target:IOUSBHost::entry { @[probemod, probefunc] = count(); }
pid$target:IOKit:IOConnect*:entry, pid$target:IOKit:IOServiceOpen:entry, pid$target:IOKit:IOCreatePlugInInterfaceForService:entry,
pid$target:IOKit:IOHIDDevice*:entry, pid$target:IOKit:IOHIDManager*:entry { @[probemod, probefunc] = count(); }
tick-20s { exit(0); }'
echo "Done — log in /tmp/mpc-dtrace.txt"
