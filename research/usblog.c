// Logs MPC's libusb traffic (touch panel) to /tmp/mpc-usb.log: claims, resets, every submitted transfer and its completion data.
#include <stdio.h>
#include <stdint.h>
#include <sys/time.h>
#include <pthread.h>
typedef struct libusb_device_handle libusb_device_handle;
struct libusb_transfer;
typedef void (*cb_fn)(struct libusb_transfer *);
struct libusb_transfer { libusb_device_handle *dev_handle; uint8_t flags; unsigned char endpoint; unsigned char type; unsigned int timeout;
  int status; int length; int actual_length; cb_fn callback; void *user_data; unsigned char *buffer; int num_iso_packets; };
int libusb_submit_transfer(struct libusb_transfer *t);
int libusb_claim_interface(libusb_device_handle *h, int i);
int libusb_reset_device(libusb_device_handle *h);
static FILE *lf; static double t0; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static double now(void){ struct timeval tv; gettimeofday(&tv,0); return tv.tv_sec + tv.tv_usec/1e6; }
static void L(const char *fmt, const unsigned char *b, int n, ...);
#include <stdarg.h>
static void L(const char *fmt, const unsigned char *b, int n, ...){
  pthread_mutex_lock(&mu); if(!lf){ lf=fopen("/tmp/mpc-usb.log","a"); t0=now(); }
  fprintf(lf,"%9.3f ",now()-t0); va_list a; va_start(a,n); vfprintf(lf,fmt,a); va_end(a);
  for(int i=0;i<n && i<256;i++) fprintf(lf," %02X",b[i]); fprintf(lf,"\n"); fflush(lf); pthread_mutex_unlock(&mu);
}
#define SLOTS 256
static struct { struct libusb_transfer *t; cb_fn orig; } tab[SLOTS];
static void my_cb(struct libusb_transfer *t){
  cb_fn orig = 0;
  for(int i=0;i<SLOTS;i++) if(tab[i].t==t){ orig=tab[i].orig; break; }
  const unsigned char *data = t->buffer; int n = t->actual_length;
  if(t->type==0){ data = t->buffer+8; }
  if((t->endpoint & 0x80) || t->type==0) L("DONE ep=%02X type=%d status=%d len=%d:", data, n, t->endpoint, t->type, t->status, n);
  else L("DONE ep=%02X type=%d status=%d len=%d", 0, 0, t->endpoint, t->type, t->status, n);
  if(orig) orig(t);
}
static int my_submit(struct libusb_transfer *t){
  if(t->type==0) L("SUBMIT CONTROL setup+data:", t->buffer, t->length);
  else if(!(t->endpoint & 0x80)) L("SUBMIT OUT ep=%02X type=%d:", t->buffer, t->length, t->endpoint, t->type);
  else L("SUBMIT IN ep=%02X type=%d len=%d", 0, 0, t->endpoint, t->type, t->length);
  if(t->callback != my_cb){
    int slot=-1; for(int i=0;i<SLOTS;i++){ if(tab[i].t==t){ slot=i; break; } if(slot<0 && !tab[i].t) slot=i; }
    if(slot>=0){ tab[slot].t=t; tab[slot].orig=t->callback; t->callback=my_cb; }
  }
  return libusb_submit_transfer(t);
}
static int my_claim(libusb_device_handle *h, int i){ int r=libusb_claim_interface(h,i); L("CLAIM interface %d -> %d", 0, 0, i, r); return r; }
static int my_reset(libusb_device_handle *h){ int r=libusb_reset_device(h); L("RESET DEVICE -> %d", 0, 0, r); return r; }
__attribute__((used)) static struct { const void *rep; const void *orig; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void*)my_submit,(const void*)libusb_submit_transfer},
  {(const void*)my_claim,(const void*)libusb_claim_interface},
  {(const void*)my_reset,(const void*)libusb_reset_device},
};
// --- PACE-protected code may resolve libusb functions at runtime via dlsym: hand out our wrappers there too
#include <dlfcn.h>
#include <string.h>
static void *my_dlsym(void *h, const char *n){
  void *r = dlsym(h, n);
  if(n && !strncmp(n,"libusb",6)) L("DLSYM %s", 0, 0, n);
  if(n && !strcmp(n,"libusb_submit_transfer")) return (void*)my_submit;
  if(n && !strcmp(n,"libusb_claim_interface")) return (void*)my_claim;
  if(n && !strcmp(n,"libusb_reset_device")) return (void*)my_reset;
  return r;
}
__attribute__((used)) static struct { const void *rep; const void *orig; } dlInterposers[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void*)my_dlsym,(const void*)dlsym},
};
__attribute__((constructor)) static void hello(void){ L("usblog loaded", 0, 0); }
