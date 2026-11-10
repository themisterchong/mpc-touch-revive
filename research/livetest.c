// livetest <seconds> [hex...]: prints what arrives on the virtual "MPC Touch Live" source, sends hex to its destination
#include <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void rd(const MIDIPacketList *pl, void *a, void *b){ const MIDIPacket *p=&pl->packet[0];
  for(UInt32 i=0;i<pl->numPackets;i++,p=MIDIPacketNext(p)){ printf("IN"); for(int j=0;j<p->length;j++) printf(" %02X",p->data[j]); printf("\n"); fflush(stdout);} }
static int named(MIDIObjectRef o){ CFStringRef s=0; char b[128]={0}; MIDIObjectGetStringProperty(o,kMIDIPropertyDisplayName,&s); if(s){CFStringGetCString(s,b,128,kCFStringEncodingUTF8);CFRelease(s);} return !strcmp(b,"MPC Touch Live"); }
int main(int c,char**v){ MIDIClientRef cl; MIDIPortRef ip,op; MIDIClientCreate(CFSTR("livetest"),0,0,&cl); MIDIInputPortCreate(cl,CFSTR("i"),rd,0,&ip); MIDIOutputPortCreate(cl,CFSTR("o"),&op);
  MIDIEndpointRef d=0; for(ItemCount i=0;i<MIDIGetNumberOfSources();i++) if(named(MIDIGetSource(i))) MIDIPortConnectSource(ip,MIDIGetSource(i),0);
  for(ItemCount i=0;i<MIDIGetNumberOfDestinations();i++) if(named(MIDIGetDestination(i))) d=MIDIGetDestination(i);
  printf("dest %s\n", d?"found":"MISSING");
  for(int a=2;a<c;a++){ Byte b[256]; int n=0; const char*s=v[a]; while(*s){ while(*s==' ')s++; if(!*s)break; b[n++]=strtol(s,(char**)&s,16);} Byte buf[512]; MIDIPacketList*pl=(MIDIPacketList*)buf; MIDIPacket*pk=MIDIPacketListInit(pl); MIDIPacketListAdd(pl,512,pk,0,n,b); MIDISend(op,d,pl); }
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,atof(v[1]),false); return 0; }
