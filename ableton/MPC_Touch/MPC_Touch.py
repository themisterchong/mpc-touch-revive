# MPC Touch for Ableton Live (11 / 12).
# Talks to the virtual "MPC Touch Live" MIDI port made by the touchmouse helper (which also powers the Touch on).
#
# Pads    : ch10 notes, translated to a 4x4 drum layout (pad 1 = C1 = 36), banks A-H. They play the selected track
#           directly through Live (velocity / aftertouch untouched), so set the port's "Track" switch on.
# Buttons : ch1 notes; lights are CC on ch1 with the same number, brightness 0-3.
# Pad RGB : F0 47 7F 37 65 00 04 <pad 0-15> <r> <g> <b> F7 (0-127).
# Helper  : F0 7D 4D 01 <0/1> F7 = Full Level off/on (done in the helper, so velocity stays out of Live's way).
from __future__ import absolute_import, print_function, unicode_literals

import time

import Live
from _Framework.ControlSurface import ControlSurface
from _Framework.ButtonElement import ButtonElement
from _Framework.EncoderElement import EncoderElement
from _Framework.InputControlElement import MIDI_NOTE_TYPE, MIDI_CC_TYPE

from .screen_link import ScreenLink, device_layout

# --- hardware map (captured from the device, see docs/mapping.json) ---
PAD_NOTES = (37, 36, 42, 82, 40, 38, 46, 44, 48, 47, 45, 43, 49, 55, 51, 53)   # pad 1..16, bottom-left first
PAD_CHANNEL = 9

SHIFT, REC, OVERDUB, STOP, PLAY, PLAY_START = 49, 73, 80, 81, 82, 83
TAP, UNDO, ERASE, COPY = 53, 67, 9, 122
NOTE_REPEAT, FULL_LEVEL, LEVEL_16 = 11, 39, 40
GROUPS = (35, 36, 37, 38)                     # A/E, B/F, C/G, D/H
MAIN, BROWSE, QLINK, PLUS, MINUS = 52, 123, 0, 54, 55
JOG_PRESS = 111
BUTTONS = (SHIFT, REC, OVERDUB, STOP, PLAY, PLAY_START, TAP, UNDO, ERASE, COPY, NOTE_REPEAT, FULL_LEVEL,
           LEVEL_16) + GROUPS + (MAIN, BROWSE, QLINK, PLUS, MINUS, JOG_PRESS)
QLINK_CCS = (16, 17, 18, 19)
QLINK_TOUCH = (84, 85, 86, 87)                 # touch-sensitive Q-Links send these notes (and flicker while turning)
JOG_CC = 100

OFF, DIM, MID, ON = 0, 1, 2, 3

# pad banks A-H: first note of each bank (A = C1 like a Drum Rack, G/H reach the low notes)
BANK_BASE = (36, 52, 68, 84, 100, 116, 4, 20)
REPEAT_RATES = ((1.0, '1/4'), (0.5, '1/8'), (1.0 / 3, '1/8T'), (0.25, '1/16'), (1.0 / 6, '1/16T'),
                (0.125, '1/32'), (1.0 / 12, '1/32T'))


def relative(value):
    return value if value < 64 else value - 128


def rgb7(color):
    return ((color >> 16) & 255) >> 1, ((color >> 8) & 255) >> 1, (color & 255) >> 1


def scaled(rgb, k):
    return tuple(int(c * k) for c in rgb)


class MPC_Touch(ControlSurface):

    def __init__(self, c_instance):
        ControlSurface.__init__(self, c_instance)
        self._shift = False
        self._bank = 0
        self._step_mode = False                     # 16 LEVEL: pads = 16 steps of the selected sound
        self._pad_mode = 'drum'                     # SHIFT + A/B/C/D: drum / keys / clips / mixer
        self._step_page = 0                         # which bar (groups A-D in step mode)
        self._step_len = 0.25                       # STEPS Q3: note length of the pattern
        self._humanize = 20                         # STEPS Q4: how much HUMANIZE varies the velocity (%)
        self._step_note = 36                        # sound to sequence when there is no Drum Rack
        self._qlink_bank = 0
        self._copy_held = False                     # COPY held: tap something to duplicate it (with SHIFT = DELETE)
        self._copy_used = False                     # ...and something was tapped while it was held
        self._copy_src = None                       # (track, scene) of the clip picked to copy
        self._copy_pasted = False
        self._erase_held = False
        self._levels = False                        # 16 LEVEL: one sound over all 16 pads (MPC)
        self._levels_param = 'velocity'             # velocity / tune / filter
        self._level_notes = {}                      # pad → note playing (for the note off)
        self._chord_notes = {}                      # chord pads: pad → notes playing
        self._chord_count = {}                      # note → how many held chords use it
        self._chord_style = 'rnb'                   # rnb / house / triads
        self._chord_oct = 0                         # CHORDS: octave shift
        self._chord_bank = 0                        # CHORDS: bank A–D (in key · borrowed colours)
        self._chord_mode = 'chords'                 # CHORDS: 'chords' (pad = degree) or 'prog' (pads = progressions)
        self._chord_last = None                     # the last chord's upper voices (smooth voice leading)
        self._level_restore = None                  # (parameter, value) to put back after Tune / Filter levels
        self._swing = None                          # 0.50 … 0.75, MPC style; kept in the Live set
        self._step_sel = None                       # (pitch, step) selected on the screen: Q-Links edit that step
        self._q_rest = [0.0] * 4
        self._rec = None
        self._melody_view = False                   # STEPS on a melodic track: MELODY view (one note per step) instead of the grid
        self._wave_bank = 0                         # WAVE page Q-Link page: 0 = EDIT (start/end/zoom/slice), 1.. = Simpler pages
        self._wave_view = None                      # (start, end) frames the WAVE page shows (Q-Link step size follows it)
        self._wave_slice = None                     # frame of the chop you're on (Q1 moves its start, the wheel walks the chops)                            # sampling in progress: (record track, slot, target track)
        self._mel_oct = 3                           # instrument tracks: octave on screen + pads (3 = C3 = note 60)
        self._mel_inkey = True                      # piano roll shows only the song's scale
        self._pad_key = None                        # (track, pad layout) the pads were last set up for
        self._qlink_map_key = None                  # what the Q-Links are natively mapped to right now
        self._qlink_watch = []                      # (parameter, listener) pairs feeding the screen
        self._full_level = False
        self._repeat_held = False
        self._repeat_latched = False
        self._repeat_rate = 3
        self._leds = {}
        self._pad_colors = [None] * 16
        self._qlink_rest = [0.0] * 4
        self._qlink_last = [0.0] * 4
        self._tick = 0
        with self.component_guard():
            self._buttons = {}
            for note in BUTTONS:
                b = ButtonElement(True, MIDI_NOTE_TYPE, 0, note)
                b.add_value_listener(self._on_button, identify_sender=True)
                self._buttons[note] = b
            self._pads = [ButtonElement(True, MIDI_NOTE_TYPE, PAD_CHANNEL, n) for n in PAD_NOTES]
            self._qlinks = []
            for i, cc in enumerate(QLINK_CCS):
                e = EncoderElement(MIDI_CC_TYPE, 0, cc, Live.MidiMap.MapMode.relative_two_compliment)
                e.add_value_listener(self._on_qlink, identify_sender=True)
                self._qlinks.append(e)
            # claim the Q-Link touch notes, otherwise they reach the track and play notes 84-87
            self._qlink_touch = []
            for n in QLINK_TOUCH:
                b = ButtonElement(True, MIDI_NOTE_TYPE, 0, n)
                b.add_value_listener(self._on_qlink_touch, identify_sender=True)
                self._qlink_touch.append(b)
            # the screen app nudges us through the helper (CC 127 ch 16) so its taps are handled now, not on the next tick
            self._wake = ButtonElement(False, MIDI_CC_TYPE, 15, 127)
            self._wake.add_value_listener(self._on_wake)
            self._jog = EncoderElement(MIDI_CC_TYPE, 0, JOG_CC, Live.MidiMap.MapMode.relative_two_compliment)
            self._jog.add_value_listener(self._on_jog)
        self._apply_bank()
        self._send_helper(1, 0)
        self._screen = ScreenLink(self)
        self.show_message('MPC Touch connected')

    # ---------- helpers ----------
    def _app(self):
        return Live.Application.get_application()

    def _send_helper(self, cmd, value):
        self._send_midi((0xF0, 0x7D, 0x4D, cmd, value, 0xF7))

    def _led(self, note, level):
        if self._leds.get(note) != level:
            self._leds[note] = level
            self._send_midi((0xB0, note, level))

    def _pad_color(self, index, rgb):
        if self._pad_colors[index] != rgb:
            self._pad_colors[index] = rgb
            self._send_midi((0xF0, 0x47, 0x7F, 0x37, 0x65, 0x00, 0x04, index) + tuple(rgb) + (0xF7,))

    def _selected_track(self):
        return self.song().view.selected_track

    def _selected_device(self):
        return self._selected_track().view.selected_device

    def _all_tracks(self):
        s = self.song()
        return list(s.tracks) + list(s.return_tracks) + [s.master_track]

    # ---------- pads ----------
    def _apply_bank(self):
        base = BANK_BASE[self._bank]
        script_pads = self._step_mode or self._levels or self._pad_mode in ('clips', 'mixer') or self.pad_mode() == 'chords'
        if self.pad_mode() != 'chords' and getattr(self, '_chord_notes', None) and getattr(self, '_screen', None) is not None:
            self.chord_release_all()                    # left the chord pads while holding: no hanging notes
        self._pad_key = (self._selected_track(), self.pad_mode(), self._mel_oct, self._bank)
        for i, pad in enumerate(self._pads):
            listening = pad.value_has_listener(self._on_script_pad)
            if script_pads:                         # the script takes the pads (no translation to the track)
                pad.set_identifier(PAD_NOTES[i])
                if not listening:
                    pad.add_value_listener(self._on_script_pad, identify_sender=True)
            else:
                if listening:
                    pad.remove_value_listener(self._on_script_pad)
                pad.set_identifier(self._pad_note(i))   # no listeners + new identifier = Live translates the note
            pad.set_channel(PAD_CHANNEL)
        self.request_rebuild_midi_map()

    NOTE_NAMES = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B')

    def note_name(self, n):
        return '%s%d' % (self.NOTE_NAMES[n % 12], n // 12 - 2)     # Live's naming: 60 = C3

    def track_kind(self, track=None):
        """what the first screen tab shows: drum / slice / simpler / instrument / empty / audio / other"""
        track = track or self._selected_track()
        if not hasattr(track, 'devices') or not hasattr(track, 'clip_slots'):
            return 'other'                          # return / master track
        if not getattr(track, 'has_midi_input', False):
            return 'audio'
        if self._drum_rack(track.devices) is not None:
            return 'drum'
        for d in track.devices:
            if d.class_name == 'OriginalSimpler':
                return 'slice' if d.playback_mode == 2 else 'simpler'
            if int(d.type) == 1:                    # any other instrument, rack or plug-in / AU
                return 'instrument'
        return 'empty'

    def is_melodic(self):
        return self.track_kind() in ('instrument', 'simpler', 'empty')

    def pad_mode(self):
        """drum mode on an instrument track = keyboard, like Push"""
        if self._pad_mode == 'drum' and self.is_melodic():
            scr = getattr(self, '_screen', None)              # (not there yet while starting up)
            return 'chords' if scr is not None and scr.page == 'PADS' else 'keys'     # the screen's CHORDS page: one pad = one chord
        return self._pad_mode

    def melodic_rows(self):
        """one octave of the piano roll, high note first: the scale (+ the next root) or all 12 (+ the next C)"""
        root, intervals = self._scale()
        base = 12 * (self._mel_oct + 2)
        notes = [base + root + i for i in intervals] + [base + root + 12] if self._mel_inkey else list(range(base, base + 13))
        return [n for n in notes if 0 <= n < 128][::-1]

    def set_octave(self, octave):
        self._mel_oct = max(-1, min(7, octave))
        rows = self.melodic_rows()
        if self._step_note not in rows:
            self._step_note = rows[-1]              # keep sequencing inside the visible octave
        self._apply_bank()

    # ---------- CHORDS: one pad = one chord of the song's key (MPC Pad Perform) ----------
    # pads 1-8 = the degrees I..vii + I up; pads 9-16 = the same degrees, richer. Built from the scale itself,
    # so every chord stays in key. rnb = 7th/9th voicings + root in the bass · house = rootless m7/m9 stabs · triads
    CHORD_SHAPES = {                          # (main, rich): scale steps above the root (0 = root, 2 = 3rd, 4 = 5th …)
        'rnb': ((2, 4, 6, 8), (2, 6, 8, 10)),           # 3 5 7 9  ·  3 7 9 11  (+ root bass)
        'house': ((0, 2, 4, 6), (2, 4, 6, 8)),          # 1 3 5 7  ·  3 5 7 9 (rootless)
        'triads': ((0, 2, 4), (0, 2, 4, 7)),            # 1 3 5    ·  1 3 5 8
        'gospel': ((2, 4, 6, 8), (2, 6, 8, 10, 12)),    # 3 5 7 9  ·  3 7 9 11 13, wide, root bass
        'lofi': ((2, 6), (2, 6, 8)),                    # shells: 3 7 · 3 7 9 over the root (jazz / lo-fi)
        'deep': ((2, 4, 6, 8), (2, 6, 8, 10)),          # minor 9 / 11 stabs, rootless, low (deep house)
        'disco': ((0, 2, 4, 7), (0, 2, 4, 6, 7)),       # bright triads + octave · 7th (disco, French house)
        'dark': ((0, 4, 8), (0, 3, 4, 8)),              # 1 5 9 · 1 4 5 9: open, no 3rd (trap, dark, cinematic)
    }
    BASS_STYLES = ('rnb', 'gospel', 'lofi')             # these add the root an octave below
    # chord banks (MPC Pad Perform): A = the song's key, B C D = borrowed colours of the same root
    #   minor: A natural minor · B dorian (the major IV, Dilla) · C harmonic minor (the dominant V) · D the parallel major
    #   major: A major · B mixolydian (the flat VII) · C lydian (the sharp IV) · D the parallel minor
    BANKS = {'minor': ((0, 2, 3, 5, 7, 8, 10), (0, 2, 3, 5, 7, 9, 10), (0, 2, 3, 5, 7, 8, 11), (0, 2, 4, 5, 7, 9, 11)),
             'major': ((0, 2, 4, 5, 7, 9, 11), (0, 2, 4, 5, 7, 9, 10), (0, 2, 4, 6, 7, 9, 11), (0, 2, 3, 5, 7, 8, 10))}
    BANK_NAMES = {'minor': ('IN KEY', 'DORIAN', 'HARMONIC', 'MAJOR'), 'major': ('IN KEY', 'MIXOLYDIAN', 'LYDIAN', 'MINOR')}

    # PROGRESSIONS mode (MPC Pad Perform): per style 4 ready-made progressions, pads 1–4 = the first in order, 5–8 the second …
    # (scale degrees of the bank's scale, 1 = the root: they stay in key and follow the banks / key changes)
    PROGRESSIONS = {
        'rnb':    ((2, 5, 1, 6), (1, 6, 2, 5), (4, 3, 2, 1), (6, 2, 5, 1)),
        'lofi':   ((2, 5, 1, 6), (4, 3, 6, 2), (1, 6, 4, 5), (3, 6, 2, 5)),
        'gospel': ((4, 3, 2, 1), (1, 4, 1, 5), (6, 2, 5, 1), (4, 5, 3, 6)),
        'house':  ((1, 6, 3, 7), (1, 4, 5, 4), (6, 4, 1, 5), (1, 7, 6, 7)),
        'deep':   ((1, 4, 1, 4), (1, 6, 4, 5), (1, 4, 7, 3), (6, 7, 1, 1)),
        'disco':  ((1, 6, 4, 5), (1, 4, 5, 4), (6, 4, 1, 5), (2, 5, 1, 1)),
        'dark':   ((1, 6, 3, 7), (1, 6, 7, 1), (1, 4, 6, 5), (6, 7, 1, 1)),
        'triads': ((1, 5, 6, 4), (1, 4, 5, 1), (6, 4, 1, 5), (1, 6, 4, 5)),
    }

    def pad_degree(self, i, n=7):
        """pad → (scale degree 0-based, rich voicing, an octave up)"""
        if getattr(self, '_chord_mode', 'chords') == 'prog':
            prog = self.PROGRESSIONS.get(self._chord_style, self.PROGRESSIONS['rnb'])
            return (prog[i // 4 % 4][i % 4] - 1) % max(1, n), i >= 8, False
        deg = i % 8
        return (deg % 7 if n >= 7 else deg % n), i >= 8, deg == 7

    def chord_scale(self):
        """(root, intervals, bank names) for the chord pads: the bank's scale on the song's root"""
        root, iv = self._scale()
        kind = 'minor' if (3 in iv and 4 not in iv) else 'major'
        bank = getattr(self, '_chord_bank', 0)
        if bank and len(iv) == 7:
            iv = list(self.BANKS[kind][bank])
        return root, iv, self.BANK_NAMES[kind]

    def chord_for(self, i, voice_lead=False):
        root, iv, _ = self.chord_scale()
        n = len(iv)
        deg, rich, up = self.pad_degree(i, n)
        up = 1 if up else 0
        def semi(k):                          # scale step k above the degree → semitones above the degree's root
            k2 = deg + k
            return iv[k2 % n] + 12 * (k2 // n) - iv[deg]
        shape = self.CHORD_SHAPES.get(self._chord_style, self.CHORD_SHAPES['rnb'])[1 if rich else 0]
        if self._chord_style in ('rnb', 'gospel', 'deep') and rich and semi(2) == 4:
            shape = (2, 6, 8, 12)                 # major / dominant: 3 7 9 13 (an 11 would clash with the major 3rd)
        low = -12 if self._chord_style == 'deep' else 0     # deep house sits an octave lower
        base = 12 * (3 + self._chord_oct + 2) + root + iv[deg] + 12 * up + low   # degree root around C3
        upper = sorted(base + semi(k) for k in shape)
        # voicing: of all inversions that sit around the middle (centre ± 6), take the one closest to the last chord
        # (smooth voice leading) — anchored to the centre, so it never wanders off up or down
        centre = 12 * (3 + self._chord_oct + 2) + 7 + low + (5 if self._chord_style == 'gospel' else 0)
        cands = []
        for r in range(len(upper)):
            inv = sorted(upper[r:] + [u + 12 for u in upper[:r]])
            mean = sum(inv) / float(len(inv))
            inv = [u + 12 * int(round((centre - mean) / 12.0)) for u in inv]
            if abs(sum(inv) / float(len(inv)) - centre) <= (9 if self._chord_style == 'gospel' else 6):
                cands.append(inv)
        clean = [c for c in cands if all(b - a != 1 for a, b in zip(c, c[1:]))]
        if clean:                                     # no half-step rubs between neighbouring voices (muddy)
            cands = clean
        if not cands:
            cands = [upper]
        last = self._chord_last if (voice_lead and self._chord_last) else None
        if last:
            upper = min(cands, key=lambda c: sum(min(abs(x - y) for y in last) for x in c))
        else:
            upper = min(cands, key=lambda c: abs(sum(c) / float(len(c)) - centre))
        notes = list(upper)
        if self._chord_style in self.BASS_STYLES:
            bass = base - 12
            while bass > min(upper) - 12:
                bass -= 12
            notes = [bass] + notes
        notes = [x for x in notes if 0 <= x < 128]
        return notes, self.chord_name(base, [base + semi(k) for k in (0, 2, 4, 6, 8, 10, 12)], shape)

    ROMAN = ('I', 'II', 'III', 'IV', 'V', 'VI', 'VII')

    def chord_name(self, base, stack, shape):
        names = ('C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B')
        third, fifth, seventh, ninth, eleventh, thirteenth = [(x - base) % 12 for x in stack[1:7]]
        q = ''
        if 2 not in shape and 0 in shape and 8 in shape:   # no 3rd: 1 5 9 (sus2) · 1 4 5 9
            return names[base % 12] + ('sus4add9' if 3 in shape else 'sus2')
        if third == 3 and fifth == 6:
            q = 'm7b5' if 6 in shape else 'dim'
        elif third == 3:
            q = 'm'
            if 6 in shape:
                q = 'm11' if 10 in shape else ('m9' if 8 in shape else 'm7')
        else:
            if fifth == 8:
                q = '+'
            elif 6 in shape:
                maj = seventh == 11
                if 12 in shape:
                    q = 'maj13' if maj else '13'
                elif 8 in shape:
                    q = 'maj9' if maj else '9'
                else:
                    q = 'maj7' if maj else '7'
        return names[base % 12] + q

    def _chord_off(self, n):
        c = self._chord_count.get(n, 0) - 1
        if c <= 0:                                   # only when no other held chord still uses this note
            self._chord_count.pop(n, None)
            self._send_midi((0xF0, 0x7D, 0x4D, 0x11, n & 127, 0, 0xF7))
        else:
            self._chord_count[n] = c

    def chord_release_all(self):
        for i in list(self._chord_notes):
            for n in self._chord_notes.pop(i, []):
                self._chord_off(n)
        self._screen.chord_held = []

    def chord_pad(self, i, value):
        # notes are counted: two chords that share a note (legato changes) don't cut each other off
        if value == 0:
            for n in self._chord_notes.pop(i, []):
                self._chord_off(n)
            self._screen.chord_held = [k for k in self._chord_notes]
            self._refresh_pads()
            self._screen.push()
            return
        for n in self._chord_notes.pop(i, []):           # (retrigger the same pad)
            self._chord_off(n)
        notes, name = self.chord_for(i, voice_lead=True)
        self._chord_last = notes[1:] if self._chord_style in self.BASS_STYLES else notes
        self._chord_notes[i] = notes
        for n in notes:
            if self._chord_count.get(n, 0) > 0:          # already sounding from another pad: restrike it
                self._send_midi((0xF0, 0x7D, 0x4D, 0x11, n & 127, 0, 0xF7))
            self._chord_count[n] = self._chord_count.get(n, 0) + 1
            self._send_midi((0xF0, 0x7D, 0x4D, 0x10, n & 127, max(1, min(127, value)), 0xF7))
        self._screen.chord_held = [k for k in self._chord_notes]
        self.show_message('Chord ' + name)
        self._refresh_pads()
        self._screen.push()

    def _scale(self):
        song = self.song()
        intervals = list(getattr(song, 'scale_intervals', []) or []) or [0, 2, 4, 5, 7, 9, 11]
        return getattr(song, 'root_note', 0), intervals

    def _pad_note(self, i):
        if self.pad_mode() == 'keys':               # pads = the song's scale from the current octave up
            root, intervals = self._scale()
            n = 12 * (self._mel_oct + 2) + root + 12 * (i // len(intervals)) + intervals[i % len(intervals)]
        else:
            n = BANK_BASE[self._bank] + i
        return max(0, min(127, n))

    # 4x4 window on the session, around the selected track/scene (clips and mixer modes)
    def _ring(self):
        song = self.song()
        tracks = list(song.tracks)
        sel = song.view.selected_track
        t0 = (tracks.index(sel) // 4) * 4 if sel in tracks else 0
        scenes = list(song.scenes)
        s0 = (scenes.index(song.view.selected_scene) // 4) * 4
        return tracks, t0, scenes, s0

    def _on_script_pad(self, value, sender):
        if self._levels:
            return self._on_level_pad(value, sender)
        if self._step_mode:
            return self._on_step_pad(value, sender)
        i_pad = self._pads.index(sender)
        if self.pad_mode() == 'chords' or (value == 0 and i_pad in self._chord_notes):
            return self.chord_pad(i_pad, value)
        if value == 0:
            return
        i = self._pads.index(sender)
        col, row = i % 4, i // 4                    # row 0 = bottom
        tracks, t0, scenes, s0 = self._ring()
        if t0 + col >= len(tracks):
            return
        track = tracks[t0 + col]
        if self._pad_mode == 'clips':
            scene = s0 + (3 - row)
            if scene >= len(scenes):
                return
            slot = track.clip_slots[scene]
            if self._shift:
                track.stop_all_clips()
            else:
                slot.fire()
                self.song().view.selected_track = track
        elif self._pad_mode == 'mixer':
            if row == 0:
                self.song().view.selected_track = track
            elif row == 1:
                track.mute = not track.mute
            elif row == 2:
                track.solo = not track.solo
            elif row == 3 and track.can_be_armed:
                track.arm = not track.arm

    def _refresh_session_pads(self):
        tracks, t0, scenes, s0 = self._ring()
        blink = self._tick % 4 < 2
        for i in range(16):
            col, row = i % 4, i // 4
            c = (0, 0, 0)
            if t0 + col < len(tracks):
                track = tracks[t0 + col]
                if self._pad_mode == 'clips':
                    scene = s0 + (3 - row)
                    if scene < len(scenes):
                        slot = track.clip_slots[scene]
                        if slot.has_clip:
                            clip = slot.clip
                            c = rgb7(clip.color)
                            if clip.is_recording:
                                c = (127, 0, 0) if blink else (30, 0, 0)
                            elif clip.is_triggered:
                                c = c if blink else scaled(c, 0.2)
                            elif not clip.is_playing:
                                c = scaled(c, 0.3)
                        elif getattr(track, 'arm', False):
                            c = (12, 0, 0)
                else:
                    if row == 0:
                        c = rgb7(track.color) if track == self.song().view.selected_track else scaled(rgb7(track.color), 0.3)
                    elif row == 1:
                        c = (100, 75, 0) if not track.mute else (3, 2, 0)
                    elif row == 2:
                        c = (0, 50, 127) if track.solo else (0, 2, 5)
                    elif row == 3 and track.can_be_armed:
                        c = (127, 0, 0) if track.arm else (5, 0, 0)
            self._pad_color(i, c)

    def _refresh_key_pads(self):
        track_rgb = rgb7(self._selected_track().color)
        root, _ = self._scale()
        for i in range(16):
            n = self._pad_note(i)
            self._pad_color(i, track_rgb if (n - root) % 12 == 0 else scaled(track_rgb, 0.25))

    # ---------- step sequencer (pads = 16 sixteenths of one bar; groups A-D = bar 1-4) ----------
    STEP = 0.25

    def _current_rack(self):
        track = self._selected_track()
        return self._drum_rack(track.devices) if hasattr(track, 'devices') else None

    def current_step_note(self):
        rack = self._current_rack()
        if rack is not None and rack.view.selected_drum_pad is not None:
            return rack.view.selected_drum_pad.note
        return self._step_note

    def step_clip(self, create=False):
        song = self.song()
        slot = song.view.highlighted_clip_slot
        if slot is None:
            return None
        if slot.has_clip:
            return slot.clip if slot.clip.is_midi_clip else None
        if create and song.view.selected_track.has_midi_input:
            slot.create_clip(4.0)
            slot.fire()                                     # MPC-style: the pattern runs straight away
            self.show_message('New 1-bar clip — playing')
            return slot.clip
        return None

    def _ensure_length(self, clip, needed):
        if clip.length >= needed:
            return
        for attr in ('loop_end', 'end_marker', 'loop_end'):
            try:
                setattr(clip, attr, needed)
            except Exception:
                pass

    def preview(self, note, velocity=100):
        # play the sound on the selected track through the helper (note on ch 11), note off after ~0.2 s
        self._send_midi((0xF0, 0x7D, 0x4D, 0x10, note & 127, max(1, min(127, int(velocity))), 0xF7))
        self.schedule_message(2, lambda: self._send_midi((0xF0, 0x7D, 0x4D, 0x11, note & 127, 0, 0xF7)))

    # ---------- WAVE page Q-Links: sample-accurate start / end, zoom, slice (MPC sample edit) ----------
    def _simpler_param(self, d, name):
        return next((p for p in d.parameters if p.name == name), None)

    def _wave_page0(self, d):
        """the first Q-Link page of the SIMPLER screen (mockup): per play mode"""
        if d.playback_mode == 2:                    # MPC: Q1 / Q2 = start / end of the chop you're on, the jog wheel = next / previous chop
            return ['CHOP START', 'CHOP END', 'SENSITIVITY', 'FILTER']
        if d.playback_mode == 1:                    # (zoom is done by hand on the screen, not on a Q-Link)
            return ['START', 'END', 'TRANSPOSE', 'FILTER']
        return ['START', 'END', 'DECAY', 'FILTER']

    # the chop you're on belongs to ONE sample: another sample (or track) never inherits its position
    @property
    def _wave_slice(self):
        v = self.__dict__.get('_ws')
        if v is None:
            return None
        try:
            d = self._screen._simpler()
            return v[1] if d is not None and d.sample is not None and d.sample.file_path == v[0] else None
        except Exception:
            return None

    @_wave_slice.setter
    def _wave_slice(self, frame):
        try:
            d = self._screen._simpler() if frame is not None else None
            self.__dict__['_ws'] = (d.sample.file_path, frame) if d is not None and d.sample is not None else None
        except Exception:
            self.__dict__['_ws'] = None

    def _chops(self, s):
        """the chop starts inside START–END (chop 1 = the START marker)"""
        cuts = sorted(x for x in s.slices if s.start_marker <= x < s.end_marker)
        if not cuts or cuts[0] != s.start_marker:
            cuts = [s.start_marker] + cuts
        return cuts

    def _move_cut(self, s, k, new, G=None):
        """move the start of chop k (k = 0: the START marker) to `new`; chops in the way are pushed along, not stopped at
        (MPC). Returns the new frame of chop k."""
        G = G or int(0.0105 * (getattr(s, 'sample_rate', 44100) or 44100))   # Live keeps chops ≥ 10 ms apart
        cuts = self._chops(s)
        n = len(cuts)
        new = int(max(k * G, min(s.end_marker - (n - k) * G, new)))
        pos = list(cuts)
        pos[k] = new
        for j in range(k + 1, n):                       # pushed to the right
            pos[j] = max(pos[j], pos[j - 1] + G)
        for j in range(k - 1, -1, -1):                  # pushed to the left
            pos[j] = min(pos[j], pos[j + 1] - G)
        # apply in an order where no chop ever crosses its neighbour: moving right → from the far end back, left → from the start on
        order = range(n - 1, -1, -1) if new > cuts[k] else range(n)
        out = new
        for j in order:
            if pos[j] == cuts[j]:
                continue
            if j == 0:
                s.start_marker = pos[0]
                got = pos[0]
            else:
                got = s.move_slice(cuts[j], pos[j])
            if j == k:
                out = got
        return out

    def wave_chop(self, step):
        """next / previous chop (jog wheel on the SIMPLER page): select it, hear it, show it"""
        d = self._screen._simpler()
        if d is None or d.sample is None or d.playback_mode != 2:
            return False
        s = d.sample
        cuts = self._chops(s)
        if not cuts:
            return True
        cur = cuts.index(self._wave_slice) if self._wave_slice in cuts else -1
        n = max(0, min(len(cuts) - 1, cur + step)) if cur >= 0 else 0
        self._wave_slice = cuts[n]
        nxt = cuts[n + 1] if n + 1 < len(cuts) else s.end_marker
        self._screen.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': cuts[n], 'slice': cuts[n],
                              'chop': [cuts[n], nxt], 'index': n, 'count': len(cuts)})
        self.preview(36 + n, 100)
        return True

    def wave_delete_chop(self):
        """ERASE on the SIMPLER page (slices): delete the chop you're on — it joins the one before (MPC)"""
        d = self._screen._simpler()
        if d is None or d.sample is None or d.playback_mode != 2:
            return False
        s = d.sample
        cuts = self._chops(s)
        k = cuts.index(self._wave_slice) if self._wave_slice in cuts else -1
        if k < 0:
            self._screen.send_ui({'type': 'notice', 'text': 'Pick a chop first (turn the wheel), then ERASE'})
        elif k == 0:
            self._screen.send_ui({'type': 'notice', 'text': "Chop 1 is the start of the sample — move it with Q1 instead"})
        else:
            s.remove_slice(cuts[k])
            self._wave_slice = cuts[k - 1]
            nxt = cuts[k + 1] if k + 1 < len(cuts) else s.end_marker
            self._screen.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': cuts[k - 1], 'slice': cuts[k - 1],
                                  'chop': [cuts[k - 1], nxt]})
            self._screen.send_ui({'type': 'notice', 'text': 'Chop %d deleted · now %d chops' % (k + 1, len(cuts) - 1)})
        return True

    def wave_qlink_info(self):
        """for the SIMPLER page: the Q-Link pages and what Q1-Q4 do right now (+ their values)"""
        d = self._screen._simpler()
        if d is None:
            return None
        names, pages = device_layout(d)
        if self._wave_bank == 0:
            s = d.sample
            labels = []
            for n in self._wave_page0(d):
                v = ''
                if n == 'CHOP START' and s is not None:
                    cuts = self._chops(s)
                    k = cuts.index(self._wave_slice) if self._wave_slice in cuts else 0
                    n = 'CHOP %d START' % (k + 1) if cuts else 'CHOP START'
                    v = '%.3f s' % (cuts[k] / float(getattr(s, 'sample_rate', 44100) or 44100)) if cuts else '–'
                elif n == 'CHOP END' and s is not None:
                    cuts = self._chops(s)
                    k = cuts.index(self._wave_slice) if self._wave_slice in cuts else 0
                    end = cuts[k + 1] if k + 1 < len(cuts) else s.end_marker
                    n = 'CHOP %d END' % (k + 1) if cuts else 'CHOP END'
                    v = '%.3f s' % (end / float(getattr(s, 'sample_rate', 44100) or 44100))
                elif n == 'SENSITIVITY' and s is not None:
                    st = s.slicing_style
                    if st == 2:
                        n, v = 'PARTS', str(s.slicing_region_count)
                    elif st == 1:
                        n, v = 'DIVISION', str(s.slicing_beat_division)
                    elif st == 3:
                        n, v = 'MANUAL', 'tap to cut'
                    else:
                        v = '%d%%' % int(round(s.slicing_sensitivity * 100))
                elif n in ('DECAY', 'FILTER', 'TRANSPOSE'):
                    p = self._simpler_param(d, {'DECAY': 'Ve Decay', 'FILTER': 'Filter Freq', 'TRANSPOSE': 'Transpose'}[n])
                    v = p.str_for_value(p.value) if p is not None else ''
                labels.append([n, v])
        else:
            params = list(d.parameters)[1:]
            labels = [[params[i].name, params[i].str_for_value(params[i].value)] for i in pages[min(self._wave_bank, len(pages)) - 1]]
        return {'pages': ['EDIT'] + names, 'bank': self._wave_bank, 'labels': labels,
                'slice': self._wave_slice}          # the chop the wheel is on (the screen highlights it, also after a restart)

    def _wave_qlink(self, i, d):
        simpler = self._screen._simpler()
        if simpler is None or simpler.sample is None:
            return
        s = simpler.sample
        role = self._wave_page0(simpler)[i]
        span = (self._wave_view[1] - self._wave_view[0]) if self._wave_view else s.length
        step = max(1.0, span / 600.0) * (0.1 if self._shift else 1.0)        # ~600 ticks across the visible part
        move = int(round(d * step)) or (1 if d > 0 else -1)
        if role == 'START':
            s.start_marker = max(0, min(s.end_marker - 1, s.start_marker + move))
            self._screen.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': s.start_marker})
        elif role == 'END':
            s.end_marker = max(s.start_marker + 1, min(s.length - 1, s.end_marker + move))
            self._screen.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': s.end_marker})
        elif role == 'ZOOM':
            self._screen.send_ui({'type': 'wave_zoom', 'delta': d})
        elif role == 'CHOP START':                      # move the start of the chop you're on (between its neighbours)
            cuts = self._chops(s)
            if not cuts:
                return
            k = cuts.index(self._wave_slice) if self._wave_slice in cuts else 0
            new = self._move_cut(s, k, cuts[k] + move)     # (chop 1 = the START marker; neighbours get pushed along)
            self._wave_slice = new
            self._screen.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': new, 'slice': new})
        elif role == 'CHOP END':                        # its end = the start of the next chop (or the END marker for the last one)
            cuts = self._chops(s)
            if not cuts:
                return
            k = cuts.index(self._wave_slice) if self._wave_slice in cuts else 0
            if k + 1 < len(cuts):
                new = self._move_cut(s, k + 1, max(cuts[k] + 64, cuts[k + 1] + move))   # pushes the chops after it along
            else:
                new = int(max(cuts[k] + 64, min(s.length, s.end_marker + move)))
                s.end_marker = new
            self._wave_slice = cuts[k]
            self._screen.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': cuts[k], 'keep': new})
        elif role == 'SENSITIVITY':
            if s.slicing_style == 0:
                s.slicing_sensitivity = max(0.0, min(1.0, s.slicing_sensitivity + d * 0.01))
            else:
                self._q_rest[1] += d / 5.0
                k = int(self._q_rest[1])
                if k:
                    self._q_rest[1] -= k
                    if s.slicing_style == 2:
                        s.slicing_region_count = max(2, min(64, s.slicing_region_count + k))
                    elif s.slicing_style == 1:
                        s.slicing_beat_division = max(0, min(10, s.slicing_beat_division + k))
        elif role in ('DECAY', 'FILTER', 'TRANSPOSE'):
            p = self._simpler_param(simpler, {'DECAY': 'Ve Decay', 'FILTER': 'Filter Freq', 'TRANSPOSE': 'Transpose'}[role])
            if p is not None:
                if p.is_quantized or role == 'TRANSPOSE':
                    self._q_rest[3] += d / 5.0
                    k = int(self._q_rest[3])
                    if k:
                        self._q_rest[3] -= k
                        p.value = max(p.min, min(p.max, p.value + k))
                else:
                    p.value = max(p.min, min(p.max, p.value + d * (p.max - p.min) / (1000.0 if self._shift else 200.0)))

    # ---------- MELODY: one sample, a pitch per step, changed on the fly (always in the song's key) ----------
    def scale_step(self, pitch, steps):
        """move a pitch by whole scale steps (snapping to the scale first)"""
        root, intervals = self._scale()
        pcs = sorted(set((root + i) % 12 for i in intervals))
        def in_scale(p):
            return p % 12 in pcs
        p = pitch
        while not in_scale(p) and p > 0:
            p -= 1
        direction = 1 if steps > 0 else -1
        for _ in range(abs(steps)):
            p += direction
            while not in_scale(p) and 0 < p < 127:
                p += direction
        return max(0, min(127, p))

    # ---------- NOTES page: a piano roll (melody composer) — notes with their own start / length ----------
    _note_sel = None                                # (pitch, start) of the note the Q-Links edit

    def _roll_find(self, clip, pitch, start):
        """(Live's note vector, the note in it): apply_note_modifications wants that vector back, not a list"""
        if clip is None:
            return None, None
        ns = clip.get_notes_extended(int(pitch), 1, max(0.0, float(start) - 0.002), 0.004)
        return (ns, ns[0]) if ns else (None, None)

    def roll_add(self, pitch, start, dur, vel=100):
        clip = self.step_clip(create=True)
        if clip is None:
            return
        scr = getattr(self, '_screen', None)
        if scr is not None and getattr(scr, '_roll_clip', None) is not clip:   # a clip you just started drawing in:
            scr._roll_clip, scr._roll_track = clip, self.song().view.selected_track   # keep the rows where they are
        self._ensure_length(clip, 4.0 * (int((start + dur - 0.001) // 4.0) + 1))
        clip.add_new_notes((Live.Clip.MidiNoteSpecification(pitch=int(pitch), start_time=float(start), duration=float(dur),
                                                            velocity=float(vel)),))
        self._note_sel = (int(pitch), float(start))
        if not self.song().is_playing:
            self.preview(int(pitch), vel)

    def roll_delete(self, pitch, start):
        clip = self.step_clip()
        if clip is not None:
            clip.remove_notes_extended(int(pitch), 1, max(0.0, float(start) - 0.002), 0.004)
        if self._note_sel == (int(pitch), float(start)):
            self._note_sel = None

    def roll_move(self, pitch, start, new_pitch, new_start, new_dur):
        clip = self.step_clip()
        vec, n = self._roll_find(clip, pitch, start)
        if n is None:
            return
        n.pitch = max(0, min(127, int(new_pitch)))
        n.start_time = max(0.0, float(new_start))
        n.duration = max(1 / 32.0, float(new_dur))
        self._ensure_length(clip, 4.0 * (int((n.start_time + n.duration - 0.001) // 4.0) + 1))
        clip.apply_note_modifications(vec)
        self._note_sel = (n.pitch, n.start_time)
        if int(new_pitch) != int(pitch) and not self.song().is_playing:
            self.preview(n.pitch, n.velocity)

    def roll_quantize(self, grid):
        clip = self.step_clip()
        if clip is None:
            return
        ns = clip.get_notes_extended(0, 128, 0.0, clip.length)
        for n in ns:
            n.start_time = round(n.start_time / grid) * grid
        if ns:
            clip.apply_note_modifications(ns)
        if self._note_sel is not None:
            self._note_sel = (self._note_sel[0], round(self._note_sel[1] / grid) * grid)
        self.show_message('Quantized to 1/%d' % int(round(4 / grid)))

    def _roll_qlink(self, i, d, clip):
        """Q1 PITCH (in key, or by semitone) · Q2 VELOCITY · Q3 LENGTH (1/16 steps) · Q4 NUDGE (early / late)"""
        if self._note_sel is None:
            return
        vec, n = self._roll_find(clip, *self._note_sel)
        if n is None:
            self._note_sel = None
            return
        self._q_rest[i] += d / (3.0 if i in (0, 2) else 1.0)
        k = int(self._q_rest[i])
        if k == 0:
            return
        self._q_rest[i] -= k
        if i == 0:
            p = n.pitch
            if self._mel_inkey:                     # the next note of the scale up / down
                root, iv = self._scale()
                for _ in range(abs(k)):
                    p += 1 if k > 0 else -1
                    while (p - root) % 12 not in iv:
                        p += 1 if k > 0 else -1
            else:
                p += k
            n.pitch = max(0, min(127, p))
            if not self.song().is_playing:
                self.preview(n.pitch, n.velocity)
        elif i == 1:
            n.velocity = float(max(1, min(127, n.velocity + k)))
        elif i == 2:
            n.duration = max(0.0625, n.duration + 0.25 * k)
        else:
            n.start_time = max(0.0, n.start_time + 0.005 * k)
        clip.apply_note_modifications(vec)
        self._note_sel = (n.pitch, n.start_time)

    def melody_notes(self, clip):
        """the top note of every step of the current bar: {step: note}"""
        t0 = self._step_page * 4.0
        out = {}
        for n in clip.get_notes_extended(0, 128, t0, 4.0):
            k = int((n.start_time - t0) / self.STEP + 0.001)
            if k not in out or n.pitch > out[k].pitch:
                out[k] = n
        return out

    def melody_step(self, step, delta):
        """+ / − on a step: move its note a scale step (an empty step gets the root of the octave on screen)"""
        clip = self.step_clip(create=True)
        if clip is None:
            return
        notes = self.melody_notes(clip)
        if step in notes:
            n = notes[step]
            vec = clip.get_notes_extended(n.pitch, 1, n.start_time, 0.001)
            new = self.scale_step(n.pitch, delta)
            for x in vec:
                x.pitch = new
            clip.apply_note_modifications(vec)
            if not self.song().is_playing:
                self.preview(new)
        else:
            self.toggle_step(self.melodic_rows()[-1], step, self._step_page)
        self._step_sel = (self.melody_notes(clip)[step].pitch if step in self.melody_notes(clip) else 0, step)

    def melody_transpose(self, delta):
        clip = self.step_clip()
        if clip is None:
            return
        vec = clip.get_notes_extended(0, 128, 0.0, clip.length)
        for n in vec:
            n.pitch = self.scale_step(n.pitch, delta)
        clip.apply_note_modifications(vec)
        self._mel_transpose = getattr(self, '_mel_transpose', 0) + delta

    def melody_random(self):
        import random
        clip = self.step_clip()
        if clip is None:
            return
        root, intervals = self._scale()
        base = 12 * (self._mel_oct + 2) + root
        choices = [base + i for i in intervals] + [base + 12 + i for i in intervals[:3]]
        vec = clip.get_notes_extended(0, 128, self._step_page * 4.0, 4.0)
        for n in vec:
            n.pitch = random.choice(choices)
        clip.apply_note_modifications(vec)

    def _melody_qlink(self, i, d, clip):
        if i == 0:                                      # Q1: the whole loop up / down in key
            self._q_rest[0] += d / 8.0
            k = int(self._q_rest[0])
            if k:
                self._q_rest[0] -= k
                self.melody_transpose(k)
        elif i == 1 and self._step_sel is not None:    # Q2: the selected step
            self._q_rest[1] += d / 6.0
            k = int(self._q_rest[1])
            if k:
                self._q_rest[1] -= k
                self.melody_step(self._step_sel[1], k)
        elif i == 2:                                    # Q3: glide (Simpler / instrument)
            dev = self._find_param(list(self._selected_track().devices), ('Glide Time', 'Glide', 'Portamento'))
            mode = self._find_param(list(self._selected_track().devices), ('Glide Mode',))
            if dev is not None:
                if mode is not None and mode.value == mode.min and d > 0:
                    mode.value = mode.min + 1          # glide on
                dev.value = max(dev.min, min(dev.max, dev.value + d * (dev.max - dev.min) / 200.0))
        elif i == 3:                                    # Q4: note length of the whole loop
            vec = clip.get_notes_extended(0, 128, 0.0, clip.length)
            for n in vec:
                n.duration = max(0.03, min(4.0, n.duration * (1.0 + d * 0.04)))
            clip.apply_note_modifications(vec)

    # ---------- REC SAMPLE: record the Touch's input (or resample the beat) straight into this track's Simpler ----------
    SAMPLER_TRACK = 'Sampler In'

    def _sampler_track(self, source):
        song = self.song()
        track = next((t for t in song.tracks if t.name == self.SAMPLER_TRACK), None)
        if track is None:
            song.create_audio_track(-1)
            track = list(song.tracks)[-1]
            track.name = self.SAMPLER_TRACK
        names = [r.display_name for r in track.available_input_routing_types]
        want = 'Resampling' if source == 'resample' else next((n for n in names if n.startswith('Ext')), None)
        if want is None:
            return None, 'No audio input in Ableton: Settings → Audio → Audio Input Device = MPC Touch Audio'
        track.input_routing_type = track.available_input_routing_types[names.index(want)]
        track.current_monitoring_state = 2 if source == 'resample' else 1      # resample: off (no feedback); input: auto
        return track, None

    def rec_state(self):
        if self._rec is None:
            return {'rec': False}
        track = self._rec[0]
        return {'rec': True, 'source': self._rec[3], 'level': round(max(track.input_meter_left, track.input_meter_right), 3)}

    def rec_sample(self, source='input'):
        song = self.song()
        if self._rec is None:
            target = song.view.selected_track
            if not getattr(target, 'has_midi_input', False):
                self.show_message('REC SAMPLE: select the MIDI track (Simpler) to sample into')
                return
            track, err = self._sampler_track(source)
            if track is None:
                self.show_message(err)
                self._screen.send_ui({'type': 'notice', 'text': err})
                return
            slot = next((sl for sl in track.clip_slots if not sl.has_clip), None)
            if slot is None:
                song.create_scene(-1)
                slot = list(track.clip_slots)[-1]
            track.arm = True
            song.view.selected_track = target           # stay on your Simpler track
            try:
                slot.fire(launch_quantization=Live.Song.Quantization.q_no_q)   # start right now, not on the next bar
            except Exception:
                slot.fire()
            self._rec = (track, slot, target, source)
            self.show_message('Sampling… press REC SAMPLE again to stop')
        else:
            track, slot, target, source = self._rec
            self._rec = None
            track.stop_all_clips(False)
            track.arm = False
            def finish(tries=[0]):
                clip = slot.clip if slot.has_clip else None
                path = getattr(clip, 'file_path', '') if clip is not None else ''
                if not path:
                    tries[0] += 1
                    if tries[0] < 20:
                        self.schedule_message(2, finish)
                    return
                song.view.selected_track = target
                def into_simpler(tries=[0]):
                    simpler = next((d for d in target.devices if d.class_name == 'OriginalSimpler'), None)
                    if simpler is None:
                        if tries[0] == 0:                   # no Simpler yet (empty MIDI track): put one on it
                            browser = self._app().browser
                            item = next((c for c in browser.instruments.children if c.name == 'Simpler'), None)
                            if item is not None:
                                browser.load_item(item)
                        tries[0] += 1
                        if tries[0] < 15:
                            self.schedule_message(2, into_simpler)
                        return
                    simpler.replace_sample(path)
                    self._screen.send_ui({'type': 'notice', 'text': 'Sample loaded into Simpler'})
                    if slot.has_clip:
                        slot.delete_clip()                  # the file stays in the project's Recorded folder
                into_simpler()
            self.schedule_message(3, finish)

    # ---------- MPC 16 Levels ----------
    def set_levels(self, on, param=None):
        self._restore_level_param()
        if param:
            self._levels_param = param
        self._levels = bool(on)
        if self._levels and self._step_mode:
            self._step_mode = False
            self._screen.send_ui({'type': 'step_mode', 'on': False})
        self._apply_bank()
        self._screen.send_ui({'type': 'levels', 'on': self._levels, 'param': self._levels_param})
        self.show_message(('16 Levels: ' + self._levels_param + ' — pad 1 lowest, pad 16 highest') if self._levels else 'Pads play')

    def level_base(self):
        """the note 16 Levels plays: the selected drum pad / slice, or the root of the octave on screen"""
        if self.is_melodic():
            return self.melodic_rows()[-1]
        return self.current_step_note()

    def _find_param(self, devices, names):
        for d in devices:
            for p in d.parameters:
                if p.name in names:
                    return p
            if d.can_have_chains:
                for ch in d.chains:
                    found = self._find_param(ch.devices, names)
                    if found is not None:
                        return found
        return None

    def _level_param(self, names):
        rack = self._current_rack()
        if rack is not None and not self.is_melodic():
            pad = rack.drum_pads[self.current_step_note()]
            devices = list(pad.chains[0].devices) if pad.chains else []
        else:
            devices = list(self._selected_track().devices)
        return self._find_param(devices, names)

    def _restore_level_param(self):
        if self._level_restore is not None:
            p, v = self._level_restore
            try:
                p.value = v
            except Exception:
                pass
            self._level_restore = None

    def _on_level_pad(self, value, sender):
        i = self._pads.index(sender)                    # 0 = pad 1 (bottom left)
        if value == 0:
            n = self._level_notes.pop(i, None)
            if n is not None:
                self._send_midi((0xF0, 0x7D, 0x4D, 0x11, n & 127, 0, 0xF7))
            return
        note, vel, p = self.level_base(), value, self._levels_param
        if p == 'velocity':
            vel = int(round(8 + i * 119 / 15.0))
        elif p == 'tune':
            if self.is_melodic():
                note += i - 8
            else:
                prm = self._level_param(('Transpose',))
                if prm is not None:
                    if self._level_restore is None:
                        self._level_restore = (prm, prm.value)
                    prm.value = max(prm.min, min(prm.max, float(i - 8)))
        elif p == 'filter':
            prm = self._level_param(('Filter Freq', 'Frequency', 'Filter Frequency'))
            if prm is not None:
                if self._level_restore is None:
                    self._level_restore = (prm, prm.value)
                prm.value = prm.min + (prm.max - prm.min) * (0.15 + 0.85 * i / 15.0)
        note = max(0, min(127, note))
        self._level_notes[i] = note
        self._send_midi((0xF0, 0x7D, 0x4D, 0x10, note, max(1, min(127, vel)), 0xF7))

    def _refresh_level_pads(self):
        rack = self._current_rack()
        rgb = rgb7(self._selected_track().color)
        if rack is not None and not self.is_melodic():
            pad = rack.drum_pads[self.current_step_note()]
            if pad.chains:
                rgb = rgb7(pad.chains[0].color)
        for i in range(16):
            c = scaled(rgb, 0.12 + 0.88 * i / 15.0)
            if i in self._level_notes:
                c = (127, 127, 127)
            self._pad_color(i, c)

    # ---------- swing (MPC style: the 2nd and 4th 16th of every beat come later) ----------
    def swing(self):
        if self._swing is None:
            try:
                self._swing = float(self.song().get_data('mpc_swing', 0.5))
            except Exception:
                self._swing = 0.5
        return self._swing

    @staticmethod
    def swing_offset(v):
        return (v - 0.5) * 0.5                          # beats: 58 % → the off 16th sits 0.04 beat late

    def set_swing(self, v):
        old = self.swing()
        v = max(0.5, min(0.75, round(v, 3)))
        if v == old:
            return
        self._swing = v
        try:
            self.song().set_data('mpc_swing', v)
        except Exception:
            pass
        clip = self.step_clip()
        if clip is None:
            return
        o_old, o_new = self.swing_offset(old), self.swing_offset(v)
        notes = clip.get_notes_extended(0, 128, 0.0, clip.length)
        moved = False
        for n in notes:                                 # re-time the off-beat 16ths of the clip on screen
            pos = n.start_time % 0.5
            if abs(pos - (0.25 + o_old)) < 0.012:
                n.start_time = n.start_time - pos + 0.25 + o_new
                moved = True
        if moved:
            clip.apply_note_modifications(notes)

    # ---------- one step: chance, ratchet, velocity, pitch (screen selects it, Q-Links / buttons edit it) ----------
    NUDGE = 0.05                                        # a step's notes may sit up to 0.05 beat early (NUDGE / LAID BACK)

    def _step_notes(self, clip, pitch, step):
        t = self._step_page * 4.0 + step * self.STEP - self.NUDGE
        return clip.get_notes_extended(pitch, 1, max(0.0, t), self.STEP)   # Live's own note vector (needed to apply edits)

    def _step_base(self, step):
        t = self._step_page * 4.0 + step * self.STEP
        return t + (self.swing_offset(self.swing()) if step % 2 == 1 else 0.0)

    # ---------- the selected ROW (pad / note) in the bar on screen: fill, clear, velocity, laid back ----------
    def row_edit(self, what, value=None):
        clip = self.step_clip(create=what == 'fill')
        if clip is None:
            return
        note, t0 = self.current_step_note(), self._step_page * 4.0
        self._ensure_length(clip, t0 + 4.0)
        notes = clip.get_notes_extended(note, 1, max(0.0, t0 - self.NUDGE), 4.0)
        if what == 'fill':                               # 1/4 · 1/8 · 1/16 · offbeat (the 8th between the beats)
            steps = {'4': range(0, 16, 4), '8': range(0, 16, 2), '16': range(16), 'off': range(2, 16, 4)}.get(str(value), [])
            clip.remove_notes_extended(note, 1, max(0.0, t0 - self.NUDGE), 4.0)
            clip.add_new_notes(tuple(Live.Clip.MidiNoteSpecification(pitch=note, start_time=self._step_base(k),
                                                                     duration=t0 + k * self.STEP + self.STEP - self._step_base(k),
                                                                     velocity=100.0) for k in steps))
            self.show_message('Filled 1/%s' % value if value != 'off' else 'Filled the offbeats')
        elif what == 'clear':
            clip.remove_notes_extended(note, 1, max(0.0, t0 - self.NUDGE), 4.0)
            self._step_sel = None
        elif what == 'velocity' and notes:              # absolute 1..127
            for n in notes:
                n.velocity = max(1.0, min(127.0, float(value)))
            clip.apply_note_modifications(notes)
        elif what == 'vary' and notes:                   # VARY VELOCITY: every hit a little different (feel)
            import random
            for n in notes:
                n.velocity = float(max(20, min(127, n.velocity + random.randint(-12, 12))))
            clip.apply_note_modifications(notes)
        elif what == 'nudge' and notes:                  # LAID BACK (+) / RUSH (−): the whole row, in beats
            for n in notes:
                n.start_time = max(0.0, n.start_time + float(value))
            clip.apply_note_modifications(notes)

    def set_step_len(self, v):                          # NOTE LENGTH: every note in the bar on screen
        self._step_len = v
        clip = self.step_clip()
        if clip is None:
            return
        notes = clip.get_notes_extended(0, 128, max(0.0, self._step_page * 4.0 - self.NUDGE), 4.0)
        for n in notes:
            n.duration = v
        if notes:
            clip.apply_note_modifications(notes)

    def row_info(self, clip):
        note, t0 = self.current_step_note(), self._step_page * 4.0
        notes = clip.get_notes_extended(note, 1, max(0.0, t0 - self.NUDGE), 4.0) if clip is not None else []
        if not notes:
            return {'note': note, 'velocity': None, 'nudge': 0}
        first = {}                                      # one note per step: a roll's repeats are not "late"
        for n in notes:
            k = int((n.start_time - t0 + self.NUDGE) / self.STEP + 0.001)
            if k not in first or n.start_time < first[k]:
                first[k] = n.start_time
        offs = [t - self._step_base(k) for k, t in first.items()]
        return {'note': note, 'velocity': int(round(sum(n.velocity for n in notes) / len(notes))),
                'nudge': int(round(1000 * sum(offs) / len(offs)))}

    def step_edit(self, what, value):
        if self._step_sel is None:
            return
        clip = self.step_clip()
        if clip is None:
            return
        pitch, step = self._step_sel
        notes = self._step_notes(clip, pitch, step)
        if not notes:
            return
        if what == 'ratchet':
            n0 = notes[0]
            t = self._step_page * 4.0 + step * self.STEP
            clip.remove_notes_extended(pitch, 1, t, self.STEP)
            count = max(1, min(4, int(value)))
            start = t + (self.swing_offset(self.swing()) if step % 2 == 1 else 0.0)
            length = (t + self.STEP - start) / count
            clip.add_new_notes(tuple(Live.Clip.MidiNoteSpecification(pitch=pitch, start_time=start + k * length, duration=length * 0.85,
                                                                     velocity=n0.velocity, probability=n0.probability) for k in range(count)))
            return
        if what == 'nudge':                             # this step a little early (−) / late (+), in beats
            base = self._step_base(step)
            for n in notes:
                n.start_time = max(0.0, max(base - self.NUDGE, min(base + 0.06, n.start_time + float(value))))
            clip.apply_note_modifications(notes)
            return
        if what == 'delete':
            clip.remove_notes_extended(pitch, 1, max(0.0, self._step_page * 4.0 + step * self.STEP - self.NUDGE), self.STEP)
            self._step_sel = None
            return
        for n in notes:
            if what == 'chance':
                n.probability = max(0.0, min(1.0, float(value)))
            elif what == 'velocity':
                n.velocity = max(1.0, min(127.0, float(value)))
            elif what == 'pitch':
                n.pitch = max(0, min(127, int(value)))
        clip.apply_note_modifications(notes)
        if what == 'pitch':
            self._step_sel = (max(0, min(127, int(value))), step)

    def copy_bar(self):
        """COPY BAR: the bar on screen into the next bar (the clip grows when needed), then show that bar"""
        clip = self.step_clip(create=False)
        if clip is None:
            return
        src = self._step_page * 4.0
        dst = src + 4.0
        if self._step_page >= 3:
            self.show_message('Bar 4 is the last bar')
            return
        self._ensure_length(clip, dst + 4.0)
        clip.remove_notes_extended(0, 128, dst, 4.0)
        specs = []
        for n in list(clip.get_notes_extended(0, 128, src, 4.0)):
            specs.append(Live.Clip.MidiNoteSpecification(pitch=n.pitch, start_time=n.start_time + 4.0, duration=n.duration,
                                                         velocity=n.velocity, probability=n.probability))
        if specs:
            clip.add_new_notes(tuple(specs))
        self._step_page += 1
        self.show_message('Bar %d copied to bar %d' % (self._step_page, self._step_page + 1))

    def humanize(self):
        """HUMANIZE: every note in the bar on screen gets a slightly different velocity (+-12), like a real drummer"""
        import random
        clip = self.step_clip(create=False)
        if clip is None:
            return
        notes = clip.get_notes_extended(0, 128, self._step_page * 4.0, 4.0)
        for n in notes:
            spread = max(1, int(round(30 * self._humanize / 100.0)))
            n.velocity = float(max(20, min(127, n.velocity + random.randint(-spread, spread))))
        clip.apply_note_modifications(notes)
        self.show_message('Humanized')

    def toggle_step(self, note, step, page, velocity=100):
        clip = self.step_clip(create=True)
        if clip is None:
            self.show_message('Steps: select an empty or MIDI clip slot on a MIDI track')
            return
        t = page * 4.0 + step * self.STEP
        self._ensure_length(clip, (page + 1) * 4.0)
        if clip.get_notes_extended(note, 1, max(0.0, t - self.NUDGE), self.STEP):
            clip.remove_notes_extended(note, 1, max(0.0, t - self.NUDGE), self.STEP)
            if self._step_sel == (note, step):
                self._step_sel = None
        else:
            if not self.song().is_playing:
                self.preview(note, velocity)
            start = t + (self.swing_offset(self.swing()) if step % 2 == 1 else 0.0)    # swing
            clip.add_new_notes((Live.Clip.MidiNoteSpecification(pitch=note, start_time=start, duration=t + self.STEP - start,
                                                                velocity=float(velocity)),))

    def _on_step_pad(self, value, sender):
        if value == 0:
            return
        i = self._pads.index(sender)
        if self._shift:                             # SHIFT + pad = choose the sound / note to sequence
            note = self._pad_note(i) if self.is_melodic() else BANK_BASE[self._bank] + i
            self._step_note = note
            rack = self._current_rack()
            name = self.note_name(note)
            if rack is not None:
                rack.view.selected_drum_pad = rack.drum_pads[note]
                self.select_pad_sound(rack.drum_pads[note])
                name = rack.drum_pads[note].name
            self.preview(note, value)
            self.show_message('Steps: ' + name)
            return
        self.toggle_step(self.current_step_note(), i, self._step_page, max(1, value))

    def _refresh_step_pads(self):
        if self._shift:                                     # holding SHIFT: pads show the sounds to pick from
            return self._refresh_sound_pads()
        clip = self.step_clip()
        note = self.current_step_note()
        rack = self._current_rack()
        track = self._selected_track()
        rgb = rgb7(track.color)
        if rack is not None and rack.drum_pads[note].chains:
            rgb = rgb7(rack.drum_pads[note].chains[0].color)
        on = set()
        play = -1
        if clip is not None:
            start = self._step_page * 4.0
            for n in clip.get_notes_extended(note, 1, start, 4.0):
                on.add(int((n.start_time - start) / self.STEP + 0.001))
            if clip.is_playing:
                play = int((clip.playing_position - start) / self.STEP)
        for i in range(16):
            if i == play:
                c = (127, 127, 127) if i in on else (40, 40, 40)
            elif i in on:
                c = rgb
            else:
                c = (16, 16, 16) if i % 4 == 0 else (5, 5, 5)
            self._pad_color(i, c)

    def _refresh_sound_pads(self):
        rack = self._current_rack()
        selected = self.current_step_note()
        track_rgb = rgb7(self._selected_track().color)
        melodic = self.is_melodic()
        root, _ = self._scale()
        for i in range(16):
            note = self._pad_note(i) if melodic else BANK_BASE[self._bank] + i
            c = (0, 0, 0)
            if melodic:
                c = track_rgb if (note - root) % 12 == 0 else scaled(track_rgb, 0.5)
            elif rack is not None:
                pad = rack.drum_pads[note]
                if pad.chains:
                    c = rgb7(pad.chains[0].color)
            else:
                c = track_rgb
            if note == selected:
                c = (127, 127, 127)
            elif c != (0, 0, 0):
                c = scaled(c, 0.35)
            self._pad_color(i, c)

    def _drum_rack(self, devices):
        for d in devices:
            if d.can_have_drum_pads:
                return d
            if d.can_have_chains:
                for chain in d.chains:
                    found = self._drum_rack(chain.devices)
                    if found:
                        return found
        return None

    def _refresh_pads(self):
        track = self._selected_track()
        base = BANK_BASE[self._bank]
        track_rgb = rgb7(track.color) if hasattr(track, 'color') else (40, 40, 40)
        rack = self._drum_rack(track.devices) if hasattr(track, 'devices') else None
        simpler = None
        if rack is None and hasattr(track, 'devices'):
            for d in track.devices:
                if d.class_name == 'OriginalSimpler':
                    simpler = d
                    break
        if self.pad_mode() == 'chords':                  # chord pads: plain = track colour, rich = brighter
            for i in range(16):
                self._pad_color(i, track_rgb if i in self._chord_notes else scaled(track_rgb, 0.55 if i >= 8 else 0.3))
            return
        for i in range(16):
            note = base + i
            rgb = (0, 0, 0)
            if note > 127:
                pass
            elif rack is not None:
                pad = rack.drum_pads[note]
                if pad.chains:
                    rgb = rgb7(pad.chains[0].color) if hasattr(pad.chains[0], 'color') else track_rgb
                    selected = rack.view.selected_drum_pad
                    rgb = rgb if (selected is not None and selected.note == note) else scaled(rgb, 0.45)
                    if pad.mute:
                        rgb = (6, 0, 0)
            elif simpler is not None and simpler.playback_mode == 2 and simpler.sample is not None:
                slice_count = len(simpler.sample.slices)
                if 36 <= note < 36 + slice_count:
                    rgb = track_rgb
            else:
                rgb = track_rgb if note % 12 == 0 else scaled(track_rgb, 0.3)
            self._pad_color(i, rgb)

    # ---------- buttons ----------
    def _on_button(self, value, sender):
        self._handle_button(value, sender)
        self._sync_qlinks()                         # Q-LINK page / SHIFT fine mode right away
        self._update_lights()                       # lights follow the press right away
        self._screen.push()                         # and so does the screen

    def _handle_button(self, value, sender):
        note = sender.message_identifier()
        pressed = value > 0
        if note == SHIFT:
            self._shift = pressed
            self._send_mod()
            return
        if note == NOTE_REPEAT:
            if pressed and self._shift:
                self._repeat_latched = not self._repeat_latched
            self._repeat_held = pressed
            self._update_note_repeat()
            return
        # held buttons: need their release too
        if note == ERASE:                                # MPC: hold ERASE + tap a clip / track name / scene = delete it
            self._erase_held = pressed
            if pressed and self._screen.page == 'SAMPLE':
                self.wave_delete_chop()                 # SIMPLER page, slices: ERASE = delete the chop you're on
            self._send_mod()
            return
        elif note == COPY:
            song = self.song()
            # COPY: tap a clip to pick it, tap slots to paste it there (released without pasting: into the slot below).
            # SHIFT+COPY = DELETE: tap what to delete. Nothing happens on release.
            if pressed:
                self._copy_held, self._copy_used, self._copy_src, self._copy_pasted = True, False, None, False
            else:
                self._copy_held = False
                shift = self._shift
                if self._copy_src is not None and not self._copy_pasted:
                    ti, si = self._copy_src
                    tracks = list(song.tracks)
                    if ti < len(tracks):
                        tracks[ti].duplicate_clip_slot(si)
                        self.show_message('Clip duplicated below')
                self._copy_src = None
            self._send_mod()
            return
        if not pressed:
            return
        song = self.song()
        shift = self._shift
        if note == PLAY:
            if not song.is_playing:
                if not self._resume_clips():
                    song.continue_playing()
        elif note == PLAY_START:
            song.current_song_time = 0.0
            if not self._resume_clips():
                song.start_playing()
        elif note == STOP:
            if shift:                                    # SHIFT+STOP: everything off, nothing to resume
                self._resume = []
                self._last_playing = []
                song.stop_all_clips()
            else:                                        # MPC: remember the clips that play, PLAY brings them back
                self._resume = [t.clip_slots[t.playing_slot_index] for t in song.tracks
                                if getattr(t, 'playing_slot_index', -1) >= 0 and t.playing_slot_index < len(t.clip_slots)]
            song.stop_playing()
        elif note == REC:                               # REC follows the view: Session = record a clip, Arrangement = timeline
            self.press_rec()
        elif note == OVERDUB:                           # layer onto what is already there (MIDI overdub)
            if self._app().view.is_view_visible('Session'):
                self.toggle_overdub()
            else:
                song.arrangement_overdub = not song.arrangement_overdub
        elif note == TAP:
            if shift:
                song.metronome = not song.metronome
            else:
                song.tap_tempo()
        elif note == UNDO:
            if shift:
                if song.can_redo:
                    song.redo()
            elif song.can_undo:
                song.undo()
        elif note == FULL_LEVEL:
            self._full_level = not self._full_level
            self._send_helper(1, 1 if self._full_level else 0)
            self.show_message('Full Level ' + ('on' if self._full_level else 'off'))
        elif note == LEVEL_16 and not shift:            # MPC 16 Levels: the selected sound on all pads
            self.set_levels(not self._levels)
        elif note == LEVEL_16:                          # SHIFT + 16 LEVEL: step sequencer
            self._step_mode = not self._step_mode
            if self._step_mode and self._levels:
                self.set_levels(False)
            self._apply_bank()
            self._screen.send_ui({'type': 'step_mode', 'on': self._step_mode})   # the screen follows straight away
            self.show_message('Step sequencer: pads = 16 steps, A-D = bar 1-4, SHIFT+pad = choose sound' if self._step_mode else 'Pads play')
        elif note in GROUPS and shift:               # SHIFT + A/B/C/D = pad mode
            self._pad_mode = ('drum', 'keys', 'clips', 'mixer')[GROUPS.index(note)]
            self._step_mode = False
            self._apply_bank()
            self.show_message({'drum': 'Pads: drums', 'keys': 'Pads: keyboard in the song key (A-D = octave)',
                               'clips': 'Pads: launch clips (SHIFT+pad = stop track)',
                               'mixer': 'Pads: mixer — rows: select / mute / solo / arm'}[self._pad_mode])
        elif note in GROUPS and self._step_mode:
            self._step_page = GROUPS.index(note)
            self.show_message('Steps: bar %d' % (self._step_page + 1))
        elif note in GROUPS and self.pad_mode() == 'chords':    # chord pads: A-D = the chord bank (the wheel = octave)
            self._chord_bank = GROUPS.index(note)
            self._chord_last = None
            self.show_message('Chords: bank %s · %s' % ('ABCD'[self._chord_bank], self.chord_scale()[2][self._chord_bank].lower()))
        elif note in GROUPS and self.pad_mode() == 'keys':      # keyboard: A-D = octave 1-4
            self.set_octave(GROUPS.index(note) + 1)
            self.show_message('Octave C%d' % self._mel_oct)
        elif note in GROUPS:
            self._bank = GROUPS.index(note)
            self._apply_bank()
            self.show_message('Pad bank %s' % 'ABCD'[self._bank])
        elif note == MAIN:
            view = self._app().view
            if shift:
                view.show_view('Detail')
                if view.is_view_visible('Detail/Clip'):
                    view.show_view('Detail/DeviceChain')
                else:
                    view.show_view('Detail/Clip')
            elif self._screen.page != 'SESSION':          # MPC: MAIN = the main (session) screen...
                self._screen.send_ui({'type': 'show_page', 'page': 'SESSION'})
            else:                                       # ...pressed again: Session <-> Arrangement
                self.toggle_main_view()
        elif note == BROWSE:                            # SHIFT = browser on the Touch screen, MENU = next screen page
            self._screen.send_ui({'type': 'browse_toggle'} if shift else {'type': 'next_page'})
        elif note == QLINK and self._screen.page == 'SAMPLE' and self._screen._simpler() is not None:
            names = ['EDIT'] + device_layout(self._screen._simpler())[0]
            self._wave_bank = (self._wave_bank + (-1 if shift else 1)) % len(names)
            self.show_message('Q-Links: ' + names[self._wave_bank])
        elif note == QLINK:
            device = self._selected_device()
            count = len(device_layout(device)[1]) if device is not None else 1
            self._qlink_bank = (self._qlink_bank + (-1 if shift else 1)) % count     # wraps around
            self._show_qlinks()
        elif note in (PLUS, MINUS):
            step = 1 if note == PLUS else -1
            if shift:
                self._select_device(step)
            else:
                self._select_track(step)
        elif note == JOG_PRESS and self._screen.page == 'DEVICE':
            device = self._selected_device()
            if device is not None and device.parameters:
                on = device.parameters[0]                   # "Device On"
                on.value = on.max if on.value == on.min else on.min
        elif note == JOG_PRESS and self._screen.page == 'BROWSE':
            pass                                        # handled by the screen app directly
        elif note == JOG_PRESS and self._screen.page == 'SAMPLE' and self.wave_chop(-1 if shift else 1):
            pass                                        # MPC: press = on to the next chop (SHIFT = back)
        elif note == JOG_PRESS:
            if shift:
                song.view.selected_scene.fire()
            else:
                slot = song.view.highlighted_clip_slot
                if slot is not None:
                    slot.fire()

    # ---------- COPY / DELETE on what you tap on the screen ----------
    def modifier(self):
        if getattr(self, '_erase_held', False):
            return 'delete'
        if self._copy_held:
            return 'delete' if self._shift else 'copy'
        return 'shift' if self._shift else None

    def _send_mod(self):
        src = None
        if self._copy_src is not None:
            src = [self._copy_src[0] - self._screen._session_offset, self._copy_src[1] - self._screen._scene_offset]
        self._screen.send_ui({'type': 'mod', 'mod': self.modifier(), 'src': src})

    def _used(self, what):
        self._copy_used = True
        self.show_message(what)

    def touch_clip(self, ti, si, open_only=False):
        song = self.song()
        tracks = list(song.tracks)
        if ti >= len(tracks) or si >= len(tracks[ti].clip_slots):
            return
        track, slot = tracks[ti], tracks[ti].clip_slots[si]
        mod = self.modifier()
        if mod == 'delete':
            if slot.has_clip:
                slot.delete_clip()
                self._used('Clip deleted')
        elif mod == 'copy':
            if self._copy_src is None:
                if slot.has_clip:                       # 1st tap: pick the clip
                    self._copy_src = (ti, si)
                    self._copy_used = True
            elif self._copy_src != (ti, si):            # next taps: paste it there (any track / scene)
                src_t, src_s = self._copy_src
                src = tracks[src_t].clip_slots[src_s] if src_t < len(tracks) else None
                if src is not None and src.has_clip:
                    try:
                        src.duplicate_clip_to(slot)
                        self._copy_pasted = True
                        self._used('Clip copied')
                    except Exception as e:              # e.g. MIDI clip onto an audio track
                        self.show_message("Can't copy there: %s" % e)
            self._send_mod()
        else:
            song.view.selected_track = track
            song.view.highlighted_clip_slot = slot
            if open_only or mod == 'shift':          # hold / SHIFT+tap: open it without launching
                self._screen.send_ui({'type': 'show_track'})
            else:
                slot.fire()

    def touch_track(self, ti):
        song = self.song()
        tracks = list(song.tracks)
        if ti >= len(tracks):
            return
        mod = self.modifier()
        if mod == 'delete':
            if len(tracks) > 1:
                song.delete_track(ti)
                self._used('Track deleted (UNDO brings it back)')
        elif mod == 'copy':
            song.duplicate_track(ti)
            self._used('Track duplicated')
        else:
            song.view.selected_track = tracks[ti]
            self._qlink_bank = 0

    def new_track(self, kind='midi'):
        """a new track right after the selected one (selected, ready to load something)"""
        song = self.song()
        tracks = list(song.tracks)
        sel = song.view.selected_track
        index = tracks.index(sel) + 1 if sel in tracks else len(tracks)
        if kind == 'audio':
            song.create_audio_track(index)
        else:
            song.create_midi_track(index)
        song.view.selected_track = list(song.tracks)[index]
        self._qlink_bank = 0
        return list(song.tracks)[index]

    def touch_arrangement_clip(self, ti, ci):
        song = self.song()
        tracks = list(song.tracks)
        if ti >= len(tracks):
            return
        track = tracks[ti]
        clips = list(track.arrangement_clips)
        if ci >= len(clips):
            return
        clip = clips[ci]
        mod = self.modifier()
        if mod == 'delete':
            track.delete_clip(clip)
            self._used('Clip deleted')
        elif mod == 'copy':
            track.duplicate_clip_to_arrangement(clip, clip.end_time)      # right after itself
            self._used('Clip duplicated')
        else:
            song.view.selected_track = track
            song.current_song_time = clip.start_time
            self._screen.send_ui({'type': 'arr_selected', 'track': ti, 'index': ci})

    def touch_scene(self, si):
        song = self.song()
        scenes = list(song.scenes)
        if si >= len(scenes):
            return
        mod = self.modifier()
        if mod == 'delete':
            if len(scenes) > 1:
                song.delete_scene(si)
                self._used('Scene deleted')
        elif mod == 'copy':
            song.duplicate_scene(si)
            self._used('Scene duplicated')
        else:
            song.view.selected_scene = scenes[si]
            scenes[si].fire()

    def _on_wake(self, value):
        self._screen.poll()
        self._update_lights()

    def set_step_mode(self, on):
        if bool(on) != self._step_mode:
            self._step_mode = bool(on)
            self._apply_bank()

    def _resume_clips(self):
        """PLAY after STOP: the session clips that were playing start again (together); False = nothing to resume"""
        slots = [sl for sl in getattr(self, '_resume', []) if sl.has_clip]
        if not slots:                                   # stopped some other way (screen ■, spacebar, Live): what played last
            slots = [sl for sl in getattr(self, '_last_playing', []) if sl.has_clip]
        if not slots:
            return False
        for sl in slots:
            sl.fire()
        if not self.song().is_playing:
            self.song().start_playing()
        return True

    def toggle_overdub(self):
        # our own on/off (Live 12 links song.overdub to Session Record, and Session Record can be left on by a recording):
        # on = add to the clip that plays on the armed track · off = stop adding
        song = self.song()
        self._od = not (getattr(self, '_od', False) and song.session_record)   # (turned off elsewhere: one press = on again)
        song.session_record = self._od
        self.show_message('Overdub on: play to add to the loop' if self._od else 'Overdub off')

    def press_rec(self):
        song = self.song()
        if self._app().view.is_view_visible('Session'):     # Session: record a loop of LENGTH bars (the screen's strip)
            if song.session_record and not any(sl.has_clip and sl.clip.is_recording for sl in getattr(self._selected_track(), 'clip_slots', [])):
                song.session_record = False                 # (overdub on: REC turns it off)
                self._od = False
            else:
                self._screen._loop_rec(song)
        else:
            song.record_mode = not song.record_mode

    def toggle_main_view(self):
        view = self._app().view
        view.show_view('Arranger' if view.is_view_visible('Session') else 'Session')

    def _update_note_repeat(self):
        nr = getattr(self._c_instance, 'note_repeat', None)
        on = self._repeat_held or self._repeat_latched
        if nr is not None:
            nr.repeat_rate = REPEAT_RATES[self._repeat_rate][0]
            nr.enabled = on
        if on:
            self.show_message('Note Repeat ' + REPEAT_RATES[self._repeat_rate][1] + ('  (latched)' if self._repeat_latched else '  (turn the jog wheel to change)'))

    def _select_track(self, step):
        tracks = self._all_tracks()
        current = self.song().view.selected_track
        i = tracks.index(current) if current in tracks else 0
        self.song().view.selected_track = tracks[max(0, min(len(tracks) - 1, i + step))]
        self._qlink_bank = 0

    def device_list(self, track=None):
        """the track's devices, with the selected drum pad's sound (its chain) right after the Drum Rack — MPC style"""
        track = track or self._selected_track()
        out = []
        rack = self._drum_rack(track.devices) if hasattr(track, 'devices') else None
        for d in getattr(track, 'devices', []):
            out.append((d, None))
            if rack is not None and (d == rack or (d.can_have_chains and self._drum_rack([d]) == rack)):
                pad = rack.view.selected_drum_pad
                if pad is not None and pad.chains:
                    out.extend((x, pad.name) for x in pad.chains[0].devices)
        return out

    def select_pad_sound(self, pad):
        """a drum pad was picked: its sound becomes the device on DEVICE and on the Q-Links"""
        if pad is not None and pad.chains and pad.chains[0].devices:
            self.song().view.select_device(pad.chains[0].devices[0])
            self._qlink_bank = 0

    def _select_device(self, step):
        track = self._selected_track()
        devices = [d for d, _ in self.device_list(track)]
        if not devices:
            return
        current = track.view.selected_device
        i = devices.index(current) if current in devices else 0
        self.song().view.select_device(devices[max(0, min(len(devices) - 1, i + step))])
        self._qlink_bank = 0
        self._show_qlinks()

    # ---------- Q-Links: 4 parameters of the selected device; Q-LINK button pages through them ----------
    def _qlink_params(self):
        if self._screen.page == 'SAMPLE':
            d = self._screen._simpler()
            if d is not None and d.sample is not None:
                pages = device_layout(d)[1]
                self._wave_bank = min(self._wave_bank, len(pages))
                if self._wave_bank == 0:
                    return 'wave', []                   # handled in _on_qlink: start / end / zoom / slice
                self._qlink_bank = self._wave_bank - 1  # SOUND / FILTER / LFO / AMP ENV / START: Simpler's own controls
                params = list(d.parameters)[1:]
                return d, [params[i] for i in pages[self._qlink_bank]]
        if self._screen.page == 'STEPS' and self.step_clip() is not None:
            return 'steps', []                          # handled in _on_qlink (pattern / step edits)
        if self._screen.page == 'MIXER':                # mixer page: Q1-Q4 = the first 4 tracks shown — volume, pan or a send (MPC)
            off = getattr(self._screen, '_mix_offset', 0)
            tracks = list(self.song().tracks)[off:off + 4]
            what = getattr(self._screen, '_mix_param', 'volume')
            def pick(t):
                m = t.mixer_device
                if what == 'pan':
                    return m.panning
                if what.startswith('send'):
                    sends = list(m.sends)
                    k = int(what[4:] or 0)
                    return sends[k] if k < len(sends) else m.volume
                return m.volume
            return 'mixer', [pick(t) for t in tracks]
        device = self._selected_device()
        if device is None:
            return None, []
        params = list(device.parameters)[1:]       # [0] is Device On
        pages = device_layout(device)[1]
        self._qlink_bank = min(self._qlink_bank, len(pages) - 1)
        return device, [params[i] for i in pages[self._qlink_bank]]

    def _show_qlinks(self):
        device, params = self._qlink_params()
        if device is None:
            self.show_message('Q-Links: no device selected')
        elif device == 'mixer':
            self.show_message('Q-Links: volume of the first 4 tracks on the mixer page')
        elif device == 'wave':
            self.show_message('Q-Links: Q1 start · Q2 end · Q3 zoom · Q4 slice (SHIFT = finer)')
        elif device == 'steps':
            self.show_message('Q-Links: Q1 swing · Q2 velocity (select a step: velocity · pitch · chance · ratchet)')
        else:
            self.show_message('Q-Links  %s  page %d:  %s' % (device.name, self._qlink_bank + 1, '  |  '.join(p.name for p in params)))

    # ---------- Q-Links: mapped natively in Live (smooth, handled in Live's engine, not per tick in Python) ----------
    def _sync_qlinks(self):
        device, params = self._qlink_params()
        key = (device, self._qlink_bank, self._shift, tuple(params))
        if key == self._qlink_map_key:
            return
        self._qlink_map_key = key
        for p, f in self._qlink_watch:
            try:
                if p.value_has_listener(f):
                    p.remove_value_listener(f)
            except Exception:
                pass                                # the device was deleted
        self._qlink_watch = []
        if device in ('mixer', 'steps', 'wave'):
            knobs = [-1] * len(params)                  # (no device knobs to light up on the screen)
        else:
            knobs = device_layout(device)[1][self._qlink_bank] if device is not None else []
        for i, e in enumerate(self._qlinks):
            if i < len(params):
                e.mapping_sensitivity = 0.2 if self._shift else 1.0     # SHIFT = 5x finer
                e.connect_to(params[i])
                f = self._param_watcher(params[i], knobs[i])
                params[i].add_value_listener(f)
                self._qlink_watch.append((params[i], f))
            else:
                e.release_parameter()
        self.request_rebuild_midi_map()

    def _param_watcher(self, p, knob):
        def changed():                              # straight to the screen (the full state only goes out 10x a second)
            if knob >= 0:
                self._screen.send_ui({'type': 'param', 'index': knob, 'value': p.value, 'text': p.str_for_value(p.value)})
        return changed

    def _on_qlink(self, value, sender):
        # mapped Q-Links: Live moves the parameter itself (listening keeps the CC off the track).
        # STEPS page: Q1 swing · Q2 velocity of the sound — or, with a step selected: Q1 velocity · Q2 pitch · Q3 chance · Q4 ratchet
        # (decided by what WE mapped: Live's mapped_parameter() keeps the old parameter after release_parameter(), so once a
        #  Q-Link had been on a device page it never reached the SIMPLER / STEPS handlers again)
        mode = self._qlink_map_key[0] if self._qlink_map_key else None
        if not (isinstance(mode, str) and mode in ('wave', 'steps')):
            return
        if self._screen.page == 'SAMPLE':
            self._screen.send_ui({'type': 'wave_q_active', 'q': self._qlinks.index(sender)})
            return self._wave_qlink(self._qlinks.index(sender), relative(value))
        if self._screen.page != 'STEPS':
            return
        i, d = self._qlinks.index(sender), relative(value)
        clip = self.step_clip()
        if clip is None:
            return
        if self.is_melodic():                       # NOTES (melody composer): the selected note
            return self._roll_qlink(i, d, clip)
        if self._step_sel is None:                  # (mockup) Q1 VELOCITY · Q2 LAID BACK · Q3 LENGTH of the row · Q4 swing
            if i == 3:
                self.set_swing(self.swing() + d * 0.0025)
            elif i == 0:
                note = self.current_step_note()
                notes = clip.get_notes_extended(note, 1, 0.0, clip.length)
                for n in notes:
                    n.velocity = max(1.0, min(127.0, n.velocity + d))
                if notes:
                    clip.apply_note_modifications(notes)
            elif i == 2:                                # Q3 LENGTH: every note in the bar 1/32 · 1/16 · 1/8 · 1/4
                self._q_rest[2] += d / 8.0
                k = int(self._q_rest[2])
                if k:
                    self._q_rest[2] -= k
                    lens = [0.125, 0.25, 0.5, 1.0]
                    cur = lens.index(self._step_len) if self._step_len in lens else 1
                    self._step_len = lens[max(0, min(3, cur + k))]
                    notes = clip.get_notes_extended(0, 128, self._step_page * 4.0, 4.0)
                    for n in notes:
                        n.duration = self._step_len
                    if notes:
                        clip.apply_note_modifications(notes)
                    self.show_message('Length 1/%d' % int(4 / self._step_len))
            elif i == 1:                                # Q2 LAID BACK / RUSH: the selected row late / early
                self.row_edit('nudge', d * 0.004)
            return
        pitch, step = self._step_sel
        notes = self._step_notes(clip, pitch, step)
        if not notes:
            return
        if i == 0:
            self.step_edit('velocity', notes[0].velocity + d)
        elif i == 1 and self.is_melodic():
            self._q_rest[1] += d / 6.0                  # ~6 ticks per semitone
            k = int(self._q_rest[1])
            if k:
                self._q_rest[1] -= k
                self.step_edit('pitch', pitch + k)
        elif i == 2:                                    # Q3 NUDGE this step
            self.step_edit('nudge', d * 0.004)
        elif i == 3:
            self._q_rest[3] += d / 10.0
            k = int(self._q_rest[3])
            if k:
                self._q_rest[3] -= k
                self.step_edit('ratchet', max(1, min(4, len(notes) + k)))

    def _on_qlink_touch(self, value, sender):
        i = self._qlink_touch.index(sender)
        device, params = self._qlink_params()
        if device == 'wave':                            # a finger on a Q-Link on the SIMPLER page: show which one it is
            self._screen.send_ui({'type': 'wave_touch', 'q': i, 'on': value > 0})
            return
        if device is None or device in ('mixer', 'steps') or i >= len(params):
            return
        knob = device_layout(device)[1][self._qlink_bank][i]
        self._screen.send_ui({'type': 'qlink_touch', 'index': knob, 'on': value > 0})

    # ---------- jog wheel ----------
    def _on_jog(self, value):
        step = relative(value)
        if self._screen.page == 'BROWSE' or getattr(self._screen, 'jog_focus', False):   # the screen app has the wheel
            return                                        # (browsing, or a value tapped on the screen)
        if self._screen.page == 'SAMPLE' and not self._shift and self.wave_chop(1 if step > 0 else -1):   # slices: chop by chop
            return
        if self._screen.page == 'DEVICE':                 # device page: the wheel walks through the track's devices
            self._select_device(step)
            return
        if self._screen.page == 'STEPS' and not self._shift and not self.is_melodic():   # drum sequencer: scroll the pad rows
            self._screen.send_ui({'type': 'step_rows', 'by': step})
            return
        if self._screen.page == 'STEPS' and not self._shift and self.is_melodic():       # notes / melody: the octave
            self.set_octave(self._mel_oct + (1 if step > 0 else -1))
            self.show_message('Octave %d' % self._mel_oct)
            return
        if self._screen.page == 'PADS' and not self._shift and self.pad_mode() == 'chords':   # chord pads: their octave
            self._chord_oct = max(-2, min(2, self._chord_oct + (1 if step > 0 else -1)))
            self._chord_last = None
            return
        if self._repeat_held or self._repeat_latched:
            self._repeat_rate = max(0, min(len(REPEAT_RATES) - 1, self._repeat_rate + step))
            self._update_note_repeat()
            return
        song = self.song()
        if self._shift or (self._screen.page == 'SESSION' and not self._app().view.is_view_visible('Session')):
            self._select_track(step)                      # SHIFT, or the arrangement: through the tracks
            return
        scenes = list(song.scenes)
        i = scenes.index(song.view.selected_scene)
        song.view.selected_scene = scenes[max(0, min(len(scenes) - 1, i + step))]

    # ---------- lights (Live calls this about 10x per second) ----------
    def update_display(self):
        ControlSurface.update_display(self)
        self._tick += 1
        if self._tick % 30 == 0:                   # re-send all lights every 3 s (after a replug or another tool)
            self._leds = {}
            self._pad_colors = [None] * 16
        if self._pad_key != (self._selected_track(), self.pad_mode(), self._mel_oct, self._bank):
            self._apply_bank()                      # another track (or instrument) selected: pads follow
        self._update_lights()
        self._auto_arm()
        self._sync_qlinks()                         # follows device / page changes made in Live itself
        self._screen.tick()

    def _auto_arm(self):
        """the selected MIDI track is armed, every other track disarmed (only one ever armed) — like Push.
        Audio tracks are never armed automatically (their input would play through: feedback); press ● for those.
        Leaves things alone while REC SAMPLE is running, and never touches the 'Sampler In' track."""
        sel = self._selected_track()
        if sel == getattr(self, '_arm_follow', None) or self._rec is not None:   # (==: Live hands out a new wrapper every time)
            return
        self._arm_follow = sel
        song = self.song()
        try:
            for t in song.tracks:
                if t == sel or t.name == 'Sampler In' or not getattr(t, 'can_be_armed', False):
                    continue
                if t.arm:
                    t.arm = False
            if getattr(sel, 'can_be_armed', False) and getattr(sel, 'has_midi_input', False) and not sel.arm:
                sel.arm = True
        except Exception as e:
            self.log_message('auto arm: %r' % e)

    def _update_lights(self):
        song = self.song()
        playing = song.is_playing
        beat_on = playing and (song.current_song_time % 1.0) < 0.25
        self._led(PLAY, ON if playing else DIM)
        self._led(STOP, DIM if playing else ON)
        self._led(PLAY_START, DIM)
        session_view = self._app().view.is_view_visible('Session')
        self._led(REC, ON if ((song.session_record and not getattr(self, '_od', False)) if session_view else song.record_mode) else DIM)
        self._led(OVERDUB, ON if (getattr(song, 'arrangement_overdub', False) and not session_view) or (session_view and song.session_record and getattr(self, '_od', False)) else DIM)
        self._led(TAP, ON if beat_on else (MID if song.metronome else DIM))
        self._led(UNDO, DIM if song.can_undo else OFF)
        slot = song.view.highlighted_clip_slot
        has_clip = slot is not None and slot.has_clip
        self._led(ERASE, DIM if has_clip else OFF)
        self._led(COPY, DIM if has_clip else OFF)
        self._led(SHIFT, ON if self._shift else DIM)
        repeat = self._repeat_held or self._repeat_latched
        self._led(NOTE_REPEAT, (ON if self._tick % 4 < 2 else MID) if self._repeat_latched else (ON if repeat else DIM))
        self._led(FULL_LEVEL, ON if self._full_level else DIM)
        self._led(LEVEL_16, ON if self._levels else (MID if self._step_mode else DIM))
        for i, g in enumerate(GROUPS):
            lit = self._step_page if self._step_mode else (self._mel_oct - 1 if self.pad_mode() == 'keys' else self._bank % 4)
            self._led(g, ON if lit == i else DIM)
        view = self._app().view
        self._led(MAIN, ON if view.is_view_visible('Session') else MID)
        self._led(BROWSE, ON if view.is_view_visible('Browser') else DIM)
        self._led(QLINK, ON if self._selected_device() is not None else DIM)
        self._led(PLUS, DIM)
        self._led(MINUS, DIM)
        if self._levels:
            self._refresh_level_pads()
        elif self._step_mode:
            self._refresh_step_pads()
        elif self._pad_mode in ('clips', 'mixer'):
            self._refresh_session_pads()
        elif self.pad_mode() == 'keys':
            if self._tick % 2 == 0:
                self._refresh_key_pads()
        elif self._tick % 2 == 0:
            self._refresh_pads()

    def receive_midi(self, midi_bytes):
        self.midi_in_count = getattr(self, 'midi_in_count', 0) + 1
        self.midi_in_last = midi_bytes
        ControlSurface.receive_midi(self, midi_bytes)

    def disconnect(self):
        for note in BUTTONS:
            self._send_midi((0xB0, note, OFF))
        for i in range(16):
            self._send_midi((0xF0, 0x47, 0x7F, 0x37, 0x65, 0x00, 0x04, i, 0, 0, 0, 0xF7))
        self._send_helper(1, 0)
        self._screen.disconnect()
        ControlSurface.disconnect(self)
