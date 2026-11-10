# Link between the MPC Touch Remote Script and the touch-screen app (MPCScreen) on the Touch's display.
# Plain UDP on localhost, one JSON object per datagram:
#   script -> app (port 9100): {"type": "state", ...}   whenever something the screen shows changed
#   app -> script (port 9101): {"cmd": "...", ...}      edits made with a finger
from __future__ import absolute_import, print_function, unicode_literals

import json

import Live
import math
import socket

APP_PORT = 9100
SCRIPT_PORT = 9101
SESSION_TRACKS = 8
SESSION_SCENES = 4                      # the Touch shows 4 clip rows (the loop recorder sits below)

SIMPLER_MODES = ('Classic', 'One-Shot', 'Slice')
SLICE_STYLES = ('Transient', 'Beat', 'Region', 'Manual')


def _color(obj):
    try:
        return obj.color
    except Exception:
        return 0x404040



FIRST_PAGE = {                                              # Q1-Q4 on page 1 of the go-to effects (matches the FX picker)
    'DrumBuss': ('Drive', 'Crunch', 'Boom Amt', 'Dry/Wet'),
    'GlueCompressor': ('Threshold', 'Ratio', 'Attack', 'Output'),
    'Compressor2': ('Threshold', 'Ratio', 'Release', 'Output'),
    'AutoFilter2': ('Frequency', 'Resonance', 'LFO Amount', 'Dry/Wet'),
    'StereoGain': ('Output', 'Stereo Width', 'Bass Mono', 'Balance'),
    'Reverb': ('Room Size', 'Decay Time', 'Predelay', 'Dry/Wet'),
    'Echo': ('L Time', 'Feedback', 'LP Freq', 'Dry Wet'),
    'Delay': ('L 16th', 'Feedback', 'Ping Pong', 'Dry/Wet'),
    'Saturator': ('Drive', 'Type', 'Color Freq', 'Dry/Wet'),
    'Roar': ('Drive', 'Tone Amt', 'Feedback', 'Dry/Wet'),
    'Vinyl': ('Crackle Volume', 'Global Drive', 'Tracing Drive', 'Crackle Density'),
    'BeatRepeat': ('Interval', 'Grid', 'Chance', 'Mix Type'),
    'Chorus2': ('Rate', 'Amount', 'Width', 'Dry/Wet'),
    'PhaserNew': ('Mod Freq', 'Amount', 'Feedback', 'Dry/Wet'),
}

def device_layout(device):
    """The device's knob pages (4 knobs = the 4 Q-Links each): (page names, [[index into parameters[1:]] per page]).
    Most devices: their parameters in order. EQ Eight: one page per band (the B set is only for Mid/Side)."""
    names = [p.name for p in list(device.parameters)[1:]]
    if device.class_name == 'OriginalSimpler':             # Simpler: sound · filter · LFO · envelopes
        # candidates in order, the first 4 Live shows win: with the filter / LFO off Live hides their knobs,
        # then the page offers their on switch (and SOUND fills up with detune / pan) instead of empty slots
        groups = [('SOUND', ('Volume', 'Transpose', 'Filter Freq', 'Filter Res', 'Detune', 'Pan', 'Glide Time')),
                  ('FILTER', ('F On', 'Filter Freq', 'Filter Res', 'Filter Drive', 'Fe < Env')),
                  ('LFO', ('L On', 'L Rate', 'Filt < LFO', 'Vol < LFO', 'Pitch < LFO', 'Pan < LFO')),
                  ('AMP ENV', ('Ve Attack', 'Ve Decay', 'Ve Sustain', 'Ve Release')),
                  ('TRIM', ('S Start', 'S Length', 'Fade In', 'Fade Out'))]   # where each note starts playing + its fades
        pages = [[names.index(n) for n in ns if n in names][:4] for _, ns in groups]
        return [g for g, _ in groups], pages
    if device.class_name == 'Eq8':
        pages = [[names.index('%d %s A' % (b, k)) for k in ('Frequency', 'Gain', 'Q', 'Filter Type') if '%d %s A' % (b, k) in names]
                 for b in range(1, 9)]
        pages.append([names.index(n) for n in ('Output', 'Scale', 'Adaptive Q') if n in names])
        return [str(b) for b in range(1, 9)] + ['Out'], pages
    first = FIRST_PAGE.get(device.class_name)
    if first:                                               # the go-to FX: the 4 controls that matter first (FX picker)
        top = [names.index(n) for n in first if n in names]
        rest = [i for i in range(len(names)) if i not in top]
        pages = [top] + [rest[i:i + 4] for i in range(0, len(rest), 4)]
        return [str(k + 1) for k in range(len(pages))], pages
    count = len(names)
    vmc = getattr(device, 'visible_macro_count', None)      # a rack: only the macros it shows (at least one Q-Link page)
    if isinstance(vmc, int) and device.can_have_chains:
        count = min(count, max(4, vmc))
    pages = [list(range(i, min(i + 4, count))) for i in range(0, count, 4)] or [[]]
    return [str(k + 1) for k in range(len(pages))], pages

class ScreenLink(object):

    def __init__(self, surface):
        self._surface = surface
        self._last = None
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setblocking(False)
        # macOS caps UDP datagrams at 9216 bytes unless the send buffer is raised (browser lists, big sessions)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
        try:
            self._sock.bind(('127.0.0.1', SCRIPT_PORT))
        except Exception as e:
            surface.log_message('screen link: cannot bind %d: %s' % (SCRIPT_PORT, e))
        self._session_offset = 0
        self._scene_offset = 0
        self._force = True
        self.page = ''                                   # page the screen shows (the jog wheel browses on BROWSE)
        import time
        self._instance = int(time.time() * 1000) % 1000000000   # lets the screen notice that Ableton/the script restarted

    def disconnect(self):
        try:
            self._sock.close()
        except Exception:
            pass

    def _song(self):
        return self._surface.song()

    # ---------- what the screen shows ----------
    def _simpler(self):
        track = self._song().view.selected_track
        device = track.view.selected_device
        candidates = ([device] if device is not None else []) + list(getattr(track, 'devices', []))
        for d in candidates:
            if d is not None and d.class_name == 'OriginalSimpler':
                return d
        pad = self._selected_pad()                   # a drum track: the Simpler inside the selected pad
        if pad is not None:
            for ch in pad.chains:
                for d in ch.devices:
                    if d.class_name == 'OriginalSimpler':
                        return d
        return None

    def _selected_pad(self):
        rack = self._surface._current_rack()
        return rack.view.selected_drum_pad if rack is not None else None

    def _simpler_state(self):
        d = self._simpler()
        if d is None or d.sample is None:
            return None
        s = d.sample
        state = {
            'name': d.name,
            'file': s.file_path,
            'length': s.length,
            'rate': getattr(s, 'sample_rate', 44100),
            'start': s.start_marker,
            'end': s.end_marker,
            'mode': SIMPLER_MODES[d.playback_mode] if d.playback_mode < 3 else str(d.playback_mode),
            'slices': list(s.slices),
            'style': SLICE_STYLES[s.slicing_style] if s.slicing_style < 4 else '',
            'division': getattr(s, 'slicing_beat_division', 0),
            'regions': getattr(s, 'slicing_region_count', 16),
            'sensitivity': getattr(s, 'slicing_sensitivity', 0.5),
            'gain': s.gain, 'gain_text': s.gain_display_string(),
            'warping': bool(getattr(s, 'warping', False)), 'warp_mode': int(getattr(s, 'warp_mode', 0)),
            'can_double': bool(getattr(d, 'can_warp_double', False)), 'can_half': bool(getattr(d, 'can_warp_half', False)),
        }
        pad = self._selected_pad()
        if d not in list(self._song().view.selected_track.devices) and pad is not None:
            state['pad'] = {'note': pad.note, 'name': pad.name}   # editing the sample of a drum pad
        prm = {p.name: p for p in d.parameters}
        def pv(n):
            p = prm.get(n)
            return [round((p.value - p.min) / (p.max - p.min), 4) if p.max > p.min else 0, p.str_for_value(p.value)] if p else [0, '']
        for n in ('Filter Type', 'Filter Freq', 'Filter Res', 'Filter Drive', 'Filt < LFO', 'L Rate', 'L Wave', 'Volume', 'F On', 'L On',
                  'Trigger Mode', 'S Loop On'):
            state['p_' + n] = pv(n)
        return state

    def _playhead(self):
        d = self._simpler()
        if d is None:
            return None
        try:
            if d.playing_position_enabled:
                return d.playing_position
        except Exception:
            pass
        return None

    def _instrument_name(self, track):
        for d in getattr(track, 'devices', []):
            if int(d.type) == 1:
                return d.name
        return ''

    def _pads_state(self):
        """the 16 pads of the current bank of the track's Drum Rack (for the PADS view)"""
        surf = self._surface
        rack = surf._current_rack()
        if rack is None:
            return None
        sel = rack.view.selected_drum_pad
        base = 36 + 16 * surf._bank
        pads = []
        for n in range(base, min(base + 16, 128)):
            pad = rack.drum_pads[n]
            filled = len(pad.chains) > 0
            sample = ''
            path = ''
            region = None
            if filled:
                for d in pad.chains[0].devices:
                    smp = getattr(d, 'sample', None)
                    if smp is not None and getattr(smp, 'file_path', ''):
                        sample = smp.file_path.split('/')[-1].rsplit('.', 1)[0]
                        path = smp.file_path
                        region = [smp.start_marker, smp.end_marker, smp.length]   # the part this pad plays
                        break
                    if not sample:
                        sample = d.name
            pads.append({'note': n, 'name': pad.name, 'filled': filled, 'sample': sample,
                         'color': _color(pad.chains[0]) if filled else 0, 'mute': pad.mute, 'solo': pad.solo,
                         'selected': sel is not None and sel.note == n, 'file': path if sel is not None and sel.note == n else '',
                         'region': region if sel is not None and sel.note == n else None})
        from .MPC_Touch import REPEAT_RATES
        return {'bank': surf._bank, 'pads': pads, 'rack': rack.name,
                'repeat': {'on': bool(surf._repeat_latched or surf._repeat_held), 'rate': REPEAT_RATES[surf._repeat_rate][1]}}

    def _tracks_state(self):
        """every track, for the track picker in the top bar"""
        song = self._song()
        sel = song.view.selected_track
        surf = self._surface
        out = []
        for i, t in enumerate(list(song.tracks)[:64]):
            out.append({'index': i, 'name': t.name, 'color': _color(t), 'kind': surf.track_kind(t),
                        'instrument': self._instrument_name(t), 'selected': t == sel})
        return out

    def _session_state(self):
        song = self._song()
        tracks = list(song.tracks)
        scenes = list(song.scenes)
        self._session_offset = max(0, min(self._session_offset, max(0, len(tracks) - SESSION_TRACKS)))
        self._scene_offset = max(0, min(self._scene_offset, max(0, len(scenes) - SESSION_SCENES)))
        s0 = self._scene_offset
        out = []
        for t in tracks[self._session_offset:self._session_offset + SESSION_TRACKS]:
            clips = []
            for slot in list(t.clip_slots)[s0:s0 + SESSION_SCENES]:
                if slot.has_clip:
                    c = slot.clip
                    clip = {'name': c.name, 'color': c.color, 'playing': c.is_playing,
                            'triggered': c.is_triggered, 'recording': c.is_recording,
                            'beats': round(c.length, 3), 'legato': bool(c.legato), 'midi': bool(c.is_midi_clip)}
                    if c.is_playing and c.length > 0:     # progress in 1/16ths (keeps the redraws few)
                        clip['progress'] = round(((c.playing_position - c.loop_start) % c.length) / c.length * 16) / 16.0
                    clips.append(clip)
                else:
                    clips.append({'empty': True, 'triggered': slot.is_triggered,
                                  'armed': getattr(t, 'arm', False)})
            out.append({'name': t.name, 'color': _color(t), 'clips': clips, 'instrument': self._instrument_name(t),
                        'selected': t == song.view.selected_track, 'arm': getattr(t, 'arm', False),
                        'mute': t.mute, 'solo': t.solo, 'can_arm': getattr(t, 'can_be_armed', False),
                        'playing': getattr(t, 'playing_slot_index', -1) >= 0})
        sel_scene = song.view.selected_scene
        scene_list = [{'name': s.name, 'color': s.color, 'selected': s == sel_scene, 'triggered': s.is_triggered}
                      for s in scenes[s0:s0 + SESSION_SCENES]]
        return {'offset': self._session_offset, 'scene_offset': s0, 'tracks': out, 'scenes': scene_list,
                'track_count': len(tracks), 'scene_count': len(scenes),
                'overview': self._overview() if len(tracks) > SESSION_TRACKS or len(scenes) > SESSION_SCENES else None}

    def _clip_edit(self, song, ti, si, what, value):
        tracks = list(song.tracks)
        if ti >= len(tracks) or si >= len(tracks[ti].clip_slots):
            return
        track = tracks[ti]
        slot = track.clip_slots[si]
        if not slot.has_clip:
            return
        c = slot.clip
        if what == 'halve':
            if c.length > 1:
                if c.looping:
                    c.loop_end = c.loop_start + c.length / 2.0
                else:
                    c.end_marker = c.start_marker + c.length / 2.0
        elif what == 'double':
            c.duplicate_loop()
        elif what == 'legato':
            c.legato = not c.legato
        elif what == 'duplicate':                       # into the first EMPTY slot below (never over another clip)
            slots = list(track.clip_slots)
            target = next((k for k in range(si + 1, len(slots)) if not slots[k].has_clip), None)
            if target is None:
                song.create_scene(-1)
                slots = list(track.clip_slots)
                target = len(slots) - 1
            slot.duplicate_clip_to(slots[target])
            self._surface.show_message('Clip copied to scene %d' % (target + 1))
        elif what == 'color':
            c.color = int(value)
        elif what == 'name':
            c.name = str(value)
        elif what == 'delete':
            slot.delete_clip()
        elif what == 'open':                            # EDIT NOTES (value 'steps' = straight to its sequencer)
            song.view.selected_track = track
            song.view.highlighted_clip_slot = slot
            self.send_ui({'type': 'show_track', 'steps': value == 'steps'})

    NOTE_NAMES = ('C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B')

    def _key_name(self, root=None):
        song = self._song()
        return '%s %s' % (self.NOTE_NAMES[(song.root_note if root is None else root) % 12], getattr(song, 'scale_name', '') or '')

    def _transpose_beat(self, d):
        """every MIDI clip on the instrument tracks (keys, bass, melody — not drums or samplers) d semitones up/down"""
        n = 0
        for t in self._song().tracks:
            if self._surface.track_kind(t) != 'instrument':
                continue
            clips = [sl.clip for sl in t.clip_slots if sl.has_clip] + list(getattr(t, 'arrangement_clips', []))
            for c in clips:
                if not c.is_midi_clip:
                    continue
                notes = c.get_all_notes_extended()
                for x in notes:
                    x.pitch = max(0, min(127, x.pitch + d))
                c.apply_note_modifications(notes)
                n += 1
        return n

    def _sample_key(self, msg, pitch=None):
        """the beat follows the sample: song key (→ chord pads, keys pads, the scale everywhere) + the keys/bass/melody
        clips transposed the shortest way. The song keeps its mode: a major sample on a minor beat = its relative minor
        (the same notes), so nothing in your chords changes except where they sit.
        pitch = (semitones, old tempo, old warping, old warp mode): the sample was PITCHED by whole semitones (faster /
        slower like a record) — its key moved that much, and UNDO also brings back the tempo and the warp."""
        song = self._song()
        smp = self._simpler()
        if smp is None or smp.sample is None or smp.sample.file_path != msg.get('file'):
            return
        semis = pitch[0] if pitch else 0
        single = bool(msg.get('single'))
        has_key = msg.get('root') is not None and (single or float(msg.get('clarity', 0)) >= 0.03)
        if not has_key and not pitch:
            self.send_ui({'type': 'notice', 'text': "No clear key in this sample — your beat stays in %s" % self._key_name()})
            return
        if has_key and not pitch and (msg.get('fit') or (msg.get('auto') and self._leader_in_use(msg.get('file')))):
            return self._fit_sample(msg, smp)
        old, d, n = song.root_note, 0, 0
        heard = ''
        if has_key:
            found = (int(msg.get('root', 0)) + semis) % 12
            iv = list(getattr(song, 'scale_intervals', []) or [0, 2, 3, 5, 7, 8, 10])
            song_minor = 3 in iv and 4 not in iv
            root = found
            if not single:
                if msg.get('minor') and not song_minor:
                    root = (found + 3) % 12              # its relative major
                elif not msg.get('minor') and song_minor:
                    root = (found + 9) % 12              # its relative minor
            heard = self.NOTE_NAMES[found] + ('' if single else (' minor' if msg.get('minor') else ' major'))
            if msg.get('named') and not pitch:
                heard += ' (from its name)'
            d = (root - song.root_note) % 12
            if d > 6:
                d -= 12                                   # the shortest way: −5 … +6 semitones
            if d:
                song.begin_undo_step() if hasattr(song, 'begin_undo_step') else None
                n = self._transpose_beat(d)
                song.root_note = root
                song.end_undo_step() if hasattr(song, 'end_undo_step') else None
                self._surface._chord_last = None
        prev_leader = getattr(self, '_key_leader', None)
        if has_key:
            self._key_leader = msg.get('file')            # this sample sets the key now: later samples follow the beat
        if pitch:
            info = {'root': old, 'd': d, 'tempo': pitch[1], 'warp': (pitch[2], pitch[3]), 'leader': prev_leader, 'pitchfile': msg.get('file'),
                    'transpose': getattr(self, '_pitch_tr', (None, 0))}
            prev = getattr(self, '_key_undo_info', None)
            if isinstance(prev, dict) and prev.get('pitchfile') == msg.get('file'):   # turning on: UNDO = back to before PITCH
                info = dict(prev, d=prev.get('d', 0) + d)
            self._key_undo_info = info
            txt = 'PITCH %+d · beat %.1f BPM' % (semis, song.tempo) + (' · %s' % self._key_name() if has_key else '')
            self.send_ui({'type': 'notice', 'undo': 'key_undo', 'text': txt})
            return
        if d == 0:
            self.send_ui({'type': 'notice', 'text': 'Sample in %s — your beat is already in that key' % heard})
            return
        self._key_undo_info = {'root': old, 'd': d, 'leader': prev_leader}
        self.send_ui({'type': 'notice', 'undo': 'key_undo',
                      'text': 'Sample in %s → beat now in %s (%+d) · %d clips moved' % (heard, self._key_name(), d, n)})

    def _leader_in_use(self, file):
        """is there a sample (other than this one) that set the beat's key, and is it still used in the set?"""
        lead = getattr(self, '_key_leader', None)
        if not lead or lead == file:
            return False
        for t in self._song().tracks:
            for dev in getattr(t, 'devices', []):
                if dev.class_name == 'OriginalSimpler' and dev.sample is not None and dev.sample.file_path == lead:
                    return True
        return False

    def _fit_sample(self, msg, smp):
        """a 2nd, 3rd … sample follows the beat (the 1st one leads): STRETCH to the beat's tempo (same pitch) + Transpose by
        whole semitones into the beat's key — the keys / bass stay where they are"""
        song = self._song()
        s = smp.sample
        single = bool(msg.get('single'))
        found = int(msg.get('root', 0)) % 12
        iv = list(getattr(song, 'scale_intervals', []) or [0, 2, 3, 5, 7, 8, 10])
        song_minor = 3 in iv and 4 not in iv
        root = found
        if not single:
            if msg.get('minor') and not song_minor:
                root = (found + 3) % 12
            elif not msg.get('minor') and song_minor:
                root = (found + 9) % 12
        semis = (song.root_note - root) % 12
        if semis > 6:
            semis -= 12                                   # the smallest move: −5 … +6
        tr = next((p for p in smp.parameters if p.name == 'Transpose'), None)
        undo = {'fit': smp, 'transpose': tr.value if tr is not None else 0, 'warp': (s.warping, s.warp_mode)}
        if tr is not None:
            tr.value = max(tr.min, min(tr.max, tr.value + semis))
        bpm = float(msg.get('bpm') or 0)
        if bpm > 0 and abs(bpm - song.tempo) > 0.05:
            was = s.warping
            s.warping = True
            if not was or s.warp_mode not in (0, 1, 2, 4, 6):   # STRETCH (Complex) — your pick for melodic samples;
                s.warp_mode = 4                                 # Re-Pitch would change its key again. A mode you chose stays.
            rate = float(getattr(s, 'sample_rate', 44100) or 44100)
            smp.warp_as((s.end_marker - s.start_marker) / rate * bpm / 60.0)
        self._key_undo_info = undo
        heard = self.NOTE_NAMES[found] + ('' if single else (' minor' if msg.get('minor') else ' major'))
        parts = ['Sample in %s' % heard]
        parts.append('transposed %+d to your %s' % (semis, self._key_name()) if semis else 'already in your key')
        if bpm > 0 and abs(bpm - song.tempo) > 0.05:
            parts.append('stretched %.1f → %.1f BPM' % (bpm, song.tempo))
        self.send_ui({'type': 'notice', 'undo': 'key_undo', 'text': ' · '.join(parts)})

    def _pitch_semis(self, msg):
        """PITCH by whole semitones (MPC / SP style): the beat's tempo = sample tempo × 2^(n/12), the sample plays like a
        record at that speed (Re-Pitch) — so it lands exactly in a real key, and the keys / bass follow it"""
        song = self._song()
        d = self._simpler()
        if d is None or d.sample is None:
            return
        s = d.sample
        bpm, semis = float(msg['bpm']), int(msg['semis'])
        old_tempo, old_warping, old_mode = song.tempo, s.warping, s.warp_mode
        tr = next((p for p in d.parameters if p.name == 'Transpose'), None)
        old_tr = tr.value if tr is not None else 0
        if tr is not None and tr.value != 0:                # PITCH = true to the sample: no extra Transpose on top
            tr.value = 0
        self._pitch_tr = (d, old_tr)
        song.tempo = bpm * 2 ** (semis / 12.0)
        s.warping = True
        s.warp_mode = 3                                     # Re-Pitch
        rate = float(getattr(s, 'sample_rate', 44100) or 44100)
        d.warp_as((s.end_marker - s.start_marker) / rate * bpm / 60.0)
        self._sample_key(msg, pitch=(semis, old_tempo, old_warping, old_mode))

    def _key_undo(self):
        info = getattr(self, '_key_undo_info', None)
        if not info:
            return
        if isinstance(info, tuple):                         # (older form)
            info = {'root': info[0], 'd': info[1]}
        self._key_undo_info = None
        song = self._song()
        if 'fit' in info:                                   # a fitted sample: its Transpose and warp back
            smp = info['fit']
            try:
                tr = next((p for p in smp.parameters if p.name == 'Transpose'), None)
                if tr is not None:
                    tr.value = info['transpose']
                smp.sample.warping, mode = info['warp']
                if smp.sample.warping:
                    smp.sample.warp_mode = mode
            except Exception:
                pass
            self.send_ui({'type': 'notice', 'text': 'Sample back as it was'})
            return
        if 'leader' in info:
            self._key_leader = info['leader']
        if info.get('d'):
            self._transpose_beat(-info['d'])
        song.root_note = info['root']
        if isinstance(info.get('transpose'), tuple) and info['transpose'][0] is not None:   # PITCH had reset its Transpose
            try:
                tr = next((p for p in info['transpose'][0].parameters if p.name == 'Transpose'), None)
                if tr is not None:
                    tr.value = info['transpose'][1]
            except Exception:
                pass
        if 'tempo' in info:
            song.tempo = info['tempo']
            smp = self._simpler()
            if smp is not None and smp.sample is not None:
                smp.sample.warping, mode = info['warp']
                if smp.sample.warping:
                    smp.sample.warp_mode = mode
        self._surface._chord_last = None
        self.send_ui({'type': 'notice', 'text': 'Back in %s · %.1f BPM' % (self._key_name(), song.tempo)})

    def _duck_by_kick(self, track, tries=[0]):
        """sidechain the compressor just added on this track from the drum track (the kick pumps it)"""
        song = self._song()
        comp = next((d for d in reversed(list(track.devices)) if d.class_name in ('Compressor2', 'GlueCompressor')), None)
        if comp is None:
            tries[0] += 1
            if tries[0] < 20:
                self._surface.schedule_message(2, lambda: self._duck_by_kick(track))
            return
        tries[0] = 0
        kick = next((t for t in song.tracks if t != track and self._surface.track_kind(t) == 'drum'), None)
        try:
            for p in comp.parameters:
                if p.name == 'S/C On':
                    p.value = 1
            if kick is not None and hasattr(comp, 'available_input_routing_types'):
                rt = next((r for r in comp.available_input_routing_types if r.display_name.endswith(kick.name) or kick.name in r.display_name), None)
                if rt is not None:
                    comp.input_routing_type = rt
                    self._surface.show_message('Ducked by %s' % kick.name)
                    return
            self._surface.show_message('Sidechain on: pick the kick track in Ableton (no drum track found)')
        except Exception as e:
            self._surface.show_message('Sidechain: %s' % e)

    # ---------- NEW BEAT: the beat templates, built straight into an empty set (no template files needed) ----------
    TEMPLATES = {
        'hiphop': {'tempo': 90.0, 'root': 5, 'scale': 'Minor',
                   'tracks': [('DRUMS', 0xff5fae, ['Drums', 'Boom Bap Kit.adg'], [['Audio Effects', 'Drum Buss']]),
                              ('CHOPS', 0x20d6f0, ['Instruments', 'Simpler'], []),
                              ('BASS', 0xffd23f, ['Sounds', 'Bass', '808 Pure.adg'], [['Audio Effects', 'Compressor']]),
                              ('KEYS', 0xb07bff, ['Sounds', 'Piano & Keys', 'E-Piano Rhodish.adg'], [])]},
        'house': {'tempo': 124.0, 'root': 9, 'scale': 'Minor',
                  'tracks': [('DRUMS', 0xff5fae, ['Drums', '909 Core Kit.adg'], [['Audio Effects', 'Drum Buss']]),
                             ('CHOPS', 0x20d6f0, ['Instruments', 'Simpler'], []),
                             ('BASS', 0xffd23f, ['Sounds', 'Bass', 'Basic FM House Bass.adg'], [['Audio Effects', 'Compressor']]),
                             ('KEYS', 0xb07bff, ['Sounds', 'Piano & Keys', 'Organ Basic.adv'], [])]},
    }

    def _fresh(self):
        fresh = self.set_is_fresh()
        if not fresh:
            self._fresh_dismissed = False                       # next empty set: ask again
        return fresh and not getattr(self, '_fresh_dismissed', False)

    def set_is_fresh(self):
        """an empty set (what Ableton opens with): no clips and no instruments anywhere -> the Touch offers NEW BEAT"""
        song = self._song()
        for t in song.tracks:
            if list(t.devices) or any(cs.has_clip for cs in t.clip_slots) or list(getattr(t, 'arrangement_clips', [])):
                return False
        return True

    def build_template(self, kind):
        tpl = self.TEMPLATES.get(kind)
        if tpl is None:
            return
        song = self._song()
        b = self._surface._app().browser
        old = [t for t in song.tracks if not list(t.devices) and not any(cs.has_clip for cs in t.clip_slots)]
        song.tempo = tpl['tempo']
        song.root_note = tpl['root']
        song.scale_name = tpl['scale']
        jobs = []                                                   # one load per tick: Live needs a moment between loads
        made = []
        for name, colour, inst, fx in tpl['tracks']:
            def make(name=name, colour=colour):
                song.create_midi_track(-1)
                t = list(song.tracks)[-1]
                t.name = name
                t.color = colour
                made.append(t)
                song.view.selected_track = t
            jobs.append(make)
            def load(path=inst):
                item = self._resolve(path)
                if item is not None:
                    b.load_item(item)
            jobs.append(load)
            if name == 'KEYS' and kind == 'hiphop':           # Rhodish: hold longer (Decay 4 s, Sustain 60 %) but a short key-up (Release ~0.55 s) so retriggered chords don't smear
                def longer():
                    def walk(devs):
                        for d in devs:
                            for p in d.parameters:
                                if p.name == 'Decay' and p.max > 100:
                                    p.value = p.max
                                elif p.name == 'Release' and p.max > 100:
                                    p.value = 74.0
                                elif p.name == 'Env 1 Sustain':
                                    p.value = p.min + (p.max - p.min) * 0.6
                            for c in getattr(d, 'chains', []) if getattr(d, 'can_have_chains', False) else []:
                                walk(list(c.devices))
                    walk(list(song.view.selected_track.devices))
                jobs.append(longer)
            for f in fx:
                def load_fx(path=f):
                    t = song.view.selected_track
                    if t.devices:
                        song.view.select_device(t.devices[-1])
                    item = self._resolve(path)
                    if item is not None:
                        b.load_item(item)
                jobs.append(load_fx)
        def tidy():
            for t in old:                                           # the empty tracks of the new set go
                if t in list(song.tracks) and len(list(song.tracks)) > 1:
                    song.delete_track(list(song.tracks).index(t))
            while len(list(song.return_tracks)) < 2:
                song.create_return_track()
        jobs.append(tidy)
        for ri, fxname, rname in ((0, 'Reverb', 'Reverb'), (1, 'Echo', 'Echo')):          # (Live adds 'A-' itself)
            def ret(ri=ri, fxname=fxname, rname=rname):
                r = list(song.return_tracks)[ri]
                for k in range(len(list(r.devices)) - 1, -1, -1):
                    r.delete_device(k)
                r.name = rname
                song.view.selected_track = r
                item = self._resolve(['Audio Effects', fxname])
                if item is not None:
                    b.load_item(item)
            jobs.append(ret)
        def master():
            m = song.master_track
            if not any(d.class_name == 'GlueCompressor' for d in m.devices):
                song.view.selected_track = m
                item = self._resolve(['Audio Effects', 'Glue Compressor'])
                if item is not None:
                    b.load_item(item)
        jobs.append(master)
        def finish():
            by = {t.name: t for t in made}
            if 'BASS' in by:
                self._duck_by_kick(by['BASS'])                      # the kick pumps the bass
            for name, amount in (('KEYS', 0.3), ('CHOPS', 0.2), ('DRUMS', 0.1)):
                t = by.get(name)
                if t is not None and list(t.mixer_device.sends):
                    list(t.mixer_device.sends)[0].value = amount    # a bit of Return A (reverb)
            if 'DRUMS' in by:
                song.view.selected_track = by['DRUMS']
            self.send_ui({'type': 'show_page', 'page': 'PADS'})
            self._surface.show_message('New %s beat: %d BPM, %s %s' % ('hip-hop' if kind == 'hiphop' else 'house', int(tpl['tempo']),
                                       ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'][tpl['root']], tpl['scale']))
        jobs.append(finish)
        def run(i=[0]):
            if i[0] >= len(jobs):
                return
            try:
                jobs[i[0]]()
            except Exception as e:
                self._surface.log_message('template step %d: %r' % (i[0], e))
            i[0] += 1
            self._surface.schedule_message(2, run)
        self._surface.schedule_message(1, run)

    def _loop_rec(self, song):
        track = song.view.selected_track
        if not getattr(track, 'can_be_armed', False):
            self._surface.show_message('Select a track to record on')
            return
        ci = getattr(self, '_ci', None)
        if ci and not ci['fired']:                              # REC during the count-in: cancel it
            song.metronome, song.clip_trigger_quantization = self._ci_restore
            self._ci = None
            return
        slots = list(track.clip_slots)
        busy = next((sl for sl in slots if sl.has_clip and sl.clip.is_recording), None)
        if busy is not None:                                    # recording: stop now (it keeps looping what you played)
            busy.fire()                                         # (ends on the next bar line)
            self._sr_off = busy                                 # then Session Record off: Live leaves it on → no accidental overdub
            self._surface._od = False
            return
        if not track.arm:
            track.arm = True
        scenes = list(song.scenes)
        sel = scenes.index(song.view.selected_scene) if song.view.selected_scene in scenes else 0
        target = next((k for k in range(sel, len(slots)) if not slots[k].has_clip), None)
        if target is None:
            song.create_scene(-1)
            slots = list(track.clip_slots)
            target = len(slots) - 1
        bars = getattr(self, '_loop_bars', 2)
        beats = bars * song.signature_numerator * 4.0 / song.signature_denominator
        song.view.highlighted_clip_slot = slots[target]
        if getattr(self, '_count_in', 0):                       # own count-in (Live's setting can't be set from a script):
            self._count_start(song, slots[target], beats if bars else None)   # one full bar of metronome, then record on the bar
            return
        if bars == 0:                                           # FREE: record until REC again
            slots[target].fire()
            self._surface.show_message('Recording on %s… REC again to stop' % track.name)
            return
        slots[target].fire(record_length=beats)
        self._surface.show_message('Recording %d bar%s on %s…' % (bars, '' if bars == 1 else 's', track.name))

    def _count_start(self, song, slot, beats):
        self._ci_restore = (song.metronome, song.clip_trigger_quantization)
        song.metronome = True
        song.clip_trigger_quantization = Live.Song.Quantization.q_bar
        bar_len = song.signature_numerator * 4.0 / song.signature_denominator
        if song.is_playing:                                     # fire on the next bar line → it starts one bar later
            self._ci = {'slot': slot, 'beats': beats, 'at': (int(song.current_song_time / bar_len) + 1) * bar_len, 'fired': False}
        else:                                                   # stopped: start, fire at once → records from bar 2
            song.start_playing()
            self._ci = {'slot': slot, 'beats': beats, 'at': None, 'fired': False}
            self._surface.schedule_message(1, self._count_fire)
        self._surface.show_message('Count-in… recording starts on the next bar')

    def _count_fire(self):
        ci = getattr(self, '_ci', None)
        if not ci or ci['fired']:
            return
        ci['fired'] = True
        if ci['beats']:
            ci['slot'].fire(record_length=ci['beats'])
        else:
            ci['slot'].fire()

    def _count_tick(self):
        sr = getattr(self, '_sr_off', None)
        if sr is not None:                                      # a REC-stopped recording has really ended: Session Record off
            try:
                if not (sr.has_clip and sr.clip.is_recording):
                    self._sr_off = None
                    if not getattr(self._surface, '_od', False):
                        self._song().session_record = False
            except Exception:
                self._sr_off = None
        ci = getattr(self, '_ci', None)
        if not ci:
            return
        song = self._song()
        try:
            if not ci['fired']:
                if ci['at'] is not None and song.current_song_time >= ci['at'] - 0.05:
                    self._count_fire()
            elif ci['slot'].has_clip and ci['slot'].clip.is_recording or not song.is_playing:
                metro, q = getattr(self, '_ci_restore', (song.metronome, song.clip_trigger_quantization))
                song.metronome = metro                          # recording now: back to how it was
                song.clip_trigger_quantization = q
                self._ci = None
        except Exception:
            self._ci = None

    def _chords_state(self):
        surf = self._surface
        try:
            if not surf.is_melodic():
                return None
            song_root, song_iv = surf._scale()
            root, iv, bank_names = surf.chord_scale()
            pads = []
            for i in range(16):
                notes, name = surf.chord_for(i)
                deg, _, upd = surf.pad_degree(i, len(iv))
                d7 = deg % 7
                acc = ''
                if len(song_iv) == len(iv) and d7 < len(iv):            # borrowed: ♭ / ♯ against the song's scale
                    acc = '♭' if iv[d7] < song_iv[d7] else ('♯' if iv[d7] > song_iv[d7] else '')
                pads.append({'name': name, 'degree': acc + surf.ROMAN[d7], 'deg': d7, 'notes': notes})
            return {'style': surf._chord_style, 'oct': surf._chord_oct, 'bank': getattr(surf, '_chord_bank', 0), 'mode_cp': getattr(surf, '_chord_mode', 'chords'),
                    'bank_names': list(bank_names), 'pads': pads,
                    'held': list(getattr(self, 'chord_held', [])), 'mode': surf.pad_mode()}
        except Exception as e:
            self._surface.log_message('chords state: %r' % e)
            return None

    def _looprec_state(self):
        try:
            return self._looprec_state_()
        except Exception:
            return None

    def _looprec_state_(self):
        song = self._song()
        track = song.view.selected_track
        rec, progress, bar = False, 0.0, 0
        bars = getattr(self, '_loop_bars', 2)
        bar_len = song.signature_numerator * 4.0 / song.signature_denominator
        slots = list(getattr(track, 'clip_slots', []))
        for sl in slots:
            if sl.has_clip and sl.clip.is_recording:
                rec = True
                pos = max(0.0, sl.clip.playing_position - sl.clip.loop_start)
                bar = int(pos / bar_len) + 1
                progress = max(0.0, min(1.0, pos / (bars * bar_len))) if bars else 0.0
                break
        scenes = list(song.scenes)
        sel = scenes.index(song.view.selected_scene) if song.view.selected_scene in scenes else 0
        nxt = next((k for k in range(sel, len(slots)) if not slots[k].has_clip), len(slots))
        try:
            playing = track.playing_slot_index
        except Exception:                                       # Main / return tracks have no clips
            playing = -1
        return {'bars': bars, 'rec': rec, 'progress': round(progress, 2), 'bar': bar, 'next': nxt + 1,
                'playing': playing + 1 if playing is not None and playing >= 0 else 0,
                'counting': bool(getattr(self, '_ci', None)) or bool(getattr(song, 'is_counting_in', False)), 'count_in': getattr(self, '_count_in', 0),
                'overdub': bool(song.session_record), 'metro': bool(song.metronome),
                'armed': bool(getattr(track, 'arm', False)), 'track': track.name}

    def _normalize(self, sample, peak):
        import math
        target = -20.0 * math.log10(max(1e-4, min(1.0, peak)))       # dB of gain that brings the peak to 0 dB
        def db(v):
            sample.gain = v
            t = sample.gain_display_string().replace('dB', '').strip()
            try:
                return float(t)
            except ValueError:
                return -999.0
        lo, hi = 0.0, 1.0
        for _ in range(24):                                          # gain is monotonic: binary search the knob
            mid = (lo + hi) / 2
            if db(mid) < target:
                lo = mid
            else:
                hi = mid
        db(lo)
        self._surface.show_message('Normalized: %s' % sample.gain_display_string())

    def _slices_to_pads(self, simpler):
        """SLICES -> DRUM PADS: a new track with a Drum Rack, pad 1 = chop 1 ... (each a one-shot Simpler on the same file)"""
        s = simpler.sample
        path = s.file_path
        cuts = sorted(x for x in s.slices if s.start_marker <= x < s.end_marker)[:16]
        if not cuts:
            self._surface.show_message('No chops yet')
            return
        ends = cuts[1:] + [s.end_marker]
        b = self._surface._app().browser
        rack_item = next((c for c in b.instruments.children if c.name == 'Drum Rack'), None)
        simpler_item = next((c for c in b.instruments.children if c.name == 'Simpler'), None)
        if rack_item is None or simpler_item is None:
            self._surface.show_message('Drum Rack / Simpler not found in the browser')
            return
        self._surface.new_track('midi')
        track = self._song().view.selected_track
        b.load_item(rack_item)
        steps = {'i': 0, 'tries': 0, 'stage': 'load'}
        def rack():
            return next((d for d in track.devices if d.can_have_drum_pads), None)
        def tick():
            r = rack()
            if r is None:
                steps['tries'] += 1
                if steps['tries'] < 40:
                    self._surface.schedule_message(2, tick)
                return
            i = steps['i']
            if i >= len(cuts):
                track.name = 'Chops'
                r.view.selected_drum_pad = r.drum_pads[36]
                self._surface.show_message('%d chops on the pads' % len(cuts))
                return
            pad = r.drum_pads[36 + i]
            if steps['stage'] == 'load':
                r.view.selected_drum_pad = pad
                b.hotswap_target = pad
                b.load_item(simpler_item)
                b.hotswap_target = None
                steps['stage'] = 'fill'
                steps['tries'] = 0
                self._surface.schedule_message(2, tick)
                return
            dev = pad.chains[0].devices[0] if pad.chains and pad.chains[0].devices else None
            if dev is None or not hasattr(dev, 'replace_sample'):
                steps['tries'] += 1
                if steps['tries'] < 40:
                    self._surface.schedule_message(2, tick)
                return
            if dev.sample is None:
                dev.replace_sample(path)
                self._surface.schedule_message(2, tick)
                return
            dev.playback_mode = 1                                    # one-shot
            dev.sample.start_marker = int(cuts[i])
            dev.sample.end_marker = int(ends[i])
            pad.chains[0].name = 'Chop %d' % (i + 1)
            steps['i'] += 1
            steps['stage'] = 'load'
            self._surface.schedule_message(1, tick)
        self._surface.schedule_message(2, tick)

    def _arrangement_state(self):
        song = self._song()
        out = []
        for t in list(song.tracks)[:32]:
            clips = []
            for c in list(getattr(t, 'arrangement_clips', []))[:200]:
                clips.append([round(c.start_time, 3), round(c.end_time, 3), c.name, c.color, bool(c.is_midi_clip)])
            vol = t.mixer_device.volume
            out.append({'name': t.name, 'color': _color(t), 'clips': clips, 'selected': t == song.view.selected_track,
                        'volume': vol.value, 'vol_text': vol.str_for_value(vol.value),
                        'arm': getattr(t, 'arm', False), 'mute': t.mute, 'solo': t.solo,
                        'can_arm': getattr(t, 'can_be_armed', False)})
        cues = [[round(c.time, 3), c.name] for c in song.cue_points]
        return {'tracks': out, 'length': song.song_length, 'cues': cues, 'back_to_arranger': bool(song.back_to_arranger),
                'loop': [song.loop_start, song.loop_length, song.loop], 'sig': song.signature_numerator}

    def _arrangement_previews(self):
        """what's inside the arrangement clips (sent every 2 s on the arrange page, not with every state):
        MIDI = up to 96 notes [start 0..1, length 0..1, pitch]; audio = the file (the screen draws its peaks)"""
        song = self._song()
        out = []
        for ti, t in enumerate(list(song.tracks)[:32]):
            for ci, c in enumerate(list(getattr(t, 'arrangement_clips', []))[:200]):
                span = max(0.001, c.end_marker - c.start_marker)
                if c.is_midi_clip:
                    notes = c.get_notes_extended(0, 128, c.start_marker, span)
                    step = max(1, len(notes) // 96)
                    out.append([ti, ci, 'midi', [[round((n.start_time - c.start_marker) / span, 4),
                                                  round(n.duration / span, 4), n.pitch] for n in list(notes)[::step]]])
                else:
                    out.append([ti, ci, 'audio', getattr(c, 'file_path', '') or ''])
        return out

    # ---------- MIXER page (Ableton's mixer section): only built while the screen shows it ----------
    def _mix_strip(self, t, index):
        m = t.mixer_device
        strip = {'index': index, 'name': t.name, 'color': _color(t),
                 'volume': m.volume.value, 'vol_text': m.volume.str_for_value(m.volume.value),
                 'pan': m.panning.value, 'pan_text': m.panning.str_for_value(m.panning.value),
                 'sends': [[s.value, s.str_for_value(s.value), s.name[:1]] for s in m.sends],
                 'selected': t == self._song().view.selected_track}
        if index >= 0:                                   # (the Main track has no mute/solo/arm/routing)
            strip.update({'mute': t.mute, 'solo': t.solo, 'arm': getattr(t, 'arm', False),
                          'can_arm': getattr(t, 'can_be_armed', False), 'midi': getattr(t, 'has_midi_input', False),
                          'monitor': getattr(t, 'current_monitoring_state', 1),
                          'in_type': t.input_routing_type.display_name, 'in_channel': t.input_routing_channel.display_name,
                          'out_type': t.output_routing_type.display_name})
        return strip

    def _mix_visible(self):
        """MIXER (MPC): 8 strips across = the tracks that fit next to the returns and Main"""
        return max(2, 7 - len(list(self._song().return_tracks)))

    def _mixer_state(self):
        song = self._song()
        tracks = list(song.tracks)
        self._mix_offset = getattr(self, '_mix_offset', 0)          # (its own window: SESSION keeps its own)
        vis = self._mix_visible()
        self._mix_offset = max(0, min(self._mix_offset, max(0, len(tracks) - vis)))
        strips = [self._mix_strip(t, self._mix_offset + i)
                  for i, t in enumerate(tracks[self._mix_offset:self._mix_offset + vis])]
        returns = [self._mix_strip(r, -2 - i) for i, r in enumerate(song.return_tracks)]
        for i, r in enumerate(song.return_tracks):
            returns[i].update({'mute': r.mute, 'solo': r.solo})
        return {'offset': self._mix_offset, 'strips': strips, 'returns': returns, 'master': self._mix_strip(song.master_track, -1),
                'track_count': len(tracks), 'visible': vis, 'param': getattr(self, '_mix_param', 'volume')}

    def _meters(self):
        song = self._song()
        off = getattr(self, '_mix_offset', 0)
        tracks = (list(song.tracks)[off:off + self._mix_visible()] + list(song.return_tracks)
                  + [song.master_track])
        return [[round(getattr(t, 'output_meter_left', 0.0), 3), round(getattr(t, 'output_meter_right', 0.0), 3)] for t in tracks]

    def _mix_track(self, index):
        song = self._song()
        if index <= -2:                                   # returns: -2 = A, -3 = B …
            rets = list(song.return_tracks)
            return rets[-index - 2] if -index - 2 < len(rets) else None
        if index < 0:
            return song.master_track
        tracks = list(song.tracks)
        return tracks[index] if index < len(tracks) else None

    def _overview(self):
        """the whole session as a mini map: one string per track, '.' empty / 'c' clip / 'p' playing"""
        song = self._song()
        rows = []
        for t in list(song.tracks)[:64]:
            s = ''
            for slot in list(t.clip_slots)[:64]:
                s += ('p' if slot.clip.is_playing else 'c') if slot.has_clip else '.'
            rows.append(s)
        return rows

    def _device_state(self):
        device = self._song().view.selected_track.view.selected_device
        if device is None:
            return None
        params = []
        for p in list(device.parameters)[1:]:          # everything after "Device On"; the screen pages through them
            params.append({'name': p.name, 'value': p.value, 'min': p.min, 'max': p.max,
                           'text': p.str_for_value(p.value), 'quantized': p.is_quantized})
        track = self._song().view.selected_track
        listing = self._surface.device_list(track)
        chain = [{'name': d.name, 'on': bool(d.parameters[0].value) if d.parameters else True, 'pad': pad, 'type': int(d.type)}
                 for d, pad in listing]
        devices = [d for d, _ in listing]
        state = {'name': device.name, 'class': device.class_name, 'type': int(device.type), 'params': params, 'qlink_page': self._surface._qlink_bank,
                 'chain': chain, 'index': devices.index(device) if device in devices else -1,
                 'track_devices': len(track.devices)}
        state['page_names'], state['pages'] = device_layout(device)
        state['on'] = bool(device.parameters[0].value) if device.parameters else True
        if device.class_name in ('Compressor2', 'GlueCompressor'):           # sidechain: is the kick pumping it?
            sc = next((p for p in device.parameters if p.name == 'S/C On'), None)
            src = ''
            try:
                src = device.input_routing_type.display_name if hasattr(device, 'input_routing_type') else ''
            except Exception:
                pass
            state['sidechain'] = {'on': bool(sc.value) if sc is not None else False, 'from': src}
        if device.class_name == 'Compressor2':
            # value -> text tables, so the screen can turn dB / ratio into the parameter's 0..1 value when dragging
            state['tables'] = {}
            for p in device.parameters:
                if p.name in ('Threshold', 'Ratio'):
                    state['tables'][p.name] = [[round(p.min + (p.max - p.min) * k / 64.0, 5),
                                                p.str_for_value(p.min + (p.max - p.min) * k / 64.0)] for k in range(65)]
        return state

    # ---------- step grid: 16 sounds x 16 steps of one bar of the selected MIDI clip ----------
    def _steps_state(self):
        surf = self._surface
        track = self._song().view.selected_track
        if not getattr(track, 'has_midi_input', False):
            return None
        melodic = surf.is_melodic()
        rack = None if melodic else surf._current_rack()
        rows = []
        if melodic:                                    # piano roll: one octave of the scale (or all 12), high note on top
            root, _ = surf._scale()
            for n in surf.melodic_rows():
                rows.append({'note': n, 'name': surf.note_name(n), 'color': _color(track),
                             'root': (n - root) % 12 == 0, 'black': n % 12 in (1, 3, 6, 8, 10)})
            lo, span = min(r['note'] for r in rows), max(r['note'] for r in rows) - min(r['note'] for r in rows) + 1
        else:
            base = 36 + 16 * surf._bank
            lo, span = base, 16
            for n in range(base, min(base + 16, 128)):
                if rack is not None:
                    pad = rack.drum_pads[n]
                    if not pad.chains:
                        continue
                    rows.append({'note': n, 'name': pad.name, 'color': _color(pad.chains[0])})
                else:
                    rows.append({'note': n, 'name': str(n), 'color': _color(track)})
        clip = surf.step_clip()
        above = below = 0
        if melodic and clip is not None:
            pitches = [n.pitch for n in clip.get_notes_extended(0, 128, 0.0, max(4.0, clip.length))]
            if clip != getattr(self, '_roll_clip', None) or track != getattr(self, '_roll_track', None):
                self._roll_clip, self._roll_track = clip, track
                if pitches:                              # a clip with notes: open the octave where most of them are
                    p = sorted(pitches)[len(pitches) // 2]
                    surf.set_octave(p // 12 - 2)
                    rows = surf.melodic_rows()
                    lo, span = min(rows), max(rows) - min(rows) + 1
                    rows_out = rows
                    rebuilt = []
                    root, _ = surf._scale()
                    for n in rows_out:
                        rebuilt.append({'note': n, 'name': surf.note_name(n), 'color': _color(track),
                                        'root': (n - root) % 12 == 0, 'black': n % 12 in (1, 3, 6, 8, 10)})
                    if rebuilt:
                        rows = rebuilt
            above = len([p for p in pitches if p > lo + span - 1])
            below = len([p for p in pitches if p < lo])
        notes = []
        bars = 1
        if clip is not None:
            bars = max(1, int((clip.length + 3.99) // 4))
            if surf._step_page >= bars:                  # a shorter clip than the bar you were on: back to bar 1
                surf._step_page = 0
        page = surf._step_page
        if clip is not None:
            agg = {}                                   # per step: velocity, chance %, ratchet count
            for nt in clip.get_notes_extended(lo, span, max(0.0, page * 4.0 - surf.NUDGE), 4.0):
                key = (nt.pitch, int((nt.start_time - page * 4.0 + surf.NUDGE) / 0.25 + 0.001))
                if not 0 <= key[1] < 16:
                    continue
                if key in agg:
                    agg[key][4] += 1
                else:                                  # [pitch, step, velocity, chance %, ratchet, nudge (1/1000 beat)]
                    agg[key] = [key[0], key[1], int(nt.velocity), int(round(nt.probability * 100)), 1,
                                int(round(1000 * (nt.start_time - surf._step_base(key[1]))))]
            notes = list(agg.values())
        melody = None
        if melodic:                                        # MELODY view: the top note per step + glide / length (+ pad pitches)
            mn = surf.melody_notes(clip) if clip is not None else {}
            dev = surf._find_param(list(track.devices), ('Glide Time', 'Glide', 'Portamento'))
            lens = [n.duration for n in mn.values()]
            melody = {'steps': [[k, n.pitch, surf.note_name(n.pitch)] for k, n in sorted(mn.items())],
                      'glide': dev.str_for_value(dev.value) if dev is not None else '',
                      'length': round(sum(lens) / len(lens) / 0.25, 2) if lens else 1.0,
                      'pads': [[surf._pad_note(i), surf.note_name(surf._pad_note(i))] for i in range(16)]}
        roll = None
        if melodic:                                        # NOTES (melody composer): every note, its own start and length
            root, iv = surf._scale()
            allnotes = clip.get_notes_extended(0, 128, 0.0, clip.length) if clip is not None else []
            sel = surf._note_sel
            roll = {'notes': [[n.pitch, round(n.start_time, 4), round(n.duration, 4), int(n.velocity)] for n in list(allnotes)[:800]],
                    'len': clip.length if clip is not None else 4.0, 'root': root, 'intervals': iv,
                    'sel': [sel[0], round(sel[1], 4)] if sel else None}
        return {'rows': rows, 'notes': notes, 'page': page, 'bars': bars, 'has_clip': clip is not None, 'clip': clip.name if clip is not None else '', 'roll': roll,
                'melody': melody, 'melody_view': surf._melody_view,
                'melodic': melodic, 'octave': surf._mel_oct, 'in_key': surf._mel_inkey, 'above': above, 'below': below,
                'selected': surf.current_step_note(), 'mode': surf._step_mode,
                'length': surf._step_len, 'humanize': surf._humanize, 'row': surf.row_info(clip), 'follow': getattr(surf, '_step_follow', True), 'transpose': getattr(surf, '_mel_transpose', 0)}

    def _step_playhead(self):
        clip = self._surface.step_clip()
        if clip is None or not clip.is_playing:
            return None
        return (clip.playing_position - self._surface._step_page * 4.0) / 0.25

    # ---------- browser ----------
    def _roots(self):
        b = self._surface._app().browser
        roots = [('Sounds', b.sounds), ('Drums', b.drums), ('Instruments', b.instruments), ('Audio Effects', b.audio_effects),
                 ('MIDI Effects', b.midi_effects), ('Plug-ins', b.plugins), ('Samples', b.samples), ('Packs', b.packs),
                 ('User Library', b.user_library)]
        for f in b.user_folders:
            roots.append((f.name, f))
        return roots

    def _resolve(self, path):
        roots = dict(self._roots())
        item = roots.get(path[0]) if path else None
        for name in path[1:]:
            if item is None:
                return None
            item = next((c for c in item.children if c.name == name), None)
        return item

    def _browse(self, path, offset=0):
        if not path:
            items = [{'name': n, 'folder': True, 'loadable': False} for n, _ in self._roots()]
        else:
            item = self._resolve(path)
            items = []
            if item is not None:
                for i, c in enumerate(item.children):
                    if i < offset:
                        continue
                    if len(items) >= 600:
                        break
                    items.append({'name': c.name, 'folder': c.is_folder or (not c.is_loadable and len(c.children) > 0),
                                  'loadable': c.is_loadable})
        for i in range(0, max(1, len(items)), 60):
            self._send({'type': 'browse', 'path': path, 'offset': offset + i, 'items': items[i:i + 60],
                        'total': len(items)})

    def _state(self):
        song = self._song()
        track = song.view.selected_track
        return {
            'type': 'state',
            'instance': self._instance,
            'screen_page': self.page,                    # what we think the screen shows (the app corrects us)
            'fresh': self._fresh(),                      # empty set: offer NEW BEAT (hip-hop / house / empty)
            'looprec': self._looprec_state() if self.page == 'SESSION' else None,
            'step_mode': self._surface._step_mode,           # (also for tracks without a step grid)
            'levels': {'on': self._surface._levels, 'param': self._surface._levels_param, 'full': self._surface._full_level},
            'step_sel': list(self._surface._step_sel) if self._surface._step_sel else None,
            'song': {'tempo': round(song.tempo, 2), 'sig': [song.signature_numerator, song.signature_denominator],
                     'metronome': bool(song.metronome), 'quant': int(song.clip_trigger_quantization),
                     'root': song.root_note, 'scale': getattr(song, 'scale_name', ''),
                     'recording': bool(song.session_record or song.record_mode),
                     'swing': int(round(self._surface.swing() * 100))},
            'track': {'name': track.name, 'color': _color(track), 'kind': self._surface.track_kind(track)},
            'playing': song.is_playing,
            'view': 'Session' if self._surface._app().view.is_view_visible('Session') else 'Arrangement',
            'recording': bool(song.session_record if self._surface._app().view.is_view_visible('Session') else song.record_mode),
            'tempo': round(song.tempo, 2),
            'simpler': self._simpler_state(),
            'sampling': self._surface.rec_state(),
            'wave_q': self._surface.wave_qlink_info() if self.page == 'SAMPLE' else None,
            'session': self._session_state(),
            'tracks': self._tracks_state(),
            'mixer': self._mixer_state() if self.page == 'MIXER' else None,
            'pads': self._pads_state(),
            'chords': self._chords_state() if self.page == 'PADS' else None,
            'device': self._device_state(),
            'steps': self._steps_state(),
            'arrangement': None if self._surface._app().view.is_view_visible('Session') else self._arrangement_state(),
        }

    def send_ui(self, obj):
        self._send(obj)

    def _send(self, obj):
        try:
            self._sock.sendto(json.dumps(obj).encode('utf-8'), ('127.0.0.1', APP_PORT))
        except Exception as e:
            self._surface.log_message('screen link send failed (%s): %s' % (obj.get('type'), e))

    # ---------- called ~10x per second from update_display ----------
    def poll(self):
        # woken by the screen app: handle its commands and answer straight away
        if self._receive():
            self.push()

    def push(self):
        try:
            state = self._state()
        except Exception:
            return
        text = json.dumps(state, sort_keys=True)
        if text != self._last:
            self._last = text
            self._send(state)

    def tick(self):
        self._receive()
        self._count_tick()
        if self.page == 'MIXER':                          # live meters (own small message, 10x a second)
            try:
                self._send({'type': 'meters', 'levels': self._meters()})
            except Exception:
                pass
        self._ticks = getattr(self, '_ticks', 0) + 1
        if self._ticks % 5 == 0:                         # CPU load for the top bar (own small message, 2x a second)
            try:
                self._send({'type': 'cpu', 'value': round(float(self._surface._app().average_process_usage), 1)})
            except Exception:
                pass
        if self.page == 'SESSION' and self._ticks % 20 == 0 and not self._surface._app().view.is_view_visible('Session'):
            try:
                prev = self._arrangement_previews()
                text = json.dumps(prev)
                if text != getattr(self, '_last_prev', None):
                    self._last_prev = text
                    self._send({'type': 'arr_previews', 'clips': prev})
            except Exception as e:
                self._surface.log_message('previews: %s' % e)
        if self.page == 'STEPS' and getattr(self._surface, '_step_follow', True):   # FOLLOW: the bar that is playing
            try:
                clip = self._surface.step_clip()
                if clip is not None and clip.is_playing and clip.length > 4.0:
                    bar = max(0, min(3, int(clip.playing_position // 4.0)))
                    if bar != self._surface._step_page:
                        self._surface._step_page = bar
            except Exception:
                pass
        try:
            state = self._state()
        except Exception as e:
            self._surface.log_message('screen link state error: %s' % e)
            return
        text = json.dumps(state, sort_keys=True)
        if text != self._last or self._force:
            self._last = text
            self._force = False
            self._send(state)
        head = self._playhead()
        step = self._step_playhead()
        song = self._song()
        if song.is_playing:                              # what plays, so PLAY after any stop can bring it back
            try:
                self._surface._last_playing = [t.clip_slots[t.playing_slot_index] for t in song.tracks
                                               if 0 <= getattr(t, 'playing_slot_index', -1) < len(t.clip_slots)]
            except Exception:
                pass
        moved = song.current_song_time != getattr(self, '_last_time', None)     # (also when stopped: playhead moved)
        self._last_time = song.current_song_time
        had = getattr(self, '_had_head', False)                                 # one more message when the sound stopped,
        self._had_head = head is not None or step is not None                   # so the screen erases its last playhead
        if head is not None or step is not None or song.is_playing or moved or had:
            clip = self._surface.step_clip() if self.page == 'STEPS' else None
            beat = clip.playing_position if clip is not None and clip.is_playing else None   # NOTES: where the clip is
            self._send({'type': 'playhead', 'pos': head, 'step': step, 'time': song.current_song_time, 'beat': beat})

    def _receive(self):
        got = False
        for _ in range(50):
            try:
                data, _addr = self._sock.recvfrom(65536)
            except Exception:
                return got
            got = True
            try:
                self._handle(json.loads(data.decode('utf-8')))
            except Exception as e:
                self._surface.log_message('screen link command error: %s' % e)
        return got

    # ---------- finger edits ----------
    def _handle(self, msg):
        cmd = msg.get('cmd')
        song = self._song()
        if cmd == 'hello':
            self.jog_focus = False                        # the screen (re)started: no field has the wheel
            self._force = True
            return
        if cmd == 'debug':
            t = song.view.selected_track
            info = {'type': 'debug', 'track': t.name}
            for attr in ('arm', 'mute', 'solo', 'current_monitoring_state', 'output_meter_level', 'has_midi_input', 'can_be_armed', 'implicit_arm'):
                try:
                    info[attr] = getattr(t, attr)
                except Exception as e:
                    info[attr] = 'err %s' % e
            for attr in ('input_routing_type', 'input_routing_channel', 'output_routing_type'):
                try:
                    info[attr] = getattr(t, attr).display_name
                except Exception as e:
                    info[attr] = 'err %s' % e
            try:
                info['volume'] = t.mixer_device.volume.value
                info['devices'] = [(d.name, d.class_name, d.is_active) for d in t.devices]
                info['master_meter'] = song.master_track.output_meter_level
            except Exception as e:
                info['err'] = str(e)
            self._send(info)
            return
        d = self._simpler()
        s = d.sample if d is not None else None
        if cmd == 'move_slice' and s is not None:
            a, b = int(msg['from']), int(msg['to'])       # dragged on the screen: like Q1, chops in the way are pushed along (MPC)
            cuts = self._surface._chops(s)
            k = min(range(len(cuts)), key=lambda j: abs(cuts[j] - a)) if cuts else 0
            self._surface._wave_slice = self._surface._move_cut(s, k, b)   # (chop 1 = the START marker)
        elif cmd == 'insert_slice' and s is not None:
            s.insert_slice(int(msg['at']))
        elif cmd == 'remove_slice' and s is not None:
            s.remove_slice(int(msg['at']))
        elif cmd == 'set_start' and s is not None:
            s.start_marker = max(0, min(int(msg['at']), s.end_marker - 1))
        elif cmd == 'set_end' and s is not None:
            s.end_marker = max(s.start_marker + 1, min(int(msg['at']), s.length))
        elif cmd == 'slice_style' and s is not None:
            if d.playback_mode != 2:
                d.playback_mode = 2
            s.slicing_style = SLICE_STYLES.index(msg['style'])
            if 'regions' in msg:
                s.slicing_region_count = int(msg['regions'])
        elif cmd == 'simpler_mode' and d is not None:
            d.playback_mode = SIMPLER_MODES.index(msg['mode'])
        elif cmd == 'reset_slices' and s is not None:
            s.reset_slices()
        elif cmd == 'fire_clip':
            tracks = list(song.tracks)
            t = self._session_offset + int(msg['track'])
            if t < len(tracks):
                slots = list(tracks[t].clip_slots)
                if int(msg['scene']) < len(slots):
                    slots[int(msg['scene'])].fire()
                song.view.selected_track = tracks[t]
        elif cmd == 'stop_track':
            tracks = list(song.tracks)
            t = self._session_offset + int(msg['track'])
            if t < len(tracks):
                tracks[t].stop_all_clips()
        elif cmd == 'fire_scene':
            scenes = list(song.scenes)
            if self._scene_offset + int(msg['scene']) < len(scenes):
                scenes[self._scene_offset + int(msg['scene'])].fire()
        elif cmd == 'session_scroll':
            self._session_offset = max(0, self._session_offset + int(msg['by']))
        elif cmd == 'scene_scroll':
            self._scene_offset = max(0, self._scene_offset + int(msg['by']))
        elif cmd == 'pick_track':                         # top bar track picker (absolute index) or ◀ ▶ (step)
            tracks = list(song.tracks)
            if 'index' in msg:
                i = int(msg['index'])
            else:
                cur = tracks.index(song.view.selected_track) if song.view.selected_track in tracks else 0
                i = cur + int(msg.get('step', 0))
            if 0 <= i < len(tracks):
                song.view.selected_track = tracks[i]
                self._surface._qlink_bank = 0
                if not self._session_offset <= i < self._session_offset + SESSION_TRACKS:   # keep it in the grid
                    self._session_offset = (i // SESSION_TRACKS) * SESSION_TRACKS
        elif cmd in ('touch_clip', 'open_clip'):
            self._surface.touch_clip(self._session_offset + int(msg['track']), self._scene_offset + int(msg['scene']),
                                     open_only=cmd == 'open_clip')
        elif cmd == 'clip_edit':                          # the clip sheet (absolute track / scene)
            self._clip_edit(song, int(msg['track']), int(msg['scene']), msg.get('what'), msg.get('value'))
        elif cmd == 'new_beat':                           # NEW BEAT on the Touch: hiphop / house / empty
            if msg.get('kind') in self.TEMPLATES:
                self.build_template(msg['kind'])
            self._fresh_dismissed = True
        elif cmd == 'jog_focus':                          # a value on the screen has the wheel (MPC): the script leaves it alone
            self.jog_focus = bool(msg.get('on'))
        elif cmd == 'sample_key':                         # the app found the key of a new sample: move the beat to it
            self._sample_key(msg)
        elif cmd == 'key_undo':
            self._key_undo()
        elif cmd == 'key_leader_follow':                  # CROP / REVERSE / NORMALIZE made a new file of the lead sample
            if getattr(self, '_key_leader', None) == msg.get('from'):
                self._key_leader = msg.get('to')
        elif cmd == 'pitch_semis':                        # TIMESTRETCH → PITCH +n: tempo to a whole semitone, key follows
            self._pitch_semis(msg)
        elif cmd == 'chord_style':                        # CHORDS: rnb / house / triads
            self._surface._chord_style = msg.get('style', 'rnb')
            self._surface._chord_last = None
        elif cmd == 'chord_mode':                         # CHORDS: chords (pad = degree) / prog (ready-made progressions)
            self._surface._chord_mode = 'prog' if msg.get('mode') == 'prog' else 'chords'
            self._surface._chord_last = None
        elif cmd == 'chord_bank':                         # CHORDS: bank A–D
            self._surface._chord_bank = max(0, min(3, int(msg.get('bank', 0))))
            self._surface._chord_last = None
        elif cmd == 'chord_oct':
            self._surface._chord_oct = max(-2, min(2, self._surface._chord_oct + int(msg.get('by', 0))))
            self._surface._chord_last = None
        elif cmd == 'chord_play':                         # a chord pad on the screen: on / off
            self._surface.chord_pad(int(msg['pad']), int(msg.get('velocity', 100)) if msg.get('on') else 0)
        elif cmd == 'loop_len':                           # RECORD A LOOP: length in bars
            self._loop_bars = max(0, min(16, int(msg.get('bars', 2))))   # 0 = FREE (stop with REC)
        elif cmd == 'loop_rec':                           # ● REC LOOP: record exactly N bars on the selected track, then it loops
            self._loop_rec(song)
        elif cmd == 'loop_overdub':                       # OVERDUB: add notes to the clip that's playing on the armed track
            self._surface.toggle_overdub()
        elif cmd == 'count_in':                           # our own count-in (one bar), see _count_start
            self._count_in = 1 if int(msg.get('value', 0)) else 0
        elif cmd == 'copy_bar':
            self._surface.copy_bar()
        elif cmd == 'step_length':
            self._surface.set_step_len(float(msg.get('value', 0.25)))
        elif cmd == 'row_edit':                           # STEPS side panel: the selected row (fill / clear / velocity / vary / nudge)
            self._surface.row_edit(msg.get('what'), msg.get('value'))
        elif cmd == 'humanize':
            self._surface.humanize()
        elif cmd == 'touch_track':
            self._surface.touch_track(self._session_offset + int(msg['track']))
        elif cmd == 'touch_scene':
            self._surface.touch_scene(self._scene_offset + int(msg['scene']))
        elif cmd == 'new_track':
            self._surface.new_track(msg.get('kind', 'midi'))
        elif cmd in ('pad_select', 'pad_clear', 'pad_mute', 'pad_solo'):
            rack = self._surface._current_rack()
            if rack is not None:
                pad = rack.drum_pads[int(msg['note'])]
                if cmd == 'pad_select':
                    rack.view.selected_drum_pad = pad
                    self._surface._step_note = pad.note
                    self._surface.select_pad_sound(pad)          # DEVICE + Q-Links follow the pad (MPC)
                    if not song.is_playing:
                        self._surface.preview(pad.note)
                elif cmd == 'pad_clear':
                    pad.delete_all_chains()
                elif cmd == 'pad_mute':
                    pad.mute = not pad.mute
                else:
                    pad.solo = not pad.solo
        elif cmd == 'full_level':                         # KIT: PADS PLAY velocity / full level (the helper does the 127)
            surf = self._surface
            if bool(msg.get('on')) != surf._full_level:
                surf._full_level = not surf._full_level
                surf._send_helper(1, 1 if surf._full_level else 0)
        elif cmd == 'note_repeat':                        # KIT F-key: NOTE REPEAT latched on / off (the jog wheel or SHIFT+key = rate)
            surf = self._surface
            if msg.get('rate'):
                from .MPC_Touch import REPEAT_RATES
                surf._repeat_rate = (surf._repeat_rate + 1) % len(REPEAT_RATES)
            else:
                surf._repeat_latched = not surf._repeat_latched
            surf._update_note_repeat()
        elif cmd == 'pad_bank':
            self._surface._bank = max(0, min(7, int(msg['bank'])))
            self._surface._apply_bank()
        elif cmd == 'track_toggle':                       # M / S / arm buttons on track headers (absolute index)
            tracks = list(song.tracks)
            i = int(msg['track'])
            tr = tracks[i] if 0 <= i < len(tracks) else (self._mix_track(i) if i <= -2 else None)   # (returns: -2, -3 …)
            if tr is not None:
                what = msg.get('what')
                if what == 'mute':
                    tr.mute = not tr.mute
                elif what == 'solo':
                    tr.solo = not tr.solo
                elif what == 'arm' and getattr(tr, 'can_be_armed', False):
                    tr.arm = not tr.arm
        elif cmd == 'set_loop':
            song.loop_start = max(0.0, float(msg['start']))
            song.loop_length = max(1.0, float(msg['length']))
            if 'on' in msg:
                song.loop = bool(msg['on'])
        elif cmd == 'loop_toggle':
            song.loop = not song.loop
        elif cmd == 'jump_cue':
            cues = list(song.cue_points)
            if int(msg['index']) < len(cues):
                cues[int(msg['index'])].jump()
        elif cmd == 'session_jump':                       # mini map tap
            self._session_offset = max(0, int(msg.get('track', 0)))
            self._scene_offset = max(0, int(msg.get('scene', 0)))
        elif cmd == 'arr_clip':                           # tap on an arrangement clip (COPY / DELETE aware)
            self._surface.touch_arrangement_clip(int(msg['track']), int(msg['index']))
        elif cmd == 'mix_param':                          # MIXER: what the faders + Q-Links set (volume / pan / send0 / send1)
            self._mix_param = msg.get('what', 'volume')
            self._surface._sync_qlinks()
        elif cmd == 'mix_page':                           # MIXER: ‹ TRACKS 1–4 · TRACKS 5–8 ›
            n, vis = len(list(song.tracks)), self._mix_visible()
            self._mix_offset = max(0, min(max(0, n - vis), getattr(self, '_mix_offset', 0) + int(msg.get('by', 4))))
            self._surface._sync_qlinks()
        elif cmd == 'mix_set':                            # fader / pan / send from the MIXER page
            t = self._mix_track(int(msg['track']))
            if t is not None:
                m = t.mixer_device
                what = msg.get('what')
                p = m.volume if what == 'volume' else m.panning if what == 'pan' else (
                    list(m.sends)[int(msg.get('index', 0))] if what == 'send' and int(msg.get('index', 0)) < len(m.sends) else None)
                if p is not None:
                    p.value = max(p.min, min(p.max, float(msg['value'])))
        elif cmd == 'monitor':
            t = self._mix_track(int(msg['track']))
            if t is not None and hasattr(t, 'current_monitoring_state'):
                t.current_monitoring_state = int(msg['state'])
        elif cmd == 'routing_options':                    # the list for a routing popup
            t = self._mix_track(int(msg['track']))
            if t is not None:
                kind = msg.get('kind')
                opts = (t.available_input_routing_types if kind == 'in_type' else
                        t.available_input_routing_channels if kind == 'in_channel' else t.available_output_routing_types)
                self._send({'type': 'routing_options', 'track': int(msg['track']), 'kind': kind,
                            'options': [o.display_name for o in opts]})
        elif cmd == 'routing_set':
            t = self._mix_track(int(msg['track']))
            if t is not None:
                kind, i = msg.get('kind'), int(msg['index'])
                if kind == 'in_type' and i < len(t.available_input_routing_types):
                    t.input_routing_type = t.available_input_routing_types[i]
                elif kind == 'in_channel' and i < len(t.available_input_routing_channels):
                    t.input_routing_channel = t.available_input_routing_channels[i]
                elif kind == 'out_type' and i < len(t.available_output_routing_types):
                    t.output_routing_type = t.available_output_routing_types[i]
        elif cmd == 'back_to_arranger':                  # Ableton's orange "Back to Arrangement" button
            song.back_to_arranger = False
        elif cmd == 'song_set':                           # top bar: tempo / signature / metronome / quantise / key
            what, v = msg.get('what'), msg.get('value')
            try:
                if what == 'tempo':
                    song.tempo = max(20.0, min(999.0, float(v)))
                elif what == 'sig':
                    song.signature_numerator, song.signature_denominator = int(v[0]), int(v[1])
                elif what == 'metronome':
                    song.metronome = not song.metronome
                elif what == 'quant':
                    song.clip_trigger_quantization = int(v)
                elif what == 'root':
                    song.root_note = int(v)
                elif what == 'scale':
                    song.scale_name = str(v)
            except Exception as e:
                self._surface.show_message('Could not set %s: %s' % (what, e))
        elif cmd == 'levels':                             # 16 Levels on/off + parameter (PADS page)
            self._surface.set_levels(msg.get('on', True), msg.get('param'))
        elif cmd == 'swing':
            self._surface.set_swing(float(msg['value']) / 100.0)
        elif cmd == 'step_select':                        # a step on the screen: Q-Links + edit buttons work on it
            self._surface._step_sel = (int(msg['pitch']), int(msg['step'])) if msg.get('pitch') is not None else None
        elif cmd == 'step_edit':
            self._surface.step_edit(msg.get('what'), msg.get('value'))
        elif cmd == 'simpler_gain':                       # the sample's own gain (Simpler's "Gain" in the sample view)
            d = self._simpler()
            if d is not None and d.sample is not None:
                d.sample.gain = max(0.0, min(1.0, float(msg['value'])))
        elif cmd == 'simpler_param':                      # filter / volume … by name (graphic, sliders)
            d = self._simpler()
            if d is not None:
                for p in d.parameters:
                    if p.name == msg.get('name'):
                        p.value = max(p.min, min(p.max, p.min + float(msg['norm']) * (p.max - p.min)))
        elif cmd == 'simpler_action':                     # destructive / warp tools
            d = self._simpler()
            what = msg.get('what')
            if d is not None and d.sample is not None:
                try:
                    if what == 'reverse':
                        d.reverse()
                    elif what == 'crop':
                        d.crop()
                    elif what == 'warp_double' and d.can_warp_double:
                        d.warp_double()
                    elif what == 'warp_half' and d.can_warp_half:
                        d.warp_half()
                    elif what in ('trigger_toggle', 'loop_toggle'):   # PLAY: One Shot ⇄ Note On (MPC) · LOOP on / off
                        p = next((x for x in d.parameters if x.name == ('Trigger Mode' if what == 'trigger_toggle' else 'S Loop On')), None)
                        if p is not None:
                            p.value = p.max if p.value == p.min else p.min
                    elif what == 'warp':
                        d.sample.warping = not d.sample.warping
                    elif what == 'normalize':              # loudest peak to 0 dB (the screen measured the peak)
                        self._normalize(d.sample, float(msg.get('peak', 1.0)))
                    elif what == 'slices_to_pads':         # every chop on its own Drum Rack pad, on a new track
                        self._slices_to_pads(d)
                except Exception as e:
                    self._surface.show_message('%s: %s' % (what, e))
        elif cmd == 'slice_amount':                       # Transient sensitivity / number of regions / beat division
            d = self._simpler()
            if d is not None and d.sample is not None:
                s = d.sample
                v = float(msg['value'])
                if s.slicing_style == 0:
                    s.slicing_sensitivity = max(0.0, min(1.0, v))
                elif s.slicing_style == 2:
                    s.slicing_region_count = max(2, min(64, int(v)))
                elif s.slicing_style == 1:
                    s.slicing_beat_division = max(0, min(10, int(v)))
        elif cmd == 'rec_sample':                         # REC SAMPLE: start / stop (source: input or resample)
            self._surface.rec_sample(msg.get('source', 'input'))
        elif cmd == 'melody_view':                        # (gone: the melody composer replaced the MELODY view)
            self._surface._melody_view = False
        elif cmd == 'roll_add':                             # NOTES page: a new note (draw)
            self._surface.roll_add(msg['pitch'], msg['start'], msg['dur'], msg.get('vel', 100))
        elif cmd == 'roll_delete':
            self._surface.roll_delete(msg['pitch'], msg['start'])
        elif cmd == 'roll_move':                            # moved / stretched by finger
            self._surface.roll_move(msg['pitch'], msg['start'], msg['new_pitch'], msg['new_start'], msg['new_dur'])
        elif cmd == 'roll_select':                          # the note the Q-Links edit (none: pitch missing)
            self._surface._note_sel = (int(msg['pitch']), float(msg['start'])) if 'pitch' in msg else None
            if 'pitch' in msg and not song.is_playing:
                self._surface.preview(int(msg['pitch']), 100)
        elif cmd == 'roll_quantize':
            self._surface.roll_quantize(float(msg.get('grid', 0.25)))
        elif cmd == 'melody_step':                        # + / − on a step (also selects it for Q2)
            self._surface.melody_step(int(msg['step']), int(msg['delta']))
        elif cmd == 'melody_transpose':
            self._surface.melody_transpose(int(msg['delta']))
        elif cmd == 'melody_random':
            self._surface.melody_random()
        elif cmd == 'wave_bank':                          # tap a Q-Link page name on the WAVE page
            self._surface._wave_bank = max(0, int(msg['bank']))
            self._surface._sync_qlinks()
        elif cmd == 'wave_view':                          # what the WAVE page shows (Q-Link step size)
            self._surface._wave_view = (float(msg['start']), float(msg['end']))
        elif cmd == 'chop_play':                          # F-key PLAY CHOP / the headphones: hear the chop you're on
            self._surface.wave_chop(0)
        elif cmd == 'chop_delete':                        # the eraser: delete the chop you're on (= ERASE)
            self._surface.wave_delete_chop()
        elif cmd == 'chop_split' and s is not None:       # CHOP +: cut the chop you're on in two (MPC "SLICE +")
            cuts = self._surface._chops(s)
            k = cuts.index(self._surface._wave_slice) if self._surface._wave_slice in cuts else 0
            if cuts:
                a, b = cuts[k], (cuts[k + 1] if k + 1 < len(cuts) else s.end_marker)
                if b - a > 1000:
                    s.insert_slice(int((a + b) // 2))
                    self._surface._wave_slice = a
                    self.send_ui({'type': 'wave_marker', 'start': s.start_marker, 'end': s.end_marker, 'focus': a, 'slice': a})
        elif cmd == 'wave_slice':                         # chop last touched (Q1 moves its start, the wheel goes on from it)
            self._surface._wave_slice = int(msg['frame'])
        elif cmd == 'smart_warp' and s is not None:      # TIMESTRETCH on the SIMPLER page: the sample to your beat's tempo
            what = msg.get('what')
            try:
                if what in ('stretch', 'pitch', 'drums'):
                    # STRETCH = same pitch (Complex: keys, piano, vinyl loops) · PITCH = like a faster record (Re-Pitch)
                    # · DRUMS = tight hits (Beats). We know the sample's tempo, so Live is told exactly how long it is in
                    # beats ("warp as") — no bars to count, no guessing by Live.
                    s.warping = True
                    s.warp_mode = {'stretch': 4, 'pitch': 3, 'drums': 0}[what]
                    bpm = float(msg.get('bpm') or 0)
                    rate = float(getattr(s, 'sample_rate', 44100) or 44100)
                    if bpm > 0:
                        d.warp_as((s.end_marker - s.start_marker) / rate * bpm / 60.0)
                    if what == 'pitch' and bpm > 0:
                        st = 12 * math.log(song.tempo / bpm, 2)
                        txt = 'PITCH: %.1f → %.1f BPM, %+.1f semitones (like a faster record)' % (bpm, song.tempo, st)
                    elif bpm > 0:
                        txt = '%s: %.1f → %.1f BPM, same pitch' % (what.upper(), bpm, song.tempo)
                    else:
                        txt = '%s on (tempo of the sample unknown: Live guessed it)' % what.upper()
                    self.send_ui({'type': 'notice', 'text': txt})
                elif what == 'double' and d.can_warp_double:
                    d.warp_double()
                elif what == 'half' and d.can_warp_half:
                    d.warp_half()
                elif what == 'off':
                    s.warping = False
            except Exception as e:
                self.send_ui({'type': 'notice', 'text': 'Timestretch: %s' % e})
        elif cmd == 'chop_bars' and s is not None:        # CHOP n BARS from the chop you're on, by the sample's BPM: 16 chops
            bpm, bars = float(msg['bpm']), int(msg['bars'])
            rate = float(getattr(s, 'sample_rate', 44100) or 44100)
            a = self._surface._wave_slice if self._surface._wave_slice is not None and s.start_marker <= self._surface._wave_slice < s.end_marker else s.start_marker
            b = min(s.length, int(a + bars * 4 * 60.0 / bpm * rate))
            if d.playback_mode != 2:
                d.playback_mode = 2
            s.end_marker = max(s.end_marker, a + 1)
            s.start_marker = a
            s.end_marker = b
            s.slicing_style = SLICE_STYLES.index('Region')
            s.slicing_region_count = 8 if bars == 1 else 16
            self._surface._wave_slice = a
            self.send_ui({'type': 'wave_marker', 'start': a, 'end': b, 'focus': a, 'slice': a, 'chop': [a, b]})
            self.send_ui({'type': 'notice', 'text': '%d bar%s at %.1f BPM → %d chops on pads 1–%d' % (bars, '' if bars == 1 else 's', bpm,
                                                                                                 s.slicing_region_count, s.slicing_region_count)})
        elif cmd == 'stop_all':
            song.stop_all_clips()
        elif cmd == 'select_track':
            tracks = list(song.tracks)
            t = self._session_offset + int(msg['track'])
            if t < len(tracks):
                song.view.selected_track = tracks[t]
        elif cmd == 'set_param_name':
            device = song.view.selected_track.view.selected_device
            if device is not None:
                for p in device.parameters:
                    if p.name == msg['name'] and p.is_enabled:
                        p.value = max(p.min, min(p.max, float(msg['value'])))
                        break
        elif cmd == 'qlink_page':
            self._surface._qlink_bank = max(0, int(msg['bank']))
            self._surface._sync_qlinks()
        elif cmd == 'set_param':
            device = song.view.selected_track.view.selected_device
            if device is not None:
                params = list(device.parameters)[1:]
                i = int(msg['index'])
                if i < len(params):
                    p = params[i]
                    p.value = max(p.min, min(p.max, float(msg['value'])))
        elif cmd == 'toggle_step':
            self._surface.toggle_step(int(msg['pitch']), int(msg['step']), int(msg.get('page', self._surface._step_page)),
                                      int(msg.get('velocity', 100)))
        elif cmd == 'step_octave':
            self._surface.set_octave(self._surface._mel_oct + int(msg.get('delta', 0)))
        elif cmd == 'step_inkey':
            self._surface._mel_inkey = not self._surface._mel_inkey
            self._surface.set_octave(self._surface._mel_oct)
        elif cmd == 'step_page':                          # a bar picked by hand: FOLLOW pauses (so it doesn't jump away)
            self._surface._step_page = max(0, min(3, int(msg['page'])))
            self._surface._step_follow = False
        elif cmd == 'step_follow':
            self._surface._step_follow = bool(msg.get('on', True))
        elif cmd == 'select_sound':
            n = int(msg['note'])
            self._surface._step_note = n
            rack = self._surface._current_rack()
            if rack is not None:
                rack.view.selected_drum_pad = rack.drum_pads[n]
                self._surface.select_pad_sound(rack.drum_pads[n])
            if not self._song().is_playing:
                self._surface.preview(n)                 # hear the sound / note you picked
        elif cmd == 'browse':
            self._browse(list(msg.get('path', [])), int(msg.get('offset', 0)))
        elif cmd in ('browse_load', 'browse_preview'):
            item = self._resolve(list(msg['path']))
            b = self._surface._app().browser
            if item is not None:
                if cmd == 'browse_load':
                    if msg.get('target') in ('new', 'chop'):  # + NEW TRACK / CHOP A SAMPLE: a new track after the selected one
                        self._surface.new_track('midi')
                    if msg.get('target') == 'chop':            # the sample → Simpler, then Slice mode (once it's there)
                        b.load_item(item)
                        def to_slice(tries=[0]):
                            d = self._simpler()
                            if d is not None:
                                d.playback_mode = 2
                            elif tries[0] < 20:
                                tries[0] += 1
                                self._surface.schedule_message(2, to_slice)
                        self._surface.schedule_message(2, to_slice)
                        return
                    rack = self._surface._current_rack()
                    target = msg.get('target')
                    track = song.view.selected_track
                    if target == 'pad_fx' and rack is not None:          # effect on one pad's sound only
                        pad = rack.drum_pads[int(msg['note'])]
                        if pad.chains and pad.chains[0].devices:
                            song.view.select_device(pad.chains[0].devices[-1])
                    elif target == 'track_fx' and track.devices:         # effect on the whole track / kit (at the end)
                        song.view.select_device(track.devices[-1])
                    elif target == 'return_fx':                          # on Return A (made if there's none), shared by all
                        if not list(song.return_tracks):
                            song.create_return_track()
                        ret = list(song.return_tracks)[0]
                        song.view.selected_track = ret
                        if ret.devices:
                            song.view.select_device(ret.devices[-1])
                        b.load_item(item)
                        song.view.selected_track = track
                        self._surface.show_message('%s on %s: turn up the send to use it' % (item.name, ret.name))
                        return
                    elif target == 'main_fx':                            # on the Main output (master), then back
                        master = song.master_track
                        song.view.selected_track = master
                        if master.devices:
                            song.view.select_device(master.devices[-1])
                        b.load_item(item)
                        song.view.selected_track = track
                        self._surface.show_message('%s added to the Main output' % item.name)
                        return
                    simpler = self._simpler() if target == 'simpler' else None
                    if simpler is not None:                  # replace the Simpler's sample (hot-swap), keep its settings
                        b.hotswap_target = simpler
                        b.load_item(item)
                        b.hotswap_target = None
                    elif msg.get('target') == 'pad' and rack is not None:   # into one pad of the Drum Rack (hot-swap)
                        pad = rack.drum_pads[int(msg['note'])]
                        rack.view.selected_drum_pad = pad
                        b.hotswap_target = pad
                        b.load_item(item)
                        b.hotswap_target = None
                    else:
                        b.load_item(item)
                    if msg.get('duck'):                      # compressor: the kick ducks it (sidechain)
                        self._duck_by_kick(track if target != 'main_fx' else song.master_track)
                elif hasattr(b, 'preview_item'):
                    b.preview_item(item)
        elif cmd == 'browse_stop_preview':
            b = self._surface._app().browser
            if hasattr(b, 'stop_preview'):
                b.stop_preview()
        elif cmd == 'set_time':
            song.current_song_time = min(max(0.0, float(msg['time'])), song.song_length)   # Live refuses a time past the song's end
        elif cmd == 'capture':                            # SESSION: CAPTURE = what you just played (not recording) becomes a clip
            try:
                song.capture_midi()
                self._surface.show_message('Captured')
            except Exception as e:
                self._surface.show_message('Nothing to capture yet: play something on the pads first')
        elif cmd == 'device_on':                          # DEVICE header: the power button
            d = song.view.selected_track.view.selected_device
            if d is not None and d.parameters:
                d.parameters[0].value = 0.0 if d.parameters[0].value else 1.0
        elif cmd == 'device_delete':                      # DEVICE header: remove it (the screen asks twice)
            d = song.view.selected_track.view.selected_device
            owner = getattr(d, 'canonical_parent', None) if d is not None else None
            if owner is not None and hasattr(owner, 'delete_device'):
                owner.delete_device(list(owner.devices).index(d))
        elif cmd == 'duck':                               # DUCKED BY KICK on / off (compressor on the selected track)
            d = song.view.selected_track.view.selected_device
            if d is not None and d.class_name in ('Compressor2', 'GlueCompressor'):
                sc = next((p for p in d.parameters if p.name == 'S/C On'), None)
                if sc is not None and sc.value:
                    sc.value = 0
                else:
                    self._duck_by_kick(song.view.selected_track)
        elif cmd == 'select_device':
            devices = [d for d, _ in self._surface.device_list()]
            i = int(msg['index'])
            if i < len(devices):
                song.view.select_device(devices[i])
                self._surface._qlink_bank = 0
        elif cmd == 'page':
            self.page = msg.get('page', '')
        elif cmd == 'step_mode':                       # the screen's STEPS page puts the pads in step mode
            self._surface.set_step_mode(msg.get('on'))
        elif cmd == 'rec':
            self._surface.press_rec()
        elif cmd == 'toggle_view':
            self._surface.toggle_main_view()
        elif cmd == 'transport':
            what = msg.get('what')
            if what == 'play':                           # the screen's ▶ / ■: same as PLAY / STOP on the Touch
                if song.is_playing:
                    song.stop_playing()
                elif not self._surface._resume_clips():
                    song.continue_playing()
            elif what == 'stop':
                song.stop_playing()
