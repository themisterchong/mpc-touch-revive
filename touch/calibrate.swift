// MPC Touch Calibrate — shows 9 crosshairs full-screen on the MPC Touch display. Tap each one;
// fits an affine correction (display-local pixels) and writes it to calibration.txt, then tells touchmouse (SIGHUP).
import AppKit

let fixDir = NSHomeDirectory() + "/Library/Application Support/MPCTouchFix"
let calPath = fixDir + "/calibration.txt", backupPath = fixDir + "/calibration.previous.txt"
func reloadTouchmouse() { let p = Process(); p.launchPath = "/usr/bin/pkill"; p.arguments = ["-HUP", "-x", "touchmouse"]; try? p.run(); p.waitUntilExit() }

func touchScreen() -> (NSScreen, CGRect)? {
  for s in NSScreen.screens {
    guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
    let id = CGDirectDisplayID(n.uint32Value)
    if CGDisplayVendorNumber(id) == 0x5109 && CGDisplayModelNumber(id) == 0x1021 { return (s, CGDisplayBounds(id)) }
  }
  return nil
}

// Least-squares fit of target = sum(coef_i * term_i(measured)); returns nil if singular
func lsq(_ rows: [[Double]], _ vals: [Double]) -> [Double]? {
  let k = rows[0].count; var a = [[Double]](repeating: [Double](repeating: 0, count: k + 1), count: k)
  for (r, v) in zip(rows, vals) { for i in 0..<k { for j in 0..<k { a[i][j] += r[i] * r[j] }; a[i][k] += r[i] * v } }
  for c in 0..<k {
    guard let piv = (c..<k).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-12 else { return nil }
    a.swapAt(c, piv); let d = a[c][c]; for j in 0...k { a[c][j] /= d }
    for i in 0..<k where i != c { let f = a[i][c]; for j in 0...k { a[i][j] -= f * a[c][j] } }
  }
  return (0..<k).map { a[$0][k] }
}
// Quadratic fit in normalized coords: u,v = measured / size (= raw/4095 under the default mapping), outputs 0..1
func quadTerms(_ u: Double, _ v: Double) -> [Double] { [1, u, v, u * v, u * u, v * v] }

// Least-squares affine fit: measured (display-local) -> target
func fitAffine(_ m: [CGPoint], _ t: [CGPoint]) -> [Double]? {
  func solve(_ vals: [Double]) -> [Double]? {
    var a = [[Double]](repeating: [0, 0, 0, 0], count: 3)
    for (p, v) in zip(m, vals) { let r = [Double(p.x), Double(p.y), 1]; for i in 0..<3 { for j in 0..<3 { a[i][j] += r[i] * r[j] }; a[i][3] += r[i] * v } }
    for c in 0..<3 {                                           // Gauss-Jordan
      guard let piv = (c..<3).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-9 else { return nil }
      a.swapAt(c, piv); let d = a[c][c]; for j in 0..<4 { a[c][j] /= d }
      for i in 0..<3 where i != c { let f = a[i][c]; for j in 0..<4 { a[i][j] -= f * a[c][j] } }
    }
    return [a[0][3], a[1][3], a[2][3]]
  }
  guard let x = solve(t.map { Double($0.x) }), let y = solve(t.map { Double($0.y) }) else { return nil }
  return x + y
}

final class CalView: NSView {
  var targets: [CGPoint] = []; var measured: [CGPoint] = []; var idx = 0; var bounds0 = CGRect.zero; var message = ""
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  override func draw(_ r: NSRect) {
    NSColor.black.setFill(); bounds.fill()
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 22, weight: .medium)]
    let text = message.isEmpty ? "Tap the centre of the cross precisely (\(idx + 1) of \(targets.count)) — Backspace undoes, Esc cancels" : message
    let sz = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: bounds.height / 2 - sz.height / 2 + (targets.indices.contains(idx) && abs(targets[idx].y - bounds.height / 2) < 50 && abs(targets[idx].x - bounds.width / 2) < 300 ? 70 : 0)), withAttributes: attrs)
    guard message.isEmpty, idx < targets.count else { return }
    let p = targets[idx]; NSColor.systemOrange.setStroke()
    let path = NSBezierPath(); path.lineWidth = 2
    path.move(to: NSPoint(x: p.x - 30, y: p.y)); path.line(to: NSPoint(x: p.x + 30, y: p.y))
    path.move(to: NSPoint(x: p.x, y: p.y - 30)); path.line(to: NSPoint(x: p.x, y: p.y + 30)); path.stroke()
    NSBezierPath(ovalIn: NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)).stroke()
  }
  override func mouseDown(with e: NSEvent) {
    guard message.isEmpty, idx < targets.count, let loc = e.cgEvent?.location else { return }
    measured.append(CGPoint(x: loc.x - bounds0.origin.x, y: loc.y - bounds0.origin.y)); idx += 1
    if idx == targets.count { finish() } else { needsDisplay = true }
  }
  override func keyDown(with e: NSEvent) {
    if e.keyCode == 53 { cancel() }
    else if e.keyCode == 51, idx > 0, message.isEmpty { idx -= 1; measured.removeLast(); needsDisplay = true }   // Backspace = undo last tap
  }
  func finish() {
    let W = Double(bounds0.width - 1), H = Double(bounds0.height - 1)
    var rows = measured.map { quadTerms(Double($0.x) / W, Double($0.y) / H) }, tg = targets, dropped = 0
    func fit() -> ([Double], [Double], [Double])? {
      guard let qx = lsq(rows, tg.map { Double($0.x) / W }), let qy = lsq(rows, tg.map { Double($0.y) / H }) else { return nil }
      let e = zip(rows, tg).map { r, t in hypot(zip(qx, r).map(*).reduce(0, +) * W - Double(t.x), zip(qy, r).map(*).reduce(0, +) * H - Double(t.y)) }
      return (qx, qy, e)
    }
    guard var (qx, qy, err) = fit() else { message = "Calibration failed — try again"; needsDisplay = true; return }
    // drop mis-taps: points far worse than the rest (max 4), refitting each time
    while dropped < 4, rows.count > 12 {
      let med = err.sorted()[err.count / 2], (worst, i) = err.enumerated().map { ($0.element, $0.offset) }.max { $0.0 < $1.0 }!
      guard worst > max(3 * med, 12) else { break }
      rows.remove(at: i); tg.remove(at: i); dropped += 1
      guard let r = fit() else { break }; (qx, qy, err) = r
    }
    let line = "quad " + (qx + qy).map { String(format: "%.8f", $0) }.joined(separator: " ") + "\n"
    try? line.write(toFile: calPath, atomically: true, encoding: .utf8); reloadTouchmouse()
    let before = zip(measured, targets).map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / Double(targets.count)
    message = String(format: "Calibrated ✓  average error %.1f px → %.1f px", before, err.reduce(0, +) / Double(err.count)) + (dropped > 0 ? "  (\(dropped) mis-tap\(dropped == 1 ? "" : "s") ignored)" : "")
    needsDisplay = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
  }
  func cancel() {
    if FileManager.default.fileExists(atPath: backupPath) { try? FileManager.default.removeItem(atPath: calPath); try? FileManager.default.moveItem(atPath: backupPath, toPath: calPath) }
    reloadTouchmouse(); NSApp.terminate(nil)
  }
}

let app = NSApplication.shared; app.setActivationPolicy(.regular)
guard let (screen, cgBounds) = touchScreen() else { print("MPC Touch display not found"); exit(1) }
// start from the uncalibrated mapping (keep the old one in case of cancel)
try? FileManager.default.removeItem(atPath: backupPath)
if FileManager.default.fileExists(atPath: calPath) { try? FileManager.default.moveItem(atPath: calPath, toPath: backupPath) }
reloadTouchmouse()
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.level = .screenSaver; win.setFrame(screen.frame, display: true)
let v = CalView(frame: NSRect(origin: .zero, size: screen.frame.size)); v.bounds0 = cgBounds
let w = cgBounds.width, h = cgBounds.height
for fy in [0.07, 0.285, 0.5, 0.715, 0.93] { for fx in [0.05, 0.275, 0.5, 0.725, 0.95] { v.targets.append(CGPoint(x: w * fx, y: h * fy)) } }
win.contentView = v; win.makeKeyAndOrderFront(nil); win.makeFirstResponder(v); app.activate(ignoringOtherApps: true)
app.run()
