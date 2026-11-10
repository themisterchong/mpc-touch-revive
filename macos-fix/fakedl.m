// Redirects MPC's lookups of /Library/Extensions/DisplayLinkDriver.kext to a copy of Akai's bundled DisplayLink 5.2.5 kext (read-only, nothing installed).
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <stdlib.h>
static const char *REAL = "/Library/Extensions/DisplayLinkDriver.kext";
// Redirect target: $MPCTOUCH_DLKEXT if set, else ~/Library/Application Support/MPCTouchFix/DisplayLinkDriver.kext
// (worked out on first use).
static char FAKE[PATH_MAX];
static void initFake(void) {
  const char *e = getenv("MPCTOUCH_DLKEXT"), *h = getenv("HOME");
  if (e && *e) snprintf(FAKE, sizeof FAKE, "%s", e);
  else if (h && *h) snprintf(FAKE, sizeof FAKE, "%s/Library/Application Support/MPCTouchFix/DisplayLinkDriver.kext", h);
}
static const char *map(const char *p, char *buf) {
  size_t n = strlen(REAL);
  if (!FAKE[0]) initFake();
  if (p && FAKE[0] && !strncmp(p, REAL, n)) { snprintf(buf, PATH_MAX, "%s%s", FAKE, p + n); fprintf(stderr, "[fakedl] %s -> fake\n", p); return buf; }
  return p;
}
static int my_open(const char *p, int f, ...) { va_list a; va_start(a, f); int m = va_arg(a, int); va_end(a); char b[PATH_MAX]; return open(map(p, b), f, m); }
static int my_stat(const char *p, struct stat *s) { char b[PATH_MAX]; return stat(map(p, b), s); }
static int my_lstat(const char *p, struct stat *s) { char b[PATH_MAX]; return lstat(map(p, b), s); }
static int my_access(const char *p, int m) { char b[PATH_MAX]; return access(map(p, b), m); }
__attribute__((used)) static struct { const void *rep; const void *orig; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void *)my_open, (const void *)open }, { (const void *)my_stat, (const void *)stat },
  { (const void *)my_lstat, (const void *)lstat }, { (const void *)my_access, (const void *)access },
};
__attribute__((constructor)) static void hello(void) { fprintf(stderr, "[fakedl] loaded\n"); }

// --- MPC Touch screen: MPC only puts its touch UI on the MPC Touch display if that display has a mode
// flagged as native (kDisplayModeNativeFlag). The old DisplayLink kext driver set it; DisplayLink Manager's
// virtual display doesn't. Mark the 1280x800 mode of the MPC Touch display (EDID vendor 0x5109, model 0x1021) as native.
#include <CoreGraphics/CoreGraphics.h>
#define MPC_TOUCH_VENDOR 0x5109
#define MPC_TOUCH_MODEL  0x1021
#define NATIVE_FLAG      0x02000000
static CGDisplayModeRef touchModes[16];
static int touchModeCount;
static CFArrayRef my_CopyAllDisplayModes(CGDirectDisplayID d, CFDictionaryRef o) {
  CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, o);
  if (modes && CGDisplayVendorNumber(d) == MPC_TOUCH_VENDOR && CGDisplayModelNumber(d) == MPC_TOUCH_MODEL) {
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
      CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
      if (CGDisplayModeGetWidth(m) == 1280 && CGDisplayModeGetHeight(m) == 800 && touchModeCount < 16) touchModes[touchModeCount++] = m;
    }
  }
  return modes;
}
static uint32_t my_ModeGetIOFlags(CGDisplayModeRef m) {
  uint32_t f = CGDisplayModeGetIOFlags(m);
  for (int i = 0; i < touchModeCount; i++) if (touchModes[i] == m) { fprintf(stderr, "[fakedl] MPC Touch display mode marked native\n"); return f | NATIVE_FLAG; }
  return f;
}
__attribute__((used)) static struct { const void *rep; const void *orig; } displayInterposers[] __attribute__((section("__DATA,__interpose"))) = {
  { (const void *)my_CopyAllDisplayModes, (const void *)CGDisplayCopyAllDisplayModes },
  { (const void *)my_ModeGetIOFlags, (const void *)CGDisplayModeGetIOFlags },
};
