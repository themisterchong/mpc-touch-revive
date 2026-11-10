// Full-screen test pattern on the MPC Touch display: 1-px detail, grey steps, text samples. Tap or Esc closes.
import AppKit
func touchScreen() -> NSScreen? {
  NSScreen.screens.first { s in
    guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
    let id = CGDirectDisplayID(n.uint32Value); return CGDisplayVendorNumber(id) == 0x5109 && CGDisplayModelNumber(id) == 0x1021
  }
}
final class V: NSView {
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with e: NSEvent) { NSApp.terminate(nil) }
  override func keyDown(with e: NSEvent) { NSApp.terminate(nil) }
  func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 13, _ w: NSFont.Weight = .regular, _ c: NSColor = .white) {
    s.draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c])
  }
  override func draw(_ r: NSRect) {
    NSColor.black.setFill(); bounds.fill()
    // 1) 1-px checkerboard + 1-px line gratings (should look like even grey/clean lines if the picture is pixel-exact)
    label("1-px checkerboard", 20, 10); label("1-px vertical lines", 230, 10); label("1-px horizontal lines", 440, 10); label("2-px lines", 650, 10)
    for y in 0..<120 { for x in 0..<180 {
      if (x + y) % 2 == 0 { NSColor.white.setFill(); NSRect(x: 20 + x, y: 32 + y, width: 1, height: 1).fill() }
      if x % 2 == 0 { NSColor.white.setFill(); NSRect(x: 230 + x, y: 32 + y, width: 1, height: 1).fill() }
      if y % 2 == 0 { NSColor.white.setFill(); NSRect(x: 440 + x, y: 32 + y, width: 1, height: 1).fill() }
      if (x / 2) % 2 == 0 { NSColor.white.setFill(); NSRect(x: 650 + x, y: 32 + y, width: 1, height: 1).fill() }
    } }
    // 2) grey steps: full ramp, plus near-black and near-white steps (each box should be distinguishable)
    label("grey ramp 0 → 255 (16 steps)", 20, 165)
    for i in 0..<16 { NSColor(white: CGFloat(i) / 15, alpha: 1).setFill(); NSRect(x: 20 + i * 76, y: 187, width: 76, height: 50).fill() }
    label("near-black: 0, 4, 8, 12 … 44  (should all differ)", 20, 245)
    for i in 0..<12 { NSColor(white: CGFloat(i * 4) / 255, alpha: 1).setFill(); NSRect(x: 20 + i * 100, y: 267, width: 100, height: 45).fill()
      label("\(i * 4)", 24 + CGFloat(i * 100), 270, 11, .regular, NSColor(white: 0.5, alpha: 1)) }
    label("near-white: 211 … 255  (should all differ)", 20, 320)
    for i in 0..<12 { NSColor(white: CGFloat(211 + i * 4) / 255, alpha: 1).setFill(); NSRect(x: 20 + i * 100, y: 342, width: 100, height: 45).fill()
      label("\(211 + i * 4)", 24 + CGFloat(i * 100), 345, 11, .regular, NSColor(white: 0.4, alpha: 1)) }
    // 3) text samples
    var y: CGFloat = 405
    for (size, w) in [(11, NSFont.Weight.regular), (13, .regular), (13, .medium), (15, .regular), (18, .regular), (24, .semibold)] as [(CGFloat, NSFont.Weight)] {
      label("\(Int(size))pt  The quick brown fox jumps over the lazy dog — Kick 01.wav  Snare_Tight 120bpm  0123456789", 20, y, size, w); y += size + 14
    }
    NSColor.white.setFill(); NSRect(x: 0, y: 620, width: bounds.width, height: 180).fill()
    y = 632
    for (size, w) in [(11, NSFont.Weight.regular), (13, .regular), (15, .regular), (18, .medium)] as [(CGFloat, NSFont.Weight)] {
      label("\(Int(size))pt  Dark text on white — Splice: Drums / Hats / Lo-fi Loops 90 BPM  0123456789", 20, y, size, w, .black); y += size + 16
    }
    label("Tap anywhere or press any key to close", 20, 770, 12, .regular, .darkGray)
  }
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
guard let s = touchScreen() else { print("MPC Touch display not found"); exit(1) }
let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: s)
w.level = .screenSaver; w.setFrame(s.frame, display: true)
let v = V(frame: NSRect(origin: .zero, size: s.frame.size)); w.contentView = v
w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v); app.activate(ignoringOtherApps: true); app.run()
