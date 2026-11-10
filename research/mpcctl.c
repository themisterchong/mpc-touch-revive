// mpcctl <seconds> <hex msg>... : talks to the MPC Touch's hidden "Private" MIDI port.
// Sends each message, then repeats the LAST message every 4 s (keep-alive) until <seconds> elapse. Prints all replies as hex.
#include <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
static double t0; static double now(void){ struct timeval tv; gettimeofday(&tv,0); return tv.tv_sec+tv.tv_usec/1e6; }
static void nm(MIDIObjectRef o, char *b, size_t n){ CFStringRef s=0; MIDIObjectGetStringProperty(o,kMIDIPropertyDisplayName,&s); b[0]=0; if(s){CFStringGetCString(s,b,n,kCFStringEncodingUTF8); CFRelease(s);} }
static void readProc(const MIDIPacketList *pl, void *ref, void *src){
  const MIDIPacket *p=&pl->packet[0];
  for(UInt32 i=0;i<pl->numPackets;i++){ printf("%7.3f RX [%s]", now()-t0, (char*)src); for(int j=0;j<p->length;j++) printf(" %02X",p->data[j]); printf("\n"); fflush(stdout); p=MIDIPacketNext(p); }
}
static int parse(const char *s, Byte *out){ int n=0; while(*s){ while(*s==' ') s++; if(!*s) break; out[n++]=(Byte)strtol(s,(char**)&s,16); } return n; }
static void sendMsg(MIDIPortRef op, MIDIEndpointRef d, const char *hex){
  Byte b[512]; int n=parse(hex,b); Byte buf[1024]; MIDIPacketList *pl=(MIDIPacketList*)buf; MIDIPacket *pk=MIDIPacketListInit(pl);
  MIDIPacketListAdd(pl,sizeof buf,pk,0,n,b); MIDISend(op,d,pl); printf("%7.3f TX %s\n", now()-t0, hex); fflush(stdout);
}
int main(int argc, char **argv){
  if(argc<3){ fprintf(stderr,"usage: mpcctl seconds hex...\n"); return 2; }
  t0=now(); double secs=atof(argv[1]); MIDIClientRef c; MIDIClientCreate(CFSTR("mpcctl"),0,0,&c);
  MIDIPortRef ip, op; MIDIInputPortCreate(c,CFSTR("in"),readProc,0,&ip); MIDIOutputPortCreate(c,CFSTR("out"),&op);
  MIDIEndpointRef dest=0;
  for(ItemCount di=0;di<MIDIGetNumberOfDevices();di++){ MIDIDeviceRef dev=MIDIGetDevice(di);
    for(ItemCount ei=0;ei<MIDIDeviceGetNumberOfEntities(dev);ei++){ MIDIEntityRef e=MIDIDeviceGetEntity(dev,ei); char b[128];
      for(ItemCount s=0;s<MIDIEntityGetNumberOfSources(e);s++){ MIDIEndpointRef ep=MIDIEntityGetSource(e,s); nm(ep,b,sizeof b); if(strstr(b,"MPC Touch")) MIDIPortConnectSource(ip,ep,strdup(b)); }
      for(ItemCount s=0;s<MIDIEntityGetNumberOfDestinations(e);s++){ MIDIEndpointRef ep=MIDIEntityGetDestination(e,s); nm(ep,b,sizeof b); if(!strcmp(b,"MPC Touch Private")) dest=ep; } } }
  if(!dest){ printf("MPC Touch Private not found\n"); return 1; }
  for(int i=2;i<argc;i++){ sendMsg(op,dest,argv[i]); CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.25,false); }
  double next=now()+4;
  while(now()-t0<secs){ CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false); if(now()>=next){ sendMsg(op,dest,argv[argc-1]); next+=4; } }
  return 0;
}
