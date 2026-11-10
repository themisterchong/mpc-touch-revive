// mpcsend "HEX BYTES" ["HEX BYTES" ...] — sends each message to "MPC Touch Private", prints replies for 1.5 s.
import CoreMIDI
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
func nm(_ o: MIDIObjectRef) -> String { var s: Unmanaged<CFString>?; MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s); return (s?.takeRetainedValue() as String?) ?? "?" }
var client = MIDIClientRef(); MIDIClientCreate("mpcsend" as CFString, nil, nil, &client)
var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { list, src in
  let name = src.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() } ?? "?"
  var p = withUnsafePointer(to: list.pointee.packet) { $0 }
  for _ in 0..<list.pointee.numPackets {
    let bytes = withUnsafeBytes(of: p.pointee.data) { Array($0.prefix(Int(p.pointee.length))) }
    print("  RX [\(name)]", bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
    p = UnsafePointer(MIDIPacketNext(UnsafeMutablePointer(mutating: p)))
  }
}
// Walk device -> entity -> endpoints: private (hidden) endpoints are skipped by MIDIGetSource/MIDIGetDestination
var dest: MIDIEndpointRef = 0
for di in 0..<MIDIGetNumberOfDevices() {
  let dev = MIDIGetDevice(di)
  for ei in 0..<MIDIDeviceGetNumberOfEntities(dev) {
    let ent = MIDIDeviceGetEntity(dev, ei)
    for si in 0..<MIDIEntityGetNumberOfSources(ent) { let s = MIDIEntityGetSource(ent, si); let n = nm(s); if n.contains("MPC") { print("  src:", n); MIDIPortConnectSource(inPort, s, Unmanaged.passRetained(n as NSString).toOpaque()) } }
    for xi in 0..<MIDIEntityGetNumberOfDestinations(ent) { let d = MIDIEntityGetDestination(ent, xi); let n = nm(d); if n.contains("MPC") { print("  dst:", n) }; if n == "MPC Touch Private" { dest = d } }
  }
}
guard dest != 0 else { print("MPC Touch Private port not found (driver offline?)"); exit(1) }
var outPort = MIDIPortRef(); MIDIOutputPortCreate(client, "out" as CFString, &outPort)
for arg in CommandLine.arguments.dropFirst() {
  let bytes = arg.split(separator: " ").compactMap { UInt8($0, radix: 16) }
  print("TX", bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
  var pl = MIDIPacketList(); let pk = MIDIPacketListInit(&pl)
  _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(&pl, 1024, pk, 0, bytes.count, $0.baseAddress!) }
  MIDISend(outPort, dest, &pl)
  RunLoop.main.run(until: Date().addingTimeInterval(0.25))
}
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
