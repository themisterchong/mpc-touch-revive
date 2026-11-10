// touchread [seconds] — opens the MPC Touch's SiS touch controller (09e8:8001), prints its HID report descriptor, then raw input reports.
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
static io_service_t findService(const char *cls, int iface) {
  NSMutableDictionary *m = (__bridge_transfer NSMutableDictionary *)IOServiceMatching(cls);
  m[@"idVendor"] = @0x09e8; m[@"idProduct"] = @0x8001; if (iface >= 0) m[@"bInterfaceNumber"] = @(iface);
  return IOServiceGetMatchingService(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)m);
}
static io_service_t childInterface(io_service_t dev) {
  io_iterator_t it = 0; io_service_t c, found = 0;
  if (IORegistryEntryGetChildIterator(dev, kIOServicePlane, &it) != KERN_SUCCESS) return 0;
  while ((c = IOIteratorNext(it))) { if (!found && IOObjectConformsTo(c, "IOUSBHostInterface")) found = c; else IOObjectRelease(c); }
  IOObjectRelease(it); return found;
}
static void hex(const char *pfx, NSData *d) { const uint8_t *b = d.bytes; printf("%s", pfx); for (NSUInteger i = 0; i < d.length; i++) printf("%02X ", b[i]); printf("\n"); fflush(stdout); }
int main(int argc, char **argv) { @autoreleasepool {
  double secs = argc > 1 ? atof(argv[1]) : 15; NSError *e = nil;
  io_service_t ds = findService("IOUSBHostDevice", -1); if (!ds) { printf("touch controller not on USB (panel off)\n"); return 1; }
  IOUSBHostDevice *dev = [[IOUSBHostDevice alloc] initWithIOService:ds options:IOUSBHostObjectInitOptionsDeviceSeize queue:nil error:&e interestHandler:nil];
  if (!dev) { printf("open device failed: %s\n", e.description.UTF8String); return 1; }
  if (!childInterface(ds) && ![dev configureWithValue:1 matchInterfaces:YES error:&e]) printf("configure: %s\n", e.description.UTF8String);
  io_service_t is = 0; for (int i = 0; i < 100 && !is; i++) { is = childInterface(ds); if (!is) usleep(100000); }
  if (!is) { printf("interface 0 not found\n"); return 1; }
  IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:is options:IOUSBHostObjectInitOptionsDeviceSeize queue:nil error:&e interestHandler:nil];
  if (!intf) { printf("open interface failed: %s\n", e.description.UTF8String); return 1; }
  // HID report descriptor: GET_DESCRIPTOR(Report=0x22), interface 0
  IOUSBDeviceRequest rq = { .bmRequestType = 0x81, .bRequest = 6, .wValue = 0x2200, .wIndex = 0, .wLength = 1024 };
  NSMutableData *desc = [intf ioDataWithCapacity:1024 error:&e]; NSUInteger got = 0;
  if ([intf sendDeviceRequest:rq data:desc bytesTransferred:&got completionTimeout:2 error:&e]) { hex("REPORT_DESCRIPTOR: ", [desc subdataWithRange:NSMakeRange(0, got)]); }
  else printf("report descriptor: %s\n", e.description.UTF8String);
  IOUSBHostPipe *pipe = nil; uint8_t addr = 0;
  for (uint8_t a = 0x81; a <= 0x8F && !pipe; a++) { pipe = [intf copyPipeWithAddress:a error:nil]; if (pipe) addr = a; }
  if (!pipe) { printf("no IN pipe found\n"); return 1; }
  printf("maxPacket=%u attrs=%u interval=%u\n", pipe.descriptors->descriptor.wMaxPacketSize, pipe.descriptors->descriptor.bmAttributes, pipe.descriptors->descriptor.bInterval); printf("reading IN endpoint 0x%02X for %.0f s — touch the screen now\n", addr, secs); fflush(stdout);
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
  while ([end timeIntervalSinceNow] > 0) {
    NSMutableData *buf = [intf ioDataWithCapacity:64 error:&e]; NSUInteger n = 0;
    static int errs = 0;
    if ([pipe sendIORequestWithData:buf bytesTransferred:&n completionTimeout:3 error:&e]) { if (n) { NSData *got = [buf subdataWithRange:NSMakeRange(0, n)]; printf("%.3f ", -[end timeIntervalSinceNow]); hex("", got); } else printf("zero-length read\n"); }
    else if (errs++ < 5) printf("read error: 0x%x %s\n", (unsigned)e.code, e.localizedDescription.UTF8String);
  }
  [intf destroy]; [dev destroy];
}}
