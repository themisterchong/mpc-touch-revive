// padcal — evens out worn/dusty MPC Touch pads.
// Hit every pad 4 times with the same, normal force: pads start red, turn yellow while counting and green when done.
// Reads raw velocities from the hidden "MPC Touch Private" port, writes a boost per pad to padgain.txt and tells
// touchmouse (SIGHUP) to load it. Weak pads are boosted up to the level of the good ones (never turned down).
#include <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define HITS 4
static const int PAD_NOTES[16] = {37, 36, 42, 82, 40, 38, 46, 44, 48, 47, 45, 43, 49, 55, 51, 53};
static int vel[16][HITS], count[16];
static MIDIPortRef outPort; static MIDIEndpointRef dest;

static void color(int pad, int r, int g, int b) {
  Byte m[12] = {0xF0, 0x47, 0x7F, 0x37, 0x65, 0x00, 0x04, (Byte)pad, (Byte)r, (Byte)g, (Byte)b, 0xF7};
  Byte buf[128]; MIDIPacketList *pl = (MIDIPacketList *)buf; MIDIPacket *pk = MIDIPacketListInit(pl);
  MIDIPacketListAdd(pl, sizeof buf, pk, 0, sizeof m, m); MIDISend(outPort, dest, pl);
}
static void readProc(const MIDIPacketList *pl, void *a, void *b) {
  const MIDIPacket *p = &pl->packet[0];
  for (UInt32 i = 0; i < pl->numPackets; i++, p = MIDIPacketNext(p))
    for (int j = 0; j + 2 < p->length; j++) {
      if (p->data[j] != 0x99 || p->data[j + 2] == 0) continue;
      for (int k = 0; k < 16; k++) if (PAD_NOTES[k] == p->data[j + 1] && count[k] < HITS) {
        vel[k][count[k]++] = p->data[j + 2];
        printf("pad %2d hit %d: %3d\n", k + 1, count[k], p->data[j + 2]); fflush(stdout);
        if (count[k] == HITS) color(k, 0, 90, 0); else color(k, 90, 70, 0);
      }
    }
}
static int cmp(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
static double median(int *v, int n) { int t[HITS]; memcpy(t, v, n * sizeof *v); qsort(t, n, sizeof *t, cmp); return n % 2 ? t[n / 2] : (t[n / 2 - 1] + t[n / 2]) / 2.0; }

int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 90;
  MIDIClientRef c; MIDIPortRef in; MIDIClientCreate(CFSTR("padcal"), 0, 0, &c);
  MIDIInputPortCreate(c, CFSTR("in"), readProc, 0, &in); MIDIOutputPortCreate(c, CFSTR("out"), &outPort);
  for (ItemCount di = 0; di < MIDIGetNumberOfDevices(); di++) {
    MIDIDeviceRef dev = MIDIGetDevice(di);
    for (ItemCount ei = 0; ei < MIDIDeviceGetNumberOfEntities(dev); ei++) {
      MIDIEntityRef e = MIDIDeviceGetEntity(dev, ei); char nm[128]; CFStringRef s;
      for (ItemCount i = 0; i < MIDIEntityGetNumberOfSources(e); i++) {
        s = 0; nm[0] = 0; MIDIObjectGetStringProperty(MIDIEntityGetSource(e, i), kMIDIPropertyDisplayName, &s);
        if (s) { CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); CFRelease(s); }
        if (!strcmp(nm, "MPC Touch Private")) MIDIPortConnectSource(in, MIDIEntityGetSource(e, i), 0);
      }
      for (ItemCount i = 0; i < MIDIEntityGetNumberOfDestinations(e); i++) {
        s = 0; nm[0] = 0; MIDIObjectGetStringProperty(MIDIEntityGetDestination(e, i), kMIDIPropertyDisplayName, &s);
        if (s) { CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); CFRelease(s); }
        if (!strcmp(nm, "MPC Touch Private")) dest = MIDIEntityGetDestination(e, i);
      }
    }
  }
  if (!dest) { fprintf(stderr, "MPC Touch Private port not found\n"); return 1; }
  for (int k = 0; k < 16; k++) color(k, 90, 0, 0);
  printf("Hit every pad %d times with the same normal force (%d s)...\n", HITS, secs); fflush(stdout);
  for (int t = 0; t < secs * 10; t++) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    int done = 1; for (int k = 0; k < 16; k++) done &= count[k] == HITS;
    if (t % 5 == 0)   // keep our colours on the pads (Ableton's script re-sends its own every few seconds)
      for (int k = 0; k < 16; k++) { if (count[k] == HITS) color(k, 0, 90, 0); else if (count[k]) color(k, 90, 70, 0); else color(k, 90, 0, 0); }
    if (done) break;
  }
  double med[16], sorted[16]; int n = 0;
  for (int k = 0; k < 16; k++) { med[k] = count[k] ? median(vel[k], count[k]) : 0; if (count[k]) sorted[n++] = med[k]; }
  if (n < 8) { printf("Only %d pads hit — not saved.\n", n); for (int k = 0; k < 16; k++) color(k, 0, 0, 0); return 1; }
  // target = level of the stronger pads (75th percentile), so only the weak ones get a boost
  for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (sorted[j] < sorted[i]) { double x = sorted[i]; sorted[i] = sorted[j]; sorted[j] = x; }
  double target = sorted[(int)(0.75 * (n - 1))];
  char path[1024]; snprintf(path, sizeof path, "%s/Library/Application Support/MPCTouchFix/padgain.txt", getenv("HOME"));
  FILE *f = fopen(path, "w");
  for (int k = 0; k < 16; k++) {
    double g = med[k] > 0 ? target / med[k] : 1.0;
    if (g < 1.0) g = 1.0;
    if (g > 8.0) g = 8.0;
    fprintf(f, "%.2f%s", g, k % 4 == 3 ? "\n" : " ");
    printf("pad %2d: median %5.1f  boost x%.2f\n", k + 1, med[k], g);
  }
  fclose(f);
  for (int k = 0; k < 16; k++) color(k, 0, 0, 0);
  system("pkill -HUP -x touchmouse");
  printf("Saved %s\n", path);
  return 0;
}
