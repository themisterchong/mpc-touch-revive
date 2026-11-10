// Prints the MPC Touch state for the launcher:
//   absent  - no MPC Touch on USB
//   online  - Akai MIDI driver has the device (Akai driver setting active)
//   offline - device on USB but Akai MIDI driver can't reach it (setting must be loaded)
import CoreMIDI
import IOKit
func s(_ o: MIDIObjectRef, _ k: CFString) -> String { var n: Unmanaged<CFString>?; MIDIObjectGetStringProperty(o, k, &n); return (n?.takeRetainedValue() as String?) ?? "" }
let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
match["idVendor"] = 0x09e8; match["idProduct"] = 0x0037
var it: io_iterator_t = 0
IOServiceGetMatchingServices(0, match, &it)
let onUSB = IOIteratorNext(it) != 0
if !onUSB { print("absent"); exit(0) }
var online = false
for i in 0..<MIDIGetNumberOfDevices() {
  let d = MIDIGetDevice(i); var off: Int32 = 1
  MIDIObjectGetIntegerProperty(d, kMIDIPropertyOffline, &off)
  if s(d, kMIDIPropertyDriverOwner).contains("akaiprofessional") && off == 0 { online = true }
}
print(online ? "online" : "offline")
