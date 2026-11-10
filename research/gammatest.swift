// Applies a highlight-compressing transfer curve to the MPC Touch display for N seconds, then restores.
import CoreGraphics
import Foundation
let secs = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let top = Float(CommandLine.arguments.dropFirst(2).first ?? "0.86") ?? 0.86   // output level for full white
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0; CGGetOnlineDisplayList(16, &ids, &n)
guard let id = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == 0x5109 && CGDisplayModelNumber($0) == 0x1021 }) else { print("no MPC Touch display"); exit(1) }
// linear up to 0.6, then a soft knee into `top`, so near-white steps stay distinct
let size = 256; var t = [CGGammaValue](repeating: 0, count: size)
for i in 0..<size { let x = Float(i) / Float(size - 1); let knee: Float = 0.6
  t[i] = x <= knee ? x * (top / 1.0 + (1 - top) * 0.0) : knee * 1 + (top - knee) * (1 - pow(1 - (x - knee) / (1 - knee), 1.6)) }
let err = CGSetDisplayTransferByTable(id, UInt32(size), t, t, t)
print(err == .success ? "curve applied (white -> \(top)) for \(Int(secs)) s" : "failed: \(err.rawValue)")
Thread.sleep(forTimeInterval: secs); CGDisplayRestoreColorSyncSettings(); print("restored")
