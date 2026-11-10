#!/bin/sh
# Copies the MPC Touch Remote Script into Ableton's User Library (Live 11/12 look there for user control surfaces).
dest="$HOME/Music/Ableton/User Library/Remote Scripts/MPC_Touch"
mkdir -p "$dest" && cp "$(dirname "$0")/MPC_Touch/"*.py "$dest/" && rm -rf "$dest/__pycache__" && echo "installed to $dest — restart Ableton"
