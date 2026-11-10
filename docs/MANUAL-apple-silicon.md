# MPC Touch on an Apple Silicon Mac (M1 or newer)

How we got the Akai MPC Touch working on an Apple M3 with macOS 26. Akai says it is unsupported there.

**Tested on:** Apple M3, macOS 26.7, SIP disabled, DisplayLink Manager (current): Ableton Live 12 (mode A) and Akai MPC 2.15 (mode B).
**Marked UNVERIFIED** below: things we believe but did not prove on this Mac.

There are two modes. Pick one per session; they cannot run at the same time (only one program can own the touch panel).

- **A. Ableton mode**: Ableton Live + our helper + our screen app. No Akai software running.
- **B. MPC software mode**: Akai's MPC 2.x software, with our DYLD fix. Needs SIP disabled.

---

## How it works (short)

- **Screen**: the Touch's display is a DisplayLink USB 2 chip (`17e9:ff00`). Its protocol is encrypted, so the Linux `udlfb` driver approach does not work. On Apple Silicon, current **DisplayLink Manager** shows it as a normal 1280x800 Mac display.
- **Controls**: pads, buttons, knobs and lights speak MIDI over Akai's CoreMIDI driver. The driver only owns the device when **`AkaiProfessionalMPCTouch.kext`** is loaded. It exposes a hidden **"MPC Touch Private"** port.
- **Touch panel**: a SiS controller (`09e8:8001`). It is switched off until someone sends the MPC startup sequence over the Private port. Only then does it appear on USB.
- **touchmouse** (`touch/touchmouse.c`) is the essential piece for Ableton mode. It:
  1. finds the Private port (walking device → entity → endpoints) and also connects its input, or the driver ignores what we send;
  2. sends MPC's startup: `BF 02 00` ×2, identity request `F0 7E 00 06 01 F7`, then `F0 47 7F 37 62/64/63/5A …` setup messages and the pad settings `67/68/69`;
  3. sends a keep-alive `F0 47 00 37 52 00 04 08 45 70 55 F7` every 4 s (the Touch answers with `… 53 …`);
  4. reads the touch panel with libusb (endpoint `0x82`, 64-byte reports with ID `0x10`, 10 contacts × 6 bytes, coordinates 0–4095), smooths with a One Euro filter, applies calibration, and turns fingers into mouse events / gestures (or sends them straight to the screen app over UDP 9102);
  5. bridges the Private port to a virtual MIDI port pair **"MPC Touch Live"** for Ableton, with a softer pad velocity curve, per-pad gain and Full Level. Messages to Live get a real `mach_absolute_time()` timestamp: Live drops track notes stamped 0;
  6. on Ctrl-C switches the panel off (`64 … 01 01 00` + `62 00 01 02`).
- **Lights**: button LED = CC on channel 1 with the button's note number, value 0–3. Pad colour = `F0 47 7F 37 65 00 04 <pad 0-15> <r> <g> <b> F7`. Full control map: [`mapping.json`](mapping.json).
- **Screen app** (`ableton/screen/MPCScreen.swift`) draws a full-screen window on the Touch display and talks to the Remote Script over UDP on localhost (app 9100, script 9101).

---

## Before you start (both modes)

1. **Power and cable.** Use the Touch's own power adapter. Connect USB directly to the Mac if you can.
   *Check:* the Touch screen lights up.
2. **Touch ribbon cable.** If touch never works anywhere, open the unit and reseat the touch panel ribbon cable. Ours was loose.
   *Check:* later, `09e8:8001` "SiS HID Touch Controller" appears in System Information → USB (only after the startup sequence, see step A4).
3. **Install DisplayLink Manager** (current version, from displaylink.com) and allow its screen-recording permission.
   *Check:* System Settings → Displays shows a 1280x800 display; the Touch shows your desktop.
4. **Get the Akai kexts** from Akai's MPC software installer (we do not ship them). Install the MPC Touch driver so `/Library/Extensions/AkaiProfessionalMPCTouch.kext` exists. Do **not** let it install DisplayLink 5.2.5.
   *Check:* `ls /Library/Extensions | grep -i akai`
5. **Build this repo:** `./build.sh` (needs `xcode-select --install` and git).
   *Check:* `build/touchmouse`, `build/screen/MPCScreen`, `build/fakedl.dylib` exist.

## Allowing the Akai kext to load

macOS forgets the Akai codeless kexts after every restart on these Macs, so they must be loaded again each session:

```sh
sudo kmutil load -p /Library/Extensions/AkaiProfessionalMPCTouch.kext
```

*Check:* `ioreg -c IOUSBHostInterface -l -w0 | grep -A6 "MPC Touch Controls"` shows `bInterfaceSubClass` = 255, and `build/mpctouch-status` prints `online`.

On Apple Silicon, third-party kexts normally need **Reduced Security** + **"Allow user management of kernel extensions from identified developers"** (Recovery → Startup Security Utility). Our test Mac already had SIP disabled, so we could not tell which of these a codeless kext really needs. **UNVERIFIED**: whether Ableton mode works with full SIP on.

---

## A. Ableton mode

Needs: DisplayLink Manager, the Akai kext loaded, touchmouse, the Remote Script, MPCScreen. Does **not** use DYLD injection. Akai's MPC software must not be running.

1. **Load the Akai kext** (see above).
   *Check:* `build/mpctouch-status` → `online`.
2. **(Optional) put helper config in place.** touchmouse reads optional files from `~/Library/Application Support/MPCTouchFix/`: `calibration.txt`, `padgain.txt`, `padsens.txt`. None are needed to start.
   *Check:* nothing to check; missing files mean defaults.
3. **Give touchmouse Accessibility permission.** It posts mouse events. Add your terminal (or the touchmouse binary) in System Settings → Privacy & Security → Accessibility.
   *Check:* touchmouse does not print `warning: no Accessibility permission`.
4. **Start touchmouse:** `build/touchmouse` (leave it running).
   *Check:* the touch panel powers on, `09e8:8001` appears on USB, touching the Touch screen moves the pointer there. If it keeps printing `touch panel not up yet`, the kext is not loaded or the Private port is not reachable.
5. **Calibrate (once):** `build/calibrate`, tap each crosshair. It writes `calibration.txt` and tells touchmouse to reload (SIGHUP).
   *Check:* taps land under your finger.
6. **(Optional) even out worn pads:** `build/padcal`, hit every pad 4 times. Writes `padgain.txt`. `build/velmon` shows raw vs. final velocities.
7. **Install the Remote Script:** `ableton/install.sh` (copies to `~/Music/Ableton/User Library/Remote Scripts/MPC_Touch`). Restart Live.
8. **Set up Live:** Settings → Link, Tempo & MIDI → Control Surface **MPC_Touch**, Input and Output **MPC Touch Live**. For the MPC Touch Live input turn **Track** and **Remote** on.
   *Check:* pads light up in colour; pressing a pad plays the selected track.
9. **Start the screen app:** `build/screen/MPCScreen` (keep the `fonts/` folder next to it, `build.sh` does this).
   *Check:* the Ableton-style screen appears on the Touch display and follows the selected track. `MPCSCREEN_MAIN=1` shows it on the Mac's own screen for testing.

**Tested on M3 / macOS 26.** Note the Touch screen picture comes from DisplayLink over USB 2, so the app limits redraws to about 15 frames/s.

---

## B. Akai MPC software mode

Needs everything from "Before you start" plus: SIP disabled, `AkaiTouchPanel.kext`, a copy of the DisplayLink 5.2.5 kext bundle, `fakedl.dylib`, the launcher.

> **Security warning:** `DYLD_INSERT_LIBRARIES` only works on MPC because MPC allows unsigned libraries *and* SIP is disabled (or AMFI relaxed). With SIP off any program can inject code into other apps and modify system files. Re-enable with `csrutil enable` in Recovery when you are done.

1. **Disable SIP:** Recovery → Terminal → `csrutil disable`, restart.
   *Check:* `csrutil status` → `disabled`.
2. **Install `AkaiTouchPanel Installer.pkg`** from the MPC installer app's `Contents/Resources`.
   *Check:* `/Library/Extensions/AkaiTouchPanel.kext` exists.
3. **Patch your own copy of AkaiTouchPanel.kext (Apple Silicon).** On our M3 it would not load as shipped because it links `com.apple.iokit.IOUSBFamily`, which Apple Silicon does not have. We removed that one entry from `Contents/Info.plist` and re-signed ad hoc:
   ```sh
   K=/Library/Extensions/AkaiTouchPanel.kext
   sudo cp -R "$K" ~/AkaiTouchPanel.kext.orig                     # keep the original
   sudo /usr/libexec/PlistBuddy -c "Delete :OSBundleLibraries" "$K/Contents/Info.plist"
   sudo codesign --force --sign - "$K"
   ```
   The removed block was:
   ```xml
   <key>OSBundleLibraries</key>
   <dict>
       <key>com.apple.iokit.IOUSBFamily</key>
       <string>1.8</string>
   </dict>
   ```
   *Check:* `codesign -dv "$K"` → `Signature=adhoc`.
4. **Put the fix files in place:**
   ```sh
   D="$HOME/Library/Application Support/MPCTouchFix"; mkdir -p "$D"
   cp build/fakedl.dylib build/mpctouch-status "$D/"
   cp -R /path/to/DisplayLinkDriver.kext "$D/"     # copy of the 5.2.5 bundle, only read by MPC
   cp -R "build/MPC Touch.app" ~/Applications/
   ```
   *Check:* `"$D/DisplayLinkDriver.kext/Contents/Info.plist"` exists.
5. **Start MPC with `~/Applications/MPC Touch.app`** (never the normal MPC icon). It loads both kexts if the Touch is `offline` (asks for your password), then starts the MPC binary directly with `DYLD_INSERT_LIBRARIES`. It does not use `open -a --env`: LaunchServices drops DYLD variables.
   *Check:* MPC's stderr shows `[fakedl] loaded`; Preferences → Hardware → Show Hardware Info is no longer greyed out; lights work; MPC's UI appears on the Touch display.
6. **Quit touchmouse first.** If touchmouse is running, MPC cannot open the touch panel.

**Tested on:** Apple M3, macOS 26, SIP disabled, MPC 2.15 (touch UI on the Touch screen + touch input fully working), and Intel iMac17,1, macOS 15 via OpenCore Legacy Patcher.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `mpctouch-status` says `absent` | Touch off, no power adapter, bad cable | Use the power adapter, replug USB, wait for the screen |
| `mpctouch-status` says `offline` | Akai kext not loaded (forgotten after restart) | `sudo kmutil load -p /Library/Extensions/AkaiProfessionalMPCTouch.kext`, then replug USB |
| touchmouse: `MPC Touch Private MIDI port not found` | Same as above | Load the kext, check `online` |
| touchmouse keeps saying `touch panel not up yet` | Startup sequence not accepted, or panel cable loose | Replug the Touch; reseat the touch ribbon cable |
| Touch screen black / no 1280x800 display | DisplayLink Manager not running or no permission | Start DisplayLink Manager, allow screen recording, replug |
| Touch display drops out now and then | Power | Replug; use the Touch's own adapter |
| Taps land in the wrong place | No calibration | Run `build/calibrate` |
| Taps don't click anywhere | No Accessibility permission | Add the terminal / touchmouse under Accessibility |
| Ableton: pads light but don't play | Track switch off | Turn **Track** on for the MPC Touch Live input |
| Ableton: some notes missing | Old helper sending timestamp 0 | Use the current touchmouse from this repo |
| Screen app shows nothing | Remote Script not selected, or UDP port 9101 busy | Pick MPC_Touch in Live, check Live's Log.txt for `screen link: cannot bind` |
| MPC: handshake stops, Hardware Info greyed out | fakedl not loaded (SIP on, or MPC started normally) | Start via MPC Touch.app; check `csrutil status` |
| MPC: UI not on the Touch display | Native-mode flag missing | Same: fakedl must be loaded |
| MPC: no touch input | touchmouse running, or AkaiTouchPanel.kext not loaded | Quit touchmouse; load AkaiTouchPanel.kext |
| Intel Mac: no handshake | Third-party USB card (Fresco Logic FL1100) | Use the Mac's own USB ports |
