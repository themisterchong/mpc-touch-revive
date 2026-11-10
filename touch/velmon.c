// velmon — logs every pad hit: raw velocity from the Touch and what touchmouse turns it into (padgain + padsens).
#include <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static const int PAD_NOTES[16] = {37, 36, 42, 82, 40, 38, 46, 44, 48, 47, 45, 43, 49, 55, 51, 53};
static double gain[16], sg = 1, sc = 1;
static void readProc(const MIDIPacketList *pl, void *a, void *b) {
  const MIDIPacket *p = &pl->packet[0];
  for (UInt32 i = 0; i < pl->numPackets; i++, p = MIDIPacketNext(p))
    for (int j = 0; j + 2 < p->length; j++) {
      if (p->data[j] != 0x99 || p->data[j + 2] == 0) continue;
      for (int k = 0; k < 16; k++) if (PAD_NOTES[k] == p->data[j + 1]) {
        int raw = p->data[j + 2];
        int v = (int)lround(127.0 * pow(fmin(1.0, raw * gain[k] * sg / 127.0), sc));
        printf("pad %2d raw %3d -> %3d\n", k + 1, raw, v); fflush(stdout);
      }
    }
}
int main(int argc, char **argv) {
  char path[1024]; snprintf(path, sizeof path, "%s/Library/Application Support/MPCTouchFix/padgain.txt", getenv("HOME"));
  FILE *f = fopen(path, "r"); for (int k = 0; k < 16; k++) { gain[k] = 1; if (f) fscanf(f, "%lf", &gain[k]); } if (f) fclose(f);
  snprintf(path, sizeof path, "%s/Library/Application Support/MPCTouchFix/padsens.txt", getenv("HOME"));
  f = fopen(path, "r"); if (f) { fscanf(f, "%lf %lf", &sg, &sc); fclose(f); }
  int secs = argc > 1 ? atoi(argv[1]) : 120;
  MIDIClientRef c; MIDIPortRef in; MIDIClientCreate(CFSTR("velmon"), 0, 0, &c);
  MIDIInputPortCreate(c, CFSTR("in"), readProc, 0, &in);
  for (ItemCount di = 0; di < MIDIGetNumberOfDevices(); di++) {
    MIDIDeviceRef dev = MIDIGetDevice(di);
    for (ItemCount ei = 0; ei < MIDIDeviceGetNumberOfEntities(dev); ei++) {
      MIDIEntityRef e = MIDIDeviceGetEntity(dev, ei);
      for (ItemCount i = 0; i < MIDIEntityGetNumberOfSources(e); i++) {
        CFStringRef s = 0; char nm[128] = ""; MIDIObjectGetStringProperty(MIDIEntityGetSource(e, i), kMIDIPropertyDisplayName, &s);
        if (s) { CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); CFRelease(s); }
        if (!strcmp(nm, "MPC Touch Private")) { MIDIPortConnectSource(in, MIDIEntityGetSource(e, i), 0); printf("listening\n"); fflush(stdout); }
      }
    }
  }
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);
  return 0;
}
