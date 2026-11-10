// Logs every CoreMIDI message MPC sends (and to which port) to /tmp/mpc-midi-tx.log, with timestamps.
#include <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <sys/time.h>
static FILE *lf;
static double t0;
static double now(void){ struct timeval tv; gettimeofday(&tv,0); return tv.tv_sec + tv.tv_usec/1e6; }
static void name(MIDIEndpointRef e, char *buf, size_t n){ CFStringRef s=0; MIDIObjectGetStringProperty(e,kMIDIPropertyDisplayName,&s); buf[0]=0; if(s){ CFStringGetCString(s,buf,n,kCFStringEncodingUTF8); CFRelease(s);} }
static void logbytes(const char *kind, MIDIEndpointRef d, const Byte *b, size_t len){
  if(!lf){ lf=fopen("/tmp/mpc-midi-tx.log","a"); t0=now(); }
  char nm[128]; name(d,nm,sizeof nm);
  fprintf(lf,"%9.3f %s [%s] len=%zu:",now()-t0,kind,nm,len);
  for(size_t i=0;i<len && i<512;i++) fprintf(lf," %02X",b[i]);
  fprintf(lf,"\n"); fflush(lf);
}
static OSStatus my_MIDISend(MIDIPortRef p, MIDIEndpointRef d, const MIDIPacketList *pl){
  const MIDIPacket *pk=&pl->packet[0];
  for(UInt32 i=0;i<pl->numPackets;i++){ logbytes("SEND",d,pk->data,pk->length); pk=MIDIPacketNext(pk);} 
  return MIDISend(p,d,pl);
}
static OSStatus my_MIDISendSysex(MIDISysexSendRequest *r){ logbytes("SYSX",r->destination,r->data,r->bytesToSend); return MIDISendSysex(r); }
static OSStatus my_MIDISendEventList(MIDIPortRef p, MIDIEndpointRef d, const MIDIEventList *el){
  const MIDIEventPacket *pk=&el->packet[0];
  for(UInt32 i=0;i<el->numPackets;i++){ logbytes("UMP ",d,(const Byte*)pk->words,pk->wordCount*4); pk=MIDIEventPacketNext(pk);} 
  return MIDISendEventList(p,d,el);
}
__attribute__((used)) static struct { const void *rep; const void *orig; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void*)my_MIDISend,(const void*)MIDISend},
  {(const void*)my_MIDISendSysex,(const void*)MIDISendSysex},
  {(const void*)my_MIDISendEventList,(const void*)MIDISendEventList},
};
// --- also log property changes MPC makes on MIDI objects (driver mode switches)
static void logprop(const char *kind, MIDIObjectRef o, CFStringRef key, const char *val){
  if(!lf){ lf=fopen("/tmp/mpc-midi-tx.log","a"); t0=now(); }
  char k[128]={0}, nmb[128]; CFStringGetCString(key,k,sizeof k,kCFStringEncodingUTF8); name(o,nmb,sizeof nmb);
  fprintf(lf,"%9.3f %s [%s] %s = %s\n",now()-t0,kind,nmb,k,val); fflush(lf);
}
static OSStatus my_SetInt(MIDIObjectRef o, CFStringRef k, SInt32 v){ char b[32]; snprintf(b,32,"%d",(int)v); logprop("PROPI",o,k,b); return MIDIObjectSetIntegerProperty(o,k,v); }
static OSStatus my_SetStr(MIDIObjectRef o, CFStringRef k, CFStringRef v){ char b[256]={0}; if(v) CFStringGetCString(v,b,sizeof b,kCFStringEncodingUTF8); logprop("PROPS",o,k,b); return MIDIObjectSetStringProperty(o,k,v); }
static OSStatus my_SetData(MIDIObjectRef o, CFStringRef k, CFDataRef v){ char b[600]={0}; size_t n=v?CFDataGetLength(v):0; const UInt8*p=v?CFDataGetBytePtr(v):0; for(size_t i=0;i<n&&i<190;i++) sprintf(b+3*i,"%02X ",p[i]); logprop("PROPD",o,k,b); return MIDIObjectSetDataProperty(o,k,v); }
static OSStatus my_SetDict(MIDIObjectRef o, CFStringRef k, CFDictionaryRef v){ logprop("PROPX",o,k,"<dict>"); return MIDIObjectSetDictionaryProperty(o,k,v); }
__attribute__((used)) static struct { const void *rep; const void *orig; } propInterposers[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void*)my_SetInt,(const void*)MIDIObjectSetIntegerProperty},
  {(const void*)my_SetStr,(const void*)MIDIObjectSetStringProperty},
  {(const void*)my_SetData,(const void*)MIDIObjectSetDataProperty},
  {(const void*)my_SetDict,(const void*)MIDIObjectSetDictionaryProperty},
};
