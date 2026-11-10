// touchmouse — makes the MPC Touch screen work as a touchscreen in any app (without MPC running).
// 1) Switches the touch panel on over the Touch's hidden "MPC Touch Private" MIDI port and keeps it alive (every 4 s).
// 2) Reads finger reports from the SiS touch controller (09e8:8001) via libusb.
// 3) Turns finger 1 into mouse down / drag / up on the MPC Touch display (EDID vendor 0x5109, model 0x1021).
// 4) Bridges the hidden port to a virtual "MPC Touch Live" MIDI port for Ableton (pads/buttons/knobs in, lights out),
//    with a softer pad velocity curve and Full Level. Ableton's script sends F0 7D 4D <cmd> <val> F7 to set those.
#include <CoreMIDI/CoreMIDI.h>
#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <libusb.h>   // libusb 1.0 (built from source by build.sh, see README)

#define TOUCH_VENDOR 0x5109
#define TOUCH_MODEL  0x1021
#define RAW_MAX 4095.0
#define DIRECT_SETTLE 0.03   // screen app: wait this long after touch-down so the first (jumpy) samples settle

static MIDIPortRef outPort; static MIDIEndpointRef privDest;
static volatile int running = 1;

static void midiSend(const char *hex) {
  Byte b[128]; int n = 0; const char *s = hex;
  while (*s) { while (*s == ' ') s++; if (!*s) break; b[n++] = (Byte)strtol(s, (char **)&s, 16); }
  Byte buf[256]; MIDIPacketList *pl = (MIDIPacketList *)buf; MIDIPacket *pk = MIDIPacketListInit(pl);
  MIDIPacketListAdd(pl, sizeof buf, pk, 0, n, b); MIDISend(outPort, privDest, pl);
}
static MIDIPortRef inPort;
static MIDIEndpointRef liveSrc, liveDest;   // virtual "MPC Touch Live" port pair, seen by Ableton
static volatile int fullLevel = 0;
static volatile double padCurve = 1.0;
static const int PAD_NOTES[16] = {37, 36, 42, 82, 40, 38, 46, 44, 48, 47, 45, 43, 49, 55, 51, 53};
static double padGain[16] = {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};   // per-pad boost for worn/dusty pads (padgain.txt, made by padcal)
static double padSensGain = 1.0;   // overall boost (padsens.txt: "<gain> <curve>"), applied on top of the per-pad gains
static void loadPadGain(void) {
  char path[1024]; snprintf(path, sizeof path, "%s/Library/Application Support/MPCTouchFix/padgain.txt", getenv("HOME"));
  FILE *f = fopen(path, "r"); double g[16]; int ok = 0;
  if (f) { ok = 1; for (int i = 0; i < 16; i++) ok &= fscanf(f, "%lf", &g[i]) == 1; fclose(f); }
  if (ok) { memcpy(padGain, g, sizeof g); fprintf(stderr, "touchmouse: pad gains loaded\n"); }
  // overall pad sensitivity: gain + curve (curve < 1 makes light hits louder)
  snprintf(path, sizeof path, "%s/Library/Application Support/MPCTouchFix/padsens.txt", getenv("HOME"));
  double sg, sc;
  if ((f = fopen(path, "r"))) {
    if (fscanf(f, "%lf %lf", &sg, &sc) == 2 && sg > 0 && sc > 0) { padSensGain = sg; padCurve = sc; fprintf(stderr, "touchmouse: pad sensitivity gain %.2f curve %.2f\n", sg, sc); }
    fclose(f);
  }
}
static int padIndex(int note) { for (int i = 0; i < 16; i++) if (PAD_NOTES[i] == note) return i; return -1; }      // velocity exponent: < 1 makes light hits louder
static void sendPacket(MIDIEndpointRef src, const Byte *b, int n) {
  Byte buf[1024]; MIDIPacketList *pl = (MIDIPacketList *)buf; MIDIPacket *pk = MIDIPacketListInit(pl);
  if (MIDIPacketListAdd(pl, sizeof buf, pk, mach_absolute_time(), n, b)) MIDIReceived(src, pl);   // real timestamp: Live drops track notes stamped 0
}
static int msgLen(Byte s) { switch (s & 0xF0) { case 0xC0: case 0xD0: return 2; default: return 3; } }
// Touch → Ableton: channel messages only (sysex from the Touch is keep-alive/identity chatter)
// Q-Link acceleration. The Touch scans the knobs at 100 Hz and sends at most one ±1 tick per 10 ms, so speed only shows
// in how long you keep turning (Ableton batches MIDI and loses that timing, so it's done here). The Remote Script maps
// the Q-Links natively in Live (linear, ~0.5% per tick; Live itself jumps for values above 4), so: plain 1 per tick,
// and only a long continuous turn ramps gently up to 3 (from 300 ms to 800 ms). A pause (>30 ms) or reversing resets.
static double qlRest[4]; static uint64_t qlLast[4], qlStart[4]; static int qlDir[4];
static int qlinkAccel(int k, int d, uint64_t now) {
  static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  double ms = 1e6 / tb.numer * tb.denom;                       // ticks per ms
  if (!qlLast[k] || (now - qlLast[k]) > 30 * ms || d != qlDir[k]) { qlStart[k] = now; qlRest[k] = 0; }
  qlLast[k] = now; qlDir[k] = d;
  double x = ((now - qlStart[k]) / ms - 300.0) / 500.0; x = x < 0 ? 0 : x > 1 ? 1 : x;
  qlRest[k] += 1.0 + 2.0 * x;
  int n = (int)qlRest[k]; qlRest[k] -= n;
  if (n > 3) n = 3;
  return n * d;
}

static void fromTouch(const MIDIPacketList *pl, void *a, void *b) {
  const MIDIPacket *p = &pl->packet[0];
  for (UInt32 i = 0; i < pl->numPackets; i++, p = MIDIPacketNext(p)) {
    for (int j = 0; j < p->length; ) {
      Byte st = p->data[j];
      if (st == 0xF0) { while (j < p->length && p->data[j] != 0xF7) j++; j++; continue; }
      if (st < 0x80 || st >= 0xF0) { j++; continue; }
      int len = msgLen(st); if (j + len > p->length) break;
      Byte m[3]; memcpy(m, p->data + j, len); j += len;
      int pi = (st & 0x0F) == 9 ? padIndex(m[1]) : -1;
      if ((st & 0xF0) == 0x90 && pi >= 0 && m[2] > 0) {   // pad hit
        int v = fullLevel ? 127 : (int)lround(127.0 * pow(fmin(1.0, m[2] * padGain[pi] * padSensGain / 127.0), padCurve));
        m[2] = v < 1 ? 1 : v > 127 ? 127 : v;
      }
      if ((st & 0xF0) == 0xA0 && pi >= 0) { int v = (int)lround(m[2] * padGain[pi] * padSensGain); m[2] = v > 127 ? 127 : v; }   // pressure
      if ((st & 0xF0) == 0xB0 && m[1] >= 16 && m[1] <= 19 && m[2]) {    // Q-Link tick
        int n = qlinkAccel(m[1] - 16, m[2] >= 64 ? -1 : 1, p->timeStamp ? p->timeStamp : mach_absolute_time());
        if (n > 63) n = 63; if (n < -63) n = -63;
        if (!n) continue;
        m[2] = n & 0x7F;
      }
      if (liveSrc) sendPacket(liveSrc, m, len);
    }
  }
}
// Ableton → Touch: everything goes to the hidden port, except our own F0 7D 4D settings messages
static void fromLive(const MIDIPacketList *pl, void *a, void *b) {
  const MIDIPacket *p = &pl->packet[0];
  for (UInt32 i = 0; i < pl->numPackets; i++, p = MIDIPacketNext(p)) {
    if (p->length >= 6 && p->data[0] == 0xF0 && p->data[1] == 0x7D && p->data[2] == 0x4D) {
      if (p->data[3] == 1) fullLevel = p->data[4] != 0;
      if (p->data[3] == 2) padCurve = 0.3 + p->data[4] / 100.0;   // 70 → 1.0 (linear)
      if (p->data[3] == 0x21 && liveSrc) {                    // screen app: wake the Remote Script now (CC 127 on ch 16)
        Byte m[3] = {0xBF, 0x7F, 0x01};
        sendPacket(liveSrc, m, 3);
      }
      if (p->data[3] == 0x20 && p->length >= 8 && liveSrc) {   // testing: inject a raw message as if it came from the Touch
        Byte m[3] = {(Byte)(p->data[4] | 0x80), p->data[5], p->data[6]};
        sendPacket(liveSrc, m, 3);
      }
      if ((p->data[3] == 0x10 || p->data[3] == 0x11) && p->length >= 7 && liveSrc) {   // screen app: play / stop a note (ch 11)
        Byte m[3] = {p->data[3] == 0x10 ? 0x9A : 0x8A, p->data[4], p->data[3] == 0x10 ? p->data[5] : 0};
        sendPacket(liveSrc, m, 3);
      }
      continue;
    }
    Byte buf[1024]; MIDIPacketList *out = (MIDIPacketList *)buf; MIDIPacket *pk = MIDIPacketListInit(out);
    if (MIDIPacketListAdd(out, sizeof buf, pk, 0, p->length, p->data) && privDest) MIDISend(outPort, privDest, out);
  }
}
// The Akai driver only talks to the device while a client also listens on the private input, so connect to it too.
static int findPrivatePort(void) {
  for (ItemCount di = 0; di < MIDIGetNumberOfDevices(); di++) {
    MIDIDeviceRef dev = MIDIGetDevice(di);
    for (ItemCount ei = 0; ei < MIDIDeviceGetNumberOfEntities(dev); ei++) {
      MIDIEntityRef e = MIDIDeviceGetEntity(dev, ei);
      for (ItemCount i = 0; i < MIDIEntityGetNumberOfDestinations(e); i++) {
        MIDIEndpointRef d = MIDIEntityGetDestination(e, i); CFStringRef s = 0; char nm[128] = {0};
        MIDIObjectGetStringProperty(d, kMIDIPropertyDisplayName, &s);
        if (s) { CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); CFRelease(s); }
        if (!strcmp(nm, "MPC Touch Private")) privDest = d;
      }
      for (ItemCount i = 0; i < MIDIEntityGetNumberOfSources(e); i++) {
        MIDIEndpointRef src = MIDIEntityGetSource(e, i); CFStringRef s = 0; char nm[128] = {0};
        MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &s);
        if (s) { CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); CFRelease(s); }
        if (!strcmp(nm, "MPC Touch Private")) { MIDIPortDisconnectSource(inPort, src); MIDIPortConnectSource(inPort, src, NULL); }
      }
    }
  }
  return privDest != 0;
}
static const char *STARTUP[] = { "BF 02 00", "BF 02 00", "F0 7E 00 06 01 F7", "F0 47 7F 37 62 00 01 61 F7",
  "F0 47 7F 37 64 00 03 00 01 01 F7", "F0 47 7F 37 64 00 03 01 01 01 F7", "F0 47 7F 37 64 00 03 02 00 00 F7",
  "F0 47 7F 37 64 00 03 03 00 00 F7", "F0 47 7F 37 63 00 03 00 00 00 F7", "F0 47 7F 37 63 00 03 01 00 00 F7",
  "F0 47 7F 37 5A 00 20 00 00 02 09 00 00 04 03 00 00 00 01 02 0A 03 0F 00 00 00 01 00 00 00 00 00 00 00 01 00 00 00 00 F7",
  // pads: 67 = trigger threshold (00 = softest tap registers; MPC sends 14), 68/69 = sensitivity (7F = max; MPC sends 14)
  "F0 47 7F 37 67 00 01 00 F7", "F0 47 7F 37 68 00 01 7F F7", "F0 47 7F 37 69 00 01 7F F7", 0 };
#define KEEPALIVE "F0 47 00 37 52 00 04 08 45 70 55 F7"
static void powerOn(void) { for (int i = 0; STARTUP[i]; i++) { midiSend(STARTUP[i]); usleep(200000); } midiSend(KEEPALIVE); }
static void powerOff(void) { midiSend("F0 47 7F 37 64 00 03 00 01 01 F7"); midiSend("F0 47 7F 37 64 00 03 01 01 00 F7"); midiSend("F0 47 7F 37 62 00 01 02 F7"); usleep(300000); }

static CGRect touchBounds(void) {
  CGDirectDisplayID ids[16]; uint32_t n = 0; CGGetOnlineDisplayList(16, ids, &n);
  for (uint32_t i = 0; i < n; i++)
    if (CGDisplayVendorNumber(ids[i]) == TOUCH_VENDOR && CGDisplayModelNumber(ids[i]) == TOUCH_MODEL) return CGDisplayBounds(ids[i]);
  return CGRectNull;
}
// --- Calibration: affine correction in display-local pixels, x' = a x + b y + c, y' = d x + e y + f.
// Written by the "MPC Touch Calibrate" app; reloaded on SIGHUP.
static double cal[6] = {1, 0, 0, 0, 1, 0};
static int calQuad = 0; static double q[12];   // quad: x' = W*(q0 + q1 u + q2 v + q3 uv + q4 u^2 + q5 v^2), y' = H*(q6..q11), u,v = 0..1
static volatile int reloadCal = 1;
static void loadCalibration(void) {
  char path[1024]; snprintf(path, sizeof path, "%s/Library/Application Support/MPCTouchFix/calibration.txt", getenv("HOME"));
  double c[6] = {1, 0, 0, 0, 1, 0}; FILE *f = fopen(path, "r"); calQuad = 0;
  if (f) {
    char kind[16] = {0};
    if (fscanf(f, "%15s", kind) == 1 && !strcmp(kind, "quad")) {
      int ok = 1; for (int i = 0; i < 12; i++) ok &= fscanf(f, "%lf", &q[i]) == 1;
      calQuad = ok;
    } else {
      rewind(f); if (fscanf(f, "%lf %lf %lf %lf %lf %lf", &c[0], &c[1], &c[2], &c[3], &c[4], &c[5]) != 6) memcpy(c, (double[]){1,0,0,0,1,0}, sizeof c);
    }
    fclose(f);
  }
  memcpy(cal, c, sizeof cal);
  loadPadGain();
  fprintf(stderr, "touchmouse: calibration %s\n", f ? "loaded" : "none (default mapping)");
}
static void onHup(int s) { reloadCal = 1; }
static CGPoint mapRaw(CGRect sb, int x, int y) {
  double lx = x / RAW_MAX * (sb.size.width - 1), ly = y / RAW_MAX * (sb.size.height - 1);
  double cx, cy;
  if (calQuad) {
    double u = x / RAW_MAX, v = y / RAW_MAX, t[6] = {1, u, v, u * v, u * u, v * v}; cx = cy = 0;
    for (int i = 0; i < 6; i++) { cx += q[i] * t[i]; cy += q[6 + i] * t[i]; }
    cx *= sb.size.width - 1; cy *= sb.size.height - 1;
  } else { cx = cal[0] * lx + cal[1] * ly + cal[2]; cy = cal[3] * lx + cal[4] * ly + cal[5]; }
  cx = fmax(0, fmin(sb.size.width - 1, cx)); cy = fmax(0, fmin(sb.size.height - 1, cy));
  return CGPointMake(sb.origin.x + cx, sb.origin.y + cy);
}

// --- One Euro filter: strong smoothing when the finger is still, little lag when it moves fast.
typedef struct { double x, dx, t; int init; } OneEuro;
#define OE_MINCUTOFF 3.0    // Hz: lower = steadier when still
#define OE_BETA      0.05   // higher = less lag on fast moves
#define OE_DCUTOFF   1.0
static double oeAlpha(double cutoff, double dt) { double tau = 1.0 / (2 * M_PI * cutoff); return 1.0 / (1.0 + tau / dt); }
static double oeFilter(OneEuro *f, double x, double t) {
  if (!f->init) { f->init = 1; f->x = x; f->dx = 0; f->t = t; return x; }
  double dt = t - f->t; if (dt <= 0) return f->x; f->t = t;
  double dx = (x - f->x) / dt; f->dx += oeAlpha(OE_DCUTOFF, dt) * (dx - f->dx);
  double cutoff = OE_MINCUTOFF + OE_BETA * fabs(f->dx);
  f->x += oeAlpha(cutoff, dt) * (x - f->x); return f->x;
}

static void post(CGEventType type, CGPoint p, int clicks) {
  CGEventRef ev = CGEventCreateMouseEvent(NULL, type, p, kCGMouseButtonLeft);
  if (clicks) CGEventSetIntegerValueField(ev, kCGMouseEventClickState, clicks);
  CGEventPost(kCGHIDEventTap, ev); CFRelease(ev);
}
static void rightClick(CGPoint p) {
  CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, p, kCGMouseButtonRight);
  CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp, p, kCGMouseButtonRight);
  CGEventPost(kCGHIDEventTap, d); CGEventPost(kCGHIDEventTap, u); CFRelease(d); CFRelease(u);
}
// Scroll events carry trackpad-style phases so apps treat them like real swipes (incl. momentum).
#define F_CONTINUOUS 88
#define F_SCROLL_PHASE 99
#define F_MOMENTUM_PHASE 123
enum { PH_NONE = 0, PH_BEGAN = 1, PH_CHANGED = 2, PH_ENDED = 4 };
enum { MO_NONE = 0, MO_BEGIN = 1, MO_CONTINUE = 2, MO_END = 3 };
static void scrollEv(double dx, double dy, int phase, int momentum) {
  CGEventRef ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, (int32_t)lround(dy), (int32_t)lround(dx));
  CGEventSetIntegerValueField(ev, F_CONTINUOUS, 1);
  CGEventSetIntegerValueField(ev, F_SCROLL_PHASE, phase);
  CGEventSetIntegerValueField(ev, F_MOMENTUM_PHASE, momentum);
  CGEventPost(kCGHIDEventTap, ev); CFRelease(ev);
}

// Tuning (screen pixels / seconds)
#define DEADZONE      10.0   // finger wobble ignored until it moves this far: taps stay clicks
#define HOLD_TO_DRAG  0.30   // iPad mode: hold this long without moving, then move = mouse drag
#define WAIT_SECOND   0.06   // mouse mode: short wait to see whether a second finger joins
#define LIFT_DEBOUNCE 0.035  // contact drop-outs shorter than this don't count as lifting
#define SCROLL_GAIN   0.8    // swipe distance -> scroll distance
#define MOMENTUM_TAU  0.45   // seconds for a flick to slow to ~37 % speed
#define MOMENTUM_MIN  120.0  // px/s: slower releases don't coast
#define DOUBLE_TIME   0.35   // max gap between taps of a double click

static double nowSec(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static double dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
static int ipadMode = 1;
// Hide the pointer while a finger is on the Touch (macOS only lets the active app do that, unless the connection
// asks for "SetsCursorInBackground" — private but long-standing WindowServer property).
typedef int CGSConnectionID;
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(CGSConnectionID, CGSConnectionID, CFStringRef, CFTypeRef);
static int cursorHidden = 0;
static void hideCursor(int hide) {
  if (hide == cursorHidden) return;
  cursorHidden = hide;
  dispatch_async(dispatch_get_main_queue(), ^{ if (hide) CGDisplayHideCursor(kCGDirectMainDisplay); else CGDisplayShowCursor(kCGDirectMainDisplay); });
}
// The MPCScreen app (Ableton screen) wants direct touches: press at once, drag = drag (slice markers, knobs).
// Its window rects are looked up once a second on the main thread (the window list is too slow to ask per touch).
#define MAX_APP_RECTS 8
static CGRect appRects[MAX_APP_RECTS]; static volatile int appRectCount = 0;
static void refreshAppRects(void) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!list) return;
  CGRect found[MAX_APP_RECTS]; int n = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(list) && n < MAX_APP_RECTS; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(list, i); CGRect r;
    char owner[64] = {0}; CFStringRef o = CFDictionaryGetValue(w, kCGWindowOwnerName);
    if (o) CFStringGetCString(o, owner, sizeof owner, kCFStringEncodingUTF8);
    CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
    if (!strcmp(owner, "MPCScreen") && b && CGRectMakeWithDictionaryRepresentation(b, &r)) found[n++] = r;
  }
  CFRelease(list);
  memcpy(appRects, found, sizeof found); appRectCount = n;
}
static int overScreenApp(CGPoint p) {
  for (int i = 0; i < appRectCount; i++) if (CGRectContainsPoint(appRects[i], p)) return 1;
  return 0;
}
// Like the MPC software: touches on the screen app go straight into it (UDP 9102, "<n> x y x y…" in window points,
// "0" = all fingers up), no mouse pointer involved: nothing to show, hide, settle or warp back.
static int appSock = -1;
static void sendAppTouches(CGPoint *pts, int n, CGRect win) {
  if (appSock < 0) appSock = socket(AF_INET, SOCK_DGRAM, 0);
  char msg[256]; int len = snprintf(msg, sizeof msg, "%d", n);
  for (int i = 0; i < n && i < 5; i++) len += snprintf(msg + len, sizeof msg - len, " %.1f %.1f", pts[i].x - win.origin.x, pts[i].y - win.origin.y);
  struct sockaddr_in a = {0}; a.sin_family = AF_INET; a.sin_port = htons(9102); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  sendto(appSock, msg, len, 0, (struct sockaddr *)&a, sizeof a);
}
static CGRect appRectAt(CGPoint p) {
  for (int i = 0; i < appRectCount; i++) if (CGRectContainsPoint(appRects[i], p)) return appRects[i];
  return CGRectNull;
}
static void announce(const char *msg) {
  char cmd[256]; snprintf(cmd, sizeof cmd, "osascript -e 'display notification \"%s\" with title \"MPC Touch\"' >/dev/null 2>&1 &", msg); system(cmd);
  fprintf(stderr, "touchmouse: %s\n", msg);
}

static void *touchThread(void *arg) {
  libusb_context *ctx; libusb_init(&ctx); libusb_device_handle *h = NULL;
reopen:
  // wait for the touch controller (it only appears after the startup sequence; also after the Touch is unplugged/replugged)
  for (int i = 0; !h && running; i++) {
    h = libusb_open_device_with_vid_pid(ctx, 0x09e8, 0x8001);
    if (!h) { if (i % 40 == 39) { fprintf(stderr, "touch panel not up yet, sending startup again\n"); findPrivatePort(); powerOn(); } usleep(100000); }
  }
  if (!h) { libusb_exit(ctx); return NULL; }
  libusb_claim_interface(h, 0);
  fprintf(stderr, "touchmouse: running in iPad mode — 3-finger tap switches to mouse mode (Ctrl-C to stop)\n");
  enum { IDLE, PENDING, PRESSED, SWIPING, MULTI, APP } st = IDLE;
  CGRect appWin = CGRectNull; double appLift = 0;
  int n = 0, maxN = 0; CGPoint pts[10];
  CGPoint downPt = {0}, cur = {0}, sm = {0}, prev = {0}, multiStart = {0};
  double downAt = 0, liftAt = 0, lastUp = -1, prevT = 0, multiAt = 0, travel = 0;
  double vx = 0, vy = 0;              // swipe velocity (px/s), for momentum
  int coasting = 0; double coastT = 0;
  OneEuro fx = {0}, fy = {0}; CGPoint filt = {0}, tapPt = {0};
  int dragging = 0, clicks = 0, direct = 0; CGPoint lastClickPt = {0};
  CGPoint savedCursor = {0}; int haveSaved = 0; double lastTouchAt = 0;   // cursor goes back to the Mac screen after a touch
  while (running) {
    unsigned char b[64]; int got = 0;
    int r = libusb_interrupt_transfer(h, 0x82, b, sizeof b, &got, 15);   // 15 ms tick drives timers + momentum
    if (r == LIBUSB_ERROR_NO_DEVICE || r == LIBUSB_ERROR_NOT_FOUND) {   // gone, or not claimed (previous owner still let go)
      fprintf(stderr, "touch panel gone (unplugged or switched off) — waiting for it\n");
      if (st == PRESSED) post(kCGEventLeftMouseUp, sm, 1);
      libusb_close(h); h = NULL; st = IDLE; n = 0; usleep(300000); goto reopen;
    }
    if (r && r != LIBUSB_ERROR_TIMEOUT) { fprintf(stderr, "touch read error: %s\n", libusb_error_name(r)); usleep(500000); continue; }
    CGRect sb = touchBounds(); if (CGRectIsNull(sb)) continue;
    if (r == 0 && getenv("TOUCH_DEBUG")) { static int k; if (k++ % 20 == 0) { fprintf(stderr, "raw %d:", got); for (int i = 0; i < got && i < 40; i++) fprintf(stderr, " %02x", b[i]); fprintf(stderr, "\n"); } }
    int fresh = 0;                                   // a new report arrived this round (not just the 15 ms tick)
    if (r == 0 && got >= 61 && b[0] == 0x10) {
      n = 0; fresh = 1;
      for (int k = 0; k < 10; k++) {
        const unsigned char *f = b + 1 + 6 * k;
        if (!(f[0] & 1)) continue;
        int x = f[2] | f[3] << 8, y = f[4] | f[5] << 8;
        if (x <= 0 || y <= 0 || x >= RAW_MAX || y >= RAW_MAX) continue;   // junk contact (seen after a reconnect)
        CGPoint p = mapRaw(sb, x, y); int dup = 0;
        for (int j = 0; j < n; j++) if (dist(pts[j], p) < 2) dup = 1;     // the same contact reported twice
        if (!dup) pts[n++] = p;
      }
    }
    double t = nowSec();
    if (reloadCal) { reloadCal = 0; loadCalibration(); }
    // filtered position of finger 1 (reset whenever a new touch starts)
    if (n == 0) { fx.init = fy.init = 0; }
    else { filt = CGPointMake(oeFilter(&fx, pts[0].x, t), oeFilter(&fy, pts[0].y, t)); }
    // a touch on the screen app goes straight to it (no pointer at all)
    if (st == IDLE && n > 0 && overScreenApp(pts[0])) { st = APP; appWin = appRectAt(pts[0]); appLift = 0; }
    if (st == APP) {
      if (n > 0) { appLift = 0; if (fresh) sendAppTouches(pts, n, appWin); }
      else {
        if (!appLift) appLift = t;
        if (t - appLift >= LIFT_DEBOUNCE) { sendAppTouches(pts, 0, appWin); st = IDLE; }
      }
      continue;
    }
    // remember where the trackpad cursor was (outside the Touch) and put it back once the touch is over
    if (n > 0) {
      if (!haveSaved) {
        CGEventRef ev = CGEventCreate(NULL); CGPoint c = CGEventGetLocation(ev); CFRelease(ev);
        if (!CGRectContainsPoint(sb, c)) { savedCursor = c; haveSaved = 1; }
      }
      hideCursor(1);
      lastTouchAt = t;
    } else if (haveSaved && st == IDLE && !coasting && t - lastTouchAt > 0.15) {
      CGWarpMouseCursorPosition(savedCursor); CGAssociateMouseAndMouseCursorPosition(true); haveSaved = 0;
    }
    if (cursorHidden && n == 0 && !haveSaved && st == IDLE && !coasting) hideCursor(0);
    // momentum: keep coasting until a new touch or the speed dies out
    if (coasting) {
      if (n > 0) { scrollEv(0, 0, PH_NONE, MO_END); coasting = 0; }
      else {
        double dt = t - coastT; coastT = t; double k = exp(-dt / MOMENTUM_TAU); vx *= k; vy *= k;
        if (hypot(vx, vy) < 20) { scrollEv(0, 0, PH_NONE, MO_END); coasting = 0; }
        else scrollEv(vx * dt, vy * dt, PH_NONE, MO_CONTINUE);
      }
    }
    switch (st) {
    case IDLE:
      if (n >= 2) { st = MULTI; maxN = n; multiStart = prev = CGPointMake((pts[0].x+pts[1].x)/2, (pts[0].y+pts[1].y)/2); multiAt = t; travel = 0; post(kCGEventMouseMoved, multiStart, 0); }
      else if (n == 1) { direct = overScreenApp(pts[0]); st = PENDING; downPt = cur = sm = tapPt = pts[0]; downAt = t; post(kCGEventMouseMoved, downPt, 0); }
      break;
    case PENDING:
      if (n >= 2) { st = MULTI; maxN = n; multiStart = prev = CGPointMake((pts[0].x+pts[1].x)/2, (pts[0].y+pts[1].y)/2); multiAt = t; travel = 0; break; }
      if (n == 1) { cur = pts[0]; tapPt = filt; }
      if (n == 0) {                                                     // tap (at the steadied position)
        downPt = tapPt;
        clicks = (t - lastUp < DOUBLE_TIME && dist(downPt, lastClickPt) < 25) ? clicks + 1 : 1;
        post(kCGEventLeftMouseDown, downPt, clicks); post(kCGEventLeftMouseUp, downPt, clicks);
        lastClickPt = downPt; lastUp = t; st = IDLE;
      } else if (direct && t - downAt > DIRECT_SETTLE) {               // screen app: press once the finger has settled
        downPt = tapPt; clicks = 1;
        post(kCGEventMouseMoved, downPt, 0); post(kCGEventLeftMouseDown, downPt, 1); lastClickPt = downPt; sm = downPt; dragging = 1; liftAt = 0; st = PRESSED;
      } else if (direct) {
      } else if (ipadMode && dist(cur, downPt) > DEADZONE) {           // iPad: quick move = swipe-scroll
        st = SWIPING; prev = cur; prevT = t; vx = vy = 0; scrollEv(0, 0, PH_BEGAN, MO_NONE);
      } else if ((ipadMode && t - downAt > HOLD_TO_DRAG) ||             // iPad: hold = press (then drag)
                 (!ipadMode && (dist(cur, downPt) > DEADZONE || t - downAt > WAIT_SECOND))) {
        downPt = tapPt;
        clicks = (t - lastUp < DOUBLE_TIME && dist(downPt, lastClickPt) < 25) ? clicks + 1 : 1;
        post(kCGEventMouseMoved, downPt, 0); post(kCGEventLeftMouseDown, downPt, clicks); lastClickPt = downPt; sm = downPt; dragging = 0; liftAt = 0; st = PRESSED;
      }
      break;
    case PRESSED:
      if (direct && n >= 2) {                                           // screen app: 2nd finger = two-finger move/zoom
        post(kCGEventLeftMouseUp, sm, clicks); lastUp = t;
        st = MULTI; maxN = n; multiStart = prev = CGPointMake((pts[0].x+pts[1].x)/2, (pts[0].y+pts[1].y)/2); multiAt = t; travel = 0; direct = 0;
        break;
      }
      if (n >= 1) {
        liftAt = 0; cur = pts[0];
        if (!dragging && dist(cur, downPt) > (ipadMode ? 3.0 : DEADZONE)) dragging = 1;
        if (dragging && dist(filt, sm) >= 0.5) { sm = filt; post(kCGEventLeftMouseDragged, sm, clicks); }
      } else {
        if (!liftAt) liftAt = t;
        if (t - liftAt >= LIFT_DEBOUNCE) { post(kCGEventLeftMouseUp, dragging ? sm : downPt, clicks); lastUp = t; st = IDLE; }
      }
      break;
    case SWIPING:
      if (n >= 1) {
        liftAt = 0; cur = pts[0];
        double dx = (cur.x - prev.x) * SCROLL_GAIN, dy = (cur.y - prev.y) * SCROLL_GAIN, dt = t - prevT;
        if (fabs(dx) >= 1 || fabs(dy) >= 1) {
          scrollEv(dx, dy, PH_CHANGED, MO_NONE);
          if (dt > 0.001) { vx = 0.6 * vx + 0.4 * dx / dt; vy = 0.6 * vy + 0.4 * dy / dt; }
          prev = cur; prevT = t;
        }
      } else {
        if (!liftAt) liftAt = t;
        if (t - liftAt >= LIFT_DEBOUNCE) {
          scrollEv(0, 0, PH_ENDED, MO_NONE);
          if (t - prevT > 0.08) vx = vy = 0;                            // finger rested before lifting: no flick
          if (hypot(vx, vy) > MOMENTUM_MIN) { coasting = 1; coastT = t; scrollEv(0, 0, PH_NONE, MO_BEGIN); }
          st = IDLE;
        }
      }
      break;
    case MULTI:
      if (n > maxN) maxN = n;
      if (n >= 2) {
        CGPoint c = CGPointMake((pts[0].x+pts[1].x)/2, (pts[0].y+pts[1].y)/2);
        double dx = (c.x - prev.x) * SCROLL_GAIN, dy = (c.y - prev.y) * SCROLL_GAIN;
        if (maxN == 2 && (fabs(dx) >= 1 || fabs(dy) >= 1)) { scrollEv(dx, dy, travel == 0 ? PH_BEGAN : PH_CHANGED, MO_NONE); prev = c; travel += hypot(dx, dy); }
      } else if (n == 0) {
        if (travel > 0) scrollEv(0, 0, PH_ENDED, MO_NONE);
        if (travel < 15 && t - multiAt < 0.4) {
          if (maxN == 2) rightClick(multiStart);                         // two-finger tap
          else if (maxN >= 3) { ipadMode = !ipadMode; announce(ipadMode ? "iPad mode: swipe scrolls, hold then drag" : "Mouse mode: drag drags"); }
        }
        st = IDLE;
      }
      break;
    }
  }
  if (st == PRESSED) post(kCGEventLeftMouseUp, sm, 1);
  libusb_release_interface(h, 0); libusb_close(h); libusb_exit(ctx); return NULL;
}
static void stop(int s) { running = 0; }
static void keepAlive(CFRunLoopTimerRef t, void *i) { if (!running) { CFRunLoopStop(CFRunLoopGetCurrent()); return; } midiSend(KEEPALIVE); }
int main(void) {
  if (!AXIsProcessTrusted()) fprintf(stderr, "warning: no Accessibility permission — clicks may be ignored (System Settings → Privacy & Security → Accessibility)\n");
  MIDIClientRef c; MIDIClientCreate(CFSTR("touchmouse"), 0, 0, &c); MIDIOutputPortCreate(c, CFSTR("out"), &outPort); MIDIInputPortCreate(c, CFSTR("in"), fromTouch, NULL, &inPort);
  MIDISourceCreate(c, CFSTR("MPC Touch Live"), &liveSrc); MIDIDestinationCreate(c, CFSTR("MPC Touch Live"), fromLive, NULL, &liveDest);
  if (!findPrivatePort()) { fprintf(stderr, "MPC Touch Private MIDI port not found — is the MPC Touch connected and the Akai driver loaded?\n"); return 1; }
  CGSConnectionID cid = _CGSDefaultConnection(); CGSSetConnectionProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
  signal(SIGINT, stop); signal(SIGTERM, stop); signal(SIGHUP, onHup);
  powerOn();
  pthread_t th; pthread_create(&th, NULL, touchThread, NULL);
  CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, NULL, NULL);
  // keep-alive every 4 s; the 0.5 s tick also notices Ctrl-C
  CFRunLoopTimerContext ctx = {0}; int tick = 0; (void)ctx;
  while (running) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false); if (++tick % 8 == 0) midiSend(KEEPALIVE); if (tick % 2 == 0) refreshAppRects(); }
  pthread_join(th, NULL); hideCursor(0); powerOff(); fprintf(stderr, "touchmouse: stopped\n"); return 0;
}
