# mpc-touch-revive

Bring the Akai **MPC Touch** back to life on modern macOS, and use it as an MPC-style controller for **Ableton Live** with its own touch-screen UI.

Akai lists the MPC Touch as unsupported on macOS 14+ and on Apple Silicon. This repo has two independent parts:

- **Ableton mode** (`touch/`, `ableton/`): no Akai software needed at runtime. A small helper powers the Touch on, turns its touch panel into touches, and gives Ableton a MIDI port. A Remote Script plus a full-screen app on the Touch's display make it an MPC-style instrument for Live.
- **MPC software mode** (`macos-fix/`): makes Akai's own MPC 2.x software talk to the Touch again (controller, lights, touch UI on the Touch screen). This needs **SIP disabled**. Read the warning below.

Step-by-step guide for M1/M2/M3/M4 Macs: **[docs/MANUAL-apple-silicon.md](docs/MANUAL-apple-silicon.md)**

## Status

| Setup | Ableton mode | MPC software mode |
|---|---|---|
| iMac17,1 (Intel), macOS 15 via OpenCore Legacy Patcher, MPC 2.10 / 2.15 | not tried | **working** (pads, buttons, lights, touch UI on the Touch screen, touch input) |
| Apple M3, macOS 26, SIP disabled, MPC 2.15 | **working** (helper, Remote Script, screen app) | **working** (touch UI on the Touch screen, touch input) |

Other Macs and macOS versions: unknown. Reports welcome.

## Why it broke (root causes)

1. **Touch panel hardware**: on our unit the touch ribbon cable was loose. Once reseated the touch controller shows up as `09e8:8001` "SiS HID Touch Controller" on the Touch's internal hub, next to `09e8:0037` (MPC Touch) and `17e9:ff00` (DisplayLink screen).
2. **Akai kexts are not active after a reboot.** `AkaiProfessionalMPCTouch.kext` is a codeless kext that sets interface 4 ("MPC Touch Controls") to subclass 255 so Akai's CoreMIDI driver owns it. Without it the Akai MIDI device stays offline. `kmutil load` re-activates it. `AkaiTouchPanel.kext` is a placeholder on `09e8:8001` so MPC can open the panel through libusb.
3. **MPC checks for the old DisplayLink kext.** MPC reads `/Library/Extensions/DisplayLinkDriver.kext/Contents/Info.plist` (DisplayLink 5.2.5). Modern DisplayLink Manager has no such file, so MPC answers the Touch's identity reply and then silently stops the handshake.
4. **MPC wants a "native" display mode.** MPC only puts its UI on the Touch display (EDID vendor `0x5109`, model `0x1021`, 1280x800) if a mode has `kDisplayModeNativeFlag`. DisplayLink Manager's virtual display does not set it.
5. **USB controller** (Intel iMac): it failed to handshake behind a Fresco Logic FL1100 card; it works on Apple's own USB ports.

Fixes 3 and 4 are one small interposing library, `macos-fix/fakedl.m`, loaded into MPC with `DYLD_INSERT_LIBRARIES`.

## WARNING: MPC software mode lowers your Mac's security

`fakedl.dylib` is injected into MPC with `DYLD_INSERT_LIBRARIES`. macOS ignores that variable for protected apps unless **System Integrity Protection (SIP) is disabled** (or AMFI is relaxed, e.g. the `amfi=0x80` boot-arg that OpenCore Legacy Patcher sets). With SIP off, any program on your Mac can do the same to other apps and change system files. Only do this on a music machine you accept that risk for, and know how to turn SIP back on (`csrutil enable` in Recovery). Ableton mode does **not** use DYLD injection.

Loading Akai's kexts on Apple Silicon may also need **Reduced Security** with "Allow user management of kernel extensions" (Startup Security Utility in Recovery).

## What you need

- MPC Touch with its **own power adapter** (USB power is not enough).
- macOS with Xcode Command Line Tools (`xcode-select --install`), git.
- **DisplayLink Manager** (current version, from displaylink.com) so the Touch screen works as a normal Mac display.
- **Akai kexts** from Akai's MPC software installer (we do not ship them): `AkaiProfessionalMPCTouch.kext` is installed by the MPC / MPC Touch driver installer into `/Library/Extensions`; `AkaiTouchPanel.kext` comes from `AkaiTouchPanel Installer.pkg` inside the MPC installer app's `Contents/Resources`.
- MPC software mode only: Akai MPC 2.x, plus a **copy of the DisplayLink 5.2.5 kext bundle** (`DisplayLinkDriver.kext`, from Akai's bundled DisplayLink 5.2.5 installer package). It is only read, never installed. Do **not** let the MPC installer install DisplayLink 5.2.5 itself: it conflicts with DisplayLink Manager.
- Ableton mode: Ableton Live 11 or 12.

## Build

```sh
./build.sh          # everything into ./build (universal arm64 + x86_64)
./build.sh fix      # MPC software mode only
./build.sh touch    # touch helper + tools (fetches libusb source from GitHub, LGPL-2.1, linked statically)
./build.sh screen   # Ableton screen app
```

## Install: MPC software mode

```sh
D="$HOME/Library/Application Support/MPCTouchFix"; mkdir -p "$D"
cp build/fakedl.dylib build/mpctouch-status "$D/"
cp -R /path/to/DisplayLinkDriver.kext "$D/"          # your copy of the 5.2.5 kext bundle
mkdir -p ~/Applications && cp -R "build/MPC Touch.app" ~/Applications/
```

Always start MPC with **MPC Touch.app**, never the normal MPC icon. It checks the Touch (`mpctouch-status`: absent / offline / online), loads the Akai kexts if needed (asks for your password), then starts MPC with the fix. `MPCTOUCH_DLKEXT=/other/path` overrides where `fakedl` looks for the 5.2.5 bundle.

## Ableton mode

See the [manual](docs/MANUAL-apple-silicon.md) for the full steps. In short: load the Akai kext, run `build/touchmouse`, run `ableton/install.sh`, pick **MPC_Touch** as control surface with input/output **MPC Touch Live** (Track + Remote on), start `build/screen/MPCScreen`.

What you get:

- **Pads**: 4x4 drum layout (pad 1 = C1), banks A-H, velocity curve and per-pad gain in the helper, Full Level, 16 Levels (velocity / tune / filter), note repeat, pad colours follow Live.
- **Chords**: one pad = one chord in the song's key (R&B / house / triad voicings, borrowed-chord banks, ready-made progressions).
- **Steps**: 16-step sequencer per bar with swing, chance, ratchet and per-step velocity / pitch locks; **Notes**: a small piano roll.
- **Sample**: Simpler waveform, drag chop markers, chop by transient / beat / 16 / 8, record or resample into Simpler, reverse / crop / warp / stretch, key and BPM detection.
- **Session / Arrange / Mixer**: clip grid with launch, M/S/arm/stop, clip sheet, capture; mixer strips with volume / pan / sends.
- **Device**: the selected device's parameters on the Q-Links and the screen; FX picker with common Live effects.
- **Browse**: samples from your User Library, Factory Packs and Live Recordings with preview, "chop it", "into Simpler", "onto a pad".
- Q-Links and the jog wheel follow whatever field is focused on screen.

## Repo layout

```
macos-fix/   fakedl.m (DYLD interposer), mpctouch-status.swift, launcher.applescript
touch/       touchmouse.c (power-on, touch input, MIDI bridge), calibrate.swift, padcal.c, velmon.c
ableton/     install.sh, MPC_Touch/ (Remote Script), screen/ (MPCScreen.swift + Barlow fonts, OFL)
docs/        MANUAL-apple-silicon.md, mapping.json (MIDI map of every control)
research/    small tools used while reverse-engineering (MIDI/USB loggers, dtrace scripts, test patterns)
```

## Related

- [savilionmusic/koala-link](https://github.com/savilionmusic/koala-link) does screen + touch for the MPC Touch on Apple Silicon for Koala Sampler.

## Disclaimer

Not affiliated with, endorsed by, or supported by Akai Professional / inMusic, Ableton, or DisplayLink. MPC, MPC Touch and Ableton Live are trademarks of their owners. This is unofficial, provided as is, and you use it at your own risk.

## Licence

MIT, see [LICENSE](LICENSE). Barlow fonts: SIL Open Font License 1.1 ([OFL.txt](ableton/screen/fonts/OFL.txt)). libusb (fetched at build time): LGPL-2.1.
