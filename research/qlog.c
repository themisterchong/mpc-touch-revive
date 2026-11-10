// qlog <secs>: log Q-link (CC16-19) and jog (CC100) ticks from "MPC Touch Live" with timestamps
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static mach_timebase_info_data_t tb; static uint64_t t0;
static void rd(const MIDIPacketList *pl, void *a, void *b) {
  const MIDIPacket *p = &pl->packet[0];
  for (UInt32 i = 0; i < pl->numPackets; i++, p = MIDIPacketNext(p)) {
    uint64_t ts = p->timeStamp ? p->timeStamp : mach_absolute_time();
    double ms = (double)(ts - t0) * tb.numer / tb.denom / 1e6;
    for (int j = 0; j + 2 < p->length + 0; j += 3)
      if ((p->data[j] & 0xF0) == 0xB0 && ((p->data[j+1] >= 16 && p->data[j+1] <= 19) || p->data[j+1] == 100)) {
        int v = p->data[j+2]; printf("%.1f cc%d %d\n", ms, p->data[j+1], v >= 64 ? v - 128 : v); }
  }
  fflush(stdout);
}
int main(int c, char **v) {
  mach_timebase_info(&tb); t0 = mach_absolute_time();
  MIDIClientRef cl; MIDIClientCreate(CFSTR("qlog"), NULL, NULL, &cl);
  MIDIPortRef in; MIDIInputPortCreate(cl, CFSTR("in"), rd, NULL, &in);
  for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
    MIDIEndpointRef s = MIDIGetSource(i); CFStringRef n; char b[128];
    MIDIObjectGetStringProperty(s, kMIDIPropertyDisplayName, &n); CFStringGetCString(n, b, 128, kCFStringEncodingUTF8);
    if (strstr(b, "MPC Touch Live")) { MIDIPortConnectSource(in, s, NULL); fprintf(stderr, "listening to %s\n", b); }
  }
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, c > 1 ? atof(v[1]) : 30, false);
}
