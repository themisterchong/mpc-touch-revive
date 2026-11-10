#!/bin/sh
# Builds everything into ./build (universal arm64 + x86_64 where possible).
#   ./build.sh            all parts
#   ./build.sh fix        only the Akai-MPC-software fix (fakedl.dylib, mpctouch-status, MPC Touch.app)
#   ./build.sh touch      only the touch helper + tools (touchmouse, calibrate, padcal, velmon)
#   ./build.sh screen     only the Ableton screen app (MPCScreen)
# Needs Xcode command line tools (clang, swiftc) and git (to fetch libusb source for touchmouse).
# LIBUSB_SRC=/path/to/libusb uses an existing libusb source checkout instead of cloning.
set -e
cd "$(dirname "$0")"
B="$PWD/build"; mkdir -p "$B"
ARCH="-arch arm64 -arch x86_64"
MIN="-mmacosx-version-min=11.0"
what="${1:-all}"

swift_universal() {   # swift_universal <out> <src> [frameworks...]
  out="$1"; src="$2"; shift 2
  swiftc -O -target arm64-apple-macos11 -o "$out.arm64" "$src" "$@"
  swiftc -O -target x86_64-apple-macos11 -o "$out.x86_64" "$src" "$@"
  lipo -create -output "$out" "$out.arm64" "$out.x86_64" && rm -f "$out.arm64" "$out.x86_64"
}

if [ "$what" = all ] || [ "$what" = fix ]; then
  echo "== macos-fix"
  clang $ARCH $MIN -dynamiclib -O2 -o "$B/fakedl.dylib" macos-fix/fakedl.m -framework CoreGraphics -framework CoreFoundation
  swift_universal "$B/mpctouch-status" macos-fix/mpctouch-status.swift
  rm -rf "$B/MPC Touch.app"; osacompile -o "$B/MPC Touch.app" macos-fix/launcher.applescript
fi

if [ "$what" = all ] || [ "$what" = touch ]; then
  echo "== touch"
  # libusb 1.0 (LGPL-2.1), compiled from source and linked statically. Pinned to the commit we tested with.
  LIBUSB_COMMIT=abba63ed3cad642cc2540ad407b5304109c0ca45
  if [ -z "$LIBUSB_SRC" ]; then
    LIBUSB_SRC="$B/libusb"
    if [ ! -d "$LIBUSB_SRC/.git" ]; then
      git clone -q https://github.com/libusb/libusb.git "$LIBUSB_SRC"
    fi
    (cd "$LIBUSB_SRC" && git checkout -q "$LIBUSB_COMMIT")
  fi
  O="$B/libusb-obj"; mkdir -p "$O"
  [ -f "$LIBUSB_SRC/libusb/version_describe.h" ] || echo '#define LIBUSB_DESCRIBE ""' > "$LIBUSB_SRC/libusb/version_describe.h"   # normally made by autotools
  L="$LIBUSB_SRC/libusb"
  for f in core descriptor hotplug io strerror sync os/darwin_usb os/events_posix os/threads_posix; do
    clang $ARCH $MIN -O2 -c -I"$LIBUSB_SRC/Xcode" -I"$L" -I"$L/os" -o "$O/$(basename $f).o" "$L/$f.c"
  done
  clang $ARCH $MIN -O2 -I"$L" -o "$B/touchmouse" touch/touchmouse.c "$O"/*.o \
    -framework CoreMIDI -framework ApplicationServices -framework CoreFoundation -framework IOKit -framework Security -lobjc
  clang $ARCH $MIN -O2 -o "$B/padcal" touch/padcal.c -framework CoreMIDI -framework CoreFoundation
  clang $ARCH $MIN -O2 -o "$B/velmon" touch/velmon.c -framework CoreMIDI -framework CoreFoundation
  swift_universal "$B/calibrate" touch/calibrate.swift
fi

if [ "$what" = all ] || [ "$what" = screen ]; then
  echo "== screen"
  mkdir -p "$B/screen"
  swift_universal "$B/screen/MPCScreen" ableton/screen/MPCScreen.swift
  rm -rf "$B/screen/fonts"; cp -R ableton/screen/fonts "$B/screen/fonts"   # the app loads fonts/ next to itself
fi
echo "done: $B"
