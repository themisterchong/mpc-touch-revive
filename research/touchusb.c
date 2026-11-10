// touchusb [seconds] — reads raw reports from the MPC Touch's SiS touch controller (09e8:8001) via libusb.
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <libusb.h>   // libusb 1.0 (built from source by build.sh, see README)
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
int main(int argc, char **argv){
  double secs = argc>1 ? atof(argv[1]) : 15;
  libusb_context *ctx; if (libusb_init(&ctx)) { printf("init failed\n"); return 1; }
  libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, 0x09e8, 0x8001);
  if (!h) { printf("touch controller not found / can't open (panel off or busy)\n"); return 1; }
  int r = libusb_claim_interface(h, 0); printf("claim interface 0: %s\n", libusb_error_name(r));
  unsigned char d[1024];
  r = libusb_control_transfer(h, 0x81, 6, 0x2200, 0, d, sizeof d, 2000);
  printf("report descriptor (%d):", r); for (int i=0;i<r;i++) printf(" %02X", d[i]); printf("\n");
  printf("reading for %.0f s — touch the screen now\n", secs); fflush(stdout);
  double t0 = now(); int errs = 0;
  while (now()-t0 < secs) {
    unsigned char b[64]; int n = 0;
    r = libusb_interrupt_transfer(h, 0x82, b, sizeof b, &n, 1000);
    if (r == 0 && n > 0) { printf("%.3f", now()-t0); for (int i=0;i<n;i++) printf(" %02X", b[i]); printf("\n"); fflush(stdout); }
    else if (r != LIBUSB_ERROR_TIMEOUT && errs++ < 5) printf("read: %s\n", libusb_error_name(r));
  }
  libusb_release_interface(h, 0); libusb_close(h); libusb_exit(ctx); return 0;
}
