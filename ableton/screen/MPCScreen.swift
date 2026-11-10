// MPCScreen — Ableton-style touch screen for the MPC Touch display.
// Shows what's selected in Live (via the MPC_Touch Remote Script, UDP localhost 9100/9101) and lets you edit it with a finger:
//   SAMPLE  : waveform of the Simpler sample, drag slice markers, tap a slice to hear it, slice by transient/beat/16/8
//   SESSION : 8x8 clip grid, tap to launch, scene launch column
//   DEVICE  : 16 knobs of the selected device, drag up/down
// Touches arrive as mouse events from touchmouse (which sends them immediately, no iPad-scroll delay, over this app).
import Cocoa
import AVFoundation
import Accelerate
import CoreMIDI

// MARK: - look (Ableton dark)
func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
enum Theme {
    // the mockup's colours
    // (brightened 2026-10-08: a step lighter, same hue; MPC / Push keep the info bright)
    // MPC-2 style: calm charcoal, one colour per page in the header
    static let bg = hex(0x26282a)
    static let panel = hex(0x2d3033)
    static let panel2 = hex(0x33363a)
    static let slot = hex(0x4a4e52)
    static let active = hex(0xeef0f1)
    static let strip = hex(0x151617)                        // the status strip on top
    static let well = hex(0x1b3c48)                         // content well: waveform, graphs
    static let fbar = hex(0x18191b)                         // the F-key bar at the bottom
    static let fkey = hex(0x36393c)
    static let white = hex(0xf4f4f6)
    static let arrBg = hex(0x1d1c1f)
    static let arrLane = hex(0x1f2a31)                       // (MPC-2: the arrangement's lanes are a dark slate well)
    static let value = hex(0x86e2b6)
    static let line = hex(0x41454a)
    static let text = hex(0xeceef0)
    static let dim = hex(0xaab0b5)
    static let faint = hex(0x80868b)
    static let hint = hex(0xc9ced2)
    static let darkInk = hex(0x141316)
    // black-ish or white text, whichever reads better on this colour
    static func ink(_ c: NSColor) -> NSColor {
        guard let s = c.usingColorSpace(.sRGB) else { return darkInk }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
        return l > 0.18 ? darkInk : .white
    }
    static let accent = hex(0xf0a33a)                       // the Q-Link focus (orange outline + Q tag)
    static let wave = hex(0x3fe0f5)
    static let play = hex(0x4fc48a)
    static let red = hex(0xe0605a)
    // MPC-2 look (2026-10-09): Barlow, NEVER bold. Small + strong (buttons, chips) = Barlow Semi Condensed Medium,
    // small labels = Semi Condensed Regular, names = Barlow Regular, big values (≥ 26 px) = Barlow Light.
    static let fontReady: Bool = {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fonts")
        var ok = false
        for n in ["Barlow-Light", "Barlow-Regular", "Barlow-Medium", "BarlowSemiCondensed-Regular", "BarlowSemiCondensed-Medium"] {
            if CTFontManagerRegisterFontsForURL(dir.appendingPathComponent(n + ".ttf") as CFURL, .process, nil) { ok = true }
        }
        return ok || NSFont(name: "Barlow-Regular", size: 12) != nil
    }()
    static var fontCache: [String: NSFont] = [:]
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        let strong = weight == .bold || weight == .heavy || weight == .black || weight == .semibold
        let light = weight == .light || weight == .thin || weight == .ultraLight
        let name = light || size >= 26 ? "Barlow-Light"
            : (strong && size <= 17 ? "BarlowSemiCondensed-Medium" : (size <= 13 ? "BarlowSemiCondensed-Regular" : "Barlow-Regular"))
        let key = "\(size)-\(name)"
        if let f = fontCache[key] { return f }
        let f = (fontReady ? NSFont(name: name, size: size) : nil) ?? NSFont.systemFont(ofSize: size, weight: light ? .light : .regular)
        fontCache[key] = f
        return f
    }
    // Every Ableton colour snaps to the nearest of the mockup's 10 bright colours
    static let paletteHex = [0xd9605a, 0xd98a45, 0xd9b44a, 0x9ccf4a, 0x4fc48a, 0x3fb8cc, 0x5a8fd9, 0x9a7ad6, 0xc46ad6, 0xd9668f]   // MPC-ish, softer
    static let palette: [(hue: CGFloat, color: NSColor)] = paletteHex.map { v in
        let c = hex(v); var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)!.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return (h, c)
    }
    static func live(_ c: Int?) -> NSColor {
        let v = c ?? 0x404040
        let raw = NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        guard c != nil else { return raw }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        raw.usingColorSpace(.sRGB)!.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        if sat < 0.12 { return hex(0xd9d9de) }                                    // greys → light grey
        func d(_ x: CGFloat) -> CGFloat { let e = abs(x - h); return min(e, 1 - e) }
        return palette.min { d($0.hue) < d($1.hue) }!.color
    }
    // a deep, saturated version of a colour for backgrounds (instead of mixing it into grey = mud)
    static func deep(_ c: NSColor, _ level: CGFloat = 0.3) -> NSColor {
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)!.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, sat * 0.9), brightness: level, alpha: 1)
    }
}

// Text exactly as the mockup sets it: Space Grotesk at the given px size and weight (500 medium, 600 semibold, 700 bold,
// .regular = 400), optional letter-spacing in em. p = top-left of the line box (like a CSS block).
func fontWeight(_ w: NSFont.Weight) -> NSFont.Weight { w }
func lineH(_ size: CGFloat) -> CGFloat { let f = Theme.font(size, .bold); return ceil(f.ascender - f.descender + f.leading) }
func drawText(_ s: String, _ p: NSPoint, size: CGFloat = 18, color: NSColor = Theme.text, weight: NSFont.Weight = .medium, center: Bool = false,
              width: CGFloat = 0, tracking: CGFloat = 0, right: Bool = false) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
    if center { style.alignment = .center } else if right { style.alignment = .right }
    var attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(size, weight), .foregroundColor: color, .paragraphStyle: style]
    if tracking != 0 { attrs[.kern] = size * tracking }
    if width > 0 { (s as NSString).draw(in: NSRect(x: p.x, y: p.y, width: width, height: lineH(size) + 2), withAttributes: attrs) }
    else { (s as NSString).draw(at: p, withAttributes: attrs) }
}
// text centred vertically in a rect (CSS align-items: center)
func drawTextV(_ s: String, _ r: NSRect, x: CGFloat? = nil, size: CGFloat, color: NSColor = Theme.text, weight: NSFont.Weight = .bold,
               center: Bool = false, tracking: CGFloat = 0) {
    let x0 = x ?? r.minX
    drawText(s, NSPoint(x: x0, y: r.midY - lineH(size) / 2), size: size, color: color, weight: weight, center: center,
             width: center ? r.width : max(1, r.maxX - x0), tracking: tracking)
}
func textW(_ s: String, size: CGFloat, weight: NSFont.Weight = .bold, tracking: CGFloat = 0) -> CGFloat {
    var attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(size, weight)]
    if tracking != 0 { attrs[.kern] = size * tracking }
    return ceil((s as NSString).size(withAttributes: attrs).width)
}

// a paragraph that wraps (CSS line-height lh), up to `lines` lines
func drawPara(_ s: String, _ p: NSPoint, width: CGFloat, size: CGFloat = 15, color: NSColor = Theme.hint, weight: NSFont.Weight = .regular,
              lines: Int = 2, lh: CGFloat = 1.35) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
    style.minimumLineHeight = size * lh; style.maximumLineHeight = size * lh
    let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font(size, weight), .foregroundColor: color, .paragraphStyle: style]
    (s as NSString).draw(with: NSRect(x: p.x, y: p.y, width: width, height: CGFloat(lines) * size * lh + 1),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
}

// the mockup's icons (24x24 SVG viewBox, stroke 2.4, round caps) — drawn as the same paths
enum Icon { case kit, wave, note, session, pads, steps, device, melody, arrange, play, stop, rec }
func drawIcon(_ icon: Icon, _ r: NSRect, _ color: NSColor) {
    let k = r.width / 24
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * k, y: r.minY + y * k) }
    let path = NSBezierPath(); path.lineWidth = 2.4 * k; path.lineCapStyle = .round; path.lineJoinStyle = .round
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rx: CGFloat) {
        path.append(NSBezierPath(roundedRect: NSRect(x: r.minX + x * k, y: r.minY + y * k, width: w * k, height: h * k), xRadius: rx * k, yRadius: rx * k))
    }
    func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) { path.move(to: P(x0, y0)); path.line(to: P(x1, y1)) }
    var fill = false
    switch icon {
    case .kit: rect(3, 3, 7, 7, 1.5); rect(14, 3, 7, 7, 1.5); rect(3, 14, 7, 7, 1.5); rect(14, 14, 7, 7, 1.5)
    case .session: rect(3, 3, 8, 8, 2); rect(13, 3, 8, 8, 2); rect(3, 13, 8, 8, 2); rect(13, 13, 8, 8, 2)
    case .wave: line(3, 12, 5, 12); line(7, 7, 7, 17); line(11, 4, 11, 20); line(15, 8, 15, 16); line(19, 10, 19, 14)
    case .note:
        path.move(to: P(9, 18)); path.line(to: P(9, 5)); path.line(to: P(20, 3)); path.line(to: P(20, 16))
        path.appendOval(in: NSRect(x: r.minX + 3 * k, y: r.minY + 15 * k, width: 6 * k, height: 6 * k))
        path.appendOval(in: NSRect(x: r.minX + 14 * k, y: r.minY + 13 * k, width: 6 * k, height: 6 * k))
    case .pads: rect(3, 3, 18, 18, 3); line(9, 3, 9, 21); line(15, 3, 15, 21); line(3, 9, 21, 9); line(3, 15, 21, 15); path.lineCapStyle = .butt
    case .steps: for y in [6, 12, 18] as [CGFloat] { line(3, y, 7, y); line(10, y, 14, y); line(17, y, 21, y) }; path.lineCapStyle = .butt
    case .device: line(4, 21, 4, 14); line(4, 10, 4, 3); line(12, 21, 12, 12); line(12, 8, 12, 3); line(20, 21, 20, 16); line(20, 12, 20, 3)
                  line(1, 14, 7, 14); line(9, 8, 15, 8); line(17, 16, 23, 16)
    case .melody: line(4, 18, 4, 14); line(9, 18, 9, 8); line(14, 18, 14, 11); line(19, 18, 19, 5)
    case .arrange: line(3, 6, 15, 6); line(3, 12, 21, 12); line(3, 18, 11, 18)
    case .play: fill = true; path.move(to: P(7, 4)); path.line(to: P(20, 12)); path.line(to: P(7, 20)); path.close()
    case .stop: fill = true; rect(6, 6, 12, 12, 2)
    case .rec: fill = true; path.appendOval(in: NSRect(x: r.minX + 5 * k, y: r.minY + 5 * k, width: 14 * k, height: 14 * k))
    }
    color.set()
    if fill { path.fill() } else { path.stroke() }
}

extension CGFloat { func clamped(_ a: CGFloat, _ b: CGFloat) -> CGFloat { Swift.min(b, Swift.max(a, self)) } }

// MARK: - link to the Remote Script
final class Link {
    var wake: (() -> Void)?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var onMessage: (([String: Any]) -> Void)?

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(9100).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 262144)
            let n = recv(self.fd, &buf, buf.count, 0)
            if n > 0, let obj = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any] { self.onMessage?(obj) }
        }
        src.resume(); source = src
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(9101).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        data.withUnsafeBytes { raw in
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        wake?()
    }
}

// MARK: - touches straight from touchmouse (UDP 9102: "<n> x y x y…" in window points, "0" = fingers up), like the
// MPC software's own touch handling: no mouse pointer in between
final class TouchInput {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    var onTouches: (([NSPoint]) -> Void)?
    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(9102).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 512)
            let n = recv(self.fd, &buf, buf.count, 0)
            guard n > 0 else { return }
            let parts = String(decoding: buf[0..<n], as: UTF8.self).split(separator: " ").compactMap { Double($0) }
            guard let count = parts.first else { return }
            var pts: [NSPoint] = []
            for i in 0..<Int(count) where 2 + 2 * i < parts.count { pts.append(NSPoint(x: parts[1 + 2 * i], y: parts[2 + 2 * i])) }
            self.onTouches?(pts)
        }
        src.resume(); source = src
    }
}

// MARK: - audition notes through the touchmouse bridge (F0 7D 4D 10/11 note vel F7 → note on/off ch 11 into Live)
final class Notes {
    private var client = MIDIClientRef(), port = MIDIPortRef()
    init() { MIDIClientCreateWithBlock("MPCScreen" as CFString, &client, nil); MIDIOutputPortCreate(client, "out" as CFString, &port) }
    private func dest() -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i); var s: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(d, kMIDIPropertyDisplayName, &s)
            if (s?.takeRetainedValue() as String?) == "MPC Touch Live" { return d }
        }
        return nil
    }
    private var cached: MIDIEndpointRef = 0
    func send(_ bytes: [UInt8]) {
        var probe: Int32 = 0       // a stale endpoint (helper restarted) fails this lookup → find it again
        if cached == 0 || MIDIObjectGetIntegerProperty(cached, kMIDIPropertyUniqueID, &probe) != noErr { cached = dest() ?? 0 }
        let d = cached
        guard d != 0 else { return }
        var list = MIDIPacketList(); let p = MIDIPacketListInit(&list)
        bytes.withUnsafeBufferPointer { b in _ = MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, p, 0, b.count, b.baseAddress!) }
        MIDISend(port, d, &list)
    }
    func on(_ note: Int, _ vel: Int = 110) { send([0xF0, 0x7D, 0x4D, 0x10, UInt8(note & 127), UInt8(vel), 0xF7]) }
    func off(_ note: Int) { send([0xF0, 0x7D, 0x4D, 0x11, UInt8(note & 127), 0, 0xF7]) }
    func wake() { send([0xF0, 0x7D, 0x4D, 0x21, 0xF7]) }
}

// MARK: - the Touch's own controls straight from the helper (no detour through Live): used for the jog wheel in the browser
final class Controls {
    private var client = MIDIClientRef(), port = MIDIPortRef()
    var onJog: ((Int) -> Void)?
    var onJogPress: ((Bool) -> Void)?
    private var shift = false
    init() {
        MIDIClientCreateWithBlock("MPCScreen controls" as CFString, &client) { [weak self] _ in self?.connect() }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { [weak self] list, _ in
            var msgs: [(UInt8, UInt8, UInt8)] = []
            list.unsafeSequence().forEach { pkt in
                let p = pkt.pointee
                withUnsafeBytes(of: p.words) { raw in
                    for w in raw.bindMemory(to: UInt32.self).prefix(Int(p.wordCount)) where w >> 28 == 2 {
                        msgs.append((UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F)))
                    }
                }
            }
            DispatchQueue.main.async { msgs.forEach { self?.handle($0) } }
        }
        connect()
    }
    private func connect() {
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i); var s: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &s)
            if (s?.takeRetainedValue() as String?) == "MPC Touch Live" { MIDIPortDisconnectSource(port, src); MIDIPortConnectSource(port, src, nil) }
        }
    }
    private func handle(_ m: (UInt8, UInt8, UInt8)) {
        let (st, d1, d2) = m
        if st == 0xB0 && d1 == 100 { onJog?(d2 < 64 ? Int(d2) : Int(d2) - 128) }
        else if (st == 0x90 || st == 0x80) && d1 == 49 { shift = st == 0x90 && d2 > 0 }          // SHIFT
        else if st == 0x90 && d1 == 111 && d2 > 0 { onJogPress?(shift) }                         // jog press
    }
}

// MARK: - key of a sample
// Key of an audio file: chroma (12 pitch classes, from harmonic salience of the notes E1–C6) correlated with major/minor key profiles.
enum KeyDetect {
    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    // key profiles of KeyFinder (Sha'ath) — tested best on Ableton's labelled loops (85 % right, single notes 17/17)
    static let major: [Double] = [6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4]
    static let minor: [Double] = [6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2]

    static func chroma(_ path: String, from: Double = 0, to: Double = 1) -> [Double]? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let total = AVAudioFramePosition(f.length)
        let a = AVAudioFramePosition(Double(total) * from), e = AVAudioFramePosition(Double(total) * to)
        let maxFrames = min(e - a, AVAudioFramePosition(f.processingFormat.sampleRate * 90))     // max 90 s
        guard maxFrames > 2048, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(maxFrames)) else { return nil }
        f.framePosition = a
        guard (try? f.read(into: buf, frameCount: AVAudioFrameCount(maxFrames))) != nil, let ch = buf.floatChannelData else { return nil }
        let sr = f.processingFormat.sampleRate, chans = Int(buf.format.channelCount)
        // mono, decimated to ~11 kHz (average of `dec` samples: a crude low-pass, plenty for < 2 kHz)
        let dec = max(1, Int(sr / 11025)), rate = sr / Double(dec)
        let n = Int(buf.frameLength) / dec
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { var s: Float = 0; for c in 0..<chans { for k in 0..<dec { s += ch[c][i * dec + k] } }; mono[i] = s / Float(chans * dec) }
        let N = 8192, log2n = vDSP_Length(13)
        guard n >= N / 2, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var win = [Float](repeating: 0, count: N); vDSP_hann_window(&win, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        // pitch salience: a note (E1…C6) is as strong as its fundamental + 5 overtones (0.8^h), so the overtones of
        // a note (its 5th, its 3rd) don't count as notes of their own — that is what made 5th-errors (C vs G)
        let notes = Array(28...84)
        let binOf = { (f: Double) in Int((f * Double(N) / rate).rounded()) }
        var chroma = [Double](repeating: 0, count: 12)
        var re = [Float](repeating: 0, count: N / 2), im = [Float](repeating: 0, count: N / 2)
        var frame = [Float](repeating: 0, count: N), mag = [Float](repeating: 0, count: N / 2)
        var start = 0
        repeat {
            for i in 0..<N { frame[i] = (start + i < n ? mono[start + i] : 0) * win[i] }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(N / 2)) } }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&sc, 1, &mag, 1, vDSP_Length(N / 2))
            } }
            var fc = [Double](repeating: 0, count: 12)
            for m in notes {
                let f0 = 440 * pow(2, Double(m - 69) / 12)
                var sal = 0.0
                for h in 1...6 {
                    let b = binOf(f0 * Double(h)); if b + 1 >= N / 2 { break }
                    sal += pow(0.8, Double(h - 1)) * Double(max(mag[b - 1], mag[b], mag[b + 1]))
                }
                // only count it when it's a local peak among its neighbours (a semitone away)
                let lo = binOf(f0 * 0.9439), hi = binOf(f0 * 1.0595)
                let here = Double(mag[binOf(f0)]), nb = Double(max(mag[max(1, lo)], mag[min(N / 2 - 1, hi)]))
                if here >= nb { fc[m % 12] += sal * (m < 48 ? 1.5 : 1.0) }        // bass notes count a bit more
            }
            let s = fc.reduce(0, +)
            if s > 1e-6 { for k in 0..<12 { chroma[k] += sqrt(fc[k] / s) } }      // each frame counts the same (loud hits don't dominate)
            start += N / 2
        } while start + N / 2 < n
        return chroma
    }

    /// the key written in the file name ("Cmin", "F# Minor", "Bbmaj", "Am 120 bpm", "Stab F 120 bpm" = root F).
    /// Sample packs label it almost always — more reliable than listening. nil = no key in the name.
    static func fromName(_ path: String) -> (root: Int, minor: Bool, single: Bool)? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let roots = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        func parse(_ m: NSTextCheckingResult, _ i: Int) -> String? { let r = m.range(at: i); return r.location == NSNotFound ? nil : (name as NSString).substring(with: r) }
        // 1) note + explicit mode, anywhere: "C min", "F#Minor", "Bbmaj", "Ebm"
        let sep = "(?:^|[\\s_\\-\\(\\[])", end = "(?=$|[\\s_\\-\\)\\]\\.,])"
        let pats = [sep + "([A-G])([#b♯♭]?)[\\s_\\-]?(maj|major|min|minor)" + end,               // explicit word
                    sep + "([A-G])([#b♯♭]?)(m)(?=[\\s_\\-]*\\d{2,3}[\\s_\\-]?bpm|$)",    // "Am 120 bpm" / "... Am"
                    sep + "([A-G])([#b♯♭]?)()(?=[\\s_\\-]*\\d{2,3}[\\s_\\-]?bpm)"]    // bare note right before the bpm = root
        for (k, pat) in pats.enumerated() {
            guard let re = try? NSRegularExpression(pattern: pat, options: k == 0 ? [.caseInsensitive] : []),
                  let m = re.matches(in: name, range: NSRange(location: 0, length: (name as NSString).length)).last,
                  let l = parse(m, 1)?.uppercased(), var r = roots[l] else { continue }
            let acc = parse(m, 2) ?? ""
            if acc == "#" || acc == "♯" { r += 1 } else if acc == "b" || acc == "♭" { r += 11 }
            let mode = (parse(m, 3) ?? "").lowercased()
            return (r % 12, mode.hasPrefix("m") && !mode.hasPrefix("maj"), k == 2)
        }
        return nil
    }
    /// drums have no key: don't move the beat for a drum loop / break (by its name or folder)
    static func looksLikeDrums(_ path: String) -> Bool {
        let p = path.lowercased()
        return ["drum", "break", "kick", "snare", "hihat", "hi-hat", "hat ", "perc", "clap", "cymbal", "shaker", "conga", "bongo", "tabla", "groove", "beat"].contains { p.contains($0) }
    }

    /// mono, ~11 kHz (averaging decimation), at most 90 s — for the tempo
    static func loadMono(_ path: String) -> ([Float], Double)? {
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let frames = min(AVAudioFramePosition(f.length), AVAudioFramePosition(f.processingFormat.sampleRate * 90))
        guard frames > 2048, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              (try? f.read(into: buf, frameCount: AVAudioFrameCount(frames))) != nil, let ch = buf.floatChannelData else { return nil }
        let sr = f.processingFormat.sampleRate, chans = Int(buf.format.channelCount)
        let dec = max(1, Int(sr / 11025)), n = Int(buf.frameLength) / dec
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { var s: Float = 0; for c in 0..<chans { for k in 0..<dec { s += ch[c][i * dec + k] } }; mono[i] = s / Float(chans * dec) }
        return (mono, sr / Double(dec))
    }

    static func corr(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }

    /// root 0–11, minor?, score, clarity (gap to the best key with a DIFFERENT key signature), single (one note dominates: a one-shot)
    static func detect(_ path: String, from: Double = 0, to: Double = 1) -> (root: Int, minor: Bool, score: Double, clarity: Double, single: Bool)? {
        guard let c = chroma(path, from: from, to: to) else { return nil }
        let order = (0..<12).sorted { c[$0] > c[$1] }
        if c[order[0]] > 1.8 * c[order[1]] {                                     // one note: that's the root (mode = keep the song's)
            return (order[0], false, 1, 1, true)
        }
        var all: [(Int, Bool, Double)] = []
        for r in 0..<12 {
            let rot = (0..<12).map { c[($0 + r) % 12] }
            all.append((r, false, corr(rot, major))); all.append((r, true, corr(rot, minor)))
        }
        all.sort { $0.2 > $1.2 }
        let best = all[0]
        let sig = { (k: (Int, Bool, Double)) in k.1 ? (k.0 + 3) % 12 : k.0 }               // relative major = same notes
        let other = all.first { sig($0) != sig(best) }!
        return (best.0, best.1, best.2, best.2 - other.2, false)
    }
}

// MARK: - tempo of a sample (Rekordbox-style BPM)
// onset strength (spectral flux, 11 kHz, 1024-point FFT, hop 128 = 11.6 ms) → autocorrelation over 60–190 BPM, weighted
// towards the usual 80–140 range, + a check of the 1/2 and 2/1 multiples; parabolic peak = 0.1 BPM resolution.
enum Tempo {
    /// the BPM written in the file name ("… 98 bpm", "loop_120BPM")
    static func fromName(_ path: String) -> Double? {
        let name = (path as NSString).lastPathComponent
        guard let re = try? NSRegularExpression(pattern: "(\\d{2,3}(?:\\.\\d+)?)[\\s_\\-]?bpm", options: .caseInsensitive),
              let m = re.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)),
              let v = Double((name as NSString).substring(with: m.range(at: 1))), v >= 50, v <= 250 else { return nil }
        return v
    }
    static func detect(mono: [Float], rate: Double) -> (bpm: Double, confidence: Double)? {
        let N = 1024, hop = 128, log2n = vDSP_Length(10), n = mono.count
        guard Double(n) > rate * 3, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var win = [Float](repeating: 0, count: N); vDSP_hann_window(&win, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        var re = [Float](repeating: 0, count: N / 2), im = [Float](repeating: 0, count: N / 2)
        var frame = [Float](repeating: 0, count: N), mag = [Float](repeating: 0, count: N / 2), prev = [Float](repeating: 0, count: N / 2)
        var flux: [Double] = []
        var start = 0
        while start + N < n {
            for i in 0..<N { frame[i] = mono[start + i] * win[i] }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(N / 2)) } }
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&sc, 1, &mag, 1, vDSP_Length(N / 2))
            } }
            var f = 0.0
            for b in 1..<N / 2 { let v = log(1 + 100 * Double(mag[b])), p = log(1 + 100 * Double(prev[b])); if v > p { f += v - p } }
            flux.append(f); prev = mag
            start += hop
        }
        // remove the slow trend (local mean over ~0.5 s), keep the peaks
        let fr = rate / Double(hop), w = Int(fr * 0.25)
        var on = [Double](repeating: 0, count: flux.count)
        for i in 0..<flux.count {
            var s = 0.0; let a = max(0, i - w), b = min(flux.count - 1, i + w)
            for j in a...b { s += flux[j] }
            on[i] = max(0, flux[i] - s / Double(b - a + 1))
        }
        // autocorrelation for lags of 60–190 BPM (+ their double, to tell 90 from 180)
        func acf(_ lag: Int) -> Double { var s = 0.0; var i = 0; while i + lag < on.count { s += on[i] * on[i + lag]; i += 1 }; return s / Double(max(1, on.count - lag)) }
        let lagMin = Int(fr * 60 / 190), lagMax = Int(fr * 60 / 60) + 1
        var ac = [Double](repeating: 0, count: 2 * lagMax + 3)
        for l in 1..<ac.count { ac[l] = acf(l) }
        // comb: a real tempo has peaks at 1, 2, 3, 4 beats (kills the 3:4 and 2:3 mix-ups); 0.1 BPM steps
        func acAt(_ x: Double) -> Double { let i = Int(x), f = x - Double(i); return i + 1 < ac.count ? ac[i] * (1 - f) + ac[i + 1] * f : 0 }
        var scores: [(bpm: Double, s: Double)] = []
        for k in 0...1300 {
            let bpm = 60 + Double(k) * 0.1, lag = 60 * fr / bpm
            var s = 0.0
            for m in 1...4 where Double(m) * lag < Double(ac.count - 2) { s += acAt(Double(m) * lag) * [1.0, 0.8, 0.6, 0.8][m - 1] }
            let prior = exp(-0.5 * pow(log2(bpm / 110) / 0.6, 2))                            // 80–140 most likely
            scores.append((bpm, s * prior))
        }
        guard var best = scores.max(by: { $0.s < $1.s }), best.s > 0 else { return nil }
        // a loop (< 40 s) is a whole number of bars: its length allows only a few exact tempos (e.g. 9.6 s = 4 bars of 100.0) —
        // take the one the rhythm supports best
        let secs = Double(n) / rate
        var loop = false
        if secs < 40 {
            func score(_ b: Double) -> Double { scores[max(0, min(scores.count - 1, Int(((b - 60) / 0.1).rounded())))].s }
            let cands = [4.0, 8, 16, 32, 64].map { 60 * $0 / secs }.filter { $0 >= 70 && $0 <= 185 }
            if let c = cands.max(by: { score($0) < score($1) }), score(c) > 0.3 * best.s { best.bpm = c; loop = true }
        }
        let others = scores.filter { abs(log2($0.bpm / best.bpm)) > 0.08 }.map { $0.s }.max() ?? 0
        let bestS = scores.max(by: { $0.s < $1.s })!.s
        return (best.bpm, loop ? 1 : (bestS > 0 ? 1 - others / bestS : 0))
    }
}

// MARK: - waveform peaks (computed once per file)
final class Peaks {
    var file = ""
    var mins: [Float] = [], maxs: [Float] = []            // per bucket of `hop` frames
    var frames = 0, hop = 64, peak: Float = 1

    // high-resolution peaks: one bucket per `hop` frames (16 frames ≈ 0.4 ms; ≤ 1 million buckets), read in chunks (long tracks)
    func load(_ path: String, done: @escaping () -> Void) {
        guard path != file else { return }
        file = path; mins = []; maxs = []
        DispatchQueue.global().async {
            guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
            let n = Int(f.length), chans = Int(f.processingFormat.channelCount)
            let hop = max(16, n / 1_000_000), nb = max(1, (n + hop - 1) / hop)
            var mn = [Float](repeating: 0, count: nb), mx = [Float](repeating: 0, count: nb)
            let chunk = AVAudioFrameCount(1 << 20)
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) else { return }
            var pos = 0
            while pos < n {
                guard (try? f.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData else { break }
                for i in 0..<Int(buf.frameLength) {
                    var v: Float = 0
                    for c in 0..<chans { v += ch[c][i] }
                    v /= Float(chans)
                    let b = (pos + i) / hop
                    if v < mn[b] { mn[b] = v }; if v > mx[b] { mx[b] = v }
                }
                pos += Int(buf.frameLength)
            }
            let pk = max(0.01, max(mx.max() ?? 1, -(mn.min() ?? -1)))
            DispatchQueue.main.async {
                if self.file == path { self.mins = mn; self.maxs = mx; self.hop = hop; self.frames = n; self.peak = pk; done() }
            }
        }
    }
}

// MARK: - the screen
final class ScreenView: NSView {
    enum Page: String, CaseIterable { case sample = "SAMPLE", steps = "STEPS", pads = "PADS", mixer = "MIXER", session = "SESSION", device = "DEVICE", browse = "BROWSE" }
    var page: Page = { let p = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .steps; return p == .browse ? .session : p }() {   // the browser is a detour: never start in it
        didSet {
            UserDefaults.standard.set(page.rawValue, forKey: "page")
            if oldValue != page { needsDisplay = true }          // always show the new page right away
            if oldValue != page { FileHandle.standardError.write("\(Date()) page \(oldValue.rawValue) -> \(page.rawValue)\n".data(using: .utf8)!) }
            if page != .browse { padTarget = nil; sampleTarget = false; browseEntryDepth = 0; browseNewTrack = false; if oldValue == .browse { chopTarget = false } }
            if page == .browse && oldValue != .browse { pageBeforeBrowse = oldValue }   // MENU brings you back here
            if oldValue == .steps && page != .steps && lastStepMode { lastStepMode = false; syncStepMode() }   // leaving STEPS: pads play again
            link.send(["cmd": "page", "page": page.rawValue])
            if page == .browse && oldValue != .browse {
                if browsePath.isEmpty { browsePath = [UserDefaults.standard.string(forKey: "browseRoot").flatMap { r in ScreenView.browseCats.contains { $0.root == r } ? r : nil } ?? "Samples"] }   // the categories are on the left already
                link.send(["cmd": "browse", "path": browsePath])
            }
        }
    }
    // the step sequencer of this track (pads in step mode, like SHIFT + 16 LEVEL)
    func openSequencer() {
        page = .steps
        if trackKind == "drum" || isSamplerTrack { lastStepMode = true; syncStepMode() }
        needsDisplay = true
    }
    func syncStepMode() { stepModeSentAt = Date(); link.send(["cmd": "step_mode", "on": page == .steps]) }
    var stepModeSentAt = Date.distantPast                    // we just told the script: ignore its older state for a moment
    var lastTrackName = ""
    var lastTrackKind = ""
    var trackKind: String { (state["track"] as? [String: Any])?["kind"] as? String ?? "" }
    var isSamplerTrack: Bool { trackKind == "simpler" || trackKind == "slice" }
    var lastSamplerView: Page = .sample                     // Simpler tracks: WAVE or STEPS, whichever you used last
    // the first tab follows the track: Simpler = waveform, everything else = step grid / piano roll
    var lastDrumView: Page = .pads                          // Drum Rack tracks: PADS or STEPS
    var trackPage: Page { isSamplerTrack ? .sample : (trackKind == "drum" || chordsOn ? .pads : .steps) }   // instrument with CHORDS on: chord pads first
    // CHORDS per instrument track (by name): on by default for keys-like tracks, off for bass and the rest
    var trackName: String { (state["track"] as? [String: Any])?["name"] as? String ?? "" }
    var chordsOn: Bool {
        guard trackKind == "instrument" else { return false }
        if let v = (UserDefaults.standard.dictionary(forKey: "chordTracks") as? [String: Bool])?[trackName] { return v }
        let n = trackName.lowercased()
        return ["key", "piano", "rhodes", "organ", "chord", "pad", "epiano", "e-piano"].contains { n.contains($0) }
    }
    func setChords(_ on: Bool) {
        var d = (UserDefaults.standard.dictionary(forKey: "chordTracks") as? [String: Bool]) ?? [:]
        d[trackName] = on; UserDefaults.standard.set(d, forKey: "chordTracks")
        page = on ? .pads : .steps; needsDisplay = true
    }   // STEPS only via 16 LEVEL
    var onTrackPage: Bool { page == .sample || page == .steps || page == .pads }
    var padTarget: (note: Int, name: String)? = nil         // browsing to load into this drum pad
    var trackTabTitle: String {
        switch trackKind {
        case "drum": return "DRUMS"
        case "instrument": return "NOTES"
        case "simpler", "slice": return "SAMPLE"
        case "audio": return "AUDIO"
        default: return "TRACK"
        }
    }
    var lastChainCount = 0
    var lastManualPage = Date.distantPast                    // when you last changed page (tab, MENU, MAIN)
    var lastStepMode = false
    var awakeTick = false
    var animTick = 0
    var lastArrangement: Bool? = nil                       // nil = not known yet (start-up is not a switch)
    var lastInstance = -1
    var state: [String: Any] = [:]
    var playhead: Double? = nil
    var lastPlayheadAt = Date.distantPast
    var stepTool = "draw"                                     // STEPS: draw (tap = add / pick) · erase (tap = remove)
    var rollTool = "draw", rollPage = 0, rollBars = 2               // NOTES (piano roll): tool · bar page · bars on screen
    var rollBeat: Double? = nil, rollFollowOff = Date.distantPast
    var rollDrag: RollDrag? = nil
    var rollRows: [Int] = []
    var rollLocal: [[Double]]? = nil, rollSel: (Int, Double)? = nil, rollLocalAt = Date.distantPast
    let link = Link()
    let notes = Notes()
    let controls = Controls()
    let peaks = Peaks()

    // sample view zoom (in frames)
    var viewStart = 0.0, viewEnd = 1.0
    var zoomedFile = ""
    // interactions
    enum Drag { case loopStart, loopEnd, loopMove(Double), none, slice(index: Int, frame: Int), start, end, knob(index: Int, y: CGFloat, value: Double), audition(note: Int), viz(Int) }
    var drag: Drag = .none
    var dragFrame = 0
    var addMode = false
    var buttons: [(NSRect, () -> Void)] = []
    // tiles that react on release (tap) or when held (0.45 s): clips in the session grid
    var holdables: [(NSRect, tap: () -> Void, hold: () -> Void)] = []
    var pendingHold: (tap: () -> Void, work: DispatchWorkItem)? = nil
    var showPicker = false                                 // the track picker (tap the track name in the top bar)
    var modifier: String? = nil                            // "copy" / "delete" / "shift" while held on the Touch
    var copySrc: [Int]? = nil                              // the clip picked with COPY (grid column, row)
    var sessionScroll = CGPoint.zero

    override var isFlipped: Bool { true }

    // no pointer on the touch screen: an invisible cursor over the whole view, also while Ableton is the active app
    static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func cursorUpdate(with event: NSEvent) { ScreenView.blankCursor.set() }
    override func mouseMoved(with event: NSEvent) { ScreenView.blankCursor.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        link.onMessage = { [weak self] m in self?.receive(m) }
        link.wake = { [weak self] in self?.notes.wake() }
        controls.onJog = { [weak self] d in
            guard let self else { return }
            if self.page == .browse { self.moveBrowseSelection(d) }
            else if self.jogFocusId != nil, let t = self.jogTurn { t(d); self.needsDisplay = true }
        }
        controls.onJogPress = { [weak self] shift in
            guard let self, self.page == .browse else { return }
            if shift { if !self.browsePath.isEmpty { self.browsePath.removeLast(); self.enterBrowse() } } else { self.activateBrowseSelection() }
        }
        link.send(["cmd": "hello"])
        // keep DisplayLink "awake": like MPC (which redraws all the time), change one corner pixel 60x a second.
        // Without this DisplayLink drops into a slow mode when the screen is still and lags when it changes again.
        let keepAwake = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.awakeTick.toggle()
            self.animTick += 1
            if self.animTick % 5 == 0 && (self.page == .session || self.page == .sample) && !self.showPicker {
                for r in self.animRects { self.setNeedsDisplay(r) }
            }
            self.setNeedsDisplay(NSRect(x: self.bounds.width - 1, y: self.bounds.height - 1, width: 1, height: 1))
        }
        RunLoop.main.add(keepAwake, forMode: .common)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if (self?.state.isEmpty ?? false) { self?.link.send(["cmd": "hello"]) }
        }
        // the script must know our page (MENU, MAIN and the jog wheel depend on it): correct it if it's off
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let theirs = self.state["screen_page"] as? String, theirs != self.page.rawValue else { return }
            self.link.send(["cmd": "page", "page": self.page.rawValue])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func receive(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "state":
            let before = pageSignature()
            state = m
            stepOverrides = [:]
            let pageBefore = page
            followContext()
            if page == pageBefore && pageSignature() == before { return }
            if let s = simpler, let file = s["file"] as? String, !file.isEmpty {
                if file != zoomedFile {
                    zoomedFile = file; viewStart = 0; viewEnd = Double(s["length"] as? Int ?? 1)
                }
                peaks.load(file) { [weak self] in self?.needsDisplay = true }
                sampleKeyCheck(s, file)
            } else if isSamplerTrack, let tn = (state["track"] as? [String: Any])?["name"] as? String {
                trackFiles[tn] = ""                          // an empty Simpler: the first sample in it counts as new
            }
            needsDisplay = true
        case "playhead":
            let oldStep = stepHead.map { Int($0) }, oldTime = songTime, oldPos = playhead
            playhead = m["pos"] as? Double; stepHead = m["step"] as? Double; lastPlayheadAt = Date()
            if let t = m["time"] as? Double {
                if barText(t) != barText(songTime) { setNeedsDisplay(NSRect(x: bounds.width - 260, y: 0, width: 260, height: topH)) }   // position chip + beat lights
                songTime = t
            }
            switch page {                                       // only redraw what moved (the Touch screen is USB 2)
            case .sample: if playhead != oldPos { setNeedsDisplay(waveRect) }
            case .steps:
                if isRollPage { rollPlayhead(m["beat"] as? Double) }
                else if stepHead.map({ Int($0) }) != oldStep { setNeedsDisplay(stepGrid) }
            case .session:
                if arrangement != nil && songTime != oldTime {
                    let span = arrEnd - arrStart
                    if arrFollow && (songTime > arrStart + span * 0.85 || songTime < arrStart) { needsDisplay = true; break }
                    let x0 = beatToX(oldTime), x1 = beatToX(songTime)
                    setNeedsDisplay(NSRect(x: min(x0, x1) - 12, y: arrRect.minY, width: abs(x1 - x0) + 24, height: arrRect.height))
                }
            default: break
            }
        case "param":
            if var d = device, var params = d["params"] as? [[String: Any]], let i = m["index"] as? Int, i < params.count {
                params[i]["value"] = m["value"]; params[i]["text"] = m["text"]
                d["params"] = params; state["device"] = d
                if page == .device || page == .pads { needsDisplay = true }   // KIT shows the pad's sound on its Q fields too
            }
        case "qlink_touch":                                   // finger on a Q-Link: light up its knob
            if let i = m["index"] as? Int {
                if m["on"] as? Bool ?? false { touchedKnob = i; touchedAt = Date() } else if touchedKnob == i { touchedKnob = nil }
                if page == .device || page == .pads { needsDisplay = true }
            }
        case "next_page":                                    // MENU on the Touch
            FileHandle.standardError.write("\(Date()) MENU\n".data(using: .utf8)!)
            lastManualPage = Date()
            if closeOverlays() { return }                    // a picker open: MENU just closes it
            if page == .browse { showPicker = false; page = pageBeforeBrowse; return }   // browser: back to where you were
            showPicker = false
            // MENU: SESSION / ARRANGE → the selected track's page, then TRACK ⇄ DEVICE (MAIN = back to the song);
            // the MIXER is only opened with its button on SESSION / ARRANGE, and MENU takes you back from it
            //   drums: KIT → SEQUENCER → DEVICE → KIT · Simpler: SIMPLER → SEQUENCER → DEVICE · instrument: SEQUENCER ⇄ DEVICE
            if page == .session { page = trackPage }
            else if page == .mixer { page = .session }
            else if page == .device { page = trackPage }
            else if page == .sample && trackKind == "drum" { page = .pads }   // a pad's sample: back to the kit
            else if page == .pads || page == .sample { openSequencer() }
            else if page == .steps && (steps?["melodic"] as? Bool ?? false) && !(steps?["melody_view"] as? Bool ?? false) {
                link.send(["cmd": "melody_view", "on": true])        // note tracks: GRID → MELODY → DEVICE
            }
            else {
                if page == .steps && (steps?["melody_view"] as? Bool ?? false) { link.send(["cmd": "melody_view", "on": false]) }
                page = .device
            }
        case "step_rows":                                    // jog wheel on the drum sequencer: scroll the rows
            stepFirst += m["by"] as? Int ?? 0; needsDisplay = true
        case "step_mode":                                    // 16 LEVEL on the Touch: follow at once (every press)
            let on = m["on"] as? Bool ?? false
            lastStepMode = on; lastManualPage = Date()
            if on { if page != .steps { page = .steps } }
            else if page == .steps { page = trackKind == "drum" ? .pads : (isSamplerTrack ? .sample : .steps) }
            stepModeSentAt = Date()                          // (state still on its way: don't second-guess)
        case "show_page":                                    // MAIN on the Touch
            _ = closeOverlays()
            if let p = Page(rawValue: m["page"] as? String ?? "") { showPicker = false; show(p) }
        case "notice":                                       // a short message from the script (e.g. sampling)
            noticeText = m["text"] as? String ?? ""; noticeAt = Date(); needsDisplay = true
            noticeUndo = m["undo"] as? String
            DispatchQueue.main.asyncAfter(deadline: .now() + noticeSecs + 0.2) { [weak self] in self?.needsDisplay = true }
        case "wave_marker":                                  // Q1 / Q2 / Q4 moved a marker: show it now, keep it in view
            guard var sm = state["simpler"] as? [String: Any] else { break }
            if let a = m["start"] as? Int { sm["start"] = a }
            if let b = m["end"] as? Int { sm["end"] = b }
            state["simpler"] = sm
            if let c = m["chop"] as? [Int], c.count == 2, c[1] > c[0] {      // the wheel went to a chop: zoom to it (with some around it)
                let len = Double(c[1] - c[0]), total = Double(sm["length"] as? Int ?? c[1])
                let a = max(0, Double(c[0]) - len * 0.35), b = min(total, Double(c[1]) + len * 0.35)
                let span = viewEnd - viewStart
                waveFocus = Double(c[0]); waveFocusAt = Date()
                zoom(by: max(256, b - a) / max(1, span), around: nil)
                zoomTarget = (a, max(a + 256, b))
                needsDisplay = true
                break
            }
            if let f0 = m["focus"] as? Int {
                waveFocus = Double(f0); waveFocusAt = Date()
                let f = m["keep"] as? Int ?? f0                   // (Q2: the chop's end is what has to stay in view)
                let span = viewEnd - viewStart
                if Double(f) < viewStart + span * 0.05 || Double(f) > viewEnd - span * 0.05 {
                    viewStart = Double(f) - span / 2; viewEnd = viewStart + span; clampView(Double(sm["length"] as? Int ?? 1))
                    needsDisplay = true
                }
            }
            if page == .sample { setNeedsDisplay(waveRect.insetBy(dx: -20, dy: -20)) }
        case "wave_q_active":                                // turning a Q-Link on the SIMPLER page: light it up in the Q-LINKS bar
            activeQ = m["q"] as? Int; activeQAt = Date(); needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.needsDisplay = true }
        case "wave_zoom":                                    // Q3: zoom around the marker you're working on
            let d = m["delta"] as? Int ?? 0
            zoom(by: pow(0.93, Double(d)), around: waveFocus)
        case "wave_touch":                                   // finger on a Q-Link: light it up while you touch it (+ Q1 / Q2: its marker)
            if let q = m["q"] as? Int { if m["on"] as? Bool ?? false { touchedQ = q } else if touchedQ == q { touchedQ = nil; activeQAt = Date() }; activeQ = q; needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.needsDisplay = true } }
            if (m["on"] as? Bool ?? false), let q = m["q"] as? Int, q < 2, let sm = simpler, (sm["mode"] as? String) != "Slice" {
                let length = Double(sm["length"] as? Int ?? 1)
                let f = Double((q == 0 ? sm["start"] : sm["end"]) as? Int ?? 0)
                waveFocus = f; waveFocusAt = Date()
                _ = length
                needsDisplay = true
            }
        case "cpu":
            cpu = m["value"] as? Double ?? 0
            setNeedsDisplay(NSRect(x: 0, y: 0, width: bounds.width, height: topH))
        case "meters":
            meters = (m["levels"] as? [[Double]]) ?? []
            if page == .mixer && choice == nil && !showPicker { for r in meterRects { setNeedsDisplay(r) } }
        case "routing_options":
            if let pc = pendingChoice, (m["track"] as? Int) == pc.track, (m["kind"] as? String) == pc.kind {
                let track = pc.track, kind = pc.kind
                choice = (pc.title, (m["options"] as? [String]) ?? [], pc.current, { [weak self] i in
                    self?.link.send(["cmd": "routing_set", "track": track, "kind": kind, "index": i]) })
                pendingChoice = nil; needsDisplay = true
            }
        case "arr_previews":                                 // what's inside the arrangement clips
            var d: [String: [Any]] = [:]
            for c in (m["clips"] as? [[Any]]) ?? [] where c.count >= 4 {
                if let t = c[0] as? Int, let i = c[1] as? Int { d["\(t)-\(i)"] = [c[2], c[3]] }
            }
            arrPreviews = d
            if page == .session && arrangement != nil { needsDisplay = true }
        case "arr_selected":
            if let t = m["track"] as? Int, let i = m["index"] as? Int { arrSelected = (t, i); needsDisplay = true }
        case "mod":                                          // COPY / SHIFT+COPY (DELETE) held on the Touch
            modifier = m["mod"] as? String; copySrc = m["src"] as? [Int]; needsDisplay = true
        case "show_track":                                   // a clip was opened (held / SHIFT+tap; EDIT NOTES = its sequencer)
            showPicker = false
            if m["steps"] as? Bool ?? false { openSequencer() } else { page = trackPage }
            needsDisplay = true
        case "browse_toggle":                                // SHIFT + MENU/BROWSE
            if page == .browse { page = pageBeforeBrowse } else { pageBeforeBrowse = page; page = .browse }
        case "jog":
            moveBrowseSelection(m["delta"] as? Int ?? 0)
        case "jog_press":
            if m["shift"] as? Bool ?? false { if !browsePath.isEmpty { browsePath.removeLast(); enterBrowse() } }
            else { activateBrowseSelection() }
        case "browse":
            if (m["path"] as? [String]) ?? [] == browsePath {
                let items = m["items"] as? [[String: Any]] ?? []
                if (m["offset"] as? Int ?? 0) == 0 { browseItems = items } else { browseItems += items }   // long lists come in parts
                if browseSelected == nil, let first = browseItems.first?["name"] as? String { browseSelected = first; browseIndex = 0; browseHeard = nil }
                needsDisplay = true
            }
        default: break
        }
    }

    var simpler: [String: Any]? { state["simpler"] as? [String: Any] }
    var session: [String: Any]? { state["session"] as? [String: Any] }
    var device: [String: Any]? { state["device"] as? [String: Any] }

    // MARK: layout
    var mpcChrome: Bool { true }                            // every page is in the MPC-2 look now                 // pages already in the MPC-2 look: status strip + page header + F-keys
    var topH: CGFloat { mpcChrome ? 104 : 89 }              // (old pages: top bar 84 + 5 px stripe)
    var bottomH: CGFloat { 96 }
    var waveRect: NSRect { NSRect(x: 0, y: 34 + 70 + 24, width: bounds.width, height: 318) }   // MPC-2 layout: under strip + header + ruler

    // MPC: tap a value = it gets a white ring and the jog wheel changes it; tap it again (or another page) = the wheel's
    // page default again (drum rows · octave · scenes · tracks in Arrange)
    var jogFocusId: String? = nil {
        didSet { if oldValue != jogFocusId { link.send(["cmd": "jog_focus", "on": jogFocusId != nil]); if jogFocusId == nil { jogTurn = nil } } }
    }
    var jogTurn: ((Int) -> Void)? = nil
    var focusSeen = false
    func focusable(_ r: NSRect, _ id: String, radius: CGFloat = 14, turn: @escaping (Int) -> Void) {
        guard jogFocusId == id else { return }
        focusSeen = true; jogTurn = turn
        NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: radius + 3, yRadius: radius + 3); o.lineWidth = 3; o.stroke()
    }
    func toggleFocus(_ id: String) { jogFocusId = jogFocusId == id ? nil : id; needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        if dirty.width <= 1 && dirty.height <= 1 {           // keep-awake pixel only
            (awakeTick ? Theme.bg : Theme.bg.blended(withFraction: 0.02, of: .white)!).setFill(); dirty.fill(); return
        }
        focusSeen = false
        defer { if jogFocusId != nil && !focusSeen { DispatchQueue.main.async { [weak self] in self?.jogFocusId = nil } } }   // its field is gone
        Theme.bg.setFill(); bounds.fill()
        buttons = []; holdables = []; mixHits = []; sliders = []; arrVolHits = []
        if dirty.width > 200 || dirty.height > 200 { animRects = [] }   // (a full redraw rebuilds them)
        if !mpcChrome { drawTopBar() }
        switch page {
        case .sample: drawSample()
        case .session: if arrangement != nil { drawArrangement() } else { drawSession() }
        case .device: drawDevice()
        case .steps: drawSteps()
        case .pads: if chordsOn { drawChords() } else if trackKind == "drum" { drawPads() } else { DispatchQueue.main.async { [weak self] in self?.page = .steps } }
        case .mixer: drawMixer()
        case .browse: drawBrowse()
        }
        if showPicker { drawTrackPicker() }
        if tempoEdit { drawTempoEdit() }
        if keyEdit { drawKeyEdit() }
        if state["fresh"] as? Bool ?? false { drawNewBeat() }
        if !noticeText.isEmpty && Date().timeIntervalSince(noticeAt) < noticeSecs {
            let r = page == .sample ? NSRect(x: 120, y: waveRect.minY + 14, width: bounds.width - 240, height: 70)
                                    : NSRect(x: 120, y: bounds.height - 56 - 12 - 70, width: bounds.width - 240, height: 70)
            Theme.strip.withAlphaComponent(0.96).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            Theme.accent.setFill(); NSRect(x: r.minX, y: r.minY, width: 4, height: r.height).fill()
            var tw = r.width - 40
            if let undo = noticeUndo {                       // e.g. the beat moved to the sample's key: one tap back
                let u = NSRect(x: r.maxX - 12 - 120, y: r.minY + 11, width: 120, height: 48)
                button(u, "UNDO", size: 16, fill: Theme.panel2, ink: Theme.text) { [weak self] in
                    self?.link.send(["cmd": undo]); self?.noticeText = ""; self?.noticeUndo = nil; self?.needsDisplay = true }
                tw -= 132
            }
            drawText(noticeText, NSPoint(x: r.minX + 20, y: r.midY - lineH(18) / 2), size: 18, color: Theme.text, weight: .regular, center: true, width: tw)
        }
        if choice != nil { drawChoice() }
        drawModifierBanner()
    }

    var onBand = false                                      // drawing on the coloured header band
    func button(_ r: NSRect, _ title: String, on: Bool = false, color: NSColor? = nil, size: CGFloat = 15, radius: CGFloat = 10,
                fill: NSColor? = nil, ink: NSColor? = nil, hitPad: CGFloat = 0, action: @escaping () -> Void) {
        let rad = min(4, radius, r.height / 2)                  // MPC: small corners
        let path = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
        let bg = fill ?? (on ? Theme.active : (onBand ? NSColor.black.withAlphaComponent(0.3) : Theme.panel2))   // selected = a white pill
        bg.setFill(); path.fill()
        drawTextV(title, r, size: size, color: ink ?? (on || fill != nil ? Theme.ink(bg) : Theme.text), weight: .bold, center: true)
        buttons.append((r.insetBy(dx: -hitPad, dy: -hitPad), action))                // hitPad: a bigger target than it looks
    }

    // TOP BAR — only what the buttons can't show or set (MENU / MAIN / PLAY / REC / +- are on the hardware):
    // [TRACK tile → track list] [PAGE + where MENU goes] … BPM · SIG · KEY · QUANT · METRO · CPU · POSITION
    var cpu: Double = 0
    var noticeText = "", noticeAt = Date.distantPast
    var pitchN: Int?                                         // PITCH semitones just sent (before the state catches up)
    var activeQ: Int?, activeQAt = Date.distantPast, touchedQ: Int?   // the Q-Link you're on (SIMPLER page)
    var noticeUndo: String?                                 // a notice with an UNDO button (sends this command)
    var noticeSecs: Double { noticeUndo != nil ? 10 : 4 }

    // KEY OF A SAMPLE: a new sample in a Simpler → the app finds its key → the script moves the beat to it
    // (song key, chord/keys pads, keys/bass/melody clips). Automatic only for a NEW sample: loaded or recorded on the Touch,
    // or the sample of a track changed while we're running — opening a track with an old sample never changes anything.
    var sampleKeys: [String: [String: Any]] = [:]          // file → found key
    var keyBusy = Set<String>()
    var trackFiles: [String: String] = [:]                  // track → the sample we saw on it
    var expectSample = Date.distantPast                     // you just loaded / recorded a sample on the Touch
    func sampleKeyCheck(_ s: [String: Any], _ file: String) {
        if s["pad"] != nil { return }                       // a drum pad's sample: drums have no key
        let tn = (state["track"] as? [String: Any])?["name"] as? String ?? ""
        let prev = trackFiles[tn]
        trackFiles[tn] = file
        let isNew = prev != file && (prev != nil || Date().timeIntervalSince(expectSample) < 90)
        if isNew { expectSample = .distantPast }
        if file.contains("/Samples/Processed/"), let p = prev, !p.isEmpty, p != file, let pk = sampleKeys[p] {
            // CROP / REVERSE / NORMALIZE make a new file of the SAME sample: keep its key, BPM and lead role — not a new sample
            if sampleKeys[file] == nil { var k = pk; k["file"] = file; sampleKeys[file] = k }
            link.send(["cmd": "key_leader_follow", "from": p, "to": file])
            return
        }
        let auto = isNew && !KeyDetect.looksLikeDrums(file)          // a drum loop / break never moves your key
        if let k = sampleKeys[file] { if auto { sendSampleKey(k, auto: true) }; return }
        if keyBusy.contains(file) { return }
        keyBusy.insert(file)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Rekordbox-style analysis: key + BPM. What the file name says wins (sample packs label both)
            var info: [String: Any] = ["file": file]
            if let n = KeyDetect.fromName(file) {
                info.merge(["root": n.root, "minor": n.minor, "clarity": 1.0, "single": n.single, "named": true]) { $1 }
            } else if let k = KeyDetect.detect(file) {
                info.merge(["root": k.root, "minor": k.minor, "clarity": k.clarity, "single": k.single]) { $1 }
            }
            if let b = Tempo.fromName(file) { info["bpm"] = b; info["bpmNamed"] = true }
            else if let (m, r) = KeyDetect.loadMono(file), let t = Tempo.detect(mono: m, rate: r) { info["bpm"] = t.bpm }
            DispatchQueue.main.async {
                guard let self else { return }
                self.keyBusy.remove(file)
                guard info["root"] != nil || info["bpm"] != nil else { return }
                self.sampleKeys[file] = info
                if auto && info["root"] != nil { self.sendSampleKey(info, auto: true) }
                self.needsDisplay = true
            }
        }
    }
    /// tap on the analysis chip: move the beat to the key · take its tempo (or ½ / ×2) · chop 1 / 2 / 4 bars from the chop you're on
    func analysisMenu(_ k: [String: Any]) {
        var opts: [(String, () -> Void)] = []
        let name = sampleKeyName(k)
        if k["root"] != nil && name != "unclear" {
            opts.append(("Fit THIS sample to the beat (transpose + stretch)", { [weak self] in self?.sendSampleKey(k, fit: true) }))
            opts.append(("Lead sample: beat → \(name) (keys & bass follow)", { [weak self] in self?.sendSampleKey(k) }))
        }
        if let bpm = k["bpm"] as? Double {
            for (t, f) in [("", 1.0), (" (½)", 0.5), (" (×2)", 2.0)] {
                let v = (bpm * f * 10).rounded() / 10
                guard v >= 40 && v <= 250 else { continue }
                opts.append((String(format: "Song tempo → %.1f BPM", v) + t, { [weak self] in self?.link.send(["cmd": "song_set", "what": "tempo", "value": v]) }))
            }
            for bars in [1, 2, 4] {
                opts.append(("Chop \(bars) bar\(bars == 1 ? "" : "s") from here (\(bars == 1 ? 8 : 16) chops)", { [weak self] in
                    self?.link.send(["cmd": "chop_bars", "bars": bars, "bpm": bpm]) }))
            }
        }
        if opts.isEmpty { noticeText = "Can't hear a clear key or tempo in this sample"; noticeUndo = nil; noticeAt = Date(); needsDisplay = true; return }
        let title = String(format: "This sample: %@%@", (k["bpm"] as? Double).map { String(format: "%.1f BPM · ", $0) } ?? "", name)
        choice = (title, opts.map { $0.0 }, "", { i in if i < opts.count { opts[i].1() } })
        needsDisplay = true
    }
    /// TIMESTRETCH on the SIMPLER page: we know the sample's tempo, so it fits your beat by itself — you only pick HOW
    func warpMenu() {
        guard let s = simpler, let file = s["file"] as? String else { return }
        let bpm = sampleKeys[file]?["bpm"] as? Double
        let song = songInfo["tempo"] as? Double ?? 0
        let warping = s["warping"] as? Bool ?? false, mode = s["warp_mode"] as? Int ?? 0
        func w(_ what: String) { var m: [String: Any] = ["cmd": "smart_warp", "what": what]; if let bpm { m["bpm"] = bpm }; link.send(m) }
        var opts: [(String, () -> Void)] = [
            ((warping && (mode == 4 || mode == 6) ? "✓ " : "") + "STRETCH · same pitch (keys, piano, vinyl)", { w("stretch") }),
            ((warping && mode == 0 ? "✓ " : "") + "DRUMS · tight hits (breaks)", { w("drums") }),
            ((!warping ? "✓ " : "") + "OFF · as recorded", { w("off") })]
        if let bpm {                                         // PITCH like a record, by WHOLE semitones: your beat goes to that tempo
            let n0 = Int((12 * log2(max(1, song) / bpm)).rounded())
            for n in Set([0, n0 - 1, n0, n0 + 1]).sorted() where abs(n) <= 7 {
                let t = bpm * pow(2, Double(n) / 12)
                guard t >= 50 && t <= 200 else { continue }
                let on = warping && mode == 3 && abs(song - t) < 0.06
                var m: [String: Any] = (KeyDetect.looksLikeDrums(file) ? [:] : (sampleKeys[file] ?? [:])).filter { ["root", "minor", "single", "clarity", "named"].contains($0.key) }   // a drum loop never moves your key
                m.merge(["cmd": "pitch_semis", "bpm": bpm, "semis": n, "file": file]) { $1 }
                let label = n == 0 ? String(format: "PITCH ±0 · beat → %.1f BPM (original)", t) : String(format: "PITCH %+d · beat → %.1f BPM", n, t)
                opts.append(((on ? "✓ " : "") + label, { [weak self] in self?.link.send(m) }))
            }
        }
        if warping {
            if s["can_half"] as? Bool ?? false { opts.append(("Runs twice too fast → ÷ 2", { w("half") })) }
            if s["can_double"] as? Bool ?? false { opts.append(("Runs half too slow → × 2", { w("double") })) }
        }
        let title = "Timestretch" + (bpm.map { String(format: " · sample %.1f BPM → your beat %.1f", $0, song) } ?? " · sample tempo unknown")
        choice = (title, opts.map { $0.0 }, "", { i in if i < opts.count { opts[i].1() } })
        needsDisplay = true
    }
    /// auto: a new sample (the 1st one in a set leads the key, later ones get fitted to the beat) · fit: this one follows the beat
    func sendSampleKey(_ k: [String: Any], auto: Bool = false, fit: Bool = false) {
        var m = k; m["cmd"] = "sample_key"; if auto { m["auto"] = true }; if fit { m["fit"] = true }; link.send(m)
    }
    func sampleKeyName(_ k: [String: Any]) -> String {
        guard k["root"] != nil else { return "–" }
        let r = KeyDetect.names[(k["root"] as? Int ?? 0) % 12]
        if k["single"] as? Bool ?? false { return r }
        if (k["clarity"] as? Double ?? 0) < 0.03 { return "unclear" }
        return r + ((k["minor"] as? Bool ?? false) ? " min" : " maj")
    }
    var tempoEdit = false
    static let quantNames = ["None", "8 Bars", "4 Bars", "2 Bars", "1 Bar", "1/2", "1/2T", "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32"]
    static let rootNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let scaleNames = ["Major", "Minor", "Dorian", "Mixolydian", "Lydian", "Phrygian", "Locrian", "Harmonic Minor", "Melodic Minor",
                             "Major Pentatonic", "Minor Pentatonic", "Minor Blues", "Whole Tone", "Chromatic"]
    var songInfo: [String: Any] { state["song"] as? [String: Any] ?? [:] }
    var pageName: String {
        switch page {
        case .steps: if (steps?["melody_view"] as? Bool ?? false) && (steps?["melodic"] as? Bool ?? false) { return "MELODY" }; return trackKind == "drum" || isSamplerTrack ? "STEPS" : (trackKind == "instrument" ? "NOTES" : "TRACK")
        case .pads: return chordsOn ? "CHORDS" : "PADS"
        case .sample: return "SIMPLER"
        case .device: return "DEVICE"
        case .mixer: return "MIXER"
        case .session: return arrangement != nil ? "ARRANGE" : "SESSION"
        case .browse: return "BROWSER"
        }
    }

    // TOP BAR — exactly the mockup: [track] [page] [4/4 · BPM] [KEY] [SWING] [position · CPU]  + 5 px track-colour stripe
    // (quantise and metronome live in the BPM panel; tap BPM)
    func labelValue(_ x: CGFloat, _ r: NSRect, label: String, value: String, labelColor: NSColor, valueColor: NSColor, valueSize: CGFloat, tracking: CGFloat = 0, topAligned: Bool = false) {
        let h = lineH(11) + lineH(valueSize)
        let y = topAligned ? r.minY + 8 : r.midY - h / 2
        drawText(label, NSPoint(x: x, y: y), size: 11, color: labelColor, weight: .bold, width: r.maxX - x - 8, tracking: tracking)
        drawText(value, NSPoint(x: x, y: y + lineH(11)), size: valueSize, color: valueColor, weight: .bold, width: r.maxX - x - 8)
    }
    // "1 · Dusty Kit" like the mockup (Ableton's own "1-MIDI" style numbers are replaced)
    static func numbered(_ name: String, _ index: Int?) -> String {
        guard let index else { return name }
        var n = name
        if let r = n.range(of: "^[0-9]+[-· ]+", options: .regularExpression) { n.removeSubrange(r) }
        return "\(index + 1) · " + (n.isEmpty ? name : n)
    }
    func drawTopBar() {
        let tcol = Theme.live((state["track"] as? [String: Any])?["color"] as? Int)
        Theme.bg.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 84).fill()
        tcol.setFill(); NSRect(x: 0, y: 84, width: bounds.width, height: 5).fill()
        // track: filled with its colour (tap = all tracks)
        let trackR = NSRect(x: 8, y: 8, width: 302, height: 68)
        let tfill = showPicker ? tcol.blended(withFraction: 0.3, of: .white)! : tcol
        tfill.setFill(); NSBezierPath(roundedRect: trackR, xRadius: 14, yRadius: 14).fill()
        let tink = Theme.ink(tfill)
        if let t = state["track"] as? [String: Any] {
            let kind = trackKind
            let icon: Icon = kind == "drum" ? .kit : (isSamplerTrack ? .wave : (kind == "audio" ? .wave : .note))
            drawIcon(icon, NSRect(x: trackR.minX + 16, y: trackR.midY - 13, width: 26, height: 26), tink)
            let inst = currentInstrument
            let label = kind == "drum" ? "DRUM KIT" : (isSamplerTrack ? "SIMPLER" : (kind == "audio" ? "AUDIO" : (kind == "empty" ? "EMPTY" : (inst.isEmpty ? "TRACK" : inst.uppercased()))))
            labelValue(trackR.minX + 54, trackR, label: label, value: ScreenView.numbered(t["name"] as? String ?? "", (state["tracks"] as? [[String: Any]])?.first { $0["selected"] as? Bool ?? false }?["index"] as? Int), labelColor: tink.withAlphaComponent(0.7), valueColor: tink, valueSize: 22, tracking: 0.08)
        } else {
            drawTextV("Waiting for Ableton…", trackR, x: trackR.minX + 16, size: 17, color: tink)
        }
        buttons.append((trackR, { [weak self] in self?.showPicker.toggle(); self?.tempoEdit = false; self?.needsDisplay = true }))
        // page: outlined in the track colour, dots = where MENU goes (tap = MENU)
        let pageR = NSRect(x: 318, y: 8, width: 190, height: 68)
        tcol.setStroke(); let po = NSBezierPath(roundedRect: pageR.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13); po.lineWidth = 2; po.stroke()
        let melodyOn = page == .steps && (steps?["melody_view"] as? Bool ?? false) && (steps?["melodic"] as? Bool ?? false)
        let picon: Icon = [Page.pads: Icon.pads, .steps: melodyOn ? .melody : .steps, .sample: .wave, .device: .device, .mixer: .device,
                           .session: arrangement != nil ? .arrange : .session, .browse: .note][page] ?? .pads
        drawIcon(picon, NSRect(x: pageR.minX + 16, y: pageR.midY - 12, width: 24, height: 24), tcol)
        let three = trackKind == "drum" || isSamplerTrack || chordsOn
        let room = pageR.width - 50 - 16 - (three ? 34 : 21) - 8                    // the title never runs into the dots
        var ps: CGFloat = 22
        while ps > 15 && textW(pageName, size: ps) > room { ps -= 1 }
        drawTextV(pageName, pageR, x: pageR.minX + 50, size: ps, color: tcol)
        buttons.append((pageR, { [weak self] in self?.receive(["type": "next_page"]) }))
        let pair: [Bool] = page == .mixer ? [false, true]
            : (three ? [page == .pads || page == .sample || page == .session, page == .steps, page == .device] : [onTrackPage || page == .session, page == .device])
        for (k, on) in pair.enumerated() {
            (on ? tcol : Theme.slot).setFill()
            NSBezierPath(ovalIn: NSRect(x: pageR.maxX - 16 - 8 - CGFloat(pair.count - 1) * 13 + CGFloat(k) * 13, y: pageR.midY - 4, width: 8, height: 8)).fill()
        }
        // song
        let si = songInfo
        let tempo = si["tempo"] as? Double ?? 120
        let sig = si["sig"] as? [Int] ?? [4, 4]
        let root = si["root"] as? Int ?? 0
        let bpmR = NSRect(x: 516, y: 8, width: 128, height: 68)
        Theme.panel2.setFill(); NSBezierPath(roundedRect: bpmR, xRadius: 14, yRadius: 14).fill()
        labelValue(bpmR.minX + 14, bpmR, label: "\(sig[0])/\(sig[1]) · BPM", value: String(format: tempo.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", tempo),
                   labelColor: Theme.dim, valueColor: Theme.text, valueSize: 24, topAligned: true)
        buttons.append((bpmR, { [weak self] in
            guard let self else { return }
            self.keyEdit = false; self.tempoEdit.toggle(); self.jogFocusId = self.tempoEdit ? "bpm" : nil; self.needsDisplay = true }))
        focusable(bpmR, "bpm") { [weak self] d in                   // wheel: ±1 BPM
            guard let self else { return }
            let v = (((self.songInfo["tempo"] as? Double ?? 120) + Double(d)) * 100).rounded() / 100
            self.link.send(["cmd": "song_set", "what": "tempo", "value": v])
            if var si = self.state["song"] as? [String: Any] { si["tempo"] = v; self.state["song"] = si }
        }
        let keyR = NSRect(x: 652, y: 8, width: 150, height: 68)
        Theme.panel2.setFill(); NSBezierPath(roundedRect: keyR, xRadius: 14, yRadius: 14).fill()
        labelValue(keyR.minX + 14, keyR, label: "KEY", value: ScreenView.rootNames[max(0, min(11, root))] + " " + (si["scale"] as? String ?? ""),
                   labelColor: Theme.dim, valueColor: Theme.text, valueSize: 20, topAligned: true)
        buttons.append((keyR, { [weak self] in self?.pickKey() }))
        let swing = si["swing"] as? Int ?? 50
        let swR = NSRect(x: 810, y: 8, width: 116, height: 68)
        Theme.palette[2].color.setFill(); NSBezierPath(roundedRect: swR, xRadius: 14, yRadius: 14).fill()
        labelValue(swR.minX + 14, swR, label: "SWING", value: "\(swing)%", labelColor: hex(0x241c00, 0.7), valueColor: hex(0x241c00), valueSize: 22, topAligned: true)
        buttons.append((swR, { [weak self] in                       // 1st tap = the wheel sets the swing · 2nd tap = the list
            guard let self else { return }
            if self.jogFocusId == "swing" { self.jogFocusId = nil; self.pickSwing() } else { self.jogFocusId = "swing"; self.needsDisplay = true } }))
        focusable(swR, "swing") { [weak self] d in
            guard let self else { return }
            let v = max(50, min(75, (self.songInfo["swing"] as? Int ?? 50) + d))
            self.link.send(["cmd": "swing", "value": v])
            if var si = self.state["song"] as? [String: Any] { si["swing"] = v; self.state["song"] = si }
        }
        // position: green while playing, red while recording, grey when stopped
        let playing = state["playing"] as? Bool ?? false, rec = si["recording"] as? Bool ?? state["recording"] as? Bool ?? false
        let posR = NSRect(x: 934, y: 8, width: bounds.width - 8 - 934, height: 68)
        let posFill = rec && playing ? Theme.red : (playing ? Theme.play : Theme.panel2)
        let pink = rec && playing ? hex(0x2b0606) : (playing ? hex(0x052814) : Theme.text)
        posFill.setFill(); NSBezierPath(roundedRect: posR, xRadius: 14, yRadius: 14).fill()
        drawIcon(rec && playing ? .rec : (playing ? .play : .stop), NSRect(x: posR.minX + 16, y: posR.midY - 11, width: 22, height: 22), pink)
        let state0 = rec && playing ? "RECORDING" : (playing ? "PLAYING" : "STOPPED")
        labelValue(posR.minX + 50, posR, label: state0 + String(format: " · CPU %.0f%%", cpu), value: barText(songTime),
                   labelColor: playing ? pink.withAlphaComponent(0.7) : Theme.dim, valueColor: pink, valueSize: 24)
        if playing {
            let beat = Int(songTime.truncatingRemainder(dividingBy: Double(max(1, sig[0])))) % 4
            for k in 0..<4 {
                (k == beat ? pink : pink.withAlphaComponent(0.25)).setFill()
                NSBezierPath(ovalIn: NSRect(x: posR.maxX - 16 - 58 + CGFloat(k) * 16, y: posR.midY - 5, width: 10, height: 10)).fill()
            }
        }
    }

    // double tap on a track name = open that track's own page (PADS / NOTES / WAVE / load page)
    var lastTrackTap: (index: Int, at: Date)? = nil
    var openTrackPending = false
    func trackTapped(_ index: Int, selected: Bool) -> Bool {          // true = it was a double tap (and the page opened)
        defer { lastTrackTap = (index, Date()) }
        if selected && !(lastTrackTap.map { $0.index == index && Date().timeIntervalSince($0.at) < 0.4 } ?? false) {
            showPicker = false; page = trackPage; lastManualPage = Date(); needsDisplay = true   // the selected track again: its page
            return true
        }
        guard let last = lastTrackTap, last.index == index, Date().timeIntervalSince(last.at) < 0.4 else { return false }
        lastTrackTap = nil
        showPicker = false
        if selected { page = trackPage } else { openTrackPending = true }   // another track: open its page once it's selected
        lastManualPage = Date(); needsDisplay = true
        return true
    }

    func pickSwing() {                                          // MPC's classic swing values (Q1 on STEPS fine-tunes)
        let opts = ["50% (straight)", "54%", "56%", "58%", "60%", "62%", "66%", "71%"]
        let cur = songInfo["swing"] as? Int ?? 50
        choice = ("Swing", opts, opts.first { $0.hasPrefix("\(cur)%") } ?? "", { [weak self] i in
            let v = Int(opts[i].prefix(2)) ?? 50
            self?.link.send(["cmd": "swing", "value": v]) })
        needsDisplay = true
    }

    func pickSignature() {
        let opts = ["2/4", "3/4", "4/4", "5/4", "6/8", "7/8", "12/8"]
        let sig = songInfo["sig"] as? [Int] ?? [4, 4]
        choice = ("Time signature", opts, "\(sig[0])/\(sig[1])", { [weak self] i in
            let p = opts[i].split(separator: "/").map { Int($0)! }
            self?.link.send(["cmd": "song_set", "what": "sig", "value": p]) })
        needsDisplay = true
    }
    func pickQuant() {
        let q = songInfo["quant"] as? Int ?? 4
        choice = ("Clip launch quantise", ScreenView.quantNames, ScreenView.quantNames[min(q, ScreenView.quantNames.count - 1)], { [weak self] i in
            self?.link.send(["cmd": "song_set", "what": "quant", "value": i]) })
        needsDisplay = true
    }
    // NEW BEAT: an empty set in Ableton → pick a starting point; the script builds the tracks, sounds and returns
    func drawNewBeat() {
        let area = NSRect(x: 0, y: topH, width: bounds.width, height: bounds.height - topH)
        Theme.bg.setFill(); area.fill()
        buttons.append((area, {}))
        let top = topH + 24
        drawText("NEW BEAT", NSPoint(x: 32, y: top), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        drawText("What are we making?", NSPoint(x: 32, y: top + lineH(13) + 10), size: 34, weight: .light)
        let cards: [(String, String, String, [String], NSColor, String)] = [
            ("HIP-HOP", "90 BPM · F Minor", "hiphop", ["DRUMS · Boom Bap Kit + Drum Buss", "CHOPS · Simpler, ready to sample", "BASS · 808 Pure, ducked by the kick",
                                                    "KEYS · E-Piano Rhodish", "Returns · A Reverb, B Echo · Glue on Main"], Theme.palette[9].color, "hiphop"),
            ("HOUSE", "124 BPM · A Minor", "house", ["DRUMS · 909 Core Kit + Drum Buss", "CHOPS · Simpler, ready to sample", "BASS · FM House Bass, ducked by the kick",
                                                  "KEYS · Organ Basic (holds while you hold)", "Returns · A Reverb, B Echo · Glue on Main"], Theme.palette[5].color, "house"),
            ("EMPTY", "start from scratch", "", ["Just the empty set:", "load what you like", "with LOAD on the Touch"], Theme.panel2, "")]
        let cy = top + lineH(13) + 10 + 34 + 30, ch = bounds.height - 32 - cy
        let cw = (bounds.width - 64 - 2 * 16) / 3
        for (k, c) in cards.enumerated() {
            let r = NSRect(x: 32 + CGFloat(k) * (cw + 16), y: cy, width: cw, height: ch)
            Theme.panel.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).setClip()
            (k < 2 ? c.4 : hex(0x4a4e52)).setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawText(c.0, NSPoint(x: r.minX + 24, y: r.minY + 26), size: 34, color: Theme.text, weight: .light, width: r.width - 48)
            drawText(c.1, NSPoint(x: r.minX + 24, y: r.minY + 26 + 46), size: 18, color: k < 2 ? Theme.value : Theme.dim, weight: .regular, width: r.width - 48)
            for (i, line) in c.3.enumerated() {
                drawText(line, NSPoint(x: r.minX + 24, y: r.minY + 130 + CGFloat(i) * 30), size: 15, color: Theme.hint, weight: .regular, width: r.width - 48)
            }
            let go = NSRect(x: r.minX + 24, y: r.maxY - 24 - 56, width: r.width - 48, height: 56)
            (k < 2 ? hex(0xdcdfe1) : Theme.panel2).setFill(); NSBezierPath(roundedRect: go, xRadius: 3, yRadius: 3).fill()
            drawTextV(k < 2 ? "START" : "SKIP", go, size: 16, color: k < 2 ? hex(0x1e2022) : Theme.text, weight: .bold, center: true, tracking: 0.08)
            let kind = c.5
            buttons.append((r, { [weak self] in
                guard let self else { return }
                self.link.send(["cmd": "new_beat", "kind": kind])
                self.state["fresh"] = false
                if !kind.isEmpty { self.noticeText = "Building your beat…"; self.noticeAt = Date() }
                self.needsDisplay = true
            }))
        }
    }

    // KEY: one panel — root notes on top, scales below, DONE (tap outside, MENU or MAIN close it too)
    var keyEdit = false
    func pickKey() { keyEdit.toggle(); tempoEdit = false; jogFocusId = nil; showPicker = false; choice = nil; needsDisplay = true }
    func closeOverlays() -> Bool {
        let open = keyEdit || tempoEdit || choice != nil || clipSheet != nil || fxPick
        keyEdit = false; tempoEdit = false; choice = nil; clipSheet = nil; fxPick = false
        if open { needsDisplay = true }
        return open
    }
    func drawKeyEdit() {
        let c = mpcWindow("Key & scale", width: 1180, height: 470) { [weak self] in self?.keyEdit = false; self?.needsDisplay = true }
        let root = songInfo["root"] as? Int ?? 0, scale = songInfo["scale"] as? String ?? ""
        let mw = (c.width - 8 - 11 * 3) / 12
        mpcSeg(c.minX, c.minY, label: "Root", ScreenView.rootNames, selected: root, h: 56, minW: mw) { [weak self] i in
            self?.link.send(["cmd": "song_set", "what": "root", "value": i]) }
        let sy = c.minY + lineH(12) + 6 + 56 + 22
        drawText("SCALE", NSPoint(x: c.minX, y: sy), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        let cols = 4, w = (c.width - CGFloat(cols - 1) * 8) / CGFloat(cols), h: CGFloat = 52
        for (i, sc) in ScreenView.scaleNames.enumerated() {
            let r = NSRect(x: c.minX + CGFloat(i % cols) * (w + 8), y: sy + lineH(12) + 6 + CGFloat(i / cols) * (h + 8), width: w, height: h)
            if r.maxY > c.maxY + 8 { break }
            button(r, sc, on: sc == scale, size: 16) { [weak self] in self?.link.send(["cmd": "song_set", "what": "scale", "value": sc]) }
        }
    }

    // tempo: big value with steps (TAP on the Touch still taps the tempo)
    func drawTempoEdit() {
        let c = mpcWindow("Tempo", width: 820, height: 400) { [weak self] in self?.tempoEdit = false; self?.jogFocusId = nil; self?.needsDisplay = true }
        let tempo = songInfo["tempo"] as? Double ?? 120
        drawText("BPM · turn the wheel or tap the steps · TAP on the Touch taps it", NSPoint(x: c.minX, y: c.minY), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        let vr = NSRect(x: c.minX, y: c.minY + 22, width: c.width, height: 90)
        drawText(String(format: "%.2f", tempo), NSPoint(x: vr.minX, y: vr.minY), size: 80, color: Theme.value, weight: .light, center: true, width: vr.width)
        focusable(vr.insetBy(dx: 240, dy: 0), "bpm", radius: 4) { [weak self] d in self?.stripTurn("bpm", d) }
        let steps: [Double] = [-10, -1, -0.1, 0.1, 1, 10]
        let w = (c.width - 5 * 8) / 6
        for (k, st) in steps.enumerated() {
            mpcButton(NSRect(x: c.minX + CGFloat(k) * (w + 8), y: vr.maxY + 18, width: w, height: 64), (st > 0 ? "+" : "−") + (abs(st) < 1 ? "0.1" : String(Int(abs(st)))), size: 20) { [weak self] in
                guard let self else { return }
                let v = (((self.songInfo["tempo"] as? Double ?? 120) + st) * 100).rounded() / 100
                self.link.send(["cmd": "song_set", "what": "tempo", "value": v])
                if var si = self.state["song"] as? [String: Any] { si["tempo"] = v; self.state["song"] = si }
                self.needsDisplay = true
            }
        }
        let q = songInfo["quant"] as? Int ?? 4, metro = songInfo["metronome"] as? Bool ?? false
        let qn = q < ScreenView.quantNames.count ? ScreenView.quantNames[q] : "?"
        let fy = vr.maxY + 18 + 64 + 22
        mpcField(NSRect(x: c.minX, y: fy, width: (c.width - 16) / 2, height: 80), label: "Clip launch quantise · tap", value: qn) { [weak self] in
            self?.tempoEdit = false; self?.jogFocusId = nil; self?.pickQuant() }
        mpcSeg(c.minX + (c.width + 16) / 2, fy, label: "Metronome", ["OFF", "ON"], selected: metro ? 1 : 0, h: 54, minW: ((c.width - 16) / 2 - 11) / 2) { [weak self] k in
            if (k == 1) != metro { self?.link.send(["cmd": "song_set", "what": "metronome"]) } }
    }

    var allTracks: [[String: Any]] { state["tracks"] as? [[String: Any]] ?? [] }
    var currentInstrument: String {
        if let t = allTracks.first(where: { $0["selected"] as? Bool ?? false }) {
            let inst = t["instrument"] as? String ?? ""
            if !inst.isEmpty { return inst }
            switch t["kind"] as? String ?? "" { case "audio": return "Audio"; case "empty": return "Empty"; default: return "" }
        }
        return ""
    }

    // the track picker: every track as a tile with its instrument; tap = go there
    func drawTrackPicker() {
        let tracks = allTracks
        let cols = 4, gap: CGFloat = 10, tileH: CGFloat = 96
        let rowsN = CGFloat((tracks.count + 2 + cols - 1) / cols)
        let c = mpcWindow("Tracks · tap one to go there", width: bounds.width - 32, height: 48 + 16 + rowsN * (tileH + gap) - gap + 16) { [weak self] in
            self?.showPicker = false; self?.needsDisplay = true }
        pickerOrigin = c.origin; pickerWidth = c.width
        defer { drawNewTrackTiles(after: tracks.count) }
        let tileW = (c.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, t) in tracks.enumerated() {
            let r = NSRect(x: c.minX + CGFloat(i % cols) * (tileW + gap), y: c.minY + CGFloat(i / cols) * (tileH + gap), width: tileW, height: tileH)
            if r.maxY > bounds.height - 8 { break }
            let sel = t["selected"] as? Bool ?? false
            let tc = Theme.live(t["color"] as? Int)
            (sel ? hex(0x3a3e42) : Theme.panel2).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).setClip()
            tc.setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: 4).fill()
            NSGraphicsContext.restoreGraphicsState()
            if sel { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4); o.lineWidth = 1.5; o.stroke() }
            let kind = t["kind"] as? String ?? ""
            let label: String = {
                let inst = t["instrument"] as? String ?? ""
                switch kind {
                case "drum": return "Drums · " + inst
                case "audio": return "Audio track"
                case "empty": return "Empty MIDI track"
                case "other": return "Return / Main"
                default: return inst
                }
            }()
            drawText(ScreenView.undated(t["name"] as? String ?? ""), NSPoint(x: r.minX + 16, y: r.minY + 18), size: 22, color: Theme.text, weight: .regular, width: r.width - 28)
            drawText(label, NSPoint(x: r.minX + 16, y: r.minY + 54), size: 15, color: Theme.faint, weight: .regular, width: r.width - 28)
            let index = t["index"] as? Int ?? i
            buttons.append((r, { [weak self] in
                guard let self else { return }
                self.link.send(["cmd": "pick_track", "index": index]); self.showPicker = false
                if self.page != .session && self.page != .device { self.page = .steps; self.lastTrackName = "" }   // its own page follows
                self.needsDisplay = true
            }))
        }
    }

    // "+ MIDI track" / "+ Audio track" at the end of the picker: a new track after the selected one
    var pickerOrigin = NSPoint(x: 16, y: 120), pickerWidth: CGFloat = 1248     // the picker window's content (set while drawing it)
    func drawNewTrackTiles(after count: Int) {
        let cols = 4, gap: CGFloat = 10, tileW = (pickerWidth - gap * CGFloat(cols - 1)) / CGFloat(cols), tileH: CGFloat = 96
        for (k, (title, kind)) in [("+  MIDI track", "midi"), ("+  Audio track", "audio")].enumerated() {
            let i = count + k
            let r = NSRect(x: pickerOrigin.x + CGFloat(i % cols) * (tileW + gap), y: pickerOrigin.y + CGFloat(i / cols) * (tileH + gap), width: tileW, height: tileH)
            if r.maxY > bounds.height - 8 { break }
            hex(0x4a4e52).setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            o.lineWidth = 1; o.setLineDash([5, 4], count: 2, phase: 0); o.stroke()
            drawText(title, NSPoint(x: r.minX, y: r.midY - 13), size: 20, color: Theme.hint, weight: .regular, center: true, width: r.width)
            buttons.append((r, { [weak self] in
                guard let self else { return }
                self.link.send(["cmd": "new_track", "kind": kind]); self.showPicker = false
                self.page = kind == "audio" ? .session : .steps; self.lastTrackName = ""      // MIDI: the "load something" page
                self.needsDisplay = true
            }))
        }
    }

    // while COPY / DELETE is held on the Touch: say what a tap will do
    func drawModifierBanner() {
        guard let m = modifier, m != "shift" else { return }
        let del = m == "delete"
        let r = NSRect(x: 0, y: bounds.height - 56, width: bounds.width, height: 56)
        (del ? hex(0xa93744) : hex(0x2f5f94)).setFill(); r.fill()
        let copyText = copySrc == nil ? "COPY  —  tap the clip to copy  (or a track name / scene to duplicate it)"
                                      : "COPY  —  tap where to paste it  ·  release COPY = paste in the slot below"
        drawText(del ? "DELETE  —  tap a clip, track name or scene to remove it  (UNDO brings it back)" : copyText,
                 NSPoint(x: 0, y: r.midY - lineH(19) / 2), size: 19, color: .white, weight: .regular, center: true, width: bounds.width)
    }

    // MARK: SAMPLE page
    func frameToX(_ f: Double) -> CGFloat { waveRect.minX + CGFloat((f - viewStart) / max(1, viewEnd - viewStart)) * waveRect.width }
    func xToFrame(_ x: CGFloat) -> Double { viewStart + Double((x - waveRect.minX) / waveRect.width) * (viewEnd - viewStart) }

    // SIMPLER (mockup Sampler): [CLASSIC ONE-SHOT SLICE · hint ······ LOAD SAMPLE · REC SAMPLE] [CHOP row, Slice only]
    // [waveform 290 high] [Q-LINKS: 4 values + REVERSE NORMALIZE CROP WARP]  [PADS PLAY 360: what the pads do (+ SLICES → DRUM PADS)]
    static let chopYellow = hex(0xffd23f)
    var sliceMode: Bool { (simpler?["mode"] as? String) == "Slice" }
    func autoButton(_ x: inout CGFloat, _ y: CGFloat, _ title: String, on: Bool, color: NSColor, ink: NSColor, h: CGFloat = 48, rightToLeft: Bool = false,
                    action: @escaping () -> Void) {
        let w = textW(title, size: 15) + 36
        let r = NSRect(x: rightToLeft ? x - w : x, y: y, width: w, height: h)
        button(r, title, size: 15, fill: on ? color : Theme.panel2, ink: on ? ink : Theme.text, action: action)
        x = rightToLeft ? r.minX - 8 : r.maxX + 8
    }
    func drawSample() {
        // MPC-2 layout (mockup "SAMPLE · chop"): strip 34 · red header 70 · ruler 24 · teal well 318 · parameters · F-keys 56
        let (pcol, pstripe) = ScreenView.pageColour[.sample]!
        mpcStrip()
        let s = simpler
        let padEdit = s?["pad"] as? [String: Any]
        let mode = s?["mode"] as? String ?? ""
        let file = s?["file"] as? String ?? ""
        let sm = state["sampling"] as? [String: Any] ?? [:]
        let recOn = sm["rec"] as? Bool ?? false
        let analysis = sampleKeys[file]
        let style = s?["style"] as? String ?? ""
        let fileName = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: #"\s*\[\d{4}-\d{2}-\d{2} \d{6}\]$"#, with: "", options: .regularExpression)   // (CROP / REVERSE copies' date)
        var hf: [HeaderField] = []
        if padEdit == nil && !file.isEmpty {
            if let k = analysis {
                if let b = k["bpm"] as? Double { hf.append(HeaderField(label: "Tempo", value: String(format: "%.1f BPM", b), action: { [weak self] in self?.analysisMenu(k) })) }
                hf.append(HeaderField(label: "Key", value: KeyDetect.looksLikeDrums(file) ? "drums · no key" : sampleKeyName(k), action: { [weak self] in self?.analysisMenu(k) }))
            } else { hf.append(HeaderField(label: "Analysis", value: "listening…", action: nil)) }
        }
        let tools: [Tool] = mode == "Slice" ? [
            Tool(glyph: "draw", on: style == "Manual", action: { [weak self] in self?.link.send(["cmd": "slice_style", "style": "Manual"]) }),
            Tool(glyph: "erase", on: false, action: { [weak self] in self?.link.send(["cmd": "chop_delete"]) }),
            Tool(glyph: "audition", on: false, action: { [weak self] in self?.link.send(["cmd": "chop_play"]) }),
            Tool(glyph: "zoom", on: false, action: { [weak self] in self?.zoom(by: 1e9) })] : (s == nil ? [] : [
            Tool(glyph: "zoom", on: false, action: { [weak self] in self?.zoom(by: 1e9) })])
        let recTool = Tool(glyph: recOn ? "stop" : "rec", on: recOn, action: { [weak self] in
                let src = recOn ? (sm["source"] as? String ?? "input") : "input"
                if src != "resample" { self?.expectSample = Date() }
                self?.link.send(["cmd": "rec_sample", "source": src]) },
            hold: { [weak self] in self?.link.send(["cmd": "rec_sample", "source": "resample"]) }, tint: hex(0xffb3ad))
        mpcHeader(pcol, icon: "wave",
                  name: HeaderField(label: padEdit != nil ? "Pad sample" : "Sample", value: padEdit.map { $0["name"] as? String ?? "" } ?? (fileName.isEmpty ? "No sample yet" : fileName),
                                    action: { [weak self] in self?.browseSamples() }),
                  fields: hf, tools: tools,
                  buttons: [Tool(glyph: "browse", on: false, action: { [weak self] in self?.browseSamples() }), recTool])
        let tabs = sampleTabs(padEdit != nil)
        guard let s else {
            let r = NSRect(x: 0, y: 104, width: bounds.width, height: bounds.height - 104 - 56)
            Theme.well.setFill(); r.fill()
            drawText("No sample here yet", NSPoint(x: 0, y: r.midY - 80), size: 30, color: Theme.text, weight: .light, center: true, width: bounds.width)
            drawText("load one from the browser, or record one — hold REC to resample your beat", NSPoint(x: 0, y: r.midY - 34), size: 17, color: Theme.hint, weight: .regular, center: true, width: bounds.width)
            mpcButton(NSRect(x: bounds.midX - 250, y: r.midY + 10, width: 240, height: 52), "LOAD SAMPLE", glyph: "browse", style: .light) { [weak self] in self?.browseSamples() }
            mpcButton(NSRect(x: bounds.midX + 10, y: r.midY + 10, width: 240, height: 52), recOn ? "STOP" : "REC SAMPLE", glyph: recOn ? "stop" : "rec", style: .red) { [weak self] in
                self?.expectSample = Date(); self?.link.send(["cmd": "rec_sample", "source": "input"]) }
            mpcFBar(tabs: tabs, actions: [], stripe: pstripe)
            return
        }
        let length = Double(s["length"] as? Int ?? 1)
        let slices = (s["slices"] as? [Int]) ?? []
        let startM = Double(s["start"] as? Int ?? 0), endM = Double(s["end"] as? Int ?? Int(length))
        let rate = Double(s["rate"] as? Int ?? 44100)

        // ruler (24): seconds of what's in view
        let r = waveRect
        hex(0x2a2d30).setFill(); NSRect(x: 0, y: r.minY - 24, width: bounds.width, height: 24).fill()
        Theme.line.setFill(); NSRect(x: 0, y: r.minY - 1, width: bounds.width, height: 1).fill()
        let spanS = (viewEnd - viewStart) / rate
        let stepS = [0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 30, 60].first { $0 >= spanS / 14 } ?? 60
        var tk = (viewStart / rate / stepS).rounded(.up) * stepS
        while tk * rate < viewEnd {
            let x = frameToX(tk * rate)
            hex(0x8a9095).setFill(); NSRect(x: x, y: r.minY - 24, width: 1, height: 6).fill()
            drawText(stepS < 0.1 ? String(format: "%.3f", tk) : (stepS < 1 ? String(format: "%.1f s", tk) : String(format: "%.0f s", tk)),
                     NSPoint(x: x + 4, y: r.minY - 23), size: 11, color: hex(0xa8aeb3), weight: .regular)
            tk += stepS
        }

        // the well: teal; the waveform light blue, white where you work (the chop you're on · or START–END in Classic / One-Shot)
        if (viewStart, viewEnd) != lastSentView { lastSentView = (viewStart, viewEnd); link.send(["cmd": "wave_view", "start": viewStart, "end": viewEnd]) }
        Theme.well.setFill(); r.fill()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r).setClip()
        var cuts = slices.map(Double.init)
        if case let .slice(i, _) = drag, i < slices.count { cuts = slices.enumerated().map { $0.offset == i ? Double(dragFrame) : Double($0.element) } }
        var sM = startM, eM = endM
        if case .start = drag { sM = Double(dragFrame) }
        if case .end = drag { eM = Double(dragFrame) }
        let sorted = cuts.sorted()
        var chopA: Double? = nil, chopB: Double? = nil, chopK: Int? = nil
        let curChop = waveFocus ?? ((state["wave_q"] as? [String: Any])?["slice"] as? Double)
        if mode == "Slice", let a = curChop, let k = sorted.firstIndex(where: { abs($0 - a) < 1 }) ?? (abs(a - sM) < 1 ? 0 : nil) {
            chopA = a; chopB = k + 1 < sorted.count ? sorted[k + 1] : eM; chopK = k
            let x0 = max(r.minX, frameToX(a)), x1 = min(r.maxX, frameToX(chopB!))
            if x1 > x0 { hex(0x2b6584).setFill(); NSRect(x: x0, y: r.minY, width: x1 - x0, height: r.height).fill() }
        }
        if !peaks.maxs.isEmpty {
            let mid = r.midY, h = r.height / 2 - 12, n = peaks.maxs.count, hop = Double(peaks.hop)
            let norm = CGFloat(1 / peaks.peak) * h
            let hiCol = hex(0xf2f6f8), loCol = hex(0x8db9c9)
            var x = r.minX
            while x < r.maxX {
                let f0 = xToFrame(x), f1 = xToFrame(x + 1)
                if f1 < 0 || f0 / hop >= Double(n) { x += 1; continue }
                let b0 = max(0, min(n - 1, Int(f0 / hop))), b1 = max(b0 + 1, min(n, Int(f1 / hop)))
                var lo: Float = 0, hi: Float = 0
                for b in b0..<b1 { lo = min(lo, peaks.mins[b]); hi = max(hi, peaks.maxs[b]) }
                let f = (f0 + f1) / 2
                let inside = f >= sM && f <= eM
                let lit = mode == "Slice" ? (chopA.map { f >= $0 && f < chopB! } ?? false) : inside
                (lit ? hiCol : loCol.withAlphaComponent(inside ? 1 : 0.35)).setFill()
                let top = mid - max(0.5, CGFloat(hi) * norm), bot = mid - min(-0.5, CGFloat(lo) * norm)
                NSRect(x: x, y: top, width: 1, height: bot - top).fill()
                x += 1
            }
            NSColor.white.withAlphaComponent(0.16).setFill(); NSRect(x: r.minX, y: mid - 0.5, width: r.width, height: 1).fill()
        } else {
            drawText("loading waveform…", NSPoint(x: r.minX, y: r.midY - 12), size: 18, color: Theme.hint, weight: .regular, center: true, width: r.width)
        }
        func tag(_ text: String, _ x: CGFloat, _ y: CGFloat, _ bg: NSColor, _ fg: NSColor, right: Bool = false) {
            let w = max(24, textW(text, size: 14, weight: .regular) + 10), t = NSRect(x: right ? x - w - 2 : x + 2, y: y, width: w, height: 24)
            bg.setFill(); NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2).fill()
            drawTextV(text, t, size: 14, color: fg, weight: .regular, center: true)
        }
        if mode == "Slice" {
            for f in cuts {
                let x = frameToX(f)
                guard x >= r.minX - 30 && x <= r.maxX + 10 else { continue }
                let sel = chopA.map { abs($0 - f) < 1 } ?? false
                (sel ? hex(0xf2f6f8) : hex(0x8fdca5)).setFill(); NSRect(x: x, y: r.minY, width: 1.5, height: r.height).fill()
                tag("\(cuts.filter { $0 < f }.count + 1)", x, r.minY + 8, sel ? .white : hex(0xa6e8bb), hex(0x13301d))
            }
            if let a = chopA, let b = chopB, ((state["wave_q"] as? [String: Any])?["bank"] as? Int ?? 0) == 0 {   // which knob moves which line (only on the CHOP Q page)
                for (q, fx, right) in [(0, frameToX(a), false), (1, frameToX(b), true)] where fx >= r.minX - 2 && fx <= r.maxX + 2 {
                    let on = touchedQ == q || (touchedQ == nil && activeQ == q)
                    tag("Q\(q + 1)", fx, r.maxY - 32, on ? Theme.accent : hex(0x4a4e52), on ? Theme.darkInk : Theme.text, right: right)
                }
            }
        }
        for (f, label) in [(sM, "S"), (eM, "E")] {
            let x = frameToX(f)
            guard x >= r.minX - 4 && x <= r.maxX + 4 else { continue }
            let editing = waveFocus.map { abs($0 - f) < 1 } ?? false && Date().timeIntervalSince(waveFocusAt) < 1.5
            (editing ? Theme.accent : hex(0xf2f6f8)).setFill(); NSRect(x: x - 0.75, y: r.minY, width: 1.5, height: r.height).fill()
            if label == "S" { tag("S", x, mode == "Slice" ? r.maxY - 32 - (chopK == 0 ? 30 : 0) : r.minY + 8, editing ? Theme.accent : hex(0x5cbf7a), hex(0x0f2a17)) }
            else { tag("E", x, r.maxY - 32, editing ? Theme.accent : hex(0xd9534f), .white, right: true) }
            focusable(NSRect(x: x - 2, y: r.minY + 2, width: 5, height: r.height - 4), "marker" + label, radius: 2) { [weak self] d in
                guard let self, let sm = self.simpler else { return }
                let len = Double(sm["length"] as? Int ?? 1)
                let stepF = max(1.0, (self.viewEnd - self.viewStart) / 500)
                let key = label == "S" ? "start" : "end"
                let cur = Double(sm[key] as? Int ?? 0)
                let nf = Int(max(0, min(len, cur + Double(d) * stepF)))
                self.link.send(["cmd": label == "S" ? "set_start" : "set_end", "at": nf])
                var s2 = sm; s2[key] = nf; self.state["simpler"] = s2
                self.waveFocus = Double(nf); self.waveFocusAt = Date()
            }
        }
        if let ph = playhead, Date().timeIntervalSince(lastPlayheadAt) < 0.5 {
            Theme.value.setFill(); NSRect(x: frameToX(ph * length) - 1, y: r.minY, width: 2, height: r.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // parameters (charcoal): Q fields + the Q-Link page · MODE · CHOP BY · PAD PLAYS · TIMESTRETCH + REVERSE NORMALIZE CROP
        let py = r.maxY, ph = bounds.height - 56 - py
        Theme.panel.setFill(); NSRect(x: 0, y: py, width: bounds.width, height: ph).fill()
        let wq = state["wave_q"] as? [String: Any] ?? [:]
        let qpages = wq["pages"] as? [String] ?? ["EDIT"], qbank = wq["bank"] as? Int ?? 0
        var q = wq["labels"] as? [[String]] ?? []
        func secs(_ f: Double) -> String { String(format: "%.3f s", f / rate) }
        if qbank == 0 { q = q.map { ($0.first ?? "") == "START" ? ["START", secs(sM)] : (($0.first ?? "") == "END" ? ["END", secs(eM)] : $0) } }
        let pageNames = qpages.enumerated().map { $0.offset == 0 ? (mode == "Slice" ? "CHOP" : "EDIT") : ($0.element == "AMP ENV" ? "AMP" : $0.element.uppercased()) }
        let (pbox, _) = mpcSeg(bounds.width - 18, py + 12, label: "Q-Link page", pageNames, selected: qbank, h: 40, rightAligned: true) { [weak self] k in
            self?.link.send(["cmd": "wave_bank", "bank": k]) }
        let fy = py + 12, fh: CGFloat = 76
        let fw = min(200, (pbox.minX - 30 - 18 - 30) / 4)
        for k in 0..<4 {
            let item = k < q.count ? q[k] : []
            let on = touchedQ == k || (touchedQ == nil && activeQ == k)
            mpcField(NSRect(x: 18 + CGFloat(k) * (fw + 10), y: fy, width: fw, height: fh), label: item.first ?? "–", value: item.count > 1 ? item[1] : "",
                     q: k + 1, active: on, mint: qbank == 0 && k < 2)
        }
        mpcRule(fy + fh + 12)
        // MODE · CHOP BY · PAD PLAYS (or LOOP in Classic)
        let ry = fy + fh + 26
        var sx: CGFloat = 18
        let modes = padEdit == nil ? ["Classic", "One-Shot", "Slice"] : ["Classic", "One-Shot"]
        let (mb, _) = mpcSeg(sx, ry, label: "Mode", modes.map { $0.uppercased() }, selected: modes.firstIndex(of: mode)) { [weak self] i in
            self?.link.send(["cmd": "simpler_mode", "mode": modes[i]]) }
        sx = mb.maxX + 22
        if mode == "Slice" {
            let st = ["Transient", "Region", "Manual", "Beat"]
            let (cb, _) = mpcSeg(sx, ry, label: "Chop by", ["TRANSIENT", "EQUAL", "MANUAL", "BPM"], selected: st.firstIndex(of: style)) { [weak self] i in
                var cmd: [String: Any] = ["cmd": "slice_style", "style": st[i]]
                if st[i] == "Region" { cmd["regions"] = 8 }
                self?.link.send(cmd) }
            sx = cb.maxX + 22
        }
        if mode == "Classic" {
            let loopOn = ((s["p_S Loop On"] as? [Any])?.last as? String) == "On"
            mpcSeg(sx, ry, label: "Loop", ["OFF", "ON"], selected: loopOn ? 1 : 0) { [weak self] i in
                if (i == 1) != loopOn { self?.link.send(["cmd": "simpler_action", "what": "loop_toggle"]) } }
        } else {
            let gate = ((s["p_Trigger Mode"] as? [Any])?.last as? String) == "Gate"
            mpcSeg(sx, ry, label: "Pad plays", ["ONE SHOT", "NOTE ON"], selected: gate ? 1 : 0) { [weak self] i in
                if (i == 1) != gate { self?.link.send(["cmd": "simpler_action", "what": "trigger_toggle"]) } }
        }
        // TIMESTRETCH (OFF STRETCH DRUMS PITCH) · REVERSE NORMALIZE CROP · CHOPS TO PADS
        let ty = ry + lineH(12) + 6 + 44 + 16
        let warping = s["warping"] as? Bool ?? false, wmode = s["warp_mode"] as? Int ?? 0
        let sbpm = analysis?["bpm"] as? Double
        let songT = songInfo["tempo"] as? Double ?? 0
        let pitching = warping && wmode == 3
        let nNow: Int? = sbpm.map { Int((12 * log2(max(1, songT) / $0)).rounded()) }
        if !pitching || pitchN == nNow { pitchN = nil }
        let shownN = pitchN ?? nNow ?? 0
        func warp(_ what: String) { jogFocusId = nil; var m: [String: Any] = ["cmd": "smart_warp", "what": what]; if let sbpm { m["bpm"] = sbpm }; link.send(m) }
        func pitch(_ n: Int) {
            guard let sbpm, !file.isEmpty else { return }
            let n = max(-7, min(7, n))
            pitchN = n
            var m: [String: Any] = (KeyDetect.looksLikeDrums(file) ? [:] : (sampleKeys[file] ?? [:])).filter { ["root", "minor", "single", "clarity", "named"].contains($0.key) }   // a drum loop never moves your key
            m.merge(["cmd": "pitch_semis", "bpm": sbpm, "semis": n, "file": file]) { $1 }
            link.send(m)
        }
        let pLabel = pitching && sbpm != nil ? String(format: "PITCH %@%d · %.1f", shownN > 0 ? "+" : (shownN == 0 ? "±" : ""), shownN, sbpm! * pow(2, Double(shownN) / 12)) : "PITCH"
        if jogFocusId == "pitch" && !pitching && pitchN == nil { jogFocusId = nil }   // left PITCH (UNDO, another mode): the wheel lets go
        let focused = jogFocusId == "pitch"
        let tsLabel = focused ? "Pitch · turn the wheel: semitones (your beat's tempo follows)"
                              : "Timestretch" + (sbpm.map { String(format: " · sample %.1f → beat %.1f", $0, songT) } ?? "")
        let sel = !warping ? 0 : (pitching ? 3 : (wmode == 0 ? 2 : 1))
        let (tb, trs) = mpcSeg(18, ty, label: tsLabel, ["OFF", "STRETCH", "DRUMS", pLabel], selected: sel, minW: 96) { [weak self] i in
            guard let self else { return }
            switch i {
            case 0: warp("off")
            case 1: warp("stretch")
            case 2: warp("drums")
            default:
                if sbpm == nil { return }
                if !pitching { pitch(nNow ?? 0) }
                self.jogFocusId = "pitch"; self.needsDisplay = true
            }
        }
        if trs.count == 4 { focusable(trs[3], "pitch", radius: 3) { d in pitch(shownN + (d > 0 ? 1 : -1)) } }
        let peak = Double(max(peaks.maxs.max() ?? 1, -(peaks.mins.min() ?? -1)))
        var bx = bounds.width - 18
        let by = tb.minY
        if mode == "Slice" && padEdit == nil {
            let w: CGFloat = 190
            mpcButton(NSRect(x: bx - w, y: by, width: w, height: 44), "CHOPS TO PADS", glyph: "kit", style: .light) { [weak self] in
                self?.link.send(["cmd": "simpler_action", "what": "slices_to_pads"]) }
            bx -= w + 14
        }
        for (title, what, g) in [("CROP", "crop", "crop"), ("NORMALIZE", "normalize", "normalize"), ("REVERSE", "reverse", "reverse")] {
            let w = textW(title, size: 14, weight: .bold, tracking: 0.07) + 26 + 30
            mpcButton(NSRect(x: bx - w, y: by, width: w, height: 44), title, glyph: g) { [weak self] in
                var m: [String: Any] = ["cmd": "simpler_action", "what": what]
                if what == "normalize" { m["peak"] = peak }
                self?.link.send(m) }
            bx -= w + 8
        }
        // F-keys: SAMPLE STEPS DEVICE · − ZOOM + · PLAY CHOP · CHOP +
        var actions: [FKey] = [FKey(glyph: nil, title: "ZOOM", weight: 1.4, action: {}, minus: { [weak self] in self?.zoom(by: 2.0) }, plus: { [weak self] in self?.zoom(by: 0.5) })]
        if mode == "Slice" {
            actions.append(FKey(glyph: "play", title: "PLAY CHOP", action: { [weak self] in self?.link.send(["cmd": "chop_play"]) }))
            actions.append(FKey(glyph: "chop", title: "CHOP +", action: { [weak self] in self?.link.send(["cmd": "chop_split"]) }))
        } else {
            actions.append(FKey(glyph: "zoom", title: "SHOW ALL", action: { [weak self] in self?.zoom(by: 1e9) }))
        }
        mpcFBar(tabs: tabs, actions: actions, stripe: pstripe)
    }

    // the F-bar's page tabs for a Simpler (SAMPLE · STEPS · DEVICE), or for a drum pad's sample (KIT · STEPS · DEVICE)
    func sampleTabs(_ padEdit: Bool) -> [FKey] {
        padEdit ? [FKey(glyph: "kit", title: "KIT", action: { [weak self] in self?.page = .pads; self?.needsDisplay = true }),
                   FKey(glyph: "steps", title: "STEPS", action: { [weak self] in self?.openSequencer() }),
                   FKey(glyph: "device", title: "DEVICE", action: { [weak self] in self?.page = .device; self?.needsDisplay = true })]
                : trackTabs(.sample)
    }

    // REC SAMPLE (Touch input) / RESAMPLE (your beat): press = start, press again = stop → into this Simpler
    func drawRecButtons(_ r: NSRect) {
        let sm = state["sampling"] as? [String: Any] ?? [:]
        let rec = sm["rec"] as? Bool ?? false, src = sm["source"] as? String ?? ""
        let w = (r.width - 8) / 2
        for (k, (title, source)) in [("REC SAMPLE", "input"), ("RESAMPLE", "resample")].enumerated() {
            let b = NSRect(x: r.minX + CGFloat(k) * (w + 8), y: r.minY, width: w, height: r.height)
            let active = rec && src == source
            if active && !animRects.contains(b) { animRects.append(b) }
            button(b, active ? "■ STOP" : title, size: 15, fill: active && !blinkOn ? Theme.red.withAlphaComponent(0.55) : (k == 0 || active ? Theme.red : Theme.panel2),
                   ink: k == 0 || active ? hex(0x2b0606) : Theme.text) { [weak self] in
                if source != "resample" { self?.expectSample = Date() }
                self?.link.send(["cmd": "rec_sample", "source": source]) }
        }
    }

    // (kept for the filter drag on the old SOUND panel; the SIMPLER page now follows the mockup)
    func sv(_ s: [String: Any], _ n: String) -> (Double, String) {
        let a = s["p_" + n] as? [Any] ?? []
        return (a.first as? Double ?? 0, a.count > 1 ? (a[1] as? String ?? "") : "")
    }
    var soundDrag: (name: String, start: Double, x: CGFloat, y: CGFloat, axis: String)? = nil
    var sliders: [(NSRect, String)] = []                        // filter graphic + gain / volume (drag areas)

    // zoom around the middle of the view, or around the slice being worked on
    // zoom glides to its target (~150 ms) instead of jumping; more zoom while gliding adds onto the target
    var zoomTarget: (Double, Double)? = nil
    var zoomTimer: Timer? = nil
    func zoom(by k: Double, around anchor: Double? = nil) {
        guard let s = simpler else { return }
        let length = Double(s["length"] as? Int ?? 1)
        var (ts, te) = zoomTarget ?? (viewStart, viewEnd)
        let span = te - ts
        let a = anchor ?? (ts + te) / 2
        let newSpan = max(256, min(length, span * k)), frac = max(0, min(1, (a - ts) / span))
        ts = a - frac * newSpan; te = ts + newSpan
        if ts < 0 { te -= ts; ts = 0 }
        if te > length { ts = max(0, ts - (te - length)); te = length }
        zoomTarget = (ts, te)
        if zoomTimer == nil {
            zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
                guard let self, let t = self.zoomTarget else { tm.invalidate(); self?.zoomTimer = nil; return }
                let ls = log(max(1, self.viewEnd - self.viewStart)), lt = log(max(1, t.1 - t.0))
                let nspan = exp(ls + (lt - ls) * 0.3)
                let mid = (self.viewStart + self.viewEnd) / 2, tmid = (t.0 + t.1) / 2
                let nmid = mid + (tmid - mid) * 0.3
                if abs(nspan - (t.1 - t.0)) < max(2, (t.1 - t.0) * 0.003) && abs(nmid - tmid) < max(2, (t.1 - t.0) * 0.003) {
                    self.viewStart = t.0; self.viewEnd = t.1; self.zoomTarget = nil; tm.invalidate(); self.zoomTimer = nil
                } else { self.viewStart = nmid - nspan / 2; self.viewEnd = nmid + nspan / 2 }
                self.setNeedsDisplay(self.waveRect.insetBy(dx: -20, dy: -20))
                self.setNeedsDisplay(NSRect(x: 0, y: self.bounds.height - 270, width: self.bounds.width, height: 270))
            }
        }
    }
    func clampView(_ length: Double) {
        if viewStart < 0 { viewEnd -= viewStart; viewStart = 0 }
        if viewEnd > length { viewStart -= viewEnd - length; viewEnd = length; viewStart = max(0, viewStart) }
    }

    // the song pages (MPC-2): slate header · F-keys SESSION · ARRANGE · MIXER (+ this page's actions)
    func songChrome(_ which: String, name: String, fields: [HeaderField] = [], tools: [Tool] = [], actions: [FKey] = []) -> () -> Void {
        let (pcol, pstripe) = ScreenView.pageColour[.session]!
        mpcStrip()
        mpcHeader(pcol, icon: which == "arrange" ? "arrange" : (which == "mixer" ? "mixer" : "session"),
                  name: HeaderField(label: which == "mixer" ? "Mixer" : (which == "arrange" ? "Song" : "Session"), value: name, action: nil), fields: fields, tools: tools)
        let tabs = [FKey(glyph: "session", title: "SESSION", on: which == "session", action: { [weak self] in
                        guard let self else { return }
                        if self.page != .session { self.show(.session) }
                        if self.arrangement != nil { self.link.send(["cmd": "toggle_view"]) } }),
                    FKey(glyph: "arrange", title: "ARRANGE", on: which == "arrange", action: { [weak self] in
                        guard let self else { return }
                        if self.page != .session { self.show(.session) }
                        if self.arrangement == nil { self.link.send(["cmd": "toggle_view"]) } }),
                    FKey(glyph: "mixer", title: "MIXER", on: which == "mixer", action: { [weak self] in self?.show(.mixer) })]
        return { [weak self] in self?.mpcFBar(tabs: tabs, actions: actions, stripe: pstripe) }
    }

    // MARK: SESSION page
    // SESSION (Push / MPC Clip Matrix style): readable at an angle — near-black background, outlined empty slots,
    // clip names in black or white depending on the colour, playing clips pulse on the beat, queued ones blink
    var animRects: [NSRect] = []                            // tiles that pulse / blink (redrawn ~12x a second)
    func beatPhase() -> Double {                            // 0..1 within the current beat, smooth between playhead messages
        let playing = state["playing"] as? Bool ?? false
        let tempo = state["tempo"] as? Double ?? 120
        let t = songTime + (playing ? Date().timeIntervalSince(lastPlayheadAt) * tempo / 60 : 0)
        return t - floor(t)
    }
    var blinkOn: Bool { Int(Date().timeIntervalSinceReferenceDate * 4) % 2 == 0 }

    func headerButtons(_ r: NSRect, track: Int, _ t: [String: Any]) {     // M  S  ●  (track index = absolute)
        let bw = min(40, (r.width - 12) / 3)
        let items: [(String, String, Bool, NSColor)] = [
            ("M", "mute", t["mute"] as? Bool ?? false, NSColor(srgbRed: 1.0, green: 0.78, blue: 0.2, alpha: 1)),
            ("S", "solo", t["solo"] as? Bool ?? false, NSColor(srgbRed: 0.3, green: 0.65, blue: 1.0, alpha: 1)),
            ("●", "arm", t["arm"] as? Bool ?? false, NSColor(srgbRed: 0.95, green: 0.25, blue: 0.25, alpha: 1))]
        for (k, (title, what, on, col)) in items.enumerated() {
            if what == "arm" && !(t["can_arm"] as? Bool ?? true) { continue }
            let b = NSRect(x: r.minX + CGFloat(k) * (bw + 4), y: r.minY, width: bw, height: r.height)
            onBand = arrangement != nil                       // (arrange headers are grey: darker off-state; session is black: grey)
            button(b, title, on: on, color: col, size: 15) { [weak self] in self?.link.send(["cmd": "track_toggle", "track": track, "what": what]) }
            onBand = false
        }
    }

    // SESSION (mockup): 4 columns (gap 10) of header 65 · clips 62 (gap 6) · M S ● ■ at the bottom; scene column 168:
    // overview 64 · scenes 62 · MIXER · STOP ALL. Tap a clip = launch; tap it again (or hold) = its clip sheet
    var clipSheet: (track: Int, scene: Int)? = nil           // absolute indices
    var lastClipTap: (track: Int, scene: Int, at: Date)? = nil
    func drawSession() {
        guard let sess = session, let tracks = sess["tracks"] as? [[String: Any]] else { return }
        animRects = []
        let scenes = sess["scenes"] as? [[String: Any]] ?? []
        let offset = sess["offset"] as? Int ?? 0, sceneOffset = sess["scene_offset"] as? Int ?? 0
        let total = allTracks.count                                 // more than fit: say which ones (swipe with 2 fingers for the rest)
        let trackPart = total > tracks.count ? "tracks \(offset + 1)–\(offset + tracks.count) of \(total)" : "\(tracks.count) tracks"
        let fbar = songChrome("session", name: trackPart + " · scenes \(sceneOffset + 1)–\(sceneOffset + 4)",
                              tools: [Tool(glyph: (state["playing"] as? Bool ?? false) ? "stop" : "play", on: state["playing"] as? Bool ?? false, action: { [weak self] in   // transport: play / stop (STOP ALL = the clips)
                                  self?.link.send(["cmd": "transport", "what": "play"]) })],
                              actions: [FKey(glyph: "stop", title: "STOP ALL", action: { [weak self] in self?.link.send(["cmd": "stop_all"]) }),
                                        FKey(glyph: "capture", title: "CAPTURE", action: { [weak self] in self?.link.send(["cmd": "capture"]) }),   // what you just played → a clip
                                        FKey(glyph: "add", title: "NEW TRACK", action: { [weak self] in self?.showPicker = true; self?.needsDisplay = true })])
        defer { fbar() }
        let top = topH + 10, bottom = bounds.height - 56 - 8
        let sceneW: CGFloat = 168, cols = max(4, tracks.count)
        let colW = (bounds.width - 32 - 10 - sceneW - CGFloat(cols - 1) * 10) / CGFloat(cols)
        let headH = 3 + 8 + lineH(20) + lineH(13) + 8 + 3
        let rows = 4                                                  // 4 clip rows (tall, easy to hit); below: the record strip
        let stripH: CGFloat = 60
        let colBottom = bottom - stripH - 12
        let clipH = (colBottom - 6 - 56 - (top + 6 + headH + 6)) / CGFloat(rows) - 6
        let pulse = 0.5 + 0.5 * cos(beatPhase() * 2 * .pi)
        Theme.bg.setFill(); NSRect(x: 0, y: topH, width: bounds.width, height: bounds.height - topH).fill()
        for (ti, t) in tracks.enumerated() {
            let colR = NSRect(x: 16 + CGFloat(ti) * (colW + 10), y: top, width: colW, height: colBottom - top)
            let tc = Theme.live(t["color"] as? Int)
            let selected = t["selected"] as? Bool ?? false
            if selected { hex(0x2f2e35).setFill(); NSBezierPath(roundedRect: colR, xRadius: 4, yRadius: 4).fill() }
            let x = colR.minX + 6, w = colR.width - 12
            // header: name + instrument (tap = select, tap again = its page; COPY / DELETE held = duplicate / delete)
            let hr = NSRect(x: x, y: colR.minY + 6, width: w, height: headH)
            let muted = t["mute"] as? Bool ?? false
            let hc = muted ? hex(0x55545c) : tc
            (selected ? hex(0x3a3e42) : Theme.panel2).setFill(); NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: hr, xRadius: 3, yRadius: 3).setClip()
            hc.setFill(); NSRect(x: hr.minX, y: hr.minY, width: hr.width, height: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            if selected { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: hr.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
            drawText(ScreenView.undated(t["name"] as? String ?? ""), NSPoint(x: hr.minX + 15, y: hr.minY + 11), size: 20, color: Theme.text, weight: .regular, width: hr.width - 30)
            drawText(t["instrument"] as? String ?? "", NSPoint(x: hr.minX + 15, y: hr.minY + 11 + lineH(20)), size: 13, color: Theme.faint, weight: .regular, width: hr.width - 30)
            buttons.append((hr, { [weak self] in
                guard let self else { return }
                if self.modifier == nil || self.modifier == "shift" { _ = self.trackTapped(offset + ti, selected: selected) }
                self.link.send(["cmd": "touch_track", "track": ti]) }))
            let clips = t["clips"] as? [[String: Any]] ?? []
            let trackPlays = clips.contains { ($0["playing"] as? Bool ?? false) } || (t["playing"] as? Bool ?? false)
            for (si, c) in clips.enumerated() where si < rows {
                let r = NSRect(x: x, y: hr.maxY + 6 + CGFloat(si) * (clipH + 6), width: w, height: clipH)
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                if c["empty"] as? Bool ?? false {
                    hex(0x2a2c2f).setFill(); path.fill()                 // an empty slot: plain (MPC)
                    let trig = c["triggered"] as? Bool ?? false
                    if trig {                                            // recording will start here: blink a red dot
                        animRects.append(r)
                        (blinkOn ? Theme.red : Theme.red.withAlphaComponent(0.35)).setFill()
                        NSBezierPath(ovalIn: NSRect(x: r.minX + 12, y: r.minY + 12, width: 12, height: 12)).fill()
                    } else if trackPlays {                               // this track plays a clip: tapping here stops it
                        Theme.faint.setFill(); NSRect(x: r.minX + 12, y: r.minY + 14, width: 8, height: 8).fill()
                    }
                } else {
                    var cc = Theme.live(c["color"] as? Int)
                    let playing = c["playing"] as? Bool ?? false, trig = c["triggered"] as? Bool ?? false, rec = c["recording"] as? Bool ?? false
                    if muted { cc = hex(0x55545c) }
                    else if !(playing || rec) { cc = cc.blended(withFraction: 0.38, of: Theme.panel)! }   // stopped: the colour, quieter
                    cc.setFill(); path.fill()
                    if playing || rec || trig { animRects.append(r.insetBy(dx: -4, dy: -4)) }
                    let ink = Theme.ink(cc)
                    let mark = NSRect(x: r.minX + 10, y: r.minY + 12, width: 12, height: 12)
                    if rec { Theme.red.setFill(); NSBezierPath(ovalIn: mark).fill() }
                    else { drawIcon(.play, mark, (trig && !blinkOn) ? ink.withAlphaComponent(0.3) : ink) }
                    drawText(c["name"] as? String ?? "", NSPoint(x: mark.maxX + 6, y: r.minY + 8), size: 16, color: ink, weight: .regular, width: r.width - 40)
                    if let beats = c["beats"] as? Double, w > 140, r.height > 70 {
                        let bars = beats / 4
                        var badge = bars >= 1 ? (bars == bars.rounded() ? "\(Int(bars))" : String(format: "%.1f", bars)) + (bars == 1 ? " bar" : " bars") : "\(Int(beats)) beats"
                        if c["legato"] as? Bool ?? false { badge += " · legato" }
                        drawText(badge, NSPoint(x: r.minX + 10, y: r.minY + 8 + lineH(16)), size: 12, color: ink.withAlphaComponent(0.65), weight: .regular, width: r.width - 20)
                    }
                    if playing || rec {                                  // where it is in its loop
                        let prog = CGFloat(c["progress"] as? Double ?? 0)
                        let pb = NSRect(x: r.minX + 10, y: r.maxY - 12, width: r.width - 20, height: 3)
                        ink.withAlphaComponent(0.2).setFill(); NSBezierPath(roundedRect: pb, xRadius: 1.5, yRadius: 1.5).fill()
                        ink.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect: NSRect(x: pb.minX, y: pb.minY, width: max(3, pb.width * prog), height: 3), xRadius: 1.5, yRadius: 1.5).fill()
                    } else if trig {
                        NSColor.white.setStroke(); let d = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                        d.lineWidth = 1.5; d.setLineDash([6, 4], count: 2, phase: 0); d.stroke()
                    }
                    if let cs = clipSheet, cs.track == offset + ti, cs.scene == sceneOffset + si {
                        NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4); o.lineWidth = 4; o.stroke()
                    }
                }
                if let src = copySrc, src == [ti, si] {
                    Theme.palette[6].color.setStroke()
                    let o = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4); o.lineWidth = 5; o.stroke()
                }
                let hasClip = !(c["empty"] as? Bool ?? false)
                if let mod = modifier, mod != "shift" {          // ERASE / COPY held: act on touch (no tap-vs-hold wait)
                    buttons.append((r, { [weak self] in
                        guard let self else { return }
                        self.clipTapped(ti, si, offset: offset, sceneOffset: sceneOffset, hasClip: hasClip)
                        if mod == "delete" && hasClip, var sess = self.state["session"] as? [String: Any],
                           var trs = sess["tracks"] as? [[String: Any]], ti < trs.count, var cl = trs[ti]["clips"] as? [[String: Any]], si < cl.count {
                            cl[si] = ["empty": true]; trs[ti]["clips"] = cl; sess["tracks"] = trs; self.state["session"] = sess   // gone at once
                        }
                        self.needsDisplay = true
                    }))
                    continue
                }
                holdables.append((r, tap: { [weak self] in self?.clipTapped(ti, si, offset: offset, sceneOffset: sceneOffset, hasClip: hasClip) },
                                     hold: { [weak self] in
                                         guard let self else { return }
                                         if hasClip && self.modifier == nil { self.clipSheet = (offset + ti, sceneOffset + si); self.needsDisplay = true }
                                         else { self.link.send(["cmd": "open_clip", "track": ti, "scene": si]) } }))
            }
            // M  S  ● (grid 3, gap 6, 56 high — big enough to hit while playing; stop = the ■ in an empty slot)
            let bw = (w - 2 * 6) / 3, by = colR.maxY - 6 - 56          // (directly under the 4 clips)
            let items: [(String, String, Bool, NSColor, NSColor)] = [
                ("M", "mute", muted, hex(0xffc83d), hex(0x241c00)),
                ("S", "solo", t["solo"] as? Bool ?? false, Theme.palette[6].color, hex(0x08142b)),
                ("●", "arm", t["arm"] as? Bool ?? false, Theme.red, hex(0x2b0606))]
            for (k, (title, what, on, _, _)) in items.enumerated() {
                if what == "arm" && !(t["can_arm"] as? Bool ?? true) { continue }
                let b = NSRect(x: x + CGFloat(k) * (bw + 6), y: by, width: bw, height: 56)
                let bp = NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3)
                (on && what != "arm" ? (what == "solo" ? Theme.value : Theme.active) : hex(0x33363a)).setFill(); bp.fill()
                if on && what == "arm" { Theme.red.setStroke(); let o = NSBezierPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
                drawTextV(title, b, size: 16, color: on ? (what == "arm" ? Theme.red : Theme.darkInk) : Theme.text, weight: .regular, center: true)
                buttons.append((b.insetBy(dx: -3, dy: -3), { [weak self] in
                    if what == "stop" { self?.link.send(["cmd": "stop_track", "track": ti]) }
                    else { self?.link.send(["cmd": "track_toggle", "track": offset + ti, "what": what]) }
                }))
            }
        }
        // scene column (168): overview 64 · scenes · MIXER · STOP ALL (gap 8)
        let sx = bounds.width - 16 - sceneW
        let ovR = NSRect(x: sx, y: top, width: sceneW, height: 64)
        let ov = (sess["overview"] as? [String]) ?? tracks.map { t in
            String(((t["clips"] as? [[String: Any]]) ?? []).map { c in (c["empty"] as? Bool ?? false) ? "." : ((c["playing"] as? Bool ?? false) ? "p" : "c") }) }
        _ = (ovR, ov)
        drawTextV("SCENES", NSRect(x: sx, y: top + 6, width: sceneW, height: headH), size: 12, color: Theme.dim, weight: .regular, center: true, tracking: 0.11)
        for si in 0..<rows {
            let r = NSRect(x: sx, y: top + 6 + headH + 6 + CGFloat(si) * (clipH + 6), width: sceneW, height: clipH)   // level with the clips
            let sc = si < scenes.count ? scenes[si] : [:]
            let sel = sc["selected"] as? Bool ?? false
            let name = (sc["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(sceneOffset + si + 1)"
            if sc["triggered"] as? Bool ?? false { animRects.append(r) }
            let lit = sel || ((sc["triggered"] as? Bool ?? false) && blinkOn)
            (lit ? hex(0x4a4e52) : Theme.panel2).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let ink = Theme.text
            drawIcon(.play, NSRect(x: r.minX + 12, y: r.midY - 6, width: 12, height: 12), ink)
            drawTextV(name, r, x: r.minX + 30, size: 17, color: ink, weight: .regular)
            buttons.append((r, { [weak self] in self?.link.send(["cmd": "touch_scene", "scene": si]) }))
        }
        // more scenes: ▲ ▼ (4 at a time), level with the M S ● row
        let navY = colBottom - 6 - 56, navW = (sceneW - 8) / 2
        mpcButton(NSRect(x: sx, y: navY, width: navW, height: 56), "", glyph: "up") { [weak self] in self?.link.send(["cmd": "scene_scroll", "by": -4]) }
        mpcButton(NSRect(x: sx + navW + 8, y: navY, width: navW, height: 56), "", glyph: "down") { [weak self] in self?.link.send(["cmd": "scene_scroll", "by": 4]) }
        drawLoopRecorder(NSRect(x: 16, y: bottom - stripH, width: bounds.width - 32, height: stripH))
        if clipSheet != nil { drawClipSheet(tracks, offset: offset, sceneOffset: sceneOffset) }
    }

    // the record strip (the hardware REC / OVERDUB do the recording): what REC will do — on which track, into which slot,
    // how long — and while recording the bar it's on; LENGTH 1·2·4·8·FREE, COUNT-IN and METRO (no buttons for those)
    func drawLoopRecorder(_ r: NSRect) {
        let lr = state["looprec"] as? [String: Any] ?? [:]
        let bars = lr["bars"] as? Int ?? 2, rec = lr["rec"] as? Bool ?? false, prog = CGFloat(lr["progress"] as? Double ?? 0)
        let countIn = lr["count_in"] as? Int ?? 0, overdub = lr["overdub"] as? Bool ?? false, metro = lr["metro"] as? Bool ?? false
        let counting = lr["counting"] as? Bool ?? false, bar = lr["bar"] as? Int ?? 1
        let tname = lr["track"] as? String ?? "", next = lr["next"] as? Int ?? 1, playingSlot = lr["playing"] as? Int ?? 0
        let live = rec || counting || overdub
        (live ? hex(0x3a1c1f) : Theme.panel).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        if live { animRects.append(r) }
        // status (what REC does / is doing)
        let sw: CGFloat = 400, x0 = r.minX + 18
        let head: String, big: String
        if counting { head = "COUNT-IN on " + tname; big = "get ready…" }
        else if rec { head = "RECORDING on " + tname; big = bars > 0 ? "bar \(min(bars, bar)) of \(bars)" : "bar \(bar) · REC = stop" }
        else if overdub { head = "OVERDUB on " + tname; big = playingSlot > 0 ? "adding to clip \(playingSlot)" : "start a clip to add to it" }
        else { head = "REC records on " + tname; big = bars > 0 ? "slot \(next) · \(bars) bar\(bars == 1 ? "" : "s") · then loops" : "slot \(next) · until REC again" }
        if live && !blinkOn || !live { (live ? Theme.red : Theme.faint).setFill() } else { Theme.red.withAlphaComponent(0.4).setFill() }
        NSBezierPath(ovalIn: NSRect(x: x0, y: r.midY - 6, width: 12, height: 12)).fill()
        let line = counting ? "COUNT-IN on \(tname) · get ready…" : (rec || overdub ? head + " · " + big : (bars > 0 ? "REC records \(bars) bar\(bars == 1 ? "" : "s") into slot \(next) · then loops" : "REC records into slot \(next) · until REC again"))
        drawTextV(line, NSRect(x: x0 + 22, y: r.minY, width: r.width - 520, height: r.height), size: 20, color: live ? hex(0xff9a9a) : Theme.text, weight: .light)
        if rec && bars > 0 {                                     // progress along the bottom of the strip
            Theme.red.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 14, y: r.maxY - 7, width: (r.width - 28) * prog, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        // LENGTH 1 2 4 8 FREE · COUNT-IN · METRO (segments, right)
        let sh: CGFloat = 40, sy = r.midY - sh / 2
        let opts = [1, 2, 4, 8, 0]
        let (mb, _) = mpcSeg(r.maxX - 14, sy, ["COUNT-IN", "METRO"], selected: nil, h: sh, rightAligned: true) { [weak self] k in
            if k == 0 { self?.link.send(["cmd": "count_in", "value": countIn > 0 ? 0 : 1]) } else { self?.link.send(["cmd": "song_set", "what": "metronome"]) } }
        // (both can be on: draw their state over the segment)
        let half = (mb.width - 8 - 3) / 2
        for (k, onNow) in [countIn > 0, metro].enumerated() where onNow {
            let rr = NSRect(x: mb.minX + 4 + CGFloat(k) * (half + 3), y: mb.minY + 4, width: half, height: mb.height - 8)
            Theme.active.setFill(); NSBezierPath(roundedRect: rr, xRadius: 2, yRadius: 2).fill()
            drawTextV(k == 0 ? "COUNT-IN" : "METRO", rr, size: 15, color: Theme.darkInk, weight: .bold, center: true, tracking: 0.07)
        }
        let (lb, _) = mpcSeg(mb.minX - 14, sy, ["1", "2", "4", "8", "FREE"], selected: opts.firstIndex(of: bars), h: sh, minW: 40, rightAligned: true) { [weak self] k in
            guard let self else { return }
            self.link.send(["cmd": "loop_len", "bars": opts[k]])
            if var l = self.state["looprec"] as? [String: Any] { l["bars"] = opts[k]; self.state["looprec"] = l; self.needsDisplay = true } }
        drawTextV("LENGTH", NSRect(x: lb.minX - 70, y: sy, width: 62, height: sh), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
    }

    // tap = launch (like Ableton); the same clip again within a few seconds = its clip sheet (no relaunch)
    func clipTapped(_ ti: Int, _ si: Int, offset: Int, sceneOffset: Int, hasClip: Bool) {
        let key = (offset + ti, sceneOffset + si)
        if modifier == nil && hasClip, let l = lastClipTap, l.track == key.0, l.scene == key.1, Date().timeIntervalSince(l.at) < 4 {
            lastClipTap = nil; clipSheet = key; needsDisplay = true; return
        }
        lastClipTap = (key.0, key.1, Date())
        link.send(["cmd": "touch_clip", "track": ti, "scene": si])
    }

    // the clip sheet (mockup): 290 high, colour edge on top · CLIP name · track · DONE · 4 panels
    func drawClipSheet(_ tracks: [[String: Any]], offset: Int, sceneOffset: Int) {
        guard let cs = clipSheet else { return }
        let ti = cs.track - offset, si = cs.scene - sceneOffset
        guard ti >= 0, ti < tracks.count, let clips = tracks[ti]["clips"] as? [[String: Any]], si >= 0, si < clips.count,
              !(clips[si]["empty"] as? Bool ?? false) else { clipSheet = nil; return }
        let c = clips[si], t = tracks[ti]
        let cc = Theme.live(c["color"] as? Int)
        buttons.append((NSRect(x: 0, y: 34, width: bounds.width, height: bounds.height - 34 - 56), { [weak self] in self?.clipSheet = nil; self?.needsDisplay = true }))   // tap outside = close (the F-keys stay usable)
        // a sheet above the F-keys (MPC-2 window style): name · LENGTH · LAUNCH · CLIP · COLOUR
        let r = NSRect(x: 16, y: bounds.height - 56 - 10 - 286, width: bounds.width - 32, height: 286)
        NSColor.black.withAlphaComponent(0.55).setFill(); NSRect(x: 0, y: 34, width: bounds.width, height: bounds.height - 34 - 56).fill()
        Theme.panel.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        hex(0x4a4e52).setStroke(); let ol = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); ol.lineWidth = 1; ol.stroke()
        let tb = NSRect(x: r.minX, y: r.minY, width: r.width, height: 52)
        hex(0x3a3e42).setFill(); NSBezierPath(roundedRect: tb, xRadius: 4, yRadius: 4).fill(); NSRect(x: tb.minX, y: tb.maxY - 4, width: tb.width, height: 4).fill()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).setClip()
        cc.setFill(); NSRect(x: r.minX, y: r.minY, width: 4, height: tb.height).fill(); NSGraphicsContext.restoreGraphicsState()
        buttons.append((r, {}))                                                                          // (taps on the sheet itself stay)
        func send(_ what: String, _ value: Any? = nil) {
            var m: [String: Any] = ["cmd": "clip_edit", "track": cs.track, "scene": cs.scene, "what": what]
            if let value { m["value"] = value }
            link.send(m)
        }
        let name = c["name"] as? String ?? ""
        let title = (name.isEmpty ? "Clip" : name)
        drawTextV(title, NSRect(x: r.minX + 18, y: tb.minY, width: 560, height: tb.height), size: 22, color: Theme.text, weight: .regular)
        drawTextV(ScreenView.undated(t["name"] as? String ?? "") + ((c["midi"] as? Bool ?? true) ? " · MIDI" : " · audio") + " · scene \(cs.scene + 1)",
                  NSRect(x: r.minX + 18 + min(560, textW(title, size: 22)) + 14, y: tb.minY, width: 420, height: tb.height), size: 14, color: Theme.dim, weight: .regular)
        mpcButton(NSRect(x: r.maxX - 12 - 100, y: tb.minY + 8, width: 100, height: 36), "DONE", style: .light) { [weak self] in
            self?.clipSheet = nil; self?.needsDisplay = true }
        let py = tb.maxY + 14, ph = r.maxY - 16 - py
        let pw = (r.width - 36 - 36) / 4
        let panels = (0..<4).map { NSRect(x: r.minX + 18 + CGFloat($0) * (pw + 12), y: py, width: pw, height: ph) }
        func label(_ p: NSRect, _ t: String) { drawText(t, NSPoint(x: p.minX, y: p.minY), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11) }
        let top = lineH(12) + 8
        // LENGTH
        var p = panels[0]
        label(p, "LENGTH")
        let beats = c["beats"] as? Double ?? 4, bars = beats / 4
        let lenText = bars >= 1 ? (bars == bars.rounded() ? "\(Int(bars))" : String(format: "%.1f", bars)) + (bars == 1 ? " bar" : " bars") : "\(Int(beats)) beats"
        mpcField(NSRect(x: p.minX, y: p.minY + top, width: p.width, height: 96), label: "Loop", value: lenText, mint: true, valueSize: 34)
        let hw = (p.width - 8) / 2
        mpcButton(NSRect(x: p.minX, y: p.maxY - 44, width: hw, height: 44), "HALF", glyph: "left") { send("halve") }
        mpcButton(NSRect(x: p.minX + hw + 8, y: p.maxY - 44, width: hw, height: 44), "DOUBLE", glyph: "right") { send("double") }
        // LAUNCH
        p = panels[1]
        label(p, "LAUNCH")
        let leg = c["legato"] as? Bool ?? false
        mpcSeg(p.minX, p.minY + top, ["FROM START", "LEGATO"], selected: leg ? 1 : 0, h: 44, minW: (p.width - 11) / 2) { k in if (k == 1) != leg { send("legato") } }
        drawPara(leg ? "Takes over at the same spot in the loop: seamless switching between variations."
                     : "Starts from the top when launched, on the next bar.",
                 NSPoint(x: p.minX, y: p.minY + top + 56), width: p.width, size: 14, color: Theme.hint, lines: 4, lh: 1.3)
        // CLIP
        p = panels[2]
        label(p, "CLIP")
        var cy = p.minY + top
        mpcButton(NSRect(x: p.minX, y: cy, width: p.width, height: 44), "DUPLICATE", glyph: "copy") { send("duplicate") }
        cy += 52
        mpcButton(NSRect(x: p.minX, y: cy, width: p.width, height: 44), (c["midi"] as? Bool ?? true) ? "EDIT NOTES" : "OPEN", glyph: "steps") { [weak self] in
            send("open", "steps"); self?.clipSheet = nil }
        cy += 52
        mpcButton(NSRect(x: p.minX, y: cy, width: p.width, height: 44), "DELETE", glyph: "delete", style: .red) { [weak self] in
            send("delete"); self?.clipSheet = nil }
        // COLOUR
        p = panels[3]
        label(p, "COLOUR")
        let sw = (p.width - 4 * 8) / 5
        for (k, entry) in Theme.palette.enumerated() {
            let b = NSRect(x: p.minX + CGFloat(k % 5) * (sw + 8), y: p.minY + top + CGFloat(k / 5) * (sw + 8), width: sw, height: sw)
            entry.color.setFill(); NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3).fill()
            if Theme.live(c["color"] as? Int) == entry.color {
                NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: b.insetBy(dx: -2.5, dy: -2.5), xRadius: 4, yRadius: 4); o.lineWidth = 1.5; o.stroke()
            }
            let col = entry.color.usingColorSpace(.sRGB)!
            let hexv = (Int(col.redComponent * 255) << 16) | (Int(col.greenComponent * 255) << 8) | Int(col.blueComponent * 255)
            buttons.append((b, { send("color", hexv) }))
        }
    }

    // session overview (mockup: 8 columns of small cells, coloured where there's a clip); tap = jump there
    func drawOverview(_ r: NSRect, _ ov: [String], offset: Int, sceneOffset: Int, visible: (Int, Int), colours: [NSColor] = []) {
        Theme.panel.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let inner = r.insetBy(dx: 6, dy: 6)
        let nt = max(1, ov.count), ns = max(1, ov.map { $0.count }.max() ?? 1)
        let cw = (inner.width - CGFloat(max(0, 8 - 1)) * 2) / 8, rowsN = max(3, Int(ceil(Double(nt * ns) / 8)))
        let ch = (inner.height - CGFloat(rowsN - 1) * 2) / CGFloat(rowsN)
        // one cell per clip slot, track by track (like the mockup's mini map)
        var k = 0
        for (ti, row) in ov.enumerated() {
            for chr in row {
                let rr = NSRect(x: inner.minX + CGFloat(k % 8) * (cw + 2), y: inner.minY + CGFloat(k / 8) * (ch + 2), width: cw, height: ch)
                if rr.maxY > inner.maxY + 0.5 { break }
                let col: NSColor = chr == "." ? Theme.panel2 : (chr == "p" ? Theme.palette[2].color : (ti < colours.count ? colours[ti].withAlphaComponent(0.85) : Theme.faint))
                col.setFill(); NSBezierPath(roundedRect: rr, xRadius: 2, yRadius: 2).fill()
                k += 1
            }
        }
        buttons.append((r, { [weak self] in
            guard let self else { return }
            self.link.send(["cmd": "session_jump", "track": 0, "scene": 0])
        }))
        _ = (offset, sceneOffset, visible, nt, ns)
    }

    // the screen follows what you do: 16 LEVEL → step grid; another track → its natural page
    func followContext() {
        let isArr = arrangement != nil
        if isArr != lastArrangement {                        // you switched Session <-> Arrangement in Live: show it
            if lastArrangement != nil && page != .browse { page = .session }
            lastArrangement = isArr
        }
        let stepMode = state["step_mode"] as? Bool ?? (steps?["mode"] as? Bool ?? false)
        let instance = state["instance"] as? Int ?? 0
        if instance != lastInstance {                        // Ableton (re)started: it follows our page
            lastInstance = instance; lastChainCount = -1; lastStepMode = page == .steps
            if stepMode && page != .steps { syncStepMode() }      // never leave the pads in step mode by surprise
            link.send(["cmd": "page", "page": page.rawValue])
        } else {
            lastStepMode = stepMode                          // (16 LEVEL itself tells us with a "step_mode" message)
        }
        let name = (state["track"] as? [String: Any])?["name"] as? String ?? ""
        // a device was added to this track (also when loaded from Ableton itself): an effect → show it on DEVICE
        let dev = state["device"] as? [String: Any]
        // (only real devices count, not a pad's sound; ignore moments without a device; and never right after you
        //  switched page yourself — that made MENU bounce back to DEVICE)
        if let dev, let chainCount = dev["track_devices"] as? Int {
            if name == lastTrackName && lastChainCount >= 0 && chainCount == lastChainCount + 1 && onTrackPage
                && (dev["type"] as? Int ?? 0) != 1 && Date().timeIntervalSince(lastManualPage) > 1.5 { page = .device }
            lastChainCount = chainCount
        } else { lastChainCount = -1 }
        if name != lastTrackName || trackKind != lastTrackKind {   // other track, or something loaded onto it
            lastTrackName = name; lastTrackKind = trackKind
            if openTrackPending { openTrackPending = false; page = trackPage }
            if onTrackPage { page = trackPage }
        }
    }

    // the parts of the state the current page (and the top bar) actually draws
    func pageSignature() -> String {
        var parts: [Any] = [state["track"] ?? "", state["playing"] ?? false, state["recording"] ?? false, state["view"] ?? "", state["tracks"] ?? "", state["fresh"] ?? false]
        switch page {
        case .sample: parts.append(state["simpler"] ?? ""); parts.append(state["wave_q"] ?? ""); parts.append(state["sampling"] ?? "")
        case .steps: parts.append(state["steps"] ?? ""); parts.append(state["step_sel"] ?? ""); parts.append(state["song"] ?? "")
        case .session: parts.append(state["arrangement"] ?? state["session"] ?? ""); parts.append(state["looprec"] ?? "")
        case .device: parts.append(state["device"] ?? "")
        case .pads: parts.append(state["pads"] ?? ""); parts.append(state["levels"] ?? ""); parts.append(state["chords"] ?? ""); parts.append(state["song"] ?? "")
            if trackKind == "drum" { parts.append(state["device"] ?? "") }    // KIT: the pad's sound on the Q fields
        case .mixer: parts.append(state["mixer"] ?? "")
        case .browse: break
        }
        let data = (try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func show(_ p: Page) {
        lastManualPage = Date()
        if p != .browse { padTarget = nil }
        page = p
        if p == .browse { link.send(["cmd": "browse", "path": browsePath]) }
        needsDisplay = true
    }

    // MARK: STEPS page — rows = sounds (Drum Rack pads of the current bank), 16 steps of one bar
    var steps: [String: Any]? { state["steps"] as? [String: Any] }
    var stepHead: Double? = nil
    var stepOverrides: [String: Bool] = [:]          // optimistic toggles until Ableton confirms
    let stepLabelW: CGFloat = 150, stepPanelW: CGFloat = 290
    var stepFirst = 0                                 // drums: the first row shown (two fingers up/down scroll)
    let stepVisible = 8                               // 8 rows; the jog wheel (or ▲ ▼) scrolls through the 16 pads
    var stepScrollAcc: CGFloat = 0, stepPinchAcc: CGFloat = 0, stepRowPx: CGFloat = 70
    var stepGrid: NSRect {
        let w = page == .steps && (steps?["melody_view"] as? Bool ?? false) ? 0 : stepPanelW + 16
        // the cells (labels are 110 wide) down to the F-bar, with a margin for the playhead's outline
        return NSRect(x: 16 + 110, y: topH + 4, width: bounds.width - 16 - (16 + 110) - w + 8, height: bounds.height - 56 - topH - 4)
    }

    func drawSteps() {
        if isRollPage { drawRoll(); return }                    // instruments: the melody composer (piano roll)
        // MPC-2 chrome: STEPS (drums / Simpler, blue) or NOTES (instruments, violet) · F-keys: the track's tabs · BAR 1–4 · PADS
        let melodicSeq = trackKind == "instrument" || trackKind == "empty"
        let (pcol, pstripe) = melodicSeq ? (hex(0x5f4b9b), hex(0x8d74d6)) : ScreenView.pageColour[.steps]!
        mpcStrip()
        let stc = steps ?? [:]
        let nbars = stc["bars"] as? Int ?? 1, curPage = stc["page"] as? Int ?? 0, follow = stc["follow"] as? Bool ?? true
        let clipName = (stc["clip"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((stc["has_clip"] as? Bool ?? false) ? "Clip" : "No clip yet")
        let grids: [Double] = [0.125, 0.25, 0.5, 1.0]
        mpcHeader(pcol, icon: melodicSeq ? "notes" : "steps", name: HeaderField(label: "Clip", value: clipName, action: nil),
                  fields: [HeaderField(label: "Length", value: "\(nbars) bar\(nbars == 1 ? "" : "s")", action: nil),
                           HeaderField(label: "Grid", value: stepLengthName, action: { [weak self] in        // tap = the next note length
                               guard let self else { return }
                               let i = grids.firstIndex(of: (self.steps?["length"] as? Double) ?? 0.25) ?? 1
                               self.link.send(["cmd": "step_length", "value": grids[(i + 1) % grids.count]]) })],
                  tools: [Tool(glyph: "draw", on: stepTool == "draw", action: { [weak self] in self?.stepTool = "draw"; self?.needsDisplay = true }),
                          Tool(glyph: "erase", on: stepTool == "erase", action: { [weak self] in self?.stepTool = "erase"; self?.needsDisplay = true }),
                          Tool(glyph: "copy", on: false, action: { [weak self] in self?.stepOverrides = [:]; self?.link.send(["cmd": "copy_bar"]) }),
                          Tool(glyph: "follow", on: follow, action: { [weak self] in self?.link.send(["cmd": "step_follow", "on": !follow]) })])
        var fActions: [FKey] = (0..<4).map { b in
            FKey(glyph: nil, title: "BAR \(b + 1)", on: curPage == b, weight: 0.62, action: { [weak self] in
                self?.stepOverrides = [:]; self?.link.send(["cmd": "step_page", "page": b]) }) }
        fActions.append(FKey(glyph: "copy", title: "COPY BAR", weight: 1.0, action: { [weak self] in
            self?.stepOverrides = [:]; self?.link.send(["cmd": "copy_bar"]) }))
        let fTabs = trackTabs(.steps)
        defer { mpcFBar(tabs: fTabs, actions: fActions, stripe: pstripe) }
        // tracks without a step grid: say what to do instead of showing an empty page
        switch trackKind {
        case "empty":
            drawText("Empty MIDI track. Load something to play:", NSPoint(x: 0, y: topH + 120), size: 26, weight: .semibold, center: true, width: bounds.width)
            let choices: [(String, String)] = [("Instrument", "Instruments"), ("Drum kit", "Drums"), ("Sound", "Sounds"), ("Sample", "Samples")]
            let w: CGFloat = 250, x0 = (bounds.width - CGFloat(choices.count) * (w + 16) + 16) / 2
            for (i, (title, root)) in choices.enumerated() {
                button(NSRect(x: x0 + CGFloat(i) * (w + 16), y: topH + 200, width: w, height: 120), title, on: false, size: 24) { [weak self] in
                    guard let self else { return }
                    self.pageBeforeBrowse = .steps; self.browsePath = [root]; self.browseEntryDepth = 1; self.show(.browse); self.enterBrowse()
                }
            }
            return
        case "audio":
            drawText("Audio track: record and launch its clips in SESSION", NSPoint(x: 0, y: bounds.midY - 60), size: 24, color: Theme.dim, center: true, width: bounds.width)
            button(NSRect(x: bounds.midX - 120, y: bounds.midY, width: 240, height: 70), "Go to SESSION", on: false, size: 22) { [weak self] in self?.show(.session) }
            return
        case "other":
            drawText("Return / Main track: its effects are on DEVICE", NSPoint(x: 0, y: bounds.midY - 60), size: 24, color: Theme.dim, center: true, width: bounds.width)
            button(NSRect(x: bounds.midX - 120, y: bounds.midY, width: 240, height: 70), "Go to DEVICE", on: false, size: 22) { [weak self] in self?.show(.device) }
            return
        default: break
        }
        guard let st = steps, let rows = st["rows"] as? [[String: Any]], !rows.isEmpty else {
            if trackKind == "drum" {                               // a kit without sounds (in this pad bank)
                drawText("No sounds on these pads yet: load samples on the pads first", NSPoint(x: 0, y: bounds.midY - 60), size: 24, color: Theme.dim, center: true, width: bounds.width)
                button(NSRect(x: bounds.midX - 130, y: bounds.midY, width: 260, height: 70), "GO TO PADS", on: true, size: 20) { [weak self] in
                    self?.lastDrumView = .pads; self?.show(.pads) }
            } else {
                drawText("Select a clip slot on this track", NSPoint(x: 0, y: bounds.midY - 20), size: 24, color: Theme.dim, center: true, width: bounds.width)
            }
            return
        }
        let melodic = st["melodic"] as? Bool ?? false
        // (the old MELODY view is gone: the melody composer replaced it)
        // STEPS (mockup): rows 62 high, gap 8 · label 110 · 16 cells (gap 6) · right column 300 · bottom bar
        let allRows = rows
        let halves = !melodic && allRows.count > 8
        let visible = min(allRows.count, stepVisible)
        stepFirst = max(0, min(allRows.count - visible, stepFirst))
        let shown = halves ? Array(allRows[stepFirst..<(stepFirst + visible)]) : allRows
        let uniform = Set(allRows.compactMap { $0["color"] as? Int }).count <= 1
        func rowColour(_ row: [String: Any]) -> NSColor {
            if melodic || !uniform { return Theme.live(row["color"] as? Int) }
            return ScreenView.padColour((row["note"] as? Int ?? 36) - 36)
        }
        let top = topH + 14 + 22, leftW = bounds.width - 32 - 300 - 16      // (22: the beat ruler)
        let rowGap: CGFloat = shown.count > 10 ? 4 : 8, maxH = bounds.height - 56 - 14 - top
        let fit = (maxH - rowGap * CGFloat(max(0, shown.count - 1))) / CGFloat(max(1, shown.count))
        let rh = halves ? fit : min(62, fit)                 // drums: the rows fill the height (pinch changes how many)
        stepRowPx = rh + rowGap
        if halves && visible < allRows.count {              // scroll bar in the left gutter
            let total = CGFloat(allRows.count) * stepRowPx, track = maxH
            Theme.panel.setFill(); NSBezierPath(roundedRect: NSRect(x: 5, y: top, width: 5, height: track), xRadius: 2.5, yRadius: 2.5).fill()
            Theme.dim.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: top + track * CGFloat(stepFirst) * stepRowPx / total, width: 5,
                                             height: track * CGFloat(visible) * stepRowPx / total), xRadius: 2.5, yRadius: 2.5).fill()
        }
        let cellW = (leftW - 110 - 6 * 16) / 16
        for c in 0..<16 {                                       // beat ruler: 1 · · · 2 · · · 3 · · · 4
            let x = 16 + 110 + 6 + CGFloat(c) * (cellW + 6)
            drawText(c % 4 == 0 ? "\(c / 4 + 1)" : "·", NSPoint(x: x, y: top - 22), size: 12, color: c % 4 == 0 ? Theme.dim : Theme.faint, weight: .regular, center: true, width: cellW)
        }
        hex(0x1d2a33).setFill()
        NSBezierPath(roundedRect: NSRect(x: 16 + 110 + 2, y: top - 4, width: 16 * (cellW + 6) + 2, height: CGFloat(shown.count) * (rh + rowGap) - rowGap + 8), xRadius: 4, yRadius: 4).fill()
        var info: [String: [Int]] = [:]                      // "pitch-step" → [pitch, step, velocity, chance %, ratchet]
        for n in (st["notes"] as? [[Int]]) ?? [] where n.count >= 2 { info["\(n[0])-\(n[1])"] = n }
        let on = Set(info.keys)
        let sel = state["step_sel"] as? [Int]
        let selected = st["selected"] as? Int ?? -1
        var selName = ""
        for (ri, row) in shown.enumerated() {
            let note = row["note"] as? Int ?? 0
            let y = top + CGFloat(ri) * (rh + rowGap)
            let color = rowColour(row)
            let black = row["black"] as? Bool ?? false, root = row["root"] as? Bool ?? false
            if let sl = sel, sl.first == note { selName = row["name"] as? String ?? "" }
            let lr = NSRect(x: 16, y: y, width: 110, height: rh)
            (note == selected ? hex(0x34414b) : hex(0x26323b)).setFill(); NSBezierPath(roundedRect: lr, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: lr, xRadius: 3, yRadius: 3).setClip()
            if note == selected { Theme.accent.setFill(); NSRect(x: lr.minX, y: lr.minY, width: 3, height: lr.height).fill() }   // the row Q1–Q3 edit
            NSGraphicsContext.restoreGraphicsState()
            (melodic && !root ? Theme.faint : color).setFill(); NSBezierPath(ovalIn: NSRect(x: lr.minX + 10, y: lr.midY - 4, width: 8, height: 8)).fill()
            drawTextV(ScreenView.undated(row["name"] as? String ?? ""), NSRect(x: lr.minX + 24, y: lr.minY, width: lr.width - 28, height: lr.height), size: rh < 40 ? 13 : 15, color: Theme.text, weight: .regular)
            buttons.append((lr, { [weak self] in self?.link.send(["cmd": "select_sound", "note": note]) }))
            for c in 0..<16 {
                let r = NSRect(x: 16 + 110 + 6 + CGFloat(c) * (cellW + 6), y: y, width: cellW, height: rh)
                let key = "\(note)-\(c)"
                let isOn = stepOverrides[key] ?? on.contains(key)
                var base = (c / 4) % 2 == 0 ? hex(0x2c3a45) : hex(0x26343e)
                if melodic && black { base = base.blended(withFraction: 0.45, of: Theme.bg) ?? base }
                let ni = info[key] ?? []
                let chance = ni.count > 3 ? CGFloat(ni[3]) / 100 : 1, ratchet = ni.count > 4 ? ni[4] : 1, vel = ni.count > 2 ? CGFloat(ni[2]) : 100
                let isSel = sel == [note, c]
                let inset: CGFloat = isSel ? 3 : 0
                if isOn {                                        // the step's colour; its velocity = how far up it is filled (MPC)
                    let cell = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                    color.blended(withFraction: 0.55, of: base)!.withAlphaComponent(0.4 + 0.6 * chance).setFill(); cell.fill()
                    NSGraphicsContext.saveGraphicsState(); cell.setClip()
                    let fh = r.height * max(0.15, vel / 127)
                    color.withAlphaComponent(0.35 + 0.65 * chance).setFill(); NSRect(x: r.minX, y: r.maxY - fh, width: r.width, height: fh).fill()
                    NSGraphicsContext.restoreGraphicsState()
                } else { base.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill() }
                if isOn && on.contains(key) {
                    var badge = ratchet > 1 ? "\(ratchet)x" : ""
                    if chance < 1 { badge += (badge.isEmpty ? "" : " ") + "\(Int(chance * 100))%" }
                    if !badge.isEmpty {
                        drawText(badge, NSPoint(x: r.minX, y: r.maxY - 6 - inset - lineH(11)), size: 11, color: Theme.darkInk, weight: .bold, center: true, width: r.width)
                    }
                }
                if isSel { Theme.accent.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
                buttons.append((r, { [weak self] in
                    guard let self else { return }
                    if isOn && self.stepTool == "erase" {        // ERASE tool: a lit step goes
                        self.stepOverrides[key] = false
                        if isSel { self.link.send(["cmd": "step_select"]); self.state["step_sel"] = nil }
                        self.link.send(["cmd": "toggle_step", "pitch": note, "step": c, "page": st["page"] as? Int ?? 0, "velocity": 100])
                    } else if isOn && !isSel {                   // a lit step: select it (Q-Links + buttons edit it)
                        self.link.send(["cmd": "step_select", "pitch": note, "step": c])
                        self.state["step_sel"] = [note, c]
                    } else {                                     // empty: add · selected: delete
                        self.stepOverrides[key] = !isOn
                        if isSel { self.link.send(["cmd": "step_select"]); self.state["step_sel"] = nil }
                        self.link.send(["cmd": "toggle_step", "pitch": note, "step": c, "page": st["page"] as? Int ?? 0, "velocity": 100])
                    }
                    self.needsDisplay = true
                }))
            }
        }
        if let h = stepHead, h >= 0, h < 16, Date().timeIntervalSince(lastPlayheadAt) < 0.5 {
            let x = 16 + 110 + 6 + CGFloat(Int(h)) * (cellW + 6)
            Theme.value.withAlphaComponent(0.9).setStroke()
            let ph = NSBezierPath(roundedRect: NSRect(x: x, y: top, width: cellW, height: CGFloat(shown.count) * (rh + rowGap) - rowGap), xRadius: 3, yRadius: 3); ph.lineWidth = 1.5; ph.stroke()
        }

        // right column (300 wide): a selected STEP (velocity · roll · nudge · pitch), else the selected ROW
        // (velocity · fill · clear · vary velocity · note length · laid back). Q-Links follow the same split.
        let px = bounds.width - 16 - 300, pw: CGFloat = 300
        var y = top
        let cur: [Int]? = sel.flatMap { sl in sl.count == 2 ? info["\(sl[0])-\(sl[1])"] : nil }
        let tempo = songInfo["tempo"] as? Double ?? 120
        func chordPadsButton(_ top: CGFloat) {               // CHORD PADS on / off: big, fills the rest of the column (used a lot)
            guard trackKind == "instrument" else { return }
            let cr = NSRect(x: px, y: top, width: pw, height: max(46, bounds.height - 56 - 12 - top))
            mpcButton(cr, chordsOn ? "CHORD PADS ON" : "CHORD PADS · one pad = one chord", glyph: "chords", style: chordsOn ? .light : .dark) { [weak self] in
                guard let self else { return }; self.setChords(!self.chordsOn) }
        }
        func ms(_ milliBeats: Int) -> String {
            let v = Int((Double(milliBeats) / 1000 * 60000 / tempo).rounded())
            return v == 0 ? "on the grid" : (v > 0 ? "+\(v) ms late" : "\(v) ms early")
        }
        func label(_ t: String) { drawText(t, NSPoint(x: px, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 6 }
        // a velocity bar: tap = set (where you tap) + the wheel fine-tunes it
        func velocityBar(_ v: Int?, id: String, set: @escaping (Int) -> Void) {
            let r = NSRect(x: px, y: y, width: pw, height: 46)
            hex(0x1c1e20).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if let v {
                Theme.value.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(6, r.width * CGFloat(v) / 127), height: r.height), xRadius: 3, yRadius: 3).fill()
            }
            drawTextV(v.map { "\($0)" } ?? "—", r, x: r.minX + 14, size: 22, color: v.map { $0 > 40 ? Theme.darkInk : Theme.text } ?? Theme.faint, weight: .light)
            buttons.append((r, { [weak self] in
                guard let self, v != nil else { return }
                let nv = max(1, min(127, Int((self.lastDown.x - r.minX) / r.width * 127)))
                set(nv); self.jogFocusId = id; self.needsDisplay = true }))
            focusable(r, id, radius: 10) { d in set(max(1, min(127, (v ?? 100) + d * 2))) }
            y += 46 + 14
        }
        // a row of choices filling the column (MPC segmented control); nil selected = momentary buttons
        func seg(_ title: String?, _ opts: [String], _ selected: Int?, h: CGFloat = 44, gap: CGFloat = 12, _ act: @escaping (Int) -> Void) {
            let room = pw - 8 - CGFloat(opts.count - 1) * 3
            let natural = opts.map { textW($0, size: 15, weight: .bold, tracking: 0.07) + 30 }
            var m = room / CGFloat(opts.count)                     // the widest equal width that still fits the column
            while m > 0 && natural.map({ max(m, $0) }).reduce(0, +) > room { m -= 1 }
            let (box, _) = mpcSeg(px, y, label: title, opts, selected: selected, h: h, minW: m, action: act)
            y = box.maxY + gap
        }
        // ◀ value ▶ (nudge / laid back)
        func stepper(_ value: String, lit: Bool, _ act: @escaping (Int) -> Void) {
            mpcButton(NSRect(x: px, y: y, width: 64, height: 44), "", glyph: "left") { act(-1) }
            drawTextV(value, NSRect(x: px + 70, y: y, width: pw - 140, height: 44), size: 16, color: lit ? Theme.value : Theme.dim, weight: .regular, center: true)
            mpcButton(NSRect(x: px + pw - 64, y: y, width: 64, height: 44), "", glyph: "right") { act(1) }
            y += 44 + 12
        }
        if let c = cur, let sl = sel {                           // ---- STEP ----
            drawTextV("STEP \(sl[1] + 1) · \(selName.uppercased())", NSRect(x: px, y: y, width: pw - 98, height: 36), size: 13, color: Theme.dim, weight: .regular, tracking: 0.08)
            mpcButton(NSRect(x: px + pw - 90, y: y, width: 90, height: 36), "DONE", style: .light) { [weak self] in
                self?.link.send(["cmd": "step_select"]); self?.state["step_sel"] = nil; self?.needsDisplay = true }
            y += 36 + 12
            label("VELOCITY · Q1")
            velocityBar(c.count > 2 ? c[2] : 100, id: "stepvel") { [weak self] v in self?.link.send(["cmd": "step_edit", "what": "velocity", "value": v]) }
            let ratchet = c.count > 4 ? c[4] : 1
            seg("Roll · Q4 (repeats in the step)", ["1×", "2×", "3×", "4×"], ratchet - 1) { [weak self] k in
                self?.link.send(["cmd": "step_edit", "what": "ratchet", "value": k + 1]) }
            label("NUDGE · Q3")
            let nb = c.count > 5 ? c[5] : 0
            stepper(ms(nb), lit: nb != 0) { [weak self] d in self?.link.send(["cmd": "step_edit", "what": "nudge", "value": 0.01 * Double(d)]) }
            if melodic {
                label("PITCH · Q2")
                stepper(selName, lit: true) { [weak self] d in self?.link.send(["cmd": "step_edit", "what": "pitch", "value": sl[0] + d]) }
            }
            mpcButton(NSRect(x: px, y: y, width: pw, height: 44), "DELETE STEP", glyph: "delete") { [weak self] in
                guard let self else { return }
                self.stepOverrides["\(sl[0])-\(sl[1])"] = false
                self.link.send(["cmd": "step_edit", "what": "delete"]); self.state["step_sel"] = nil; self.needsDisplay = true }
            chordPadsButton(max(y + 44 + 14, bounds.height - 56 - 14 - 90))
            return
        }
        // ---- ROW (no step selected) ----
        let row = st["row"] as? [String: Any] ?? [:]
        let rowName = (rows.first { ($0["note"] as? Int) == (row["note"] as? Int ?? selected) }?["name"] as? String) ?? ""
        label("ROW")
        drawText(rowName.isEmpty ? "Pick a row" : ScreenView.undated(rowName), NSPoint(x: px, y: y), size: 26, weight: .light, width: pw); y += lineH(26) + 10
        // VELOCITY (Q1): a field with its bar · tap = set it there, then the wheel fine-tunes it
        let rv = row["velocity"] as? Int
        let vr = NSRect(x: px, y: y, width: pw, height: 78)
        let vOn = jogFocusId == "rowvel" || touchedQ == 0
        mpcField(vr, label: "Velocity", value: rv.map { "\($0)" } ?? "–", q: 1, active: vOn, mint: vOn, valueSize: 30)
        let barR = NSRect(x: vr.minX + 14, y: vr.maxY - 12, width: vr.width - 28, height: 4)
        hex(0x1c1e20).setFill(); NSBezierPath(roundedRect: barR, xRadius: 2, yRadius: 2).fill()
        if let v = rv { Theme.value.setFill(); NSBezierPath(roundedRect: NSRect(x: barR.minX, y: barR.minY, width: barR.width * CGFloat(v) / 127, height: 4), xRadius: 2, yRadius: 2).fill() }
        buttons.append((vr, { [weak self] in
            guard let self, rv != nil else { return }
            let nv = max(1, min(127, Int((self.lastDown.x - vr.minX) / vr.width * 127)))
            self.link.send(["cmd": "row_edit", "what": "velocity", "value": nv]); self.jogFocusId = "rowvel"; self.needsDisplay = true }))
        focusable(vr, "rowvel", radius: 3) { [weak self] d in self?.link.send(["cmd": "row_edit", "what": "velocity", "value": max(1, min(127, (rv ?? 100) + d * 2))]) }
        y += 78 + 8
        // LAID BACK (Q2) · LENGTH (Q3): tap LAID BACK = the wheel moves it, tap LENGTH = the next length
        let hw = (pw - 8) / 2
        let rn = row["nudge"] as? Int ?? 0
        let lbR = NSRect(x: px, y: y, width: hw, height: 70), lnR = NSRect(x: px + hw + 8, y: y, width: hw, height: 70)
        let lbOn = jogFocusId == "laidback" || touchedQ == 1
        let lbText: String = { let v = Int((Double(rn) / 1000 * 60000 / tempo).rounded()); return v == 0 ? "on grid" : String(format: "%+d ms", v) }()
        mpcField(lbR, label: "Laid back", value: lbText, q: 2, active: lbOn, mint: lbOn || rn != 0, valueSize: 26)
        buttons.append((lbR, { [weak self] in self?.jogFocusId = "laidback"; self?.needsDisplay = true }))
        focusable(lbR, "laidback", radius: 3) { [weak self] d in self?.link.send(["cmd": "row_edit", "what": "nudge", "value": 0.004 * Double(d)]) }
        let curLen = (st["length"] as? Double) ?? 0.25, lens = [0.125, 0.25, 0.5, 1.0]
        mpcField(lnR, label: "Length", value: stepLengthName, q: 3, active: touchedQ == 2, mint: touchedQ == 2, valueSize: 26)
        buttons.append((lnR, { [weak self] in
            let i = lens.firstIndex(of: curLen) ?? 1
            self?.link.send(["cmd": "step_length", "value": lens[(i + 1) % lens.count]]) }))
        y += 70 + 14
        let fills = ["4", "8", "16", "off"]
        seg("Fill this bar", ["1/4", "1/8", "1/16", "OFFBEAT"], nil) { [weak self] k in
            self?.stepOverrides = [:]; self?.link.send(["cmd": "row_edit", "what": "fill", "value": fills[k]]) }
        mpcButton(NSRect(x: px, y: y - 4, width: hw, height: 44), "VARY VEL", glyph: "star") { [weak self] in
            self?.link.send(["cmd": "row_edit", "what": "vary"]) }
        mpcButton(NSRect(x: px + hw + 8, y: y - 4, width: hw, height: 44), "CLEAR ROW", glyph: "erase") { [weak self] in
            self?.stepOverrides = [:]; self?.link.send(["cmd": "row_edit", "what": "clear"]) }
        y += 44 + 10
        if !melodic && allRows.count > stepVisible {             // PADS 1–8 · PADS 9–16 (the rows on screen)
            let by = bounds.height - 56 - 14 - 46
            let lowOn = stepFirst < 4
            mpcButton(NSRect(x: px, y: by, width: hw, height: 46), "PADS 1–8", glyph: "up", style: lowOn ? .light : .dark) { [weak self] in self?.stepFirst = 0; self?.needsDisplay = true }
            mpcButton(NSRect(x: px + hw + 8, y: by, width: hw, height: 46), "PADS 9–16", glyph: "down", style: lowOn ? .dark : .light) { [weak self] in self?.stepFirst = 8; self?.needsDisplay = true }
        }
        if melodic {                                              // instruments: octave, in key, melody view
            let oct = st["octave"] as? Int ?? 3, inKey = st["in_key"] as? Bool ?? true
            let above = st["above"] as? Int ?? 0, below = st["below"] as? Int ?? 0
            stepper("OCTAVE C\(oct)" + (above + below > 0 ? "  ·  ▼\(below) ▲\(above)" : ""), lit: true) { [weak self] d in self?.stepOctave(d) }
            y -= 4
            seg(nil, ["IN KEY", "ALL 12 NOTES"], inKey ? 0 : 1, h: 40, gap: 6) { [weak self] k in
                guard let self, (k == 0) != inKey else { return }
                self.stepOverrides = [:]; self.link.send(["cmd": "step_inkey"]) }
            seg(nil, ["GRID", "MELODY"], 0, h: 40, gap: 8) { [weak self] k in self?.link.send(["cmd": "melody_view", "on": k == 1]) }
            chordPadsButton(y)
        }
    }
    // BAR 1-4 (bars beyond the clip dimmed; tapping one = edit there, the clip grows) + FOLLOW (the playing bar)
    func barButtons(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGFloat {
        let st = steps ?? [:]
        let page = st["page"] as? Int ?? 0, bars = st["bars"] as? Int ?? 1, follow = st["follow"] as? Bool ?? true
        var bx = x
        for b in 0..<4 {
            let r = NSRect(x: bx, y: y, width: w, height: h)
            let exists = b < bars
            button(r, "\(b + 1)", size: 17, fill: page == b ? Theme.white : (exists ? Theme.panel2 : Theme.panel),
                   ink: page == b ? Theme.darkInk : (exists ? Theme.text : Theme.faint), hitPad: 3) { [weak self] in
                self?.stepOverrides = [:]; self?.link.send(["cmd": "step_page", "page": b]) }
            bx += w + 8
        }
        let fw: CGFloat = 96
        button(NSRect(x: bx, y: y, width: fw, height: h), "FOLLOW", size: 14, fill: follow ? Theme.play : Theme.panel2,
               ink: follow ? hex(0x052814) : Theme.text, hitPad: 3) { [weak self] in
            self?.link.send(["cmd": "step_follow", "on": !follow]) }
        return bx + fw
    }
    // GRID | MELODY: the same switch on both views (MENU steps through them too)
    func gridMelodySwitch(_ r: NSRect, melody: Bool) {
        mpcSeg(r.minX, r.minY, ["GRID", "MELODY"], selected: melody ? 1 : 0, h: r.height, minW: (r.width - 11) / 2) { [weak self] k in
            self?.link.send(["cmd": "melody_view", "on": k == 1]) }
    }
    var stepLengthName: String {
        let v = (steps?["length"] as? Double) ?? 0.25
        return [0.125: "1/32", 0.25: "1/16", 0.5: "1/8", 1.0: "1/4"][v] ?? String(format: "%.2f", v)
    }

    // MELODY (mockup): header · 16 columns (+ · bar · −) 300 high · ON THE FLY panel 470 · PADS = 16 PITCHES
    func drawMelody(_ st: [String: Any]) {
        let mel = st["melody"] as? [String: Any] ?? [:]
        var notes: [Int: (Int, String)] = [:]
        for e in (mel["steps"] as? [[Any]]) ?? [] where e.count >= 3 { if let k = e[0] as? Int, let p = e[1] as? Int { notes[k] = (p, e[2] as? String ?? "") } }
        let pitches = notes.values.map { $0.0 }
        let lo = Double((pitches.min() ?? 60) - 12), hi = Double(max((pitches.max() ?? 72) + 12, Int(lo) + 36))
        let sel = state["step_sel"] as? [Int]
        let top = topH + 14
        let rootIdx: Int = songInfo["root"] as? Int ?? 0
        let keyName: String = ScreenView.rootNames[max(0, min(11, rootIdx))] + " " + (songInfo["scale"] as? String ?? "")
        let page = st["page"] as? Int ?? 0
        let selStep = sel.flatMap { $0.count == 2 ? $0[1] : nil }
        let selNote = selStep.flatMap { notes[$0] }
        // header row (+ BAR / GRID, small, on the right)
        drawTextV("EVERY STEP ITS OWN PITCH · IN " + keyName.uppercased(), NSRect(x: 16, y: top - 4, width: 600, height: 44), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        gridMelodySwitch(NSRect(x: bounds.width - 16 - 220, y: top - 4, width: 220, height: 44), melody: true)   // (bars: F-keys · follow: header)
        _ = (page, selNote)
        // 16 columns
        let gy = top + 44 + 8, cw = (bounds.width - 32 - 15 * 6) / 16
        let cellH: CGFloat = 300 - 34 - 34 - 8 - 22
        for c in 0..<16 {
            let x = 16 + CGFloat(c) * (cw + 6)
            mpcButton(NSRect(x: x, y: gy, width: cw, height: 34), "", glyph: "up") { [weak self] in self?.link.send(["cmd": "melody_step", "step": c, "delta": 1]) }
            let cell = NSRect(x: x, y: gy + 38, width: cw, height: cellH)
            ((c / 4) % 2 == 0 ? hex(0x2c3a45) : hex(0x26343e)).setFill(); NSBezierPath(roundedRect: cell, xRadius: 3, yRadius: 3).fill()
            let isSel = selStep == c
            let inset: CGFloat = 0
            if let (p, name) = notes[c] {
                let frac = max(0, min(1, (Double(p) - lo) / (hi - lo)))
                let h = min(cell.height - 12 - 2 * inset, CGFloat(20 + frac * 220))
                tcolor.setFill(); NSBezierPath(roundedRect: NSRect(x: cell.minX + 4 + inset, y: cell.maxY - 4 - inset - h, width: cell.width - 8 - 2 * inset, height: h), xRadius: 2, yRadius: 2).fill()
                drawText(name, NSPoint(x: cell.minX, y: cell.maxY - 8 - inset - lineH(14)), size: 14, color: Theme.ink(tcolor), weight: .regular, center: true, width: cell.width)
            }
            if isSel { Theme.accent.setStroke(); let o = NSBezierPath(roundedRect: cell.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
            let pitch = notes[c]?.0
            buttons.append((cell, { [weak self] in
                guard let self else { return }
                if let pitch {                                   // select it (Q2 changes it) · tap the selected one = remove
                    if self.state["step_sel"] as? [Int] == [pitch, c] {
                        self.link.send(["cmd": "toggle_step", "pitch": pitch, "step": c, "page": st["page"] as? Int ?? 0]); self.link.send(["cmd": "step_select"]); self.state["step_sel"] = nil
                    } else { self.link.send(["cmd": "step_select", "pitch": pitch, "step": c]); self.state["step_sel"] = [pitch, c] }
                } else { self.link.send(["cmd": "melody_step", "step": c, "delta": 0]) }
                self.needsDisplay = true
            }))
            mpcButton(NSRect(x: x, y: gy + 300 - 22 - 34, width: cw, height: 34), "", glyph: "down") { [weak self] in self?.link.send(["cmd": "melody_step", "step": c, "delta": -1]) }
        }
        if let h = stepHead, h >= 0, h < 16, Date().timeIntervalSince(lastPlayheadAt) < 0.5 {
            Theme.value.withAlphaComponent(0.9).setStroke()
            let ph = NSBezierPath(roundedRect: NSRect(x: 16 + CGFloat(Int(h)) * (cw + 6), y: gy + 38, width: cw, height: cellH), xRadius: 3, yRadius: 3); ph.lineWidth = 1.5; ph.stroke()
        }
        // ON THE FLY — Q-LINKS (470 wide)
        let py = gy + 300 - 22 + 12, ph = bounds.height - 56 - 12 - py
        let lp = NSRect(x: 16, y: py, width: 498, height: ph)                           // 470 + padding
        Theme.panel.setFill(); NSBezierPath(roundedRect: lp, xRadius: 4, yRadius: 4).fill()
        var y = lp.minY + 14
        drawText("ON THE FLY · Q-LINKS", NSPoint(x: lp.minX + 14, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 10
        let bw = (lp.width - 28 - 8) / 2, bh: CGFloat = 64
        let boxes: [(String, String)] = [("TRANSPOSE ALL", String(format: "%+d in key", st["transpose"] as? Int ?? 0)), ("THIS STEP", selNote?.1 ?? "–"),
                                         ("GLIDE", (mel["glide"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "–"),
                                         ("LENGTH", ScreenView.lengthName(mel["length"] as? Double ?? 1))]
        for (k, (l, v)) in boxes.enumerated() {
            let r = NSRect(x: lp.minX + 14 + CGFloat(k % 2) * (bw + 8), y: y + CGFloat(k / 2) * (bh + 8), width: bw, height: bh)
            mpcField(r, label: l, value: v, q: k + 1, active: touchedQ == k, mint: true, valueSize: 22)
        }
        y += 2 * bh + 8 + 10
        let unit = (lp.width - 28 - 16) / 3.3
        mpcButton(NSRect(x: lp.minX + 14, y: y, width: unit, height: 48), "ALL −1", glyph: "down") { [weak self] in self?.link.send(["cmd": "melody_transpose", "delta": -1]) }
        mpcButton(NSRect(x: lp.minX + 14 + unit + 8, y: y, width: unit, height: 48), "ALL +1", glyph: "up") { [weak self] in self?.link.send(["cmd": "melody_transpose", "delta": 1]) }
        mpcButton(NSRect(x: lp.minX + 14 + 2 * (unit + 8), y: y, width: unit * 1.3, height: 48), "RANDOM IN KEY", glyph: "star", style: .light) { [weak self] in
            self?.link.send(["cmd": "melody_random"]) }
        // PADS = 16 PITCHES (lowest first, like the mockup); tap = hear it
        let rp = NSRect(x: lp.maxX + 12, y: py, width: bounds.width - 16 - lp.maxX - 12, height: ph)
        Theme.panel.setFill(); NSBezierPath(roundedRect: rp, xRadius: 4, yRadius: 4).fill()
        drawText("PADS = 16 PITCHES · PLAY ALONG, REC = INTO THE LOOP", NSPoint(x: rp.minX + 14, y: rp.minY + 14), size: 12, color: Theme.dim, weight: .regular, width: rp.width - 28, tracking: 0.11)
        let padNotes = (mel["pads"] as? [[Any]]) ?? []
        let gy2 = rp.minY + 14 + lineH(13) + 10
        let tw = (rp.width - 28 - 7 * 6) / 8, th = (rp.maxY - 14 - gy2 - 6) / 2
        for i in 0..<min(16, padNotes.count) {
            let p = padNotes[i]
            guard let note = p.first as? Int else { continue }
            let name = p.count > 1 ? (p[1] as? String ?? "") : ""
            let r = NSRect(x: rp.minX + 14 + CGFloat(i % 8) * (tw + 6), y: gy2 + CGFloat(i / 8) * (th + 6), width: tw, height: th)
            let hit = note == selNote?.0
            let isRoot = ((note - rootIdx) % 12 + 12) % 12 == 0
            let fillC = hit ? Theme.active : (isRoot ? tcolor.blended(withFraction: 0.6, of: Theme.panel2)! : Theme.panel2)   // calm tiles, the root tinted
            fillC.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).setClip()
            (isRoot ? tcolor : tcolor.withAlphaComponent(0.45)).setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawTextV(name, r, size: 16, color: hit ? Theme.darkInk : Theme.text, weight: .regular, center: true)
            buttons.append((r, { [weak self] in
                self?.notes.on(note); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.notes.off(note) } }))
        }
    }
    // a note's length as a musician says it: 1/16 · 3/16 · 7/16 · 1/2 · 1 bar · 1¾ bars … (beats in, 4 per bar)
    static func exactLength(_ beats: Double) -> String {
        let t = Int((beats * 32).rounded())                           // in 1/128 notes
        if t <= 0 { return "–" }
        if t % 128 == 0 { return t == 128 ? "1 bar" : "\(t / 128) bars" }
        if t > 128 { return String(format: "%.2g bars", beats / 4) }
        var num = t, den = 128
        while num % 2 == 0 && den > 1 { num /= 2; den /= 2 }
        return "\(num)/\(den)"
    }
    static func lengthName(_ steps: Double) -> String {          // note length in steps (1 = 1/16) → 1/16 · 1/8 · 1/4 …
        let names: [(Double, String)] = [(0.5, "1/32"), (1, "1/16"), (2, "1/8"), (3, "3/16"), (4, "1/4"), (8, "1/2")]
        return names.min { abs($0.0 - steps) < abs($1.0 - steps) }!.1
    }

    func stepOctave(_ delta: Int) {
        stepOverrides = [:]
        link.send(["cmd": "step_octave", "delta": delta])
    }
    var octaveScroll: CGFloat = 0

    // MARK: MIXER (Ableton's mixer section, MPC-style blocks): I/O, monitor, sends, pan, fader + meter, number / S / ●
    var mixer: [String: Any]? { state["mixer"] as? [String: Any] }
    var meters: [[Double]] = []
    var meterRects: [NSRect] = []
    var choice: (title: String, options: [String], current: String, pick: (Int) -> Void)? = nil   // routing popup

    func drawMiniKnob(_ c: NSPoint, _ rad: CGFloat, _ frac: Double, bipolar: Bool = false, color: NSColor = Theme.accent) {
        let arc = NSBezierPath(); arc.appendArc(withCenter: c, radius: rad, startAngle: 135, endAngle: 405, clockwise: false)
        NSColor.black.setStroke(); arc.lineWidth = 7; arc.lineCapStyle = .round; arc.stroke()
        let from: CGFloat = bipolar ? 270 : 135, to: CGFloat = 135 + CGFloat(max(0, min(1, frac))) * 270
        let v = NSBezierPath(); v.appendArc(withCenter: c, radius: rad, startAngle: min(from, to), endAngle: max(from, to) + 0.01, clockwise: false)
        color.setStroke(); v.lineWidth = 7; v.lineCapStyle = .round; v.stroke()
    }

    func routingButton(_ r: NSRect, _ text: String, track: Int, kind: String, title: String, enabled: Bool = true) {
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        (enabled ? Theme.panel2 : Theme.panel).setFill(); path.fill()
        drawText(text, NSPoint(x: r.minX + 6, y: r.midY - 10), size: 13, color: enabled ? Theme.text : Theme.dim, width: r.width - 26)
        drawText("▾", NSPoint(x: r.maxX - 18, y: r.midY - 10), size: 13, color: Theme.dim)
        guard enabled else { return }
        buttons.append((r, { [weak self] in
            self?.pendingChoice = (track, kind, title, text)
            self?.link.send(["cmd": "routing_options", "track": track, "kind": kind]) }))
    }
    var pendingChoice: (track: Int, kind: String, title: String, current: String)? = nil

    // MARK: MIXER (mockup "Mixer", MPC style): 8 strips — the tracks that fit, the returns, Main. The header switch picks
    // what the faders (and Q1–Q4 = the first four tracks) set: VOLUME · PAN · SEND A · SEND B. ‹ › = the next four tracks.
    func drawMixer() {
        guard let mx = mixer, let strips = mx["strips"] as? [[String: Any]] else {
            drawText("…", NSPoint(x: 0, y: bounds.midY), size: 24, color: Theme.dim, center: true, width: bounds.width); return
        }
        let returns = mx["returns"] as? [[String: Any]] ?? []
        let offset = mx["offset"] as? Int ?? 0, total = mx["track_count"] as? Int ?? strips.count
        let param = mx["param"] as? String ?? "volume"
        Theme.bg.setFill(); NSRect(x: 0, y: topH, width: bounds.width, height: bounds.height - topH).fill()
        let lo4 = offset + 1, hi4 = min(total, offset + 4), maxOff = max(0, total - (mx["visible"] as? Int ?? 5))
        let fbar = songChrome("mixer", name: "\(total) tracks · \(returns.count) return\(returns.count == 1 ? "" : "s")",
                              actions: [FKey(glyph: "left", title: offset > 0 ? "TRACKS \(max(0, offset - 4) + 1)–\(min(total, max(0, offset - 4) + 4))" : "TRACKS", action: { [weak self] in
                                            guard offset > 0 else { return }; self?.link.send(["cmd": "mix_page", "by": -4]) }),
                                        FKey(glyph: "right", title: offset < maxOff ? "TRACKS \(min(maxOff, offset + 4) + 1)–\(min(total, min(maxOff, offset + 4) + 4))" : "TRACKS", action: { [weak self] in
                                            guard offset < maxOff else { return }; self?.link.send(["cmd": "mix_page", "by": 4]) }),
                                        FKey(glyph: "fx", title: "FX", action: { [weak self] in self?.browseEffects() })])
        defer { fbar() }
        // what the faders set (in the header, right)
        let opts = ["volume", "pan", "send0", "send1"]
        mpcSeg(bounds.width - 16, 34 + 13, ["VOLUME", "PAN", "SEND A", "SEND B"], selected: opts.firstIndex(of: param) ?? 0, h: 44, rightAligned: true) { [weak self] k in
            self?.link.send(["cmd": "mix_param", "what": opts[k]])
            if var m = self?.state["mixer"] as? [String: Any] { m["param"] = opts[k]; self?.state["mixer"] = m; self?.needsDisplay = true } }
        drawText("Q1–Q4 = TRACKS \(lo4)–\(hi4)", NSPoint(x: 420, y: 34 + 26), size: 13, color: NSColor.white.withAlphaComponent(0.75), weight: .regular, tracking: 0.08)
        meterRects = []
        let cols = 8, gap: CGFloat = 6, x0: CGFloat = 10, group: CGFloat = 22     // tracks | returns | Main, set apart (MPC)
        let colW = (bounds.width - 2 * x0 - CGFloat(cols - 1) * gap - 2 * group) / CGFloat(cols)
        let top = topH + 10, h = bounds.height - 56 - 10 - top
        var all: [([String: Any], String)] = strips.map { ($0, "track") } + returns.map { ($0, "return") }
        if let m = mx["master"] as? [String: Any] { all.append((m, "main")) }
        var lastKind = "track"
        for (k, (st, kind)) in all.enumerated() where k < cols {
            let x = kind == "main" ? bounds.width - x0 - colW : x0 + CGFloat(k) * (colW + gap) + (kind == "return" ? group : 0)
            if kind != lastKind {                                    // a thin line in the gap between the groups
                let gx = x - group / 2 - gap / 2
                hex(0x3a3e42).setFill(); NSRect(x: gx - 0.5, y: top + 8, width: 1, height: h - 16).fill()
                lastKind = kind
            }
            mixStrip(st, NSRect(x: x, y: top, width: colW, height: h), meterIndex: k, kind: kind, q: kind == "track" && k < 4 ? k + 1 : nil, param: param)
        }
    }

    func mixStrip(_ st: [String: Any], _ r: NSRect, meterIndex: Int, kind: String, q: Int?, param: String) {
        let index = st["index"] as? Int ?? -1
        let tc = kind == "main" ? hex(0xeef0f1) : Theme.live(st["color"] as? Int)
        let isSel = st["selected"] as? Bool ?? false
        Theme.panel.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        // name
        let head = NSRect(x: r.minX, y: r.minY, width: r.width, height: 40)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).setClip()
        (isSel ? hex(0x3a3e42) : Theme.panel2).setFill(); head.fill()
        tc.setFill(); NSRect(x: head.minX, y: head.minY, width: head.width, height: 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        let rawName = kind == "main" ? "MAIN" : ScreenView.undated(st["name"] as? String ?? "")
        let label = kind == "return" ? rawName.replacingOccurrences(of: "-", with: " · ").uppercased() : rawName.uppercased()
        drawTextV(label, head.offsetBy(dx: 0, dy: 1), size: 15, color: Theme.text, weight: .regular, center: true, tracking: 0.06)
        if index >= 0 { buttons.append((head, { [weak self] in
            guard let self else { return }
            _ = self.trackTapped(index, selected: isSel)
            self.link.send(["cmd": "pick_track", "index": index]) })) }
        // pan: a small knob with its value
        let pan = st["pan"] as? Double ?? 0
        let pc = NSPoint(x: r.midX, y: head.maxY + 30)
        drawMiniKnob(pc, 15, (pan + 1) / 2, bipolar: true, color: tc == hex(0xeef0f1) ? Theme.value : tc)
        let panText = (st["pan_text"] as? String ?? "C")
        drawText(panText, NSPoint(x: r.minX, y: pc.y + 20), size: 12, color: Theme.dim, weight: .regular, center: true, width: r.width)
        mixHits.append((NSRect(x: r.minX, y: pc.y - 24, width: r.width, height: 50), index, "pan", 0, pan, -1, 1, 220))
        // the sends: A · B (to the returns), small knobs side by side — drag up / down
        var sendBottom = pc.y + 34
        let sendList = kind == "track" ? (st["sends"] as? [[Any]] ?? []) : []
        if !sendList.isEmpty {
            let sy = pc.y + 54, n = min(2, sendList.count), sw = r.width / CGFloat(n)
            for k in 0..<n {
                let sv = (sendList[k].first as? Double) ?? 0
                let sc = NSPoint(x: r.minX + sw * (CGFloat(k) + 0.5), y: sy)
                drawMiniKnob(sc, 11, sv, color: Theme.value)
                drawText(k == 0 ? "A" : "B", NSPoint(x: sc.x - 20, y: sc.y + 14), size: 11, color: Theme.dim, weight: .regular, center: true, width: 40)
                mixHits.append((NSRect(x: r.minX + sw * CGFloat(k), y: sy - 18, width: sw, height: 44), index, "send", k, sv, 0, 1, 200))
            }
            sendBottom = sy + 30
        }
        // the fader shows what the header switch picked
        let sends = st["sends"] as? [[Any]] ?? []
        var value: Double, text: String, lo = 0.0, hi = 1.0, what = "volume", sendIx = 0
        switch param {
        case "pan": value = pan; text = panText; lo = -1; what = "pan"
        case "send0", "send1":
            sendIx = param == "send0" ? 0 : 1; what = "send"
            if kind != "main" && sendIx < sends.count { value = (sends[sendIx].first as? Double) ?? 0; text = sends[sendIx].count > 1 ? (sends[sendIx][1] as? String ?? "") : "" }
            else { value = st["volume"] as? Double ?? 0.85; text = st["vol_text"] as? String ?? ""; what = "volume" }
        default: value = st["volume"] as? Double ?? 0.85; text = st["vol_text"] as? String ?? ""
        }
        let fieldH: CGFloat = 52, btnH: CGFloat = 36
        let fTop = sendBottom + 10, fBot = r.maxY - 10 - btnH - 8 - fieldH - 10
        let track = NSRect(x: r.midX + 6, y: fTop, width: 4, height: max(40, fBot - fTop))
        let meter = NSRect(x: r.midX - 16, y: fTop, width: 10, height: track.height)
        hex(0x1c2c35).setFill(); NSBezierPath(roundedRect: meter, xRadius: 2, yRadius: 2).fill()
        meterRects.append(meter.insetBy(dx: -2, dy: -2))
        mixMeter(meter, meterIndex)
        hex(0x151617).setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let frac = CGFloat((value - lo) / (hi - lo))
        let capY = track.maxY - frac * track.height
        let cap = NSRect(x: track.midX - 13, y: capY - 9, width: 26, height: 18)
        hex(0xe6e9eb).setFill(); NSBezierPath(roundedRect: cap, xRadius: 2, yRadius: 2).fill()
        hex(0x6a6f74).setFill(); NSRect(x: cap.minX + 5, y: cap.midY - 0.5, width: cap.width - 10, height: 1).fill()
        mixHits.append((NSRect(x: r.minX, y: track.minY - 12, width: r.width, height: track.height + 24), index, what, sendIx, value, lo, hi, Double(track.height)))
        // the value (Q tag on the first four tracks)
        let fr = NSRect(x: r.minX + 6, y: r.maxY - 10 - btnH - 8 - fieldH, width: r.width - 12, height: fieldH)
        let lit = q != nil && touchedKnob != nil && touchedQ == (q! - 1)
        hex(0x33363a).setFill(); NSBezierPath(roundedRect: fr, xRadius: 3, yRadius: 3).fill()
        if mixDrag?.track == index || lit { Theme.accent.setStroke(); let o = NSBezierPath(roundedRect: fr.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
        drawTextV(text, NSRect(x: fr.minX + 10, y: fr.minY, width: fr.width - 30, height: fr.height), size: 24, color: mixDrag?.track == index ? Theme.value : Theme.text, weight: .light)
        if let q { drawText(String(format: "%02d", q), NSPoint(x: fr.maxX - 22, y: fr.minY + 4), size: 11, color: Theme.faint, weight: .regular) }
        // M S ● (returns + Main: no arm; Main: no buttons in Live's API for M/S)
        let bw = (r.width - 12 - 8) / 3, by = r.maxY - 10 - btnH
        let items: [(String, String)] = kind == "track" ? [("M", "mute"), ("S", "solo"), ("●", "arm")] : (kind == "return" ? [("M", "mute"), ("S", "solo")] : [])
        for (k, (t, w)) in items.enumerated() {
            let b = NSRect(x: r.minX + 6 + CGFloat(k) * (bw + 4), y: by, width: bw, height: btnH)
            let on = st[w] as? Bool ?? false
            let fill: NSColor = on ? (w == "arm" ? Theme.red : (w == "solo" ? Theme.value : Theme.active)) : hex(0x33363a)
            fill.setFill(); NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3).fill()
            drawTextV(t, b, size: 14, color: on ? Theme.darkInk : Theme.text, weight: .regular, center: true)
            buttons.append((b, { [weak self] in self?.link.send(["cmd": "track_toggle", "track": index, "what": w]) }))
        }
    }

    // a meter in the MPC colours: mint, yellow near the top, red at the very top
    func mixMeter(_ m: NSRect, _ i: Int) {
        let lv = i < meters.count ? meters[i] : [0, 0]
        let v = CGFloat(max(0, min(1, lv.prefix(2).max() ?? 0)))
        guard v > 0.005 else { return }
        let h = m.height * v
        let bar = NSRect(x: m.minX + 1, y: m.maxY - h, width: m.width - 2, height: h)
        Theme.value.setFill(); bar.fill()
        let yellowFrom = m.maxY - m.height * 0.8
        if bar.minY < yellowFrom { hex(0xe8c547).setFill(); NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: yellowFrom - bar.minY).fill() }
        let redFrom = m.maxY - m.height * 0.95
        if bar.minY < redFrom { Theme.red.setFill(); NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: redFrom - bar.minY).fill() }
    }

    func setLocalMix(_ track: Int, _ what: String, _ index: Int, _ v: Double) {
        guard var mx = state["mixer"] as? [String: Any] else { return }
        func upd(_ st: inout [String: Any]) {
            if what == "volume" { st["volume"] = v } else if what == "pan" { st["pan"] = v }
            else if var sends = st["sends"] as? [[Any]], index < sends.count { sends[index][0] = v; st["sends"] = sends }
        }
        if track == -1, var m = mx["master"] as? [String: Any] { upd(&m); mx["master"] = m }
        else if track <= -2, var rs = mx["returns"] as? [[String: Any]], let k = rs.firstIndex(where: { ($0["index"] as? Int) == track }) { upd(&rs[k]); mx["returns"] = rs }
        else if var strips = mx["strips"] as? [[String: Any]], let k = strips.firstIndex(where: { ($0["index"] as? Int) == track }) {
            upd(&strips[k]); mx["strips"] = strips
        }
        state["mixer"] = mx; needsDisplay = true
    }

    func drawMeter(_ m: NSRect, _ i: Int) {
        NSColor.black.setFill(); m.fill()
        let lv = i < meters.count ? meters[i] : [0, 0]
        for (k, v) in lv.prefix(2).enumerated() {
            let h = m.height * CGFloat(max(0, min(1, v)))
            let bar = NSRect(x: m.minX + 1 + CGFloat(k) * (m.width / 2), y: m.maxY - h, width: m.width / 2 - 2, height: h)
            (v > 0.92 ? NSColor.systemRed : v > 0.75 ? NSColor.systemYellow : Theme.play).setFill(); bar.fill()
        }
    }

    // finger on a fader / knob of the mixer: (area, track, what, send index, value now, min, max, px for full range)
    var mixHits: [(NSRect, Int, String, Int, Double, Double, Double, Double)] = []
    var mixDrag: (track: Int, what: String, index: Int, y: CGFloat, start: Double, lo: Double, hi: Double, px: Double)? = nil

    // routing popup: big tappable list
    func drawChoice() {
        guard let c = choice else { return }
        let cols = 3, h: CGFloat = 52
        let rows = (c.options.count + cols - 1) / cols
        let win = mpcWindow(c.title, width: 1100, height: CGFloat(rows) * (h + 8) + 48 + 40) { [weak self] in self?.choice = nil; self?.needsDisplay = true }
        let w = (win.width - CGFloat(cols - 1) * 8) / CGFloat(cols)
        for (i, o) in c.options.enumerated() {
            let r = NSRect(x: win.minX + CGFloat(i % cols) * (w + 8), y: win.minY + CGFloat(i / cols) * (h + 8), width: w, height: h)
            if r.maxY > bounds.height - 8 { break }
            button(r, o, on: o == c.current, size: 15) { [weak self] in self?.choice?.pick(i); self?.choice = nil; self?.needsDisplay = true }
        }
    }

    // MARK: PADS — the Drum Rack's 16 pads like the hardware (pad 1 bottom-left); tap = select + hear, load samples
    var pads: [String: Any]? { state["pads"] as? [String: Any] }
    static let padMap = [0, 0, 2, 2, 1, 1, 4, 4, 3, 5, 5, 6, 7, 9, 8, -1]    // the mockup's pad colours (pad 1 = index 0)
    static func padColour(_ i: Int) -> NSColor {
        let k = padMap[((i % 16) + 16) % 16]
        return k < 0 ? hex(0xd9d9de) : Theme.palette[k].color
    }
    // PADS / KIT (mockup "KIT · drum pads"): amber header · 4x4 pads (pad 1 bottom-left, like the Touch) · the selected pad: its sound's
    // Q-Links, PAD BANK, 16 LEVELS, MUTE / SOLO, EDIT SAMPLE, load buttons · F-keys KIT STEPS DEVICE | − BANK + | LOAD | CHOP A SAMPLE
    func drawPads() {
        let (pcol, pstripe) = ScreenView.pageColour[.pads]!
        mpcStrip()
        let pd = pads, list = pd?["pads"] as? [[String: Any]] ?? []
        let bank = pd?["bank"] as? Int ?? 0
        let bankL = String(UnicodeScalar(UInt8(65 + max(0, min(7, bank)))))
        let selPad = list.first { $0["selected"] as? Bool ?? false }
        let selIndex = list.firstIndex { $0["selected"] as? Bool ?? false } ?? 0
        // nothing picked in this bank: LOAD goes to its first free pad (never silently onto A01 in another bank)
        let freeIdx = list.firstIndex { !($0["filled"] as? Bool ?? false) } ?? 0
        let target = selPad ?? (list.isEmpty ? nil : list[freeIdx])
        let tIdx = selPad == nil ? freeIdx : selIndex
        let targetName = (target?["filled"] as? Bool ?? false) ? (target?["name"] as? String ?? "") : String(format: "%@%02d", bankL, tIdx + 1)
        let note = target?["note"] as? Int ?? 36, selName = selPad == nil ? "Tap a pad" : ((selPad?["filled"] as? Bool ?? false) ? ScreenView.undated(selPad?["name"] as? String ?? "") : "Empty pad")
        let filled = selPad?["filled"] as? Bool ?? false
        let clearArmed = Date().timeIntervalSince(deleteArmedAt) < 3
        mpcHeader(pcol, icon: "kit",
                  name: HeaderField(label: "Kit", value: pd?["rack"] as? String ?? "No Drum Rack", action: nil),
                  fields: [HeaderField(label: "Pad", value: selPad == nil ? "–" : String(format: "%@%02d · %@", bankL, selIndex + 1, selName), action: nil)],
                  tools: [Tool(glyph: "audition", on: false, action: { [weak self] in self?.link.send(["cmd": "pad_select", "note": note]) }),   // hear the pad
                          Tool(glyph: "chop", on: false, action: { [weak self] in self?.browseChop() }),                                      // chop a sample (new track)
                          Tool(glyph: "browse", on: false, action: { [weak self] in self?.browseForPad(note, targetName, ["Samples"]) }),    // load / replace the pad's sound
                          Tool(glyph: "delete", on: false, action: { [weak self] in                                                         // clear the pad: tap twice
                              guard let self, filled else { return }
                              if Date().timeIntervalSince(self.deleteArmedAt) < 3 { self.deleteArmedAt = .distantPast; self.link.send(["cmd": "pad_clear", "note": note]) }
                              else {
                                  self.deleteArmedAt = Date(); self.noticeText = "Tap the bin again to clear " + selName; self.noticeAt = Date()
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.needsDisplay = true }
                              }
                              self.needsDisplay = true }, tint: clearArmed && filled ? Theme.red : nil)])
        let tabs = trackTabs(.pads)
        let rep = pd?["repeat"] as? [String: Any] ?? [:]
        let repOn = rep["on"] as? Bool ?? false, metro = songInfo["metronome"] as? Bool ?? false
        let actions = [FKey(glyph: "repeat", title: "NOTE REPEAT " + (rep["rate"] as? String ?? "1/16"), on: repOn, weight: 1.3,
                            action: { [weak self] in self?.link.send(["cmd": "note_repeat"]) }),
                       FKey(glyph: "metro", title: "METRO", on: metro, action: { [weak self] in self?.link.send(["cmd": "song_set", "what": "metronome"]) }),
                       FKey(glyph: "add", title: "NEW KIT", action: { [weak self] in
                           guard let self else { return }
                           self.pageBeforeBrowse = .pads; self.browsePath = ["Drums"]; self.browseEntryDepth = 1; self.browseNewTrack = true
                           self.show(.browse); self.enterBrowse() })]
        defer { mpcFBar(tabs: tabs, actions: actions, stripe: pstripe) }
        guard !list.isEmpty else {
            drawText("No Drum Rack on this track", NSPoint(x: 0, y: bounds.midY - 20), size: 26, color: Theme.hint, weight: .light, center: true, width: bounds.width); return
        }
        let lvState = state["levels"] as? [String: Any] ?? [:]
        let levelsOn = lvState["on"] as? Bool ?? false, levelsParam = lvState["param"] as? String ?? "velocity"
        let oneColour = Set(list.compactMap { $0["color"] as? Int }).count <= 1
        func padColour(_ i: Int, _ p: [String: Any]) -> NSColor { oneColour ? ScreenView.padColour(i) : Theme.live(p["color"] as? Int) }
        // the pads (620 wide, 4x4, fill the height)
        let top: CGFloat = 104 + 16, bottom = bounds.height - 56 - 16, gap: CGFloat = 10
        let gw: CGFloat = 620, cw = (gw - 3 * gap) / 4, ch = (bottom - top - 3 * gap) / 4
        for (i, p) in list.enumerated() where i < 16 {
            let col = i % 4, row = 3 - i / 4
            let r = NSRect(x: 16 + CGFloat(col) * (cw + gap), y: top + CGFloat(row) * (ch + gap), width: cw, height: ch)
            let pfilled = p["filled"] as? Bool ?? false, sel = p["selected"] as? Bool ?? false, mute = p["mute"] as? Bool ?? false, solo = p["solo"] as? Bool ?? false
            var name = ScreenView.undated(p["name"] as? String ?? ""), sub = ScreenView.undated(p["sample"] as? String ?? "")
            var colour = padColour(i, p), level: CGFloat = 1
            if levelsOn, let sp = selPad {                          // 16 Levels: the selected sound on every pad
                name = sp["name"] as? String ?? ""; colour = padColour(selIndex, sp)
                level = CGFloat(i) / 15
                switch levelsParam {
                case "tune": sub = (i - 8 > 0 ? "+" : "") + "\(i - 8) st"
                case "filter": let hz = 200 * pow(90, Double(i) / 15); sub = hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : "\(Int(hz)) Hz"
                default: sub = "velocity \(Int((8 + Double(i) * 119 / 15).rounded()))"
                }
                swap(&name, &sub)                                       // the value is what each pad is about
            }
            if sub == name { sub = "" }
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            if pfilled || levelsOn {
                (sel && !levelsOn ? colour.blended(withFraction: 0.72, of: Theme.panel)! : hex(0x2f3235)).setFill(); path.fill()
                if levelsOn { colour.withAlphaComponent(0.15 + 0.55 * level).setFill(); path.fill() }
                NSGraphicsContext.saveGraphicsState(); path.setClip()
                colour.withAlphaComponent(mute ? 0.25 : (sel ? 1 : 0.6)).setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: 4).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                hex(0x2a2c2f).setFill(); path.fill()
                hex(0x4a4e52).setStroke(); let d = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                d.lineWidth = 1; d.setLineDash([5, 4], count: 2, phase: 0); d.stroke()
                drawGlyph("add", NSRect(x: r.midX - 12, y: r.midY - 12, width: 24, height: 24), Theme.faint)
            }
            if sel && !levelsOn { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4); o.lineWidth = 1.5; o.stroke() }
            let ink: NSColor = mute ? Theme.faint : Theme.text
            drawText(String(format: "%@%02d", bankL, i + 1), NSPoint(x: r.minX + 12, y: r.minY + 12), size: 13, color: Theme.dim, weight: .regular)
            if solo || mute { drawText(solo ? "SOLO" : "MUTE", NSPoint(x: r.maxX - 60, y: r.minY + 12), size: 12, color: solo ? Theme.value : Theme.faint, weight: .regular, width: 48, right: true) }
            if pfilled || levelsOn {
                drawText(name, NSPoint(x: r.minX + 12, y: r.maxY - 12 - lineH(13) - 2 - lineH(17)), size: 17, color: ink, weight: .regular, width: r.width - 24)
                drawText(sub, NSPoint(x: r.minX + 12, y: r.maxY - 12 - lineH(13)), size: 13, color: levelsOn || sel ? NSColor.white.withAlphaComponent(0.72) : Theme.faint, weight: .regular, width: r.width - 24)
            }
            let pn = p["note"] as? Int ?? 0, pname = pfilled ? (p["name"] as? String ?? "") : String(format: "%@%02d", bankL, i + 1)
            holdables.append((r, tap: { [weak self] in
                guard let self else { return }
                self.link.send(["cmd": "pad_select", "note": pn])
                if !pfilled && !levelsOn { self.browseForPad(pn, pname, ["Samples"]) }
            }, hold: { [weak self] in self?.browseForPad(pn, pname, ["Samples"]) }))
        }
        // the selected pad (right panel, mockup): name · its waveform · Q1–Q4 · PAD BANK · PADS PLAY + MUTE / SOLO · EDIT SAMPLE · ADD FX · 16 LEVELS
        let px = 16 + gw + 16, pw = bounds.width - 16 - px
        let panel = NSRect(x: px, y: top, width: pw, height: bottom - top)
        Theme.panel.setFill(); NSBezierPath(roundedRect: panel, xRadius: 4, yRadius: 4).fill()
        let ix = panel.minX + 14, iw = panel.width - 28
        var y = panel.minY + 14
        drawText(String(format: "PAD %@%02d", bankL, selIndex + 1), NSPoint(x: ix, y: y + 9), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        drawText(selName, NSPoint(x: ix + 64, y: y), size: 26, color: Theme.text, weight: .light, width: iw - 64)
        y += lineH(26) + 10
        // its waveform (teal well)
        let well = NSRect(x: ix, y: y, width: iw, height: 120)
        hex(0x1b3c48).setFill(); NSBezierPath(roundedRect: well, xRadius: 3, yRadius: 3).fill()
        if let path = selPad?["file"] as? String, !path.isEmpty {
            let pk = arrPeaks[path] ?? { let n = Peaks(); arrPeaks[path] = n; n.load(path) { [weak self] in self?.needsDisplay = true }; return n }()
            if !pk.maxs.isEmpty {
                let n = pk.maxs.count, cols = Int(well.width - 8), mid = well.midY, amp = (well.height - 16) / 2
                let reg = (selPad?["region"] as? [Int]) ?? []                     // only the part this pad plays (a chop)
                let len = max(1, reg.count == 3 ? reg[2] : pk.frames)
                let f0 = reg.count == 3 ? max(0, min(reg[0], len)) : 0, f1 = reg.count == 3 ? max(f0 + 1, min(reg[1], len)) : len
                let bs = f0 * n / len, be = min(n, max(bs + 1, f1 * n / len))
                var rp: Float = 0.01                                               // scaled to this piece's own peak
                for b in bs..<be { rp = max(rp, pk.maxs[b], -pk.mins[b]) }
                let wave = NSBezierPath()
                for c in 0..<cols {
                    let b0 = bs + c * (be - bs) / cols, b1 = max(b0 + 1, bs + (c + 1) * (be - bs) / cols)
                    var hi: Float = 0, lo: Float = 0
                    for b in b0..<min(n, b1) { hi = max(hi, pk.maxs[b]); lo = min(lo, pk.mins[b]) }
                    let x = well.minX + 4 + CGFloat(c)
                    wave.append(NSBezierPath(rect: NSRect(x: x, y: mid - CGFloat(hi / rp) * amp, width: 1, height: max(1, CGFloat((hi - lo) / rp) * amp))))
                }
                hex(0xeef0f1).setFill(); wave.fill()
            }
        } else {
            drawText(filled ? "a synth sound (no sample)" : "empty: hold the pad or tap the folder to load a sound", NSPoint(x: well.minX, y: well.midY - 10), size: 14, color: hex(0xc9ced2), weight: .regular, center: true, width: well.width)
        }
        if filled { buttons.append((well, { [weak self] in
            guard let self else { return }; self.link.send(["cmd": "pad_select", "note": note]); self.page = .sample; self.needsDisplay = true })) }   // tap = edit it
        y = well.maxY + 12
        // the pad's sound on the Q-Links (DEVICE follows the selected pad)
        let qOn = (state["device"] as? [String: Any])?["name"] as? String ?? ""
        if selPad != nil && !filled {
            y += 74 + 12
        } else if let dev = state["device"] as? [String: Any], let params = dev["params"] as? [[String: Any]] {
            let pages = dev["pages"] as? [[Int]] ?? [], qp = dev["qlink_page"] as? Int ?? 0
            let idx = qp < pages.count ? pages[qp] : Array(0..<min(4, params.count))
            let fw = (iw - 3 * 8) / 4
            for (k, pi) in idx.prefix(4).enumerated() where pi < params.count {
                let pr = params[pi]
                let on = touchedKnob == pi
                mpcField(NSRect(x: ix + CGFloat(k) * (fw + 8), y: y, width: fw, height: 74), label: pr["name"] as? String ?? "", value: pr["text"] as? String ?? "",
                         q: k + 1, active: on, mint: on, valueSize: 24)
            }
            if selPad == nil && !qOn.isEmpty { drawText("Q-Links on " + qOn, NSPoint(x: ix, y: y + 78), size: 12, color: Theme.faint, weight: .regular) }
            y += 74 + 12
        }
        let (bb, _) = mpcSeg(ix, y, label: "Pad bank", ["A", "B", "C", "D", "E", "F", "G", "H"], selected: bank, h: 42, minW: 40) { [weak self] k in
            self?.link.send(["cmd": "pad_bank", "bank": k]) }
        y = bb.maxY + 12
        let full = (state["levels"] as? [String: Any])?["full"] as? Bool ?? false
        let (pb, _) = mpcSeg(ix, y, label: "Pads play", ["VELOCITY", "FULL LEVEL"], selected: full ? 1 : 0, h: 42) { [weak self] k in
            self?.link.send(["cmd": "full_level", "on": k == 1])
            if var lv = self?.state["levels"] as? [String: Any] { lv["full"] = k == 1; self?.state["levels"] = lv; self?.needsDisplay = true } }
        let muted = selPad?["mute"] as? Bool ?? false, soloed = selPad?["solo"] as? Bool ?? false
        if filled {
            mpcSeg(pb.maxX + 12, y, label: "This pad", ["MUTE", "SOLO"], selected: soloed ? 1 : (muted ? 0 : nil), h: 42) { [weak self] k in
                self?.link.send(["cmd": k == 0 ? "pad_mute" : "pad_solo", "note": note]) }
        }
        y = pb.maxY + 10
        let hints = ["velocity": "16 LEVELS · velocity: pad 1 = softest, pad 16 = hardest", "tune": "16 LEVELS · tune: pad 9 = original pitch, play it like a keyboard",
                     "filter": "16 LEVELS · filter: pad 1 = dark, pad 16 = open"]
        drawPara(levelsOn ? (hints[levelsParam] ?? "") : "Tap a pad to pick and hear it · hold a pad to load a sound into it.", NSPoint(x: ix, y: y), width: iw, size: 14, color: Theme.hint, weight: .regular, lines: 2)
        // bottom: EDIT SAMPLE · ADD FX · 16 LEVELS (tap = off → velocity → tune → filter → off)
        let byb = panel.maxY - 14 - 46, w3 = (iw - 16) / 3
        mpcButton(NSRect(x: ix, y: byb, width: w3, height: 46), "EDIT SAMPLE", glyph: "wave") { [weak self] in
            guard let self, filled else { return }
            self.link.send(["cmd": "pad_select", "note": note]); self.page = .sample; self.needsDisplay = true }
        mpcButton(NSRect(x: ix + w3 + 8, y: byb, width: w3, height: 46), "ADD FX", glyph: "fx") { [weak self] in
            guard let self else { return }
            self.link.send(["cmd": "pad_select", "note": note]); self.fxPick = true; self.page = .device; self.needsDisplay = true }
        let lvOrder = ["velocity", "tune", "filter"]
        mpcButton(NSRect(x: ix + 2 * (w3 + 8), y: byb, width: w3, height: 46), levelsOn ? "16 LEVELS · " + levelsParam.uppercased() : "16 LEVELS", glyph: "pads", style: levelsOn ? .light : .dark) { [weak self] in
            guard let self else { return }
            if !levelsOn { self.link.send(["cmd": "levels", "on": true, "param": "velocity"]) }
            else if let i = lvOrder.firstIndex(of: levelsParam), i + 1 < lvOrder.count { self.link.send(["cmd": "levels", "on": true, "param": lvOrder[i + 1]]) }
            else { self.link.send(["cmd": "levels", "on": false]) } }
    }

    // the F-bar's page tabs for this track: drums KIT · STEPS · DEVICE, a Simpler SAMPLE · STEPS · DEVICE, an instrument CHORDS · NOTES · DEVICE
    func trackTabs(_ active: Page) -> [FKey] {
        if trackKind == "audio" || trackKind == "other" {
            return [FKey(glyph: "session", title: "SESSION", action: { [weak self] in self?.show(.session) }),
                    FKey(glyph: "device", title: "DEVICE", on: active == .device, action: { [weak self] in self?.page = .device; self?.needsDisplay = true })]
        }
        let first: FKey
        if trackKind == "drum" { first = FKey(glyph: "kit", title: "KIT", on: active == .pads, action: { [weak self] in self?.lastDrumView = .pads; self?.page = .pads; self?.needsDisplay = true }) }
        else if isSamplerTrack { first = FKey(glyph: "wave", title: "SAMPLE", on: active == .sample, action: { [weak self] in self?.page = .sample; self?.needsDisplay = true }) }
        else { first = FKey(glyph: "chords", title: "CHORDS", on: active == .pads, action: { [weak self] in
            guard let self else { return }
            if !self.chordsOn { self.setChords(true) }; self.page = .pads; self.needsDisplay = true }) }
        let melodicSeq = trackKind == "instrument" || trackKind == "empty"
        return [first,
                FKey(glyph: melodicSeq ? "notes" : "steps", title: melodicSeq ? "NOTES" : "STEPS", on: active == .steps, action: { [weak self] in self?.openSequencer() }),
                FKey(glyph: "device", title: "DEVICE", on: active == .device, action: { [weak self] in self?.page = .device; self?.needsDisplay = true })]
    }

    // CHORDS (KEYS / BASS tracks): one pad = one chord of the song's key, MPC Pad Perform style.
    // [4x4 chord pads, pad 1 bottom-left: 1-8 = I … vii + I, 9-16 = richer] [STYLE · OCTAVE · KEY · hint]
    static let chordStyles: [(String, String, String)] = [
        ("rnb", "R&B", "7ths and 9ths over the root: Rhodes, D'Angelo, Dilla. Pads 9–16 add the 11th / 13th."),
        ("lofi", "LO-FI", "Jazz shells, 3rd + 7th (+ 9th) over the root: dusty, room for the sample."),
        ("gospel", "GOSPEL", "Big and wide, up to the 13th over the root: church chords, keys solos."),
        ("house", "HOUSE", "Rootless m7 / maj7 stabs in one octave: organ and piano house. Let the bass play the root."),
        ("deep", "DEEP", "Minor 9 / 11 stabs, low and rootless: deep house, late-night."),
        ("disco", "DISCO", "Bright triads with the octave: disco, French house, filter loops."),
        ("dark", "DARK", "Open 1 · 5 · 9, no 3rd: trap, drill, cinematic."),
        ("triads", "SIMPLE", "Plain triads: easy to layer, good for pads and strings.")]
    func drawChords() {
        // MPC-2 (mockup "CHORDS · chord pads"): violet header · 4x4 chord pads in calm degree tones (held = lit) · key, style, octave · CHORD PADS ON
        let pcol = hex(0x5f4b9b), pstripe = hex(0x8d74d6)
        mpcStrip()
        let ch = state["chords"] as? [String: Any]
        let list = ch?["pads"] as? [[String: Any]] ?? []
        let held = Set((ch?["held"] as? [Int]) ?? []), style = ch?["style"] as? String ?? "rnb", oct = ch?["oct"] as? Int ?? 0
        let heldPad = held.sorted().first.flatMap { $0 < list.count ? list[$0] : nil }
        let tname = (state["track"] as? [String: Any])?["name"] as? String ?? ""
        mpcHeader(pcol, icon: "chords", name: HeaderField(label: "Track", value: tname + (currentInstrument.isEmpty ? "" : " · " + currentInstrument),
                                                           action: { [weak self] in self?.showPicker.toggle(); self?.needsDisplay = true }),
                  fields: [HeaderField(label: "Playing", value: heldPad.map { ($0["name"] as? String ?? "") + " · " + ($0["degree"] as? String ?? "") } ?? "–", action: nil)],
                  tools: [Tool(glyph: "chords", on: true, action: {}),                                                  // pads = chords (this page)
                          Tool(glyph: "keyboard", on: false, action: { [weak self] in self?.setChords(false) })])       // pads = single notes
        let tabs = trackTabs(.pads)
        let rep = pads?["repeat"] as? [String: Any] ?? [:]
        let lrBars = (state["looprec"] as? [String: Any])?["bars"] as? Int ?? 2
        let actions = [FKey(glyph: "key", title: "KEY & SCALE", action: { [weak self] in self?.tempoEdit = false; self?.keyEdit = true; self?.needsDisplay = true }),
                       FKey(glyph: "repeat", title: "NOTE REPEAT", on: rep["on"] as? Bool ?? false, action: { [weak self] in self?.link.send(["cmd": "note_repeat"]) }),
                       FKey(glyph: "rec", title: lrBars > 0 ? "REC \(lrBars) BARS" : "REC", on: (state["recording"] as? Bool ?? false), action: { [weak self] in self?.link.send(["cmd": "rec"]) })]
        defer { mpcFBar(tabs: tabs, actions: actions, stripe: pstripe) }
        guard list.count >= 16 else {
            drawText("Chords appear here for instrument tracks", NSPoint(x: 0, y: bounds.midY - 20), size: 26, color: Theme.hint, weight: .light, center: true, width: bounds.width)
            return
        }
        let top: CGFloat = 104 + 16, bottom = bounds.height - 56 - 16, gap: CGFloat = 10
        let gw: CGFloat = 760, cw = (gw - 3 * gap) / 4, chh = (bottom - top - 3 * gap) / 4
        let tones = [hex(0x4a3d6e), hex(0x3d3f52), hex(0x3d5158), hex(0x43404f), hex(0x3b4a5c), hex(0x4c4560), hex(0x4a4d3f), hex(0x4a3d6e)]
        for (i, p) in list.enumerated() where i < 16 {
            let col = i % 4, row = 3 - i / 4
            let r = NSRect(x: 16 + CGFloat(col) * (cw + gap), y: top + CGFloat(row) * (chh + gap), width: cw, height: chh)
            let on = held.contains(i)
            (on ? tcolor : tones[(p["deg"] as? Int ?? i % 8) % 8]).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()   // colour = the degree
            if on { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4); o.lineWidth = 1.5; o.stroke() }
            let ink = on ? Theme.ink(tcolor) : Theme.text
            drawText(p["degree"] as? String ?? "", NSPoint(x: r.minX + 12, y: r.minY + 10), size: 15, color: on ? ink.withAlphaComponent(0.7) : hex(0xb9bdd0), weight: .regular)
            drawText("\(i + 1)", NSPoint(x: r.maxX - 12 - 30, y: r.minY + 10), size: 13, color: ink.withAlphaComponent(0.45), weight: .regular, width: 30, right: true)
            drawText(p["name"] as? String ?? "", NSPoint(x: r.minX + 12, y: r.maxY - 12 - lineH(26)), size: 26, color: ink, weight: .light, width: r.width - 24)
            buttons.append((r, { [weak self] in                               // the screen pad: hear the chord
                self?.link.send(["cmd": "chord_play", "pad": i, "on": true, "velocity": 100])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.link.send(["cmd": "chord_play", "pad": i, "on": false]) }
            }))
        }
        // right panel
        let px = 16 + gw + 16, pw = bounds.width - 16 - px
        let panel = NSRect(x: px, y: top, width: pw, height: bottom - top)
        Theme.panel.setFill(); NSBezierPath(roundedRect: panel, xRadius: 4, yRadius: 4).fill()
        let ix = panel.minX + 16, iw = panel.width - 32
        var y = panel.minY + 14
        let si = songInfo
        let keyName = ScreenView.rootNames[max(0, min(11, si["root"] as? Int ?? 0))] + " " + (si["scale"] as? String ?? "").lowercased()
        mpcField(NSRect(x: ix, y: y, width: iw * 0.6, height: 76), label: "Chords in", value: keyName, mint: true, fill: nil) { [weak self] in
            self?.tempoEdit = false; self?.keyEdit = true; self?.needsDisplay = true }
        let notes: String = {                                          // the notes of the chord you hold (right, like the mockup)
            let ns = (heldPad?["notes"] as? [Int]) ?? []
            let root = si["root"] as? Int ?? 0, minor = (si["scale"] as? String ?? "").lowercased().contains("minor")
            let flat = [5, 10, 3, 8, 1, 6].contains(minor ? (root + 3) % 12 : root)
            let names = flat ? ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"] : ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
            return ns.sorted().map { names[$0 % 12] }.joined(separator: " ")
        }()
        drawText("NOTES", NSPoint(x: ix + iw - 140, y: y + 10), size: 12, color: Theme.dim, weight: .regular, width: 140, tracking: 0.11, right: true)
        drawText(notes.isEmpty ? "–" : notes, NSPoint(x: ix + iw * 0.6, y: y + 10 + lineH(12) + 6), size: 20, color: Theme.hint, weight: .regular, width: iw * 0.4, tracking: 0.12, right: true)
        y += 76 + 10
        // STYLE: 8 presets in two rows of 4
        let keys = ScreenView.chordStyles.map { $0.0 }, cur = keys.firstIndex(of: style)
        drawText("STYLE", NSPoint(x: ix, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 6
        for row in 0..<2 {
            let opts = (0..<4).map { ScreenView.chordStyles[row * 4 + $0].1 }
            let (rb, _) = mpcSeg(ix, y, opts, selected: cur.flatMap { $0 / 4 == row ? $0 % 4 : nil }, h: 42, minW: (iw - 8 - 9) / 4) { [weak self] k in
                let key = keys[row * 4 + k]
                self?.link.send(["cmd": "chord_style", "style": key])
                if var c = self?.state["chords"] as? [String: Any] { c["style"] = key; self?.state["chords"] = c; self?.needsDisplay = true } }
            y = rb.maxY + 4
        }
        drawPara(ScreenView.chordStyles.first { $0.0 == style }?.2 ?? "", NSPoint(x: ix, y: y + 4), width: iw, size: 14, color: Theme.hint, weight: .regular, lines: 2, lh: 1.3)
        y += 4 + 2 * 14 * 1.3 + 12
        // PADS PLAY: CHORDS (pad = a degree of the key) · PROGRESSIONS (each row = a progression of this style, in order)
        let prog = (ch?["mode_cp"] as? String) == "prog"
        let (mb, _) = mpcSeg(ix, y, label: prog ? "Pads play · each row = a progression" : "Pads play", ["CHORDS", "PROGRESSIONS"], selected: prog ? 1 : 0, h: 42, minW: (iw - 8 - 3) / 2) { [weak self] k in
            self?.link.send(["cmd": "chord_mode", "mode": k == 1 ? "prog" : "chords"])
            if var c = self?.state["chords"] as? [String: Any] { c["mode_cp"] = k == 1 ? "prog" : "chords"; self?.state["chords"] = c; self?.needsDisplay = true } }
        y = mb.maxY + 14
        // BANK A–D (the pad bank buttons on the Touch): A = in key · B C D = borrowed colours
        let bank = ch?["bank"] as? Int ?? 0, bnames = ch?["bank_names"] as? [String] ?? ["IN KEY", "", "", ""]
        let bw = (iw - 12) / 2
        let (bb, _) = mpcSeg(ix, y, label: "Bank · " + (bank < bnames.count ? bnames[bank].lowercased() : ""), ["A", "B", "C", "D"], selected: bank, h: 42, minW: (bw - 8 - 9) / 4) { [weak self] k in
            self?.link.send(["cmd": "chord_bank", "bank": k])
            if var c = self?.state["chords"] as? [String: Any] { c["bank"] = k; self?.state["chords"] = c; self?.needsDisplay = true } }
        // OCTAVE (also the jog wheel)
        mpcSeg(ix + bw + 12, y, label: "Octave", ["−1", "0", "+1", "+2"], selected: oct >= -1 && oct <= 2 ? oct + 1 : nil, h: 42, minW: (bw - 8 - 9) / 4) { [weak self] k in
            self?.link.send(["cmd": "chord_oct", "by": (k - 1) - oct]) }
        y = bb.maxY + 16
        _ = y
        mpcButton(NSRect(x: ix, y: panel.maxY - 14 - 56, width: iw, height: 56), "CHORD PADS ON", glyph: "chords", style: .light, size: 15) { [weak self] in
            self?.setChords(false) }                                  // tap = off: single notes again
    }

    // CHOP A SAMPLE: pick a sample → a new track with a Simpler in Slice mode, ready to chop
    var chopTarget = false
    func browseChop() {
        pageBeforeBrowse = page
        browsePath = ["Samples"]; browseEntryDepth = 1; show(.browse); chopTarget = true; enterBrowse()
    }

    var sampleTarget = false                                  // browsing to replace the Simpler's sample
    func browseSamples() {
        pageBeforeBrowse = .sample
        browsePath = ["Samples"]; browseEntryDepth = 1; show(.browse); sampleTarget = true; enterBrowse()
    }

    func browseEffects() {
        pageBeforeBrowse = .device
        browsePath = ["Audio Effects"]; browseEntryDepth = 1; show(.browse); enterBrowse()
    }

    func browseForPad(_ note: Int, _ name: String, _ root: [String]) {
        link.send(["cmd": "pad_select", "note": note])
        pageBeforeBrowse = .pads
        page = .browse                                         // (show() would clear the target)
        padTarget = (note, name)
        browsePath = root; browseEntryDepth = root.count; enterBrowse(); needsDisplay = true
    }

    // MARK: BROWSE page — Ableton's browser (incl. Places like a Splice folder) by touch
    var browsePath: [String] = []
    var browseEntryDepth = 0                                  // opened for a pad / sample / effect: BACK at this depth = back to that page
    var browseItems: [[String: Any]] = []
    var browseScroll: CGFloat = 0
    var browseSelected: String? = nil
    var browseHeard: String? = nil                            // tapped (heard) once: the next tap on it loads it
    let browseRowH: CGFloat = 46
    var browseAutoPreview = true                            // the headphones: hear what you land on
    var browseNewTrack = false
    var browseJump = false                                  // the A–Z letters over the list
    var browseKeys: [String: [String: Any]] = [:], browseBusy: Set<String> = []                              // opened with NEW KIT: what you load gets a new track

    // MARK: BROWSE (mockup "Browse"): categories · the list (tempo · key) · PREVIEW (waveform, tempo, key, how it fits) + where it goes
    var browseListRect: NSRect { NSRect(x: 274, y: topH + 12, width: 642, height: bounds.height - 56 - 12 - (topH + 12)) }
    var browsePreviewRect: NSRect { NSRect(x: 928, y: topH + 12, width: bounds.width - 12 - 928, height: bounds.height - 56 - 12 - (topH + 12)) }
    static let browseCats: [(root: String, title: String, glyph: String)] = [
        ("Sounds", "Sounds", "key"), ("Drums", "Drums", "sidechain"), ("Instruments", "Instruments", "keyboard"),
        ("Audio Effects", "Effects", "fx"), ("Samples", "Samples", "wave"), ("User Library", "My samples", "browse"), ("Favourites", "Favourites", "star")]
    // the sample files on disk by name (Live's browser gives no paths): for the preview's waveform + analysis; built once
    static var sampleIndex: [String: String] = [:]
    static var sampleIndexState = 0                           // 0 not yet · 1 building · 2 ready
    func samplePath(_ name: String) -> String? {
        if ScreenView.sampleIndexState == 0 {
            ScreenView.sampleIndexState = 1
            DispatchQueue.global(qos: .utility).async {
                var idx: [String: String] = [:]
                let fm = FileManager.default
                var roots = [NSHomeDirectory() + "/Music/Ableton/User Library", NSHomeDirectory() + "/Music/Ableton/Factory Packs", NSHomeDirectory() + "/Music/Ableton/Live Recordings"]
                for a in (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [] where a.hasPrefix("Ableton Live") { roots.append("/Applications/\(a)/Contents/App-Resources/Core Library") }
                let exts: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "ogg", "m4a"]
                for r in roots {
                    guard let en = fm.enumerator(atPath: r) else { continue }
                    while let rel = en.nextObject() as? String, idx.count < 400_000 {
                        if exts.contains((rel as NSString).pathExtension.lowercased()) { let n = (rel as NSString).lastPathComponent; if idx[n] == nil { idx[n] = r + "/" + rel } }
                    }
                }
                DispatchQueue.main.async { [weak self] in ScreenView.sampleIndex = idx; ScreenView.sampleIndexState = 2; if self?.page == .browse { self?.needsDisplay = true } }
            }
        }
        return ScreenView.sampleIndex[name]
    }
    // tempo + key of a sample in the list: the name first, else the audio (in the background, once per file)
    func browseKey(_ name: String) -> [String: Any]? {
        var info: [String: Any] = [:]
        if let b = Tempo.fromName(name) { info["bpm"] = b }
        if let k = KeyDetect.fromName(name) { info["root"] = k.root; info["minor"] = k.minor; info["single"] = k.single }
        guard let path = samplePath(name) else { return info.isEmpty ? nil : info }
        if let a = browseKeys[path] { return a.merging(info) { $1 } }
        if !browseBusy.contains(path) && !(info["bpm"] != nil && info["root"] != nil) {
            browseBusy.insert(path)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var r: [String: Any] = [:]
                if !KeyDetect.looksLikeDrums(path), let k = KeyDetect.detect(path), k.clarity >= 0.03 { r["root"] = k.root; r["minor"] = k.minor; r["single"] = k.single }
                if let (m, rate) = KeyDetect.loadMono(path), Double(m.count) / rate > 4, let t = Tempo.detect(mono: m, rate: rate) { r["bpm"] = t.bpm }
                DispatchQueue.main.async { guard let self else { return }; self.browseKeys[path] = r; self.browseBusy.remove(path); if self.page == .browse { self.needsDisplay = true } }
            }
        }
        return info.isEmpty ? nil : info
    }
    func keyText(_ k: [String: Any], long: Bool = false) -> String? {
        guard let root = k["root"] as? Int else { return nil }
        let single = k["single"] as? Bool ?? false, minor = k["minor"] as? Bool ?? false
        return ScreenView.rootNames[root % 12] + (single ? "" : (long ? (minor ? " minor" : " major") : (minor ? " min" : " maj")))
    }
    func keyFits(_ k: [String: Any]) -> Bool {
        guard let root = k["root"] as? Int else { return false }
        let single = k["single"] as? Bool ?? false, minor = k["minor"] as? Bool ?? false
        let songRoot = songInfo["root"] as? Int ?? 0, songMinor = (songInfo["scale"] as? String ?? "").lowercased().contains("minor")
        if single { return root % 12 == songRoot }
        return (minor == songMinor ? root : (minor ? root + 3 : root + 9)) % 12 == songRoot      // relative major / minor = the same notes
    }
    func browseItemGlyph(_ folder: Bool, root: String) -> String {
        if folder { return "browse" }
        return root.contains("Effects") ? "fx" : root == "Drums" ? "kit" : ["Instruments", "Sounds", "Plug-ins"].contains(root) ? "keyboard" : "wave"
    }
    func browseShown(_ name: String, folder: Bool) -> String {
        folder ? name : ScreenView.undated(name.replacingOccurrences(of: #"\.(adg|adv|amxd|wav|aif|aiff|flac|mp3|ogg|m4a|alc|als)$"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }
    func browseItemPath(_ item: [String: Any]) -> [String] { (item["path"] as? [String]) ?? browsePath + [item["name"] as? String ?? ""] }
    var browseInto: String { sampleTarget ? "Simpler" : chopTarget ? "a new chop track" : padTarget.map { "pad " + $0.name } ?? (browseNewTrack ? "a new track" : "") }
    // ★ favourites: kept on the Touch (Live has no way to add to its collections from here)
    var browseFavs: [[String]] {
        get { (UserDefaults.standard.array(forKey: "browseFavs") as? [[String]]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "browseFavs") }
    }

    func drawBrowse() {
        let (bcol, bstripe) = ScreenView.pageColour[.browse]!
        mpcStrip()
        let hi = browseIndex >= 0 && browseIndex < browseItems.count ? browseItems[browseIndex] : nil
        let hiPath = hi.map(browseItemPath)
        let isFav = hiPath.map { p in browseFavs.contains(p) } ?? false
        mpcHeader(bcol, icon: "browse", name: HeaderField(label: "Browse", value: browsePath.isEmpty ? "Ableton's browser" : browsePath.map { part in ScreenView.browseCats.first(where: { c in c.root == part })?.title ?? part }.joined(separator: "  ›  "), action: nil),
                  fields: [], tools: [
                    Tool(glyph: "audition", on: browseAutoPreview, action: { [weak self] in
                        guard let self else { return }; self.browseAutoPreview.toggle()
                        if !self.browseAutoPreview { self.link.send(["cmd": "browse_stop_preview"]) }; self.needsDisplay = true }),
                    Tool(glyph: "search", on: browseJump, action: { [weak self] in self?.browseJump.toggle(); self?.needsDisplay = true }),     // A–Z: jump to a letter
                    Tool(glyph: "star", on: isFav, action: { [weak self] in
                        guard let self, let p = hiPath, let it = hi, !((it["folder"] as? Bool ?? false) && !(it["loadable"] as? Bool ?? false)) else { return }
                        var f = self.browseFavs
                        if let i = f.firstIndex(of: p) { f.remove(at: i) } else { f.append(p) }
                        self.browseFavs = f
                        if self.browsePath == ["Favourites"] { self.enterBrowse() }
                        self.needsDisplay = true })],
                  nameWidth: 440)
        let opens = hi.map { ($0["folder"] as? Bool ?? false) && !($0["loadable"] as? Bool ?? false) } ?? true
        let bTabs = [FKey(glyph: "left", title: "BACK", action: { [weak self] in self?.browseBack() }),
                     FKey(glyph: "play", title: "PREVIEW", action: { [weak self] in
                         guard let self, let it = hi else { return }; self.previewItem(it) }),
                     hi?["search"] != nil ? FKey(glyph: "search", title: "SEARCH", on: true, action: { [weak self] in self?.activateBrowseSelection() })
                                          : FKey(glyph: opens ? "browse" : "load", title: opens ? "OPEN" : "LOAD", on: true, action: { [weak self] in self?.activateBrowseSelection() })]
        let bActions = [FKey(glyph: "up", title: "UP", action: { [weak self] in self?.moveBrowseSelection(-1) }),
                        FKey(glyph: "down", title: "DOWN", action: { [weak self] in self?.moveBrowseSelection(1) }),
                        FKey(glyph: nil, title: "", action: {}, note: "wheel = scroll · press = load")]
        defer { mpcFBar(tabs: bTabs, actions: bActions, stripe: bstripe) }
        // categories
        let cats = NSRect(x: 12, y: topH + 12, width: 250, height: browseListRect.height)
        Theme.panel.setFill(); NSBezierPath(roundedRect: cats, xRadius: 4, yRadius: 4).fill()
        var cy = cats.minY + 6
        let root = browsePath.first ?? ""
        for c in ScreenView.browseCats where cy + 52 <= cats.maxY {
            let r = NSRect(x: cats.minX + 8, y: cy, width: cats.width - 16, height: 52)
            let on = c.root == root
            if on { hex(0x4a4e52).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill() }
            drawGlyph(c.glyph, NSRect(x: r.minX + 14, y: r.midY - 10, width: 20, height: 20), on ? Theme.text : Theme.dim)
            drawTextV(c.title, NSRect(x: r.minX + 46, y: r.minY, width: r.width - 50, height: r.height), size: 18, color: Theme.text, weight: .regular)
            buttons.append((r, { [weak self] in
                guard let self else { return }
                self.browsePath = [c.root]; UserDefaults.standard.set(c.root, forKey: "browseRoot"); self.enterBrowse() }))
            cy += 54
        }
        // the list
        let list = browseListRect
        Theme.panel.setFill(); NSBezierPath(roundedRect: list, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: list.insetBy(dx: 0, dy: 4)).setClip()
        for (i, item) in browseItems.enumerated() {
            let r = NSRect(x: list.minX + 6, y: list.minY + 6 + CGFloat(i) * browseRowH - browseScroll, width: list.width - 12, height: browseRowH - 4)
            guard r.maxY > list.minY && r.minY < list.maxY else { continue }
            let name = item["name"] as? String ?? "", folder = (item["folder"] as? Bool ?? false) && !(item["loadable"] as? Bool ?? false)
            let path = browseItemPath(item), iroot = path.first ?? ""
            let sel = i == browseIndex
            if sel { Theme.active.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill() }
            else { hex(0x34383c).setFill(); NSRect(x: r.minX, y: r.maxY + 1, width: r.width, height: 1).fill() }
            let ink = sel ? Theme.darkInk : Theme.text
            drawGlyph(browseItemGlyph(folder, root: iroot), NSRect(x: r.minX + 14, y: r.midY - 9, width: 18, height: 18), sel ? Theme.darkInk : Theme.dim)
            var meta: String? = nil, fits = false
            if !folder, iroot == "Samples" || iroot == "User Library" || path.last.map({ ScreenView.sampleIndex[$0] != nil }) ?? false, let k = browseKey(path.last ?? name) {
                var parts: [String] = []
                if let b = k["bpm"] as? Double { parts.append(b == b.rounded() ? "\(Int(b))" : String(format: "%.0f", b)) }
                if let kt = keyText(k) { parts.append(kt) }
                fits = keyFits(k)
                if !parts.isEmpty { meta = parts.joined(separator: " · ") + (fits ? " ✓ key" : "") }
            }
            let mw: CGFloat = meta.map { textW($0, size: 13) + 16 } ?? 0
            drawTextV(item["label"] as? String ?? browseShown(name, folder: folder), NSRect(x: r.minX + 44, y: r.minY, width: r.width - 56 - mw, height: r.height), size: 18,
                      color: ink, weight: .regular)
            if let m = meta { drawTextV(m, NSRect(x: r.maxX - mw - 4, y: r.minY, width: mw, height: r.height), x: r.maxX - 12 - textW(m, size: 13), size: 13, color: sel ? Theme.darkInk : (fits ? Theme.value : Theme.faint), weight: .regular) }
            buttons.append((r.intersection(list), { [weak self] in
                guard let self else { return }
                if folder {
                    self.browsePath.append(name); self.enterBrowse()
                } else if self.browseIndex == i && self.browseHeard == name {
                    self.loadDefault(path)                                                     // second tap = load (the main choice)
                } else {
                    self.browseSelected = name; self.browseIndex = i; self.browseHeard = name
                    if self.browseAutoPreview { self.previewItem(item) }   // first tap = listen
                    self.needsDisplay = true
                }
            }))
        }
        NSGraphicsContext.restoreGraphicsState()
        if browseItems.isEmpty {
            drawText(browsePath == ["Favourites"] ? "No favourites yet: pick a sound and tap ★" : "…", NSPoint(x: list.minX, y: list.minY + 40), size: 18, color: Theme.dim, center: true, width: list.width)
        }
        drawBrowsePreview(hi)
        if browseJump { drawBrowseJump() }
    }

    // A–Z over the list: tap a letter = jump to the first name with it
    func drawBrowseJump() {
        let list = browseListRect
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ#").map(String.init)
        let cols = 9, gap: CGFloat = 6, w = (list.width - 24 - CGFloat(cols - 1) * gap) / CGFloat(cols), h: CGFloat = 54
        let box = NSRect(x: list.minX + 6, y: list.minY + 6, width: list.width - 12, height: 12 + 3 * (h + gap) - gap + 12)
        hex(0x1f2123).withAlphaComponent(0.97).setFill(); NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        buttons.append((box, {}))
        for (k, l) in letters.enumerated() {
            let r = NSRect(x: box.minX + 6 + CGFloat(k % cols) * (w + gap), y: box.minY + 12 + CGFloat(k / cols) * (h + gap), width: w, height: h)
            let idx = browseItems.firstIndex { n in
                let s = browseShown(n["name"] as? String ?? "", folder: false).uppercased()
                return l == "#" ? !(s.first?.isLetter ?? true) : s.hasPrefix(l) }
            mpcButton(r, l, size: 18) { [weak self] in
                guard let self else { return }
                self.browseJump = false
                if let i = idx { self.moveBrowseSelection(i - self.browseIndex) }
                self.needsDisplay = true }
            if idx == nil { Theme.panel.withAlphaComponent(0.6).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill() }
        }
    }

    // PREVIEW: the waveform, tempo / key, how it fits your beat, and the buttons for where it goes
    func drawBrowsePreview(_ item: [String: Any]?) {
        let pr = browsePreviewRect
        Theme.panel.setFill(); NSBezierPath(roundedRect: pr, xRadius: 4, yRadius: 4).fill()
        let x = pr.minX + 14, w = pr.width - 28
        var y = pr.minY + 14
        drawText("PREVIEW", NSPoint(x: x, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 6
        guard let item, let name = item["name"] as? String else {
            drawPara("Turn the wheel or tap a row to hear it, tap it again to load it.", NSPoint(x: x, y: y + 6), width: w, size: 15, color: Theme.hint, lines: 3)
            return
        }
        let folder = (item["folder"] as? Bool ?? false) && !(item["loadable"] as? Bool ?? false)
        let path = browseItemPath(item), root = path.first ?? ""
        let shown = item["label"] as? String ?? browseShown(name, folder: folder)
        drawPara(shown, NSPoint(x: x, y: y), width: w, size: 22, color: Theme.text, weight: .regular, lines: 2, lh: 1.15)
        y += (textW(shown, size: 22, weight: .regular) > w ? 2 : 1) * 22 * 1.15 + 12
        let well = NSRect(x: x, y: y, width: w, height: 96)
        hex(0x1b3c48).setFill(); NSBezierPath(roundedRect: well, xRadius: 3, yRadius: 3).fill()
        let file = folder ? nil : samplePath(path.last ?? name)
        if let file {                                            // the real waveform (white, like the mockup)
            let pk = arrPeaks[file] ?? { let n = Peaks(); arrPeaks[file] = n; n.load(file) { [weak self] in self?.setNeedsDisplay(self?.browsePreviewRect ?? .zero) }; return n }()
            if !pk.maxs.isEmpty {
                let n = pk.maxs.count, cols = Int(well.width - 8), mid = well.midY, amp = (well.height - 14) / 2
                let wave = NSBezierPath()
                for c in 0..<cols {
                    let b0 = c * n / cols, b1 = max(b0 + 1, (c + 1) * n / cols)
                    var hiV: Float = 0, lo: Float = 0
                    for b in b0..<min(n, b1) { hiV = max(hiV, pk.maxs[b]); lo = min(lo, pk.mins[b]) }
                    wave.append(NSBezierPath(rect: NSRect(x: well.minX + 4 + CGFloat(c), y: mid - CGFloat(hiV / pk.peak) * amp, width: 1, height: max(1, CGFloat((hiV - lo) / pk.peak) * amp))))
                }
                hex(0xeef0f1).setFill(); wave.fill()
            }
        } else {
            drawGlyph(browseItemGlyph(folder, root: root), NSRect(x: well.midX - 22, y: well.midY - 22, width: 44, height: 44), hex(0xeef0f1).withAlphaComponent(0.85), lw: 1.6)
        }
        y = well.maxY + 10
        if folder {
            drawPara("A folder: tap it (or OPEN) to look inside.", NSPoint(x: x, y: y), width: w, size: 15, color: Theme.hint, lines: 2)
            return
        }
        let isSample = file != nil || root == "Samples"
        if isSample {
            let k = browseKey(path.last ?? name) ?? [:]
            let fw = (w - 8) / 2
            let tb = k["bpm"] as? Double
            mpcField(NSRect(x: x, y: y, width: fw, height: 64), label: "Tempo", value: tb.map { String(format: "%.1f", $0) } ?? "–", mint: true, valueSize: 26)
            mpcField(NSRect(x: x + fw + 8, y: y, width: fw, height: 64), label: "Key", value: keyText(k, long: true) ?? (file.map { browseBusy.contains($0) } ?? false ? "…" : "–"), mint: true, valueSize: 26)
            y += 64 + 10
            let song = songInfo["tempo"] as? Double ?? 120
            var line = k["root"] == nil ? (KeyDetect.looksLikeDrums(path.last ?? name) ? "Drums: no key" : "No clear key") : (keyFits(k) ? "Same key as your beat" : "Another key: your beat can follow it")
            if let t = tb { line += String(format: " · will stretch %.0f → %.1f", t, song) }
            drawPara(line, NSPoint(x: x, y: y), width: w, size: 15, color: Theme.hint, lines: 3)
        }
        // where it goes (bottom)
        let bh: CGFloat = 48, by = pr.maxY - 14 - bh, hw = (w - 8) / 2
        let trackName = (state["track"] as? [String: Any])?["name"] as? String ?? "track"
        if isSample {                                            // samples: CHOP IT · INTO SIMPLER · ONTO A PAD (mockup)
            mpcButton(NSRect(x: x, y: by - bh - 12, width: w, height: bh), "CHOP IT · new track", glyph: "chop", style: .light) { [weak self] in
                guard let self else { return }; self.sampleTarget = false; self.padTarget = nil; self.chopTarget = true; self.load(path) }
            mpcButton(NSRect(x: x, y: by, width: hw, height: bh), "INTO SIMPLER") { [weak self] in
                guard let self else { return }
                self.chopTarget = false; self.padTarget = nil
                if self.isSamplerTrack { self.sampleTarget = true; self.load(path) } else { self.load(path, newTrack: true) } }
            let selPad = (pads?["pads"] as? [[String: Any]])?.first { $0["selected"] as? Bool ?? false }
            let padOK = trackKind == "drum" && (selPad != nil || padTarget != nil)
            mpcButton(NSRect(x: x + hw + 8, y: by, width: hw, height: bh), "ONTO A PAD") { [weak self] in
                guard let self, padOK else { return }
                self.chopTarget = false; self.sampleTarget = false
                if self.padTarget == nil, let sp = selPad { self.padTarget = (sp["note"] as? Int ?? 36, sp["name"] as? String ?? "") }
                self.load(path) }
            if !padOK { Theme.panel.withAlphaComponent(0.6).setFill(); NSBezierPath(roundedRect: NSRect(x: x + hw + 8, y: by, width: hw, height: bh), xRadius: 3, yRadius: 3).fill() }
        } else if root.contains("Effects") {
            let selPad = (pads?["pads"] as? [[String: Any]])?.first { ($0["selected"] as? Bool ?? false) && ($0["filled"] as? Bool ?? false) }
            if trackKind == "drum", let sp = selPad {
                mpcButton(NSRect(x: x, y: by - bh - 12, width: w, height: bh), "WHOLE KIT", glyph: "kit", style: .light) { [weak self] in self?.load(path, target: "track_fx") }
                mpcButton(NSRect(x: x, y: by, width: w, height: bh), "ONLY PAD " + (sp["name"] as? String ?? ""), glyph: "pads") { [weak self] in
                    self?.load(path, target: "pad_fx", note: sp["note"] as? Int ?? 36) }
            } else {
                mpcButton(NSRect(x: x, y: by, width: w, height: bh), "ADD TO " + trackName.uppercased(), glyph: "fx", style: .light) { [weak self] in self?.load(path, target: "track_fx") }
            }
        } else if browseSameKind(root) && !browseNewTrack {     // a kit on a drum track / an instrument on an instrument track: swap it
            mpcButton(NSRect(x: x, y: by - bh - 12, width: w, height: bh), "LOAD TO " + trackName.uppercased(), glyph: "load", style: .light) { [weak self] in self?.load(path) }
            mpcButton(NSRect(x: x, y: by, width: w, height: bh), "NEW TRACK", glyph: "add") { [weak self] in self?.load(path, newTrack: true) }
        } else {                                                 // anything else would be replaced: a new track first
            mpcButton(NSRect(x: x, y: by - bh - 12, width: w, height: bh), "NEW TRACK", glyph: "add", style: .light) { [weak self] in self?.load(path, newTrack: true) }
            mpcButton(NSRect(x: x, y: by, width: w, height: bh), "REPLACE " + trackName.uppercased(), glyph: "load") { [weak self] in self?.load(path) }
        }
    }
    // the main choice (second tap / LOAD / wheel press): a target if there is one, a sample = chop it, an effect = on the track
    func loadDefault(_ path: [String]) {
        let root = path.first ?? ""
        if sampleTarget || chopTarget || padTarget != nil { load(path); return }
        if root.contains("Effects") { load(path, target: "track_fx"); return }
        if root == "Samples" { chopTarget = true }
        if browseNewTrack { browseNewTrack = false; load(path, newTrack: true); return }
        if ["Drums", "Instruments", "Sounds", "Plug-ins"].contains(root) && !browseSameKind(root) { load(path, newTrack: true); return }   // never replace another kind by surprise
        load(path)
    }
    func browseSameKind(_ root: String) -> Bool {
        root == "Drums" ? trackKind == "drum" : (["Instruments", "Sounds", "Plug-ins"].contains(root) ? (trackKind == "instrument" || trackKind == "empty") : false)
    }
    func browseBack() {
        if browsePath.count <= browseEntryDepth || browsePath.isEmpty { browseEntryDepth = 0; page = pageBeforeBrowse; return }
        browsePath.removeLast(); enterBrowse()
    }

    var pageBeforeBrowse: Page = .steps
    var previewWork: DispatchWorkItem?

    // jog wheel: move the highlight, keep it on screen, preview what is loadable after a short pause
    var browseIndex = -1
    var pendingDirty = NSRect.zero, redrawScheduled = false, lastBrowseRedraw = Date.distantPast
    func moveBrowseSelection(_ delta: Int) {
        guard !browseItems.isEmpty else { return }
        // Live merges quick clicks into one message (delta 2, 3…): move by all of them
        let i = max(0, min(browseItems.count - 1, browseIndex + delta))
        let previous = browseIndex
        browseIndex = i
        let item = browseItems[i]
        browseSelected = item["name"] as? String; browseHeard = browseSelected
        let rowTop = CGFloat(i) * browseRowH, listH = browseListRect.height - 12
        let scrollBefore = browseScroll
        if rowTop < browseScroll { browseScroll = rowTop }
        if rowTop + browseRowH > browseScroll + listH { browseScroll = rowTop + browseRowH - listH }
        let scrolled = browseScroll != scrollBefore
        previewWork?.cancel()
        if browseAutoPreview, item["loadable"] as? Bool ?? false, let name = browseSelected {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.browseSelected == name else { return }
                self.previewItem(item)
            }
            previewWork = w
            DispatchQueue.main.async(execute: w)                                 // preview straight away (Live needs ~25 ms for a kit)
        }
        // redraw as little as possible: the Touch screen is DisplayLink over USB 2, every pixel costs time
        pendingDirty = pendingDirty.union(scrolled ? browseListRect : browseRowRect(previous).union(browseRowRect(i))).union(browsePreviewRect)
        if !redrawScheduled {                                   // at most ~15 frames/s: DisplayLink over USB 2 falls behind otherwise
            redrawScheduled = true
            let wait = max(0, 0.033 - Date().timeIntervalSince(lastBrowseRedraw))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.redrawScheduled = false; self.lastBrowseRedraw = Date()
                self.setNeedsDisplay(self.pendingDirty); self.pendingDirty = .zero
            }
        }
        // folder <-> loadable: the LISTEN / LOAD buttons and the OPEN / LOAD key change
        func kind(_ j: Int) -> Bool? { j >= 0 && j < browseItems.count ? !(browseItems[j]["folder"] as? Bool ?? false) || (browseItems[j]["loadable"] as? Bool ?? false) : nil }
        if previous < 0 || kind(previous) != kind(i) {
            setNeedsDisplay(NSRect(x: 0, y: topH + 8, width: bounds.width, height: 60))
            setNeedsDisplay(NSRect(x: 0, y: bounds.height - 56, width: bounds.width, height: 56))
        }
    }

    func browseRowRect(_ i: Int) -> NSRect {
        let l = browseListRect
        return NSRect(x: l.minX, y: l.minY + 6 + CGFloat(i) * browseRowH - browseScroll - 1, width: l.width, height: browseRowH + 2).intersection(l)
    }

    func activateBrowseSelection() {
        guard browseIndex >= 0, browseIndex < browseItems.count, let name = browseItems[browseIndex]["name"] as? String else {
            moveBrowseSelection(0); return
        }
        let item = browseItems[browseIndex]
        if (item["folder"] as? Bool ?? false) && !(item["loadable"] as? Bool ?? false) {
            browsePath.append(name); enterBrowse()
        } else {
            loadDefault(browseItemPath(item))
        }
    }

    // load, then show what was loaded (MPC style)
    func load(_ path: [String], newTrack: Bool = false, target: String? = nil, note: Int? = nil, duck: Bool = false) {
        if sampleTarget {                                     // replace the Simpler's sample, back to the waveform
            loadSend(["cmd": "browse_load", "path": path, "target": "simpler"]); expectSample = Date()
            sampleTarget = false; page = .sample; needsDisplay = true
            return
        }
        if chopTarget {                                       // CHOP A SAMPLE: new track, Simpler in Slice mode
            loadSend(["cmd": "browse_load", "path": path, "target": "chop"]); expectSample = Date()
            chopTarget = false; page = .sample; needsDisplay = true
            return
        }
        if let t = padTarget {                                // into one drum pad: back to the pads afterwards
            loadSend(["cmd": "browse_load", "path": path, "target": "pad", "note": t.note])
            padTarget = nil; lastDrumView = .pads; page = .pads; needsDisplay = true
            return
        }
        var msg: [String: Any] = ["cmd": "browse_load", "path": path, "target": target ?? (newTrack ? "new" : "selected")]
        if let note { msg["note"] = note }
        if duck { msg["duck"] = true }
        loadSend(msg)
        let root = path.first ?? ""
        // load, then show what you loaded: sounds → play / sequence them, samples → the waveform, effects → DEVICE
        var next: Page = ["Drums", "Instruments", "Sounds"].contains(root) ? .steps : (root == "Samples" ? .sample : .device)
        if root == "Drums" { next = .pads; lastDrumView = .pads }       // a kit: see its pads first (MPC style)
        if next == .sample { lastSamplerView = .sample }
        page = next; needsDisplay = true              // switch straight away; the new device shows as soon as Live has it
    }

    func enterBrowse() {
        browseItems = []; browseScroll = 0; browseSelected = nil; browseIndex = -1; browseJump = false
        if browsePath == ["Favourites"] {                     // ★: kept here, each with its full browser path
            browseItems = browseFavs.map { ["name": $0.last ?? "", "folder": false, "loadable": true, "path": $0] }
            if let f = browseItems.first { browseSelected = f["name"] as? String; browseIndex = 0 }
            needsDisplay = true; return
        }
        link.send(["cmd": "browse", "path": browsePath]); needsDisplay = true
    }

    // hear it: Live's preview for its browser items
    func previewItem(_ item: [String: Any]) {
        link.send(["cmd": "browse_preview", "path": browseItemPath(item)])
    }
    func loadSend(_ m: [String: Any]) { link.send(m) }

    // MARK: ARRANGE (MPC Arrange Mode style): toolbar with bar.beat counter, ruler with loop brace + locators,
    // alternating 4-bar bands, lanes with M S ● headers, clips that show their notes / waveform, Follow, pinch zoom
    var arrangement: [String: Any]? { state["arrangement"] as? [String: Any] }
    var songTime: Double = 0
    var arrStart = 0.0, arrEnd = 0.0
    var arrFollow = true
    var arrTrackScroll: CGFloat = 0
    var arrSelected: (Int, Int)? = nil
    var arrVolHits: [(NSRect, Int, Double)] = []                 // track volume faders in the headers
    var arrVolDrag: (track: Int, x: CGFloat, start: Double, width: CGFloat)? = nil                       // (track, clip index) tapped
    var arrLoopDrag: (start: Double, length: Double)? = nil   // loop brace while dragging
    var arrPreviews: [String: [Any]] = [:]                    // "track-clip" → ["midi", notes] / ["audio", path]
    var arrPeaks: [String: Peaks] = [:]
    let arrLabelW: CGFloat = 204, rulerH: CGFloat = 44, toolH: CGFloat = 52           // (mockup: header 196 + gap 8, ruler 44)
    var arrToolRow: Bool { !((arrangement?["cues"] as? [Any]) ?? []).isEmpty || (arrangement?["back_to_arranger"] as? Bool ?? false) }
    var arrRect: NSRect {
        let y = topH + 10 + (arrToolRow ? 44 + 8 : 0)
        return NSRect(x: 16 + arrLabelW, y: y, width: bounds.width - 32 - arrLabelW, height: bounds.height - 56 - 8 - y)
    }
    var rulerRect: NSRect { NSRect(x: arrRect.minX, y: arrRect.minY, width: arrRect.width, height: rulerH) }
    var lanesRect: NSRect { NSRect(x: 16, y: arrRect.minY + rulerH + 8, width: bounds.width - 32, height: arrRect.height - rulerH - 8) }
    var arrSig: Double { Double(arrangement?["sig"] as? Int ?? 4) }
    func beatToX(_ b: Double) -> CGFloat { arrRect.minX + CGFloat((b - arrStart) / max(1, arrEnd - arrStart)) * arrRect.width }
    func xToBeat(_ x: CGFloat) -> Double { arrStart + Double((x - arrRect.minX) / arrRect.width) * (arrEnd - arrStart) }
    var arrLoop: (start: Double, length: Double, on: Bool) {
        let l = arrangement?["loop"] as? [Any] ?? []
        let s = l.count > 0 ? (l[0] as? Double ?? 0) : 0, len = l.count > 1 ? (l[1] as? Double ?? 16) : 16
        let on = l.count > 2 ? (l[2] as? Bool ?? false) : false
        if let d = arrLoopDrag { return (d.start, d.length, on) }
        return (s, len, on)
    }
    func arrFit() {
        let length = max(32, (arrangement?["length"] as? Double) ?? 32)
        arrStart = 0; arrEnd = length * 1.05
    }
    func arrZoom(_ k: Double, at x: CGFloat) {
        let length = max(64, (arrangement?["length"] as? Double) ?? 64) * 2
        let span = arrEnd - arrStart, anchor = xToBeat(x), f = (anchor - arrStart) / span
        let ns = max(arrSig, min(length, span / k))
        arrStart = max(0, anchor - f * ns); arrEnd = arrStart + ns
    }
    func barText(_ t: Double) -> String {
        let sig = arrSig, bar = Int(t / sig) + 1, beat = Int(t.truncatingRemainder(dividingBy: sig)) + 1
        let six = Int((t - floor(t)) * 4) + 1
        return "\(bar).\(beat).\(six)"
    }

    func drawArrangement() {
        guard let a = arrangement, let tracks = a["tracks"] as? [[String: Any]] else { return }
        animRects = []
        if arrEnd <= arrStart { arrFit() }
        let sig = arrSig, r = arrRect, ruler = rulerRect
        let playing = state["playing"] as? Bool ?? false
        // Follow: keep the playhead in view (also when stopped and it jumped out of view, e.g. back to 1.1.1)
        if arrFollow && (playing || songTime < arrStart || songTime > arrEnd) {
            let span = arrEnd - arrStart
            if songTime > arrStart + span * 0.85 || songTime < arrStart { arrStart = max(0, songTime - span * 0.15); arrEnd = arrStart + span }
        }
        Theme.bg.setFill(); NSRect(x: 0, y: topH, width: bounds.width, height: bounds.height - topH).fill()
        let fbar = songChrome("arrange", name: String(format: "%d tracks", tracks.count),
                              fields: [HeaderField(label: "Loop", value: { let sig = Double(arrSig); let a = Int(arrLoop.start / sig) + 1, b = Int((arrLoop.start + arrLoop.length) / sig) + 1
                                                                           return arrLoop.on ? "bar \(a) – \(b)" : "off" }(), action: { [weak self] in self?.link.send(["cmd": "loop_toggle"]) })],
                              tools: [Tool(glyph: "loop", on: arrLoop.on, action: { [weak self] in self?.link.send(["cmd": "loop_toggle"]) }),
                                      Tool(glyph: "follow", on: arrFollow, action: { [weak self] in self?.arrFollow.toggle(); self?.needsDisplay = true }),
                                      Tool(glyph: "zoom", on: false, action: { [weak self] in self?.arrFit(); self?.needsDisplay = true })],
                              actions: [FKey(glyph: nil, title: "ZOOM", weight: 1.3, action: {},
                                             minus: { [weak self] in guard let self else { return }; self.arrZoom(1.5, at: self.arrRect.midX); self.needsDisplay = true },
                                             plus: { [weak self] in guard let self else { return }; self.arrZoom(1 / 1.5, at: self.arrRect.midX); self.needsDisplay = true }),
                                        FKey(glyph: "loop", title: "LOOP", on: arrLoop.on, action: { [weak self] in self?.link.send(["cmd": "loop_toggle"]) }),
                                        FKey(glyph: "rec", title: "REC", on: state["recording"] as? Bool ?? false, action: { [weak self] in self?.link.send(["cmd": "rec"]) })])
        defer { fbar() }
        // toolbar row (44, only when there are markers or the "back to arrangement" button): ◆ cues
        let ty = topH + 10
        let loop = arrLoop
        var x: CGFloat = 16
        func tool(_ title: String, on: Bool, fill: NSColor? = nil, ink: NSColor? = nil, size: CGFloat = 15, pad: CGFloat = 16, action: @escaping () -> Void) {
            let w = textW(title, size: size) + pad * 2
            button(NSRect(x: x, y: ty, width: w, height: 44), title, size: size, fill: fill ?? (on ? Theme.active : Theme.panel2), ink: ink ?? (on ? Theme.darkInk : Theme.text), action: action)
            x += w + 8
        }
        _ = loop
        let mixW: CGFloat = -8
        let cues = (a["cues"] as? [[Any]]) ?? []
        // session clips took over the arrangement: a quiet button (no blinking) next to MIXER
        let back = a["back_to_arranger"] as? Bool ?? false
        let backW = back ? textW("▶ ARRANGEMENT", size: 14) + 28 : 0
        let limit = bounds.width - 16 - mixW - 8 - (back ? backW + 8 : 0)
        for (ci, cue) in cues.enumerated() {
            let name = "◆ " + (cue.count > 1 ? (cue[1] as? String ?? "") : "")
            if x + textW(name, size: 14) + 28 > limit { break }
            tool(name, on: false, fill: Theme.panel, ink: Theme.palette[2].color, size: 14, pad: 14) { [weak self] in self?.link.send(["cmd": "jump_cue", "index": ci]) }
        }
        if back {
            button(NSRect(x: limit + 8, y: ty, width: backW, height: 44), "▶ ARRANGEMENT", size: 14, fill: Theme.panel2, ink: Theme.accent) { [weak self] in
                self?.link.send(["cmd": "back_to_arranger"]) }
        }

        // lanes fill the height (gap 6); many tracks = 62 high + scroll
        let n = max(1, tracks.count), gap: CGFloat = 6
        let lh = max(62, (lanesRect.height - gap * CGFloat(n - 1)) / CGFloat(n))
        let total = lh * CGFloat(n) + gap * CGFloat(n - 1)
        arrTrackScroll = max(0, min(arrTrackScroll, total - lanesRect.height))
        let lanes = NSRect(x: lanesRect.minX, y: lanesRect.minY, width: lanesRect.width, height: min(lanesRect.height, total - arrTrackScroll))
        let pxPerBar = r.width / CGFloat(max(0.001, (arrEnd - arrStart) / sig))
        let step = [1, 2, 4, 8, 16, 32, 64].first { CGFloat($0) * pxPerBar >= 90 } ?? 64
        let phrase = max(4, step)
        let firstBar = max(0, Int(arrStart / sig) - 1), lastBar = Int(arrEnd / sig) + 1
        // ruler (44): line under it, a line + number every phrase, loop bar on top, yellow cue triangles at the bottom
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: NSRect(x: r.minX, y: ruler.minY, width: r.width, height: ruler.height + 1)).setClip()
        NSColor.white.withAlphaComponent(0.35).setFill(); NSRect(x: r.minX, y: ruler.maxY - 1, width: r.width, height: 1).fill()
        for bar in stride(from: (firstBar / step) * step, through: lastBar, by: step) {
            let bx = beatToX(Double(bar) * sig)
            NSColor.white.withAlphaComponent(0.85).setFill(); NSRect(x: bx, y: ruler.minY, width: 2, height: ruler.height).fill()
            drawText("\(bar + 1)", NSPoint(x: bx + 6, y: ruler.minY + 14), size: 15, color: Theme.text, weight: .bold)
        }
        let lx0 = beatToX(loop.start), lx1 = beatToX(loop.start + loop.length)
        (loop.on ? Theme.accent : Theme.faint).setFill()
        NSBezierPath(roundedRect: NSRect(x: lx0, y: ruler.minY + 2, width: max(10, lx1 - lx0), height: 10), xRadius: 5, yRadius: 5).fill()
        for cue in cues {
            guard let ct = cue.first as? Double else { continue }
            let cx = beatToX(ct)
            let tri = NSBezierPath(); tri.move(to: NSPoint(x: cx - 7, y: ruler.maxY + 1)); tri.line(to: NSPoint(x: cx + 7, y: ruler.maxY + 1)); tri.line(to: NSPoint(x: cx, y: ruler.maxY - 9)); tri.close()
            Theme.palette[2].color.setFill(); tri.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        buttons.append((ruler, { [weak self] in                       // ruler tap = move the playhead (the loop bar drags, see touchDown)
            guard let self else { return }
            self.link.send(["cmd": "set_time", "time": max(0, self.xToBeat(self.lastDown.x).rounded(.down))])
        }))

        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: lanes).setClip()
        for (i, t) in tracks.enumerated() {
            let y = lanes.minY + CGFloat(i) * (lh + gap) - arrTrackScroll
            guard y + lh > lanes.minY && y < lanes.maxY else { continue }
            let tc = Theme.live(t["color"] as? Int)
            let selected = t["selected"] as? Bool ?? false, muted = t["mute"] as? Bool ?? false
            // header (196, mockup): colour edge · name + small M S ● · the volume slider with its dB (drag sideways / wheel)
            let head = NSRect(x: 16, y: y, width: 196, height: lh)
            let hp = NSBezierPath(roundedRect: head, xRadius: 4, yRadius: 4)
            (selected ? hex(0x3a3e42) : Theme.panel2).setFill(); hp.fill()
            NSGraphicsContext.saveGraphicsState(); hp.setClip(); tc.setFill(); NSRect(x: head.minX, y: head.minY, width: 4, height: head.height).fill(); NSGraphicsContext.restoreGraphicsState()
            if selected { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: head.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4); o.lineWidth = 1.5; o.stroke() }
            let compact = lh < 56                                    // very many tracks: name + buttons only
            let rowY = compact ? head.midY - 13 : head.minY + 8
            let small: [(String, String, Bool)] = [("M", "mute", muted), ("S", "solo", t["solo"] as? Bool ?? false), ("●", "arm", t["arm"] as? Bool ?? false)]
            var bx = head.maxX - 8
            for (title, what, on) in small.reversed() {
                if what == "arm" && !(t["can_arm"] as? Bool ?? true) { continue }
                let b = NSRect(x: bx - 26, y: rowY, width: 26, height: 26); bx -= 30
                let bp = NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3)
                (on && what == "arm" ? Theme.red : (on ? (what == "solo" ? Theme.value : Theme.active) : hex(0x26282a))).setFill(); bp.fill()
                drawTextV(title, b, size: 12, color: on ? (what == "arm" ? .white : Theme.darkInk) : Theme.text, weight: .regular, center: true)
                buttons.append((b.insetBy(dx: -2, dy: -4), { [weak self] in self?.link.send(["cmd": "track_toggle", "track": i, "what": what]) }))
            }
            drawTextV(ScreenView.undated(t["name"] as? String ?? "").uppercased(), NSRect(x: head.minX + 12, y: rowY, width: bx - head.minX - 16, height: 26),
                      size: 14, color: muted ? Theme.dim : Theme.text, weight: .regular, tracking: 0.04)
            buttons.append((NSRect(x: head.minX, y: head.minY, width: bx - head.minX, height: compact ? head.height : 38), { [weak self] in
                guard let self else { return }
                _ = self.trackTapped(i, selected: selected)
                self.link.send(["cmd": "pick_track", "index": i]) }))
            if !compact {                                            // volume: drag sideways (or tap it, then the wheel)
                let vol = t["volume"] as? Double ?? 0.85
                let vr = NSRect(x: head.minX + 12, y: rowY + 26 + 6, width: head.width - 24, height: max(18, head.maxY - 6 - (rowY + 32)))
                let bar = NSRect(x: vr.minX, y: vr.midY - 2, width: vr.width - 58, height: 4)
                hex(0x151617).setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
                tc.setFill(); NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(4, bar.width * CGFloat(vol)), height: bar.height), xRadius: 2, yRadius: 2).fill()
                let kx = bar.minX + bar.width * CGFloat(vol)
                hex(0xe6e9eb).setFill(); NSBezierPath(roundedRect: NSRect(x: kx - 4, y: bar.midY - 8, width: 8, height: 16), xRadius: 2, yRadius: 2).fill()
                let focused = jogFocusId == "avol\(i)" || arrVolDrag?.track == i
                drawTextV(t["vol_text"] as? String ?? "", NSRect(x: bar.maxX + 8, y: vr.minY, width: 52, height: vr.height), size: 12, color: focused ? Theme.value : Theme.dim, weight: .regular)
                arrVolHits.append((NSRect(x: bar.minX - 6, y: vr.minY - 4, width: bar.width + 12, height: vr.height + 8), i, vol))
                focusable(vr.insetBy(dx: -4, dy: -2), "avol\(i)", radius: 4) { [weak self] d in
                    guard let self else { return }
                    let v = max(0, min(1, vol + Double(d) * 0.01))
                    self.link.send(["cmd": "mix_set", "track": i, "what": "volume", "value": v])
                    if var a = self.state["arrangement"] as? [String: Any], var tr = a["tracks"] as? [[String: Any]], i < tr.count {
                        tr[i]["volume"] = v; a["tracks"] = tr; self.state["arrangement"] = a }
                }
            }
            // lane: grey, a darker block every other phrase, bar lines, phrase lines
            let lane = NSRect(x: r.minX, y: y, width: r.width, height: lh)
            let lp = NSBezierPath(roundedRect: lane, xRadius: 8, yRadius: 8)
            Theme.arrLane.setFill(); lp.fill()
            NSGraphicsContext.saveGraphicsState(); lp.setClip()
            var pb = (firstBar / phrase) * phrase
            while pb <= lastBar {
                if (pb / phrase) % 2 == 1 { NSColor.black.withAlphaComponent(0.07).setFill(); NSRect(x: beatToX(Double(pb) * sig), y: lane.minY, width: CGFloat(phrase) * pxPerBar, height: lane.height).fill() }
                pb += phrase
            }
            for bar in firstBar...lastBar where pxPerBar >= 8 || bar % phrase == 0 {
                let bx = beatToX(Double(bar) * sig), isPhrase = bar % phrase == 0
                NSColor.black.withAlphaComponent(isPhrase ? 0.55 : 0.25).setFill()
                NSRect(x: bx, y: lane.minY, width: isPhrase ? 2 : 1, height: lane.height).fill()
            }
            buttons.append((lane, { [weak self] in                     // empty lane: move the playhead there (MPC)
                guard let self else { return }
                self.link.send(["cmd": "set_time", "time": max(0, self.xToBeat(self.lastDown.x).rounded(.down))])
            }))
            for (ci, c) in ((t["clips"] as? [[Any]]) ?? []).enumerated() where c.count >= 4 {
                guard let s0 = c[0] as? Double, let e0 = c[1] as? Double else { continue }
                let cr = NSRect(x: beatToX(s0) + 1, y: lane.minY + 3, width: max(4, beatToX(e0) - beatToX(s0) - 2), height: lane.height - 6)
                guard cr.maxX > lane.minX && cr.minX < lane.maxX else { continue }
                let cc = muted ? hex(0x55545c) : Theme.live(c[3] as? Int)
                let cp = NSBezierPath(roundedRect: cr, xRadius: 6, yRadius: 6)
                cc.setFill(); cp.fill()
                NSGraphicsContext.saveGraphicsState(); cp.setClip()
                hex(0x141316, 0.22).setFill(); NSRect(x: cr.minX, y: cr.minY, width: cr.width, height: 22).fill()
                if cr.width > 30 {
                    let tx = max(cr.minX, lane.minX) + 8
                    drawText(c[2] as? String ?? "", NSPoint(x: tx, y: cr.minY + 3), size: 13, color: Theme.darkInk, weight: .bold, width: cr.maxX - tx - 6)
                }
                drawClipPreview(NSRect(x: cr.minX + 6, y: cr.minY + 28, width: cr.width - 12, height: max(4, cr.height - 40)), key: "\(i)-\(ci)", ink: Theme.darkInk)
                NSGraphicsContext.restoreGraphicsState()
                if let sel = arrSelected, sel == (i, ci) { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: cr.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5); o.lineWidth = 3; o.stroke() }
                buttons.append((cr, { [weak self] in
                    self?.arrSelected = (i, ci); self?.link.send(["cmd": "arr_clip", "track": i, "index": ci]); self?.needsDisplay = true }))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if total > lanesRect.height {                                   // scroll indicator
            let h = lanesRect.height * lanesRect.height / total, sy = lanesRect.minY + (lanesRect.height - h) * arrTrackScroll / (total - lanesRect.height)
            Theme.dim.setFill(); NSBezierPath(roundedRect: NSRect(x: bounds.width - 12, y: sy, width: 5, height: h), xRadius: 2, yRadius: 2).fill()
        }
        // playhead: 3 px white with a dark edge, from the ruler down
        let px = beatToX(songTime)
        if px >= r.minX && px <= r.maxX {
            NSColor.black.withAlphaComponent(0.4).setFill(); NSRect(x: px - 2.5, y: ruler.minY, width: 5, height: lanes.maxY - ruler.minY).fill()
            NSColor.white.setFill(); NSRect(x: px - 1.5, y: ruler.minY, width: 3, height: lanes.maxY - ruler.minY).fill()
        }
    }

    // what's inside an arrangement clip: MIDI notes as little bars, audio as its waveform outline
    func drawClipPreview(_ r: NSRect, key: String, ink: NSColor) {
        guard r.width > 6, r.height > 6, let p = arrPreviews[key], p.count >= 2 else { return }
        if (p[0] as? String) == "midi", let notes = p[1] as? [[Double]], !notes.isEmpty {
            let pitches = notes.map { $0[2] }
            let lo = pitches.min()!, hi = max(pitches.max()!, lo + 6)
            ink.withAlphaComponent(0.55).setFill()
            for n in notes {                                     // (mockup: 4 px dashes, rounded)
                let x = r.minX + CGFloat(n[0]) * r.width, w = max(4, CGFloat(n[1]) * r.width - 1)
                let y = r.maxY - CGFloat((n[2] - lo) / (hi - lo)) * (r.height - 4) - 4
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 4), xRadius: 2, yRadius: 2).fill()
            }
        } else if (p[0] as? String) == "audio", let path = p[1] as? String, !path.isEmpty {
            let pk = arrPeaks[path] ?? { let n = Peaks(); arrPeaks[path] = n; n.load(path) { [weak self] in self?.needsDisplay = true }; return n }()
            guard !pk.maxs.isEmpty else { return }
            ink.withAlphaComponent(0.6).setFill()
            let cols = Int(r.width / 2), mid = r.midY
            for k in 0..<max(1, cols) {
                let i0 = k * pk.maxs.count / max(1, cols), i1 = max(i0 + 1, (k + 1) * pk.maxs.count / max(1, cols))
                var hi: Float = 0, lo: Float = 0
                for j in i0..<min(i1, pk.maxs.count) { hi = max(hi, pk.maxs[j]); lo = min(lo, pk.mins[j]) }
                let y0 = mid - CGFloat(hi) * r.height / 2, y1 = mid - CGFloat(lo) * r.height / 2
                NSRect(x: r.minX + CGFloat(k) * 2, y: y0, width: 1.5, height: max(1, y1 - y0)).fill()
            }
        }
    }

    // MARK: DEVICE page — device strip, a graphic for EQ Eight / Compressor / Auto Filter, knobs in pages
    var vizKind: String? {
        switch device?["class"] as? String ?? "" {
        case "Eq8": return "eq"
        case "Compressor2": return "comp"
        case "AutoFilter2": return "filter"
        case "GlueCompressor", "Limiter", "Gate": return "dyn"
        case "Saturator", "Roar", "Overdrive", "Pedal", "DrumBuss", "Tube", "Vinyl", "Redux2", "Erosion2": return "shape"
        case "FilterEQ3", "ChannelEq": return "eq3"
        case "Delay", "Echo", "GrainDelay", "FilterDelay", "BeatRepeat": return "delay"
        case "Reverb", "Hybrid": return "reverb"
        case "Chorus2", "PhaserNew", "AutoPan2", "Shifter": return "mod"
        case "StereoGain": return "util"
        default: return nil
        }
    }
    var knobsPerPage: Int { vizKind == nil ? 16 : (vizKind == "eq" ? 4 : 8) }
    var deviceParams: [[String: Any]] { device?["params"] as? [[String: Any]] ?? [] }
    var devFieldHits: [(NSRect, Int)] = []                    // DEVICE: Q fields you can drag (rect, parameter index)
    var deleteArmedAt = Date.distantPast
    // Q-Link pages from the script (4 parameter indices each; EQ Eight = one page per band)
    var qPages: [[Int]] {
        if let p = device?["pages"] as? [[Int]], !p.isEmpty { return p }
        let n = deviceParams.count
        return stride(from: 0, to: max(n, 1), by: 4).map { Array($0..<min($0 + 4, n)) }
    }
    var qPerScreen: Int { max(1, knobsPerPage / 4) }      // Q-Link pages shown at once
    var qlinkPage: Int { device?["qlink_page"] as? Int ?? 0 }
    var devicePage: Int { qlinkPage / qPerScreen }
    // the parameter index shown in each knob slot of the visible screen page (nil = empty slot)
    var visibleKnobs: [Int?] {
        var out: [Int?] = []
        let pages = qPages
        for q in devicePage * qPerScreen ..< (devicePage + 1) * qPerScreen {
            let pg = q < pages.count ? pages[q] : []
            for k in 0..<4 { out.append(k < pg.count ? pg[k] : nil) }
        }
        return out
    }
    var vizRect: NSRect { NSRect(x: 16, y: topH + 72 + 14, width: 430, height: bounds.height - 56 - 14 - (topH + 72 + 14)) }   // the teal well, left
    func knobRect(_ slot: Int) -> NSRect {                 // slot = position on the visible page
        let top = vizKind == nil ? topH + 62 : vizRect.maxY + 6
        let rows: CGFloat = vizKind == nil ? 2 : 1, cols = vizKind == "eq" ? 4 : 8
        let h = (bounds.height - top - 66) / rows, w = (bounds.width - 32) / CGFloat(cols)
        return NSRect(x: 16 + CGFloat(slot % cols) * w, y: top + CGFloat(slot / cols) * h, width: w, height: h)
    }

    func param(_ name: String) -> [String: Any]? { deviceParams.first { ($0["name"] as? String) == name } }
    func pval(_ name: String) -> Double { param(name)?["value"] as? Double ?? 0 }
    func ptext(_ name: String) -> String { param(name)?["text"] as? String ?? "" }
    func setParam(_ name: String, _ value: Double) {       // send + update locally so the graphic follows the finger
        link.send(["cmd": "set_param_name", "name": name, "value": value])
        if var d = device, var ps = d["params"] as? [[String: Any]], let i = ps.firstIndex(where: { ($0["name"] as? String) == name }) {
            ps[i]["value"] = value; d["params"] = ps; state["device"] = d
        }
    }
    // "1.20 kHz" → 1200, "-3.5 dB" → -3.5, "4.00 : 1" → 4, "inf : 1" → 100
    func number(_ text: String) -> Double {
        let t = text.lowercased()
        if t.hasPrefix("inf") || t.hasPrefix("-inf") { return t.hasPrefix("-") ? -100 : 100 }
        let scanner = Scanner(string: t); scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ")
        let v = scanner.scanDouble() ?? 0
        return t.contains("khz") ? v * 1000 : v
    }
    static func freq(_ norm: Double) -> Double { 10 * pow(2200, norm) }              // Live's 0..1 → 10 Hz..22 kHz
    static func norm(_ freq: Double) -> Double { max(0, min(1, log(freq / 10) / log(2200))) }
    func xFor(_ f: Double, _ r: NSRect) -> CGFloat { r.minX + CGFloat(log(f / 10) / log(2200)) * r.width }
    func freqFor(_ x: CGFloat, _ r: NSRect) -> Double { 10 * pow(2200, Double((x - r.minX) / r.width)) }

    // RBJ biquad magnitude in dB. kind: hp lp bell lowshelf highshelf notch bp
    static func biquadDB(_ kind: String, _ f0: Double, _ gainDB: Double, _ q: Double, _ f: Double) -> Double {
        let fs = 48000.0, w0 = 2 * Double.pi * min(f0, 23000) / fs, c = cos(w0), sn = sin(w0)
        let A = pow(10, gainDB / 40), al = sn / (2 * max(0.05, q)), sa = 2 * sqrt(A) * al
        var b = [1.0, 0, 0], a = [1.0, 0, 0]
        switch kind {
        case "hp": b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]; a = [1 + al, -2 * c, 1 - al]
        case "lp": b = [(1 - c) / 2, 1 - c, (1 - c) / 2]; a = [1 + al, -2 * c, 1 - al]
        case "bp": b = [al, 0, -al]; a = [1 + al, -2 * c, 1 - al]
        case "notch": b = [1, -2 * c, 1]; a = [1 + al, -2 * c, 1 - al]
        case "bell": b = [1 + al * A, -2 * c, 1 - al * A]; a = [1 + al / A, -2 * c, 1 - al / A]
        case "lowshelf":
            b = [A * ((A + 1) - (A - 1) * c + sa), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sa)]
            a = [(A + 1) + (A - 1) * c + sa, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sa]
        case "highshelf":
            b = [A * ((A + 1) + (A - 1) * c + sa), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sa)]
            a = [(A + 1) - (A - 1) * c + sa, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sa]
        default: return 0
        }
        let w = 2 * Double.pi * f / fs
        func mag(_ k: [Double]) -> Double { let re = k[0] + k[1] * cos(w) + k[2] * cos(2 * w), im = -(k[1] * sin(w) + k[2] * sin(2 * w)); return sqrt(re * re + im * im) }
        return 20 * log10(max(1e-9, mag(b) / max(1e-12, mag(a))))
    }

    func drawFreqGrid(_ r: NSRect, dbRange: Double, dbLines: [Double]) {
        hex(0x1b3c48).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        Theme.line.withAlphaComponent(0.6).setFill()
        for f in [30.0, 100, 300, 1000, 3000, 10000] {
            let x = xFor(f, r); NSRect(x: x, y: r.minY, width: 1, height: r.height).fill()
            drawText(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))", NSPoint(x: x + 4, y: r.maxY - 22), size: 14, color: Theme.dim)
        }
        for db in dbLines {
            let y = r.midY - CGFloat(db / dbRange) * r.height / 2
            (db == 0 ? Theme.line : Theme.line.withAlphaComponent(0.35)).setFill(); NSRect(x: r.minX, y: y, width: r.width, height: 1).fill()
            drawText((db > 0 ? "+" : "") + "\(Int(db))", NSPoint(x: r.minX + 6, y: y - 18), size: 13, color: Theme.dim)
        }
    }
    func drawCurve(_ r: NSRect, dbRange: Double, offset: Double = 0, _ fn: (Double) -> Double) {
        let path = NSBezierPath(), fill = NSBezierPath()
        let midY = r.midY - CGFloat(offset / dbRange) * r.height / 2
        fill.move(to: NSPoint(x: r.minX, y: midY))
        for px in stride(from: 0, through: Int(r.width), by: 3) {
            let x = r.minX + CGFloat(px), db = max(-dbRange, min(dbRange, fn(freqFor(x, r))))
            let pt = NSPoint(x: x, y: r.midY - CGFloat(db / dbRange) * r.height / 2)
            if px == 0 { path.move(to: pt) } else { path.line(to: pt) }
            fill.line(to: pt)
        }
        fill.line(to: NSPoint(x: r.maxX, y: midY)); fill.close()
        Theme.accent.withAlphaComponent(0.18).setFill(); fill.fill()
        Theme.accent.setStroke(); path.lineWidth = 3; path.stroke()
    }

    static let eqKinds = ["hp48", "hp", "lowshelf", "bell", "notch", "highshelf", "lp", "lp48"]
    static let bandColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink]
    func eqBand(_ b: Int) -> (on: Bool, kind: String, f: Double, g: Double, q: Double) {
        let scale = param("Scale") != nil ? pval("Scale") : 1
        let kind = ScreenView.eqKinds[max(0, min(7, Int(pval("\(b) Filter Type A"))))]
        return (pval("\(b) Filter On A") > 0.5, kind, ScreenView.freq(pval("\(b) Frequency A")), pval("\(b) Gain A") * scale, 0.1 * pow(180, pval("\(b) Q A")))
    }
    func eqDB(_ f: Double) -> Double {
        var total = pval("Output")
        for b in 1...8 {
            let band = eqBand(b); if !band.on { continue }
            switch band.kind {
            case "hp48": total += 4 * ScreenView.biquadDB("hp", band.f, 0, band.q, f)
            case "lp48": total += 4 * ScreenView.biquadDB("lp", band.f, 0, band.q, f)
            default: total += ScreenView.biquadDB(band.kind, band.f, band.g, band.q, f)
            }
        }
        return total
    }
    func eqDot(_ b: Int, _ r: NSRect) -> NSPoint {
        let band = eqBand(b), gainKinds = ["lowshelf", "bell", "highshelf"]
        let db = gainKinds.contains(band.kind) ? band.g : 0
        return NSPoint(x: xFor(band.f, r), y: r.midY - CGFloat(db / 18) * r.height / 2)
    }
    func drawEQ(_ r: NSRect) {
        drawFreqGrid(r, dbRange: 18, dbLines: [-12, -6, 0, 6, 12])
        drawCurve(r, dbRange: 18) { self.eqDB($0) }
        for b in 1...8 {
            let p = eqDot(b, r), on = eqBand(b).on, col = ScreenView.bandColors[b - 1]
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30))
            if on { col.setFill(); dot.fill() } else { col.withAlphaComponent(0.8).setStroke(); dot.lineWidth = 2; dot.stroke() }
            drawText("\(b)", NSPoint(x: p.x - 15, y: p.y - 11), size: 16, color: on ? .black : col, weight: .bold, center: true, width: 30)
        }
        if case let .viz(b) = drag, b > 0 {
            let band = eqBand(b)
            drawText("\(b): \(ptext("\(b) Frequency A"))   \(String(format: "%+.1f dB", band.g))", NSPoint(x: r.maxX - 330, y: r.minY + 10), size: 18, color: Theme.text, weight: .semibold, width: 320)
        }
    }

    func compCurve(_ x: Double) -> Double {
        let T = number(ptext("Threshold")), R = max(1, number(ptext("Ratio"))), K = pval("Knee")
        if 2 * (x - T) < -K { return x }
        if K > 0 && 2 * abs(x - T) <= K { return x + (1 / R - 1) * pow(x - T + K / 2, 2) / (2 * K) }
        return T + (x - T) / R
    }
    func drawComp(_ r: NSRect) {
        vizCard(r, "threshold \(ptext("Threshold"))  ·  ratio \(ptext("Ratio"))")
        let side = min(r.width - 40, r.height - 64)
        let sq = NSRect(x: r.minX + 20, y: r.minY + 44, width: side, height: side)      // -60..0 dB both ways
        func pt(_ inDB: Double, _ outDB: Double) -> NSPoint { NSPoint(x: sq.minX + CGFloat((inDB + 60) / 60) * sq.width, y: sq.maxY - CGFloat((outDB + 60) / 60) * sq.height) }
        NSColor.white.withAlphaComponent(0.1).setFill()
        for db in stride(from: -60.0, through: 0, by: 12) {
            let p = pt(db, db); NSRect(x: p.x, y: sq.minY, width: 1, height: sq.height).fill(); NSRect(x: sq.minX, y: p.y, width: sq.width, height: 1).fill()
        }
        let diag = NSBezierPath(); diag.move(to: pt(-60, -60)); diag.line(to: pt(0, 0)); NSColor.white.withAlphaComponent(0.3).setStroke()
        diag.lineWidth = 1; diag.setLineDash([4, 4], count: 2, phase: 0); diag.stroke()
        let curve = NSBezierPath()
        for i in 0...120 { let x = -60 + Double(i) / 2; let p = pt(x, max(-60, compCurve(x))); i == 0 ? curve.move(to: p) : curve.line(to: p) }
        hex(0xeef0f1).setStroke(); curve.lineWidth = 2.5; curve.stroke()
        let T = max(-60, min(0, number(ptext("Threshold"))))
        let knee = pt(T, max(-60, compCurve(T)))
        Theme.accent.setFill(); NSBezierPath(ovalIn: NSRect(x: knee.x - 6, y: knee.y - 6, width: 12, height: 12)).fill()
        drawText("drag: sideways threshold · up / down ratio", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }
    // value for a target number using the value→text table the script sent (Threshold/Ratio are not linear)
    func tableValue(_ name: String, target: Double) -> Double? {
        guard let tables = device?["tables"] as? [String: Any], let t = tables[name] as? [[Any]] else { return nil }
        var best: (Double, Double)? = nil
        for row in t where row.count == 2 {
            guard let v = row[0] as? Double, let text = row[1] as? String else { continue }
            let d = abs(number(text) - target)
            if best == nil || d < best!.1 { best = (v, d) }
        }
        return best?.0
    }

    static let filterKinds = ["lp", "hp", "bp", "notch"]
    func filterDB(_ f: Double) -> Double {
        let type = Int(pval("Filter Type")), kind = type < 4 ? ScreenView.filterKinds[type] : "lp"
        let f0 = ScreenView.freq(pval("Frequency")), q = 0.7 + pval("Resonance") * 12
        let stages = pval("Filter Slope") > 0.5 ? 2.0 : 1.0
        return stages * ScreenView.biquadDB(kind, f0, 0, kind == "bp" ? max(0.7, q) : q, f)
    }
    func drawFilter(_ r: NSRect) {
        drawFreqGrid(r, dbRange: 36, dbLines: [-24, -12, 0, 12, 24])
        drawCurve(r, dbRange: 36) { self.filterDB($0) }
        let x = xFor(ScreenView.freq(pval("Frequency")), r), y = r.minY + CGFloat(1 - pval("Resonance")) * r.height
        Theme.accent.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 17, y: y - 17, width: 34, height: 34)).fill()
        drawText("\(ptext("Filter Type"))  ·  \(ptext("Frequency"))  ·  Res \(ptext("Resonance"))", NSPoint(x: r.minX + 60, y: r.minY + 10), size: 20, weight: .semibold, width: r.width - 80)
    }

    func drawKnob(_ r: NSRect, _ p: [String: Any], _ i: Int, _ d: [String: Any]) {
        let mn = p["min"] as? Double ?? 0, mx = p["max"] as? Double ?? 1
        var v = p["value"] as? Double ?? 0
        if case let .knob(di, _, dv) = drag, di == i { v = dv }
        let frac = mx > mn ? (v - mn) / (mx - mn) : 0
        let rad: CGFloat = min(56, r.height * 0.26), c = NSPoint(x: r.midX, y: r.minY + rad + 34)
        // the frame hugs knob + name (not the whole cell): Q-mapped = outlined with its Q tag, touched = lit
        let fr = NSRect(x: r.minX + 4, y: r.minY + 2, width: r.width - 8, height: c.y + rad + 14 + lineH(16) + 12 - (r.minY + 2))
        let qk = (qlinkPage < qPages.count ? qPages[qlinkPage] : []).firstIndex(of: i)
        if qk != nil || touchedKnob == i { Theme.panel.setFill(); NSBezierPath(roundedRect: fr, xRadius: 3, yRadius: 3).fill() }
        if touchedKnob == i { Theme.accent.setStroke(); let o = NSBezierPath(roundedRect: fr.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
        let arc = NSBezierPath(); arc.appendArc(withCenter: c, radius: rad, startAngle: 135, endAngle: 405, clockwise: false)
        Theme.panel2.setStroke(); arc.lineWidth = 11; arc.lineCapStyle = .round; arc.stroke()
        let val = NSBezierPath(); val.appendArc(withCenter: c, radius: rad, startAngle: 135, endAngle: 135 + CGFloat(frac) * 270, clockwise: false)
        Theme.accent.setStroke(); val.lineWidth = 11; val.lineCapStyle = .round; val.stroke()
        if let k = qk {                                         // Q tag, top right (as on the fields)
            let on = touchedKnob == i
            let t = NSRect(x: fr.maxX - 30, y: fr.minY + 6, width: 24, height: 18)
            (on ? Theme.accent : Theme.panel2).setFill(); NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2).fill()
            drawTextV(String(format: "%02d", k + 1), t, size: 12, color: on ? Theme.darkInk : Theme.dim, weight: .regular, center: true)
        }
        drawText(p["text"] as? String ?? "", NSPoint(x: r.minX, y: c.y - 12), size: 17, color: touchedKnob == i ? Theme.value : Theme.text, weight: .regular, center: true, width: r.width)
        drawText(p["name"] as? String ?? "", NSPoint(x: r.minX + 4, y: c.y + rad + 14), size: 16, color: Theme.dim, center: true, width: r.width - 8)
    }

    // MARK: FX picker (mockup Fx): 5 groups of 3 · detail panel 412 (380 + padding) with ADD IT TO
    struct FxInfo { let name: String; let sub: String; let about: String; let greatOn: String; let q: String; let duck: Bool }
    static let fxCategories: [(String, Int, [FxInfo])] = [
        ("PUNCH", 0, [
            FxInfo(name: "Drum Buss", sub: "punch · boom · crunch", about: "Makes drums hit harder: drive, crunch, and a tuned low \"boom\" under the kick.", greatOn: "the drum track, the whole beat", q: "Q1 Drive · Q2 Crunch · Q3 Boom · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Glue Compressor", sub: "glue it together", about: "Gently squeezes a group so it sounds like one record — the classic bus compressor.", greatOn: "drums, the main output", q: "Q1 Threshold · Q2 Ratio · Q3 Attack · Q4 Makeup", duck: true),
            FxInfo(name: "Compressor", sub: "pump · sidechain", about: "Control dynamics — or let the kick duck the bass and chords for the house pump.", greatOn: "bass, chords, pads (ducked by the kick)", q: "Q1 Threshold · Q2 Ratio · Q3 Release · Q4 Out", duck: true)]),
        ("SHAPE", 2, [
            FxInfo(name: "EQ Eight", sub: "cut · boost", about: "Clean up mud, cut the lows from everything but kick and bass, add air.", greatOn: "every track", q: "Q1–Q4 = Frequency · Gain · Q · Type of a band", duck: false),
            FxInfo(name: "Auto Filter", sub: "sweeps", about: "The house build-up: sweep a low-pass open, or high-pass out the lows for a breakdown.", greatOn: "chops, chords, the whole beat", q: "Q1 Frequency · Q2 Resonance · Q3 LFO · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Utility", sub: "gain · width · mono", about: "Make the bass mono, widen chops, fix levels — small but used everywhere.", greatOn: "bass (mono), chops (width)", q: "Q1 Gain · Q2 Width · Q3 Bass Mono · Q4 Pan", duck: false)]),
        ("SPACE", 5, [
            FxInfo(name: "Reverb", sub: "room · hall", about: "Puts sounds in a space. Best on a return track so all sounds share one room.", greatOn: "Return A: snares, claps, vox", q: "Q1 Size · Q2 Decay · Q3 Pre-delay · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Echo", sub: "dub delay", about: "Tape-style echoes with character — throws on a vocal or a snare.", greatOn: "Return B: vox chops, stabs", q: "Q1 Time · Q2 Feedback · Q3 Filter · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Delay", sub: "clean repeats", about: "Simple synced echoes, ping-pong for width.", greatOn: "hats, percs, melodies", q: "Q1 Time · Q2 Feedback · Q3 Ping-pong · Q4 Dry/Wet", duck: false)]),
        ("COLOUR", 1, [
            FxInfo(name: "Saturator", sub: "warmth", about: "Analog-style warmth and grit; makes an 808 audible on small speakers.", greatOn: "808s, bass, drums", q: "Q1 Drive · Q2 Curve · Q3 Tone · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Roar", sub: "dirt · character", about: "Heavy colour and distortion with filters — from subtle to destroyed.", greatOn: "drums, chops, synths", q: "Q1 Drive · Q2 Tone · Q3 Feedback · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Vinyl Distortion", sub: "lo-fi", about: "Crackle and warp for the dusty boom-bap feel.", greatOn: "chops, the whole beat", q: "Q1 Crackle · Q2 Drive · Q3 Tracing · Q4 Density", duck: false)]),
        ("MOVE", 7, [
            FxInfo(name: "Beat Repeat", sub: "stutter", about: "Live stutters and glitch fills, MPC-style.", greatOn: "drums, vox", q: "Q1 Interval · Q2 Grid · Q3 Chance · Q4 Mix", duck: false),
            FxInfo(name: "Chorus-Ensemble", sub: "wide · lush", about: "Thick and wide — great on keys and pads.", greatOn: "keys, pads, chops", q: "Q1 Rate · Q2 Amount · Q3 Width · Q4 Dry/Wet", duck: false),
            FxInfo(name: "Phaser-Flanger", sub: "swoosh", about: "Swirling movement, classic on hats in house.", greatOn: "hats, chords", q: "Q1 Rate · Q2 Amount · Q3 Feedback · Q4 Dry/Wet", duck: false)])]
    var fxPick = false
    var fxSel = (0, 0)
    var fxDuck = true
    func drawFxPicker(_ top: CGFloat) {
        let detail = NSRect(x: bounds.width - 16 - 412, y: top, width: 412, height: bounds.height - 56 - 10 - top)
        let left = NSRect(x: 16, y: top, width: detail.minX - 14 - 16, height: detail.height)
        let cardW = (left.width - 92 - 3 * 8) / 3
        for (ci, cat) in ScreenView.fxCategories.enumerated() {
            let y = left.minY + CGFloat(ci) * (92 + 10)
            let col = Theme.palette[cat.1].color
            let lr = NSRect(x: left.minX, y: y, width: 92, height: 92)
            Theme.panel.setFill(); NSBezierPath(roundedRect: lr, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: lr, xRadius: 4, yRadius: 4).setClip()
            col.setFill(); NSRect(x: lr.minX, y: lr.minY, width: 4, height: lr.height).fill(); NSGraphicsContext.restoreGraphicsState()
            drawTextV(cat.0, lr, size: 13, color: Theme.dim, weight: .regular, center: true, tracking: 0.11)
            for (k, fx) in cat.2.enumerated() {
                let r = NSRect(x: lr.maxX + 8 + CGFloat(k) * (cardW + 8), y: y, width: cardW, height: 92)
                let on = fxSel == (ci, k)
                (on ? col.blended(withFraction: 0.72, of: Theme.panel)! : Theme.panel2).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                if on { NSColor.white.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4); o.lineWidth = 1.5; o.stroke() }
                let ink = Theme.text
                let inset: CGFloat = 0
                let th = lineH(18) + 4 + lineH(13)
                drawText(fx.name, NSPoint(x: r.minX + 14 + inset, y: r.midY - th / 2), size: 18, color: ink, weight: .regular, width: r.width - 28)
                drawText(fx.sub, NSPoint(x: r.minX + 14 + inset, y: r.midY - th / 2 + lineH(18) + 4), size: 13, color: on ? Theme.hint : Theme.faint, weight: .regular, width: r.width - 28)
                buttons.append((r, { [weak self] in self?.fxSel = (ci, k); self?.needsDisplay = true }))
            }
        }
        // detail panel
        Theme.panel.setFill(); NSBezierPath(roundedRect: detail, xRadius: 4, yRadius: 4).fill()
        let cat = ScreenView.fxCategories[fxSel.0], fx = cat.2[fxSel.1], col = Theme.palette[cat.1].color
        let x = detail.minX + 16, w = detail.width - 32
        var y = detail.minY + 16
        let tag = NSRect(x: x, y: y, width: textW(cat.0, size: 12) + 20, height: lineH(12) + 8)
        col.blended(withFraction: 0.55, of: Theme.panel)!.setFill(); NSBezierPath(roundedRect: tag, xRadius: 2, yRadius: 2).fill()
        drawTextV(cat.0, tag, size: 12, color: Theme.text, weight: .regular, center: true, tracking: 0.08); y = tag.maxY + 10
        drawText(fx.name, NSPoint(x: x, y: y - 4), size: 30, weight: .light, width: w); y += 30 + 10
        drawPara(fx.about, NSPoint(x: x, y: y), width: w, size: 16, color: Theme.hint, lines: 3, lh: 1.35)
        y += ceil(textW(fx.about, size: 16, weight: .regular) / w + 0.15).clamped(1, 3) * 16 * 1.35 + 10 + 4
        drawText("GREAT ON", NSPoint(x: x, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 10
        drawText(fx.greatOn, NSPoint(x: x, y: y), size: 16, color: Theme.text, weight: .regular, width: w); y += lineH(16) + 10 + 4
        drawText("Q-LINKS", NSPoint(x: x, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 10
        drawPara(fx.q, NSPoint(x: x, y: y), width: w, size: 16, color: Theme.value, weight: .regular, lines: 2, lh: 1.28); y += lineH(16) + 10
        if fx.duck {                                              // sidechain: the kick ducks it (the house pump)
            mpcButton(NSRect(x: x, y: y, width: w, height: 48), fxDuck ? "DUCKED BY THE KICK" : "DUCK BY THE KICK", glyph: "sidechain", style: fxDuck ? .light : .dark) { [weak self] in
                self?.fxDuck.toggle(); self?.needsDisplay = true }
        }
        // ADD IT TO (bottom)
        let space = cat.0 == "SPACE"
        let path = ["Audio Effects", fx.name]
        let padNote = (pads?["pads"] as? [[String: Any]])?.first(where: { $0["selected"] as? Bool ?? false })?["note"] as? Int
        let targets: [(String, String)] = space ? [("RETURN A (shared)", "return_fx"), ("ONLY THIS PAD", "pad_fx"), ("WHOLE TRACK", "track_fx")]
                                                : [("WHOLE TRACK", "track_fx"), ("ONLY THIS PAD", "pad_fx"), ("MAIN OUTPUT", "main_fx")]
        let bw = (w - 8) / 2, gy = detail.maxY - 16 - 54 - 8 - 54
        drawText("ADD IT TO", NSPoint(x: x, y: gy - 10 - lineH(12)), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        for (k, (label, target)) in targets.enumerated() {
            let r = NSRect(x: x + CGFloat(k % 2) * (bw + 8), y: gy + CGFloat(k / 2) * (54 + 8), width: bw, height: 54)
            if target == "pad_fx" && (trackKind != "drum" || padNote == nil) {
                Theme.panel2.withAlphaComponent(0.4).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                drawTextV(label, r, size: 14, color: Theme.faint, weight: .regular, center: true, tracking: 0.07); continue
            }
            mpcButton(r, label, glyph: target == "pad_fx" ? "pads" : (target == "main_fx" ? "mixer" : (target == "return_fx" ? "fx" : "add")), style: k == 0 ? .light : .dark) { [weak self] in
                guard let self else { return }
                self.fxPick = false
                self.load(path, target: target, note: target == "pad_fx" ? padNote : nil, duck: fx.duck && self.fxDuck)
            }
        }
    }
    static func fxColour(_ name: String) -> NSColor {
        for cat in fxCategories where cat.2.contains(where: { name.hasPrefix($0.name) }) { return Theme.palette[cat.1].color }
        return Theme.palette[5].color
    }

    func drawDevice() {
        // mockup "Device": CHAIN row (chips with arrows) · the graphic in a teal well (left) · Q-LINK PAGE + Q1–Q4 (+ the next
        // page dimmed) · sidechain for compressors · F-keys: PREV / NEXT DEVICE · ADD FX
        let d = device
        let chain = d?["chain"] as? [[String: Any]] ?? []
        let sel = d?["index"] as? Int ?? -1
        let (dcol, dstripe) = ScreenView.pageColour[.device]!
        mpcStrip()
        let on = d?["on"] as? Bool ?? true
        mpcHeader(dcol, icon: "device", name: HeaderField(label: "Device", value: fxPick ? "Add an effect" : (d?["name"] as? String ?? "No device"), action: nil),
                  fields: [],
                  tools: fxPick || d == nil ? [Tool(glyph: "fx", on: fxPick, action: { [weak self] in guard let self else { return }; self.fxPick.toggle(); self.needsDisplay = true })]
                       : [Tool(glyph: "power", on: on, action: { [weak self] in
                              self?.link.send(["cmd": "device_on"])
                              if var dd = self?.device { dd["on"] = !on; self?.state["device"] = dd; self?.needsDisplay = true } }),
                          Tool(glyph: "add", on: false, action: { [weak self] in guard let self else { return }; self.fxPick = true; self.needsDisplay = true }),
                          Tool(glyph: "delete", on: false, action: { [weak self] in                     // twice = remove (no undo on the Touch)
                              guard let self else { return }
                              if Date().timeIntervalSince(self.deleteArmedAt) < 3 { self.deleteArmedAt = .distantPast; self.link.send(["cmd": "device_delete"]) }
                              else {
                                  self.deleteArmedAt = Date(); self.noticeText = "Tap the bin again to remove " + (d?["name"] as? String ?? "it"); self.noticeAt = Date()
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.needsDisplay = true }   // the bin back to white
                              }
                              self.needsDisplay = true }, tint: Date().timeIntervalSince(deleteArmedAt) < 3 ? Theme.red : nil)])
        let n = chain.count
        let dActions = [FKey(glyph: "left", title: "PREV DEVICE", action: { [weak self] in
                            guard let self, sel > 0 else { return }; self.fxPick = false; self.link.send(["cmd": "select_device", "index": sel - 1]) }),
                        FKey(glyph: "right", title: "NEXT DEVICE", action: { [weak self] in
                            guard let self, sel >= 0, sel + 1 < n else { return }; self.fxPick = false; self.link.send(["cmd": "select_device", "index": sel + 1]) }),
                        FKey(glyph: "fx", title: "ADD FX", on: fxPick, action: { [weak self] in guard let self else { return }; self.fxPick.toggle(); self.needsDisplay = true })]
        let dTabs = trackTabs(.device)
        defer { mpcFBar(tabs: dTabs, actions: dActions, stripe: dstripe) }
        // CHAIN
        let row = NSRect(x: 0, y: topH, width: bounds.width, height: 72)
        hex(0x2a2d30).setFill(); row.fill()
        drawTextV("CHAIN", NSRect(x: 16, y: row.minY, width: 60, height: row.height), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        var x: CGFloat = 16 + 60 + 6
        let order = chain.indices.filter { !(chain[$0]["pad"] is String) } + chain.indices.filter { chain[$0]["pad"] is String }
        let addW = textW("ADD FX", size: 15, weight: .regular, tracking: 0.07) + 52
        var padLabelDone = false
        for (j, i) in order.enumerated() {
            let dev = chain[i]
            let isPad = dev["pad"] is String
            if isPad && !padLabelDone {
                padLabelDone = true
                let lw = textW("PAD", size: 12, tracking: 0.11) + 4
                if x + lw + 60 > bounds.width - 16 - addW - 8 { break }
                drawTextV("PAD", NSRect(x: x + 4, y: row.minY, width: lw, height: row.height), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
                x += lw + 14
            } else if j > 0 {
                drawGlyph("right", NSRect(x: x - 2, y: row.midY - 8, width: 16, height: 16), Theme.faint); x += 18
            }
            let isInstr = (dev["type"] as? Int ?? 2) == 1
            let devOn = dev["on"] as? Bool ?? true
            let name = dev["name"] as? String ?? ""
            let w = textW(name, size: 15, weight: .regular) + 58
            if x + w > bounds.width - 16 - addW - 8 { break }
            let r = NSRect(x: x, y: row.midY - 22, width: w, height: 44)
            let isSel = i == sel && !fxPick
            (isSel ? Theme.active : Theme.panel2).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if !isSel { hex(0x4a4e52).setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); o.lineWidth = 1; o.stroke() }
            let ink = isSel ? Theme.darkInk : (devOn ? Theme.text : Theme.faint)
            drawGlyph(isInstr ? (trackKind == "drum" && !isPad ? "kit" : "keyboard") : "fx", NSRect(x: r.minX + 12, y: r.midY - 9, width: 18, height: 18), ink)
            drawTextV(name, NSRect(x: r.minX + 38, y: r.minY, width: w - 46, height: r.height), size: 15, color: ink, weight: .regular)
            buttons.append((r, { [weak self] in self?.fxPick = false; self?.link.send(["cmd": "select_device", "index": i]) }))
            x += w + 8
        }
        let ar = NSRect(x: x, y: row.midY - 22, width: addW, height: 44)
        let dash = NSBezierPath(roundedRect: ar.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); dash.lineWidth = 1; dash.setLineDash([5, 4], count: 2, phase: 0)
        hex(0x565b60).setStroke(); dash.stroke()
        drawGlyph("add", NSRect(x: ar.minX + 12, y: ar.midY - 9, width: 18, height: 18), Theme.hint)
        drawTextV("ADD FX", NSRect(x: ar.minX + 36, y: ar.minY, width: addW - 40, height: ar.height), size: 15, color: Theme.hint, weight: .regular, tracking: 0.07)
        buttons.append((ar, { [weak self] in guard let self else { return }; self.fxPick = true; self.needsDisplay = true }))
        if fxPick || d == nil { drawFxPicker(row.maxY + 12); return }
        guard let d else { return }
        devFieldHits = []
        // the graphic (or the device, big)
        let well = vizRect
        hex(0x1b3c48).setFill(); NSBezierPath(roundedRect: well, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: well, xRadius: 4, yRadius: 4).setClip()   // a graphic stays in its well
        switch vizKind {
        case "eq": drawEQ(well)
        case "comp": drawComp(well)
        case "filter": drawFilter(well)
        case "dyn": drawDynamics(well)
        case "shape": drawShaper(well)
        case "eq3": drawEQ3(well)
        case "delay": drawDelay(well)
        case "reverb": drawReverb(well)
        case "mod": drawModulation(well)
        case "util": drawUtility(well)
        default:
            drawGlyph((d["type"] as? Int ?? 2) == 1 ? "keyboard" : "fx", NSRect(x: well.midX - 32, y: well.midY - 52, width: 64, height: 64), hex(0xeef0f1).withAlphaComponent(0.85), lw: 1.6)
            drawText(d["name"] as? String ?? "", NSPoint(x: well.minX, y: well.midY + 24), size: 22, color: Theme.text, weight: .light, center: true, width: well.width)
            drawText(on ? "turn the Q-Links · drag a field" : "switched off", NSPoint(x: well.minX, y: well.midY + 56), size: 14, color: Theme.hint, weight: .regular, center: true, width: well.width)
        }
        if !on { NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(roundedRect: well, xRadius: 4, yRadius: 4).fill() }
        NSGraphicsContext.restoreGraphicsState()
        // Q-LINK PAGE + the fields
        let px = well.maxX + 14, pw = bounds.width - 16 - px
        var y = well.minY
        let names = d["page_names"] as? [String] ?? []
        let pages = qPages.count, cur = min(qlinkPage, max(0, pages - 1))
        func pageLabel(_ k: Int) -> String {
            let nm = k < names.count ? names[k] : "\(k + 1)"
            return Int(nm) != nil ? "PAGE \(k + 1)" : "\(k + 1) · " + nm.uppercased()
        }
        func pageLabelLong(_ k: Int) -> String {
            let nm = k < names.count ? names[k] : "\(k + 1)"
            return Int(nm) != nil ? "PAGE \(k + 1) OF \(pages)" : "\(k + 1) · " + nm.uppercased() + "  (of \(pages))"
        }
        func setPage(_ k: Int) {
            link.send(["cmd": "qlink_page", "bank": k])
            if var dd = device { dd["qlink_page"] = k; state["device"] = dd }
            needsDisplay = true
        }
        drawTextV("Q-LINK PAGE", NSRect(x: px, y: y, width: 110, height: 44), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11)
        if pages <= 4 {
            if pages > 1 { mpcSeg(px + 118, y, (0..<pages).map(pageLabel), selected: cur, h: 44) { [weak self] k in self?.qlinkSet(k) } }
            else { drawTextV(pageLabel(0), NSRect(x: px + 118, y: y, width: 200, height: 44), size: 15, color: Theme.text, weight: .regular, tracking: 0.07) }
        } else {                                                  // many pages: ‹ PAGE n OF m ›
            mpcButton(NSRect(x: px + 118, y: y, width: 54, height: 44), "", glyph: "left") { [weak self] in self?.qlinkSet((cur + pages - 1) % pages) }
            drawTextV(pageLabelLong(cur), NSRect(x: px + 182, y: y, width: 260, height: 44), size: 15, color: Theme.text, weight: .regular, center: true, tracking: 0.07)
            mpcButton(NSRect(x: px + 452, y: y, width: 54, height: 44), "", glyph: "right") { [weak self] in self?.qlinkSet((cur + 1) % pages) }
        }
        _ = setPage
        y += 44 + 14
        let params = deviceParams
        let fw = (pw - 3 * 8) / 4, fh: CGFloat = 76
        for (row, page) in [cur, cur + 1].enumerated() where page < pages {
            for (k, pi) in qPages[page].prefix(4).enumerated() where pi < params.count {
                let pr = params[pi]
                let r = NSRect(x: px + CGFloat(k) * (fw + 8), y: y, width: fw, height: fh)
                var val = pr["text"] as? String ?? ""
                if case let .knob(di, _, dv) = drag, di == pi, let mn = pr["min"] as? Double, let mx = pr["max"] as? Double { _ = (mn, mx); val = pr["text"] as? String ?? String(format: "%.2f", dv) }
                let lit = row == 0 && (touchedKnob == pi || { if case let .knob(di, _, _) = drag { return di == pi }; return false }())
                mpcField(r, label: pr["name"] as? String ?? "", value: val, q: row == 0 ? k + 1 : nil, active: lit, mint: lit, valueSize: 28)
                if row == 1 { Theme.bg.withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill() }
                devFieldHits.append((r, pi))
            }
            y += fh + 8
        }
        // sidechain (compressors): the kick pumps it
        if let sc = d["sidechain"] as? [String: Any] {
            let scOn = sc["on"] as? Bool ?? false
            let br = NSRect(x: px, y: well.maxY - 48, width: 220, height: 48)
            mpcButton(br, scOn ? "DUCKED BY KICK" : "DUCK BY THE KICK", glyph: "sidechain", style: scOn ? .light : .dark) { [weak self] in
                self?.link.send(["cmd": "duck"]) }
            let from = (sc["from"] as? String ?? "")
            drawTextV(scOn ? "sidechain: " + (from.isEmpty || from == "No Input" ? "pick the kick in Ableton" : from) : "the kick pushes it down: the house pump",
                      NSRect(x: br.maxX + 12, y: br.minY, width: pw - br.width - 12, height: br.height), size: 17, color: Theme.hint, weight: .light)
        }
    }
    func qlinkSet(_ k: Int) {
        link.send(["cmd": "qlink_page", "bank": k])
        if var dd = device { dd["qlink_page"] = k; state["device"] = dd }
        needsDisplay = true
    }


    // MARK: effect graphics for every effect type (Ableton's pictures, touch-sized). Drag = the two main controls.
    func pnorm(_ name: String) -> Double {
        guard let p = param(name), let v = p["value"] as? Double, let mn = p["min"] as? Double, let mx = p["max"] as? Double, mx > mn else { return 0 }
        return (v - mn) / (mx - mn)
    }
    func setNorm(_ name: String, _ n: Double) {
        guard let p = param(name), let mn = p["min"] as? Double, let mx = p["max"] as? Double else { return }
        var v = mn + max(0, min(1, n)) * (mx - mn)
        if p["quantized"] as? Bool ?? false { v = v.rounded() }
        setParam(name, v)
    }
    func firstParam(_ names: [String]) -> String? { names.first { param($0) != nil } }
    var wetName: String? { firstParam(["Dry/Wet", "Dry Wet", "DryWet"]) }

    // which two controls a drag moves (x, y)
    var vizAxes: (String?, String?) {
        let cls = device?["class"] as? String ?? ""
        switch cls {
        case "GlueCompressor": return ("Threshold", "Ratio")
        case "Limiter": return ("Input Gain", "Ceiling")
        case "Gate": return ("Threshold", "Floor")
        case "DrumBuss": return ("Crunch", "Drive")
        case "Redux2": return ("Sample Rate", "Bit Depth")
        case "Vinyl": return ("Crackle Volume", "Global Drive")
        case "Erosion2": return ("Frequency", "Amount")
        case "FilterEQ3", "ChannelEq": return (nil, nil)
        case "Reverb": return ("Decay Time", wetName)
        case "Hybrid": return ("Decay", wetName)
        case "Chorus2": return ("Rate", "Amount")
        case "PhaserNew": return ("Mod Freq", "Amount")
        case "AutoPan2": return (firstParam(["Frequency", "Rate"]), "Amount")
        case "Shifter": return ("Lfo Rate Hz", "Lfo Amount St")
        case "StereoGain": return ("Stereo Width", "Output")
        case "BeatRepeat": return ("Decay", "Chance")
        default:
            if ["Delay", "Echo", "GrainDelay", "FilterDelay"].contains(cls) { return (wetName, firstParam(["Feedback", "1 Feedback"])) }
            return (wetName, firstParam(["Drive", "Global Drive", "Amount"]))
        }
    }

    // a dark card with a title line, like Ableton's device display
    func vizCard(_ r: NSRect, _ title: String) {                   // the teal well (MPC-2), its line in small caps
        hex(0x1b3c48).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        drawText(title.uppercased(), NSPoint(x: r.minX + 14, y: r.minY + 12), size: 12, color: hex(0xc9ced2), weight: .regular, width: r.width - 28, tracking: 0.11)
    }
    var tcolor: NSColor { Theme.live((state["track"] as? [String: Any])?["color"] as? Int) }

    // DYNAMICS: input → output curve (threshold knee, ratio slope / ceiling / floor) + gain-reduction-style attack/release
    func drawDynamics(_ r: NSRect) {
        let cls = device?["class"] as? String ?? ""
        vizCard(r, cls == "Limiter" ? "\(ptext("Ceiling")) ceiling  ·  release \(ptext("Release"))"
                    : cls == "Gate" ? "threshold \(ptext("Threshold"))  ·  floor \(ptext("Floor"))"
                    : "threshold \(ptext("Threshold"))  ·  ratio \(ptext("Ratio"))  ·  attack \(ptext("Attack"))  ·  release \(ptext("Release"))")
        let sq = NSRect(x: r.minX + 24, y: r.minY + 44, width: r.height - 64, height: r.height - 64)
        hex(0x163440).setFill(); sq.fill()
        NSColor(white: 1, alpha: 0.12).setFill()
        for k in 1..<6 { let t = CGFloat(k) / 6; NSRect(x: sq.minX + t * sq.width, y: sq.minY, width: 1, height: sq.height).fill(); NSRect(x: sq.minX, y: sq.minY + t * sq.height, width: sq.width, height: 1).fill() }
        func pt(_ inDB: Double, _ outDB: Double) -> NSPoint { NSPoint(x: sq.minX + CGFloat((inDB + 60) / 60) * sq.width, y: sq.maxY - CGFloat((outDB + 60) / 60) * sq.height) }
        let thr = cls == "Limiter" ? number(ptext("Ceiling")) - number(ptext("Input Gain")) : number(ptext("Threshold"))
        var ratio = max(1, number(ptext("Ratio"))); if ptext("Ratio").lowercased().contains("inf") || cls == "Limiter" { ratio = 100 }
        let floorDB = cls == "Gate" ? max(-60, number(ptext("Floor"))) : -60
        let curve = NSBezierPath()
        for k in 0...120 {
            let i = -60 + Double(k) / 2
            var o = i
            if cls == "Gate" { o = i < thr ? max(-60, i + floorDB) : i }
            else if i > thr { o = thr + (i - thr) / ratio }
            if cls == "Limiter" { o = min(i + number(ptext("Input Gain")), number(ptext("Ceiling"))) }
            let p = pt(i, max(-60, min(0, o)))
            if k == 0 { curve.move(to: p) } else { curve.line(to: p) }
        }
        tcolor.setStroke(); curve.lineWidth = 4; curve.stroke()
        Theme.accent.setFill(); let tp = pt(max(-60, min(0, thr)), max(-60, min(0, thr))); NSBezierPath(ovalIn: NSRect(x: tp.x - 12, y: tp.y - 12, width: 24, height: 24)).fill()
        // attack / release shape on the right
        let er = NSRect(x: sq.maxX + 30, y: sq.minY, width: r.maxX - sq.maxX - 54, height: sq.height)
        hex(0x163440).setFill(); er.fill()
        let atk = cls == "Gate" || cls == "Limiter" ? 0.05 : min(1, pnorm("Attack") + 0.05), rel = min(1, pnorm("Release") + 0.08)
        let env = NSBezierPath(); env.move(to: NSPoint(x: er.minX, y: er.maxY - 10))
        let a = er.minX + er.width * 0.08, b = a + er.width * 0.25 * CGFloat(atk), c = er.minX + er.width * 0.55
        env.line(to: NSPoint(x: a, y: er.maxY - 10)); env.line(to: NSPoint(x: b, y: er.minY + 20)); env.line(to: NSPoint(x: c, y: er.minY + 20))
        for k in 0...30 { let t = CGFloat(k) / 30; env.line(to: NSPoint(x: c + t * (er.maxX - c - 10) * CGFloat(0.3 + 0.7 * rel), y: er.minY + 20 + (er.height - 30) * (1 - exp(-4 * t)))) }
        env.line(to: NSPoint(x: er.maxX - 10, y: er.maxY - 10))
        tcolor.withAlphaComponent(0.9).setStroke(); env.lineWidth = 3; env.stroke()
        drawText(cls == "Gate" ? "OPEN / CLOSE" : "ATTACK · RELEASE", NSPoint(x: er.minX + 12, y: er.maxY - 30), size: 13, color: Theme.dim, weight: .bold)
        drawText("drag: sideways = \(vizAxes.0 ?? "") · up/down = \(vizAxes.1 ?? "")", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }

    // SATURATION / DISTORTION: the shaper curve + a sine before and after
    func drawShaper(_ r: NSRect) {
        let cls = device?["class"] as? String ?? ""
        let driveName = vizAxes.1 ?? "Drive"
        let drive = pnorm(driveName)
        var title = "\(driveName) \(ptext(driveName))"
        if cls == "DrumBuss" { title += "  ·  crunch \(ptext("Crunch"))  ·  boom \(ptext("Boom Amt")) at \(ptext("Boom Freq"))" }
        else if cls == "Redux2" { title = "bits \(ptext("Bit Depth"))  ·  rate \(ptext("Sample Rate"))" }
        else if let w = wetName { title += "  ·  mix \(ptext(w))" }
        vizCard(r, title)
        // drive in dB (Saturator, Pedal…) = real gain into the curve; otherwise a 0–100 % amount
        let dt = ptext(driveName).lowercased()
        let k = dt.contains("db") ? max(0.4, pow(10, number(dt) / 20)) : 1 + drive * 6, hard = cls == "Pedal" || cls == "Redux2" || ptext("Type").lowercased().contains("hard")
        let bits = cls == "Redux2" ? max(1, number(ptext("Bit Depth"))) : 0
        func shape(_ x: Double) -> Double {
            if bits > 0 { let q = pow(2, bits - 1); return (x * q).rounded() / q }
            return hard ? max(-1, min(1, x * k)) : tanh(k * x) / tanh(k)
        }
        let box = NSRect(x: r.minX + 24, y: r.minY + 44, width: r.height - 64, height: r.height - 64)
        hex(0x163440).setFill(); box.fill()
        NSColor(white: 1, alpha: 0.15).setFill(); NSRect(x: box.midX, y: box.minY, width: 1, height: box.height).fill(); NSRect(x: box.minX, y: box.midY, width: box.width, height: 1).fill()
        let c = NSBezierPath()
        for i in 0...100 { let x = -1 + Double(i) / 50; let p = NSPoint(x: box.minX + CGFloat(i) / 100 * box.width, y: box.midY - CGFloat(shape(x)) * box.height / 2)
            if i == 0 { c.move(to: p) } else { c.line(to: p) } }
        tcolor.setStroke(); c.lineWidth = 4; c.stroke()
        // sine in (grey) and out (colour)
        let wr = NSRect(x: box.maxX + 30, y: box.minY, width: r.maxX - box.maxX - 54, height: box.height)
        hex(0x163440).setFill(); wr.fill()
        let sin1 = NSBezierPath(), sin2 = NSBezierPath()
        for i in 0...200 { let t = Double(i) / 200, s = sin(t * 4 * .pi) * 0.9
            let x = wr.minX + CGFloat(t) * wr.width
            let p1 = NSPoint(x: x, y: wr.midY - CGFloat(s) * wr.height * 0.42), p2 = NSPoint(x: x, y: wr.midY - CGFloat(shape(s)) * wr.height * 0.42)
            if i == 0 { sin1.move(to: p1); sin2.move(to: p2) } else { sin1.line(to: p1); sin2.line(to: p2) } }
        NSColor(white: 1, alpha: 0.25).setStroke(); sin1.lineWidth = 2; sin1.stroke()
        tcolor.setStroke(); sin2.lineWidth = 3.5; sin2.stroke()
        if cls == "DrumBuss" {                                   // the boom: a low bump in the corner
            let bAmt = pnorm("Boom Amt")
            Theme.accent.withAlphaComponent(0.25 + 0.6 * bAmt).setFill()
            NSBezierPath(ovalIn: NSRect(x: wr.minX + 16, y: wr.maxY - 16 - 70 * CGFloat(bAmt) - 20, width: 90, height: 70 * CGFloat(bAmt) + 20)).fill()
            drawText("BOOM", NSPoint(x: wr.minX + 34, y: wr.maxY - 34), size: 13, color: .black, weight: .bold)
        }
        drawText("drag: sideways = \(vizAxes.0 ?? "") · up/down = \(driveName)", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }

    // EQ THREE / CHANNEL EQ: the curve from the band gains (drag a dot up/down)
    func eq3Bands() -> [(name: String, f: Double, kind: String)] {
        if (device?["class"] as? String) == "ChannelEq" {
            return [("Low Gain", 100, "lowshelf"), ("Mid Gain", max(120, number(ptext("Mid Freq"))), "bell"), ("High Gain", 8000, "highshelf")]
        }
        let lo = max(30, number(ptext("FreqLo"))), hi = max(lo * 2, number(ptext("FreqHi")))
        return [("GainLo", lo, "lowshelf"), ("GainMid", sqrt(lo * hi), "bell"), ("GainHi", hi, "highshelf")]
    }
    func eq3Gain(_ n: String) -> Double { let t = ptext(n).lowercased(); return t.contains("inf") ? -24 : max(-24, min(15, number(t))) }
    func drawEQ3(_ r: NSRect) {
        vizCard(r, eq3Bands().map { "\($0.name.replacingOccurrences(of: " Gain", with: "").replacingOccurrences(of: "Gain", with: "")) \(ptext($0.name))" }.joined(separator: "  ·  "))
        let g = NSRect(x: r.minX + 16, y: r.minY + 40, width: r.width - 32, height: r.height - 56)
        drawFreqGrid(g, dbRange: 24, dbLines: [-12, 0, 12])
        let bands = eq3Bands()
        drawCurve(g, dbRange: 24) { f in bands.reduce(0) { $0 + ScreenView.biquadDB($1.kind, $1.f, self.eq3Gain($1.name), 0.7, f) } }
        for b in bands {
            let p = NSPoint(x: xFor(b.f, g), y: g.midY - CGFloat(eq3Gain(b.name) / 24) * g.height / 2)
            tcolor.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)).fill()
        }
    }

    // DELAY / ECHO / BEAT REPEAT: the echoes as fading taps on a beat timeline (L on top, R below)
    func delayBeats(_ side: String) -> Double {
        let tempo = songInfo["tempo"] as? Double ?? 120
        let synced = pval("\(side) Sync") > 0.5 || pval("\(side) Synced") > 0.5
        if synced, param("\(side) 16th") != nil { return max(0.25, number(ptext("\(side) 16th")) * 0.25) }
        let t = ptext("\(side) Time").lowercased()
        let sec = t.contains("ms") ? number(t) / 1000 : number(t)
        return max(0.05, sec * tempo / 60)
    }
    func drawDelay(_ r: NSRect) {
        let cls = device?["class"] as? String ?? ""
        let fbName = firstParam(["Feedback", "1 Feedback"]) ?? "Feedback"
        vizCard(r, cls == "BeatRepeat" ? "grid \(ptext("Grid"))  ·  interval \(ptext("Interval"))  ·  chance \(ptext("Chance"))  ·  decay \(ptext("Decay"))"
                    : "feedback \(ptext(fbName))" + (wetName.map { "  ·  mix \(ptext($0))" } ?? ""))
        let g = NSRect(x: r.minX + 16, y: r.minY + 44, width: r.width - 32, height: r.height - 60)
        let beats = 4.0
        hex(0x163440).setFill(); g.fill()
        for b in 0...16 { NSColor(white: 1, alpha: b % 4 == 0 ? 0.25 : 0.08).setFill(); NSRect(x: g.minX + CGFloat(Double(b) / 16) * g.width, y: g.minY, width: 1, height: g.height).fill() }
        let fb = pnorm(fbName)
        if cls == "BeatRepeat" {
            let grid = max(0.0625, number(ptext("Grid")) > 0 ? 1 / max(1, number(String(ptext("Grid").split(separator: "/").last ?? "16"))) * 4 : 0.25)
            let decay = pnorm("Decay")
            var t = 1.0, k = 0
            while t < beats && k < 64 {
                let a = pow(1 - decay * 0.9, Double(k))
                tcolor.withAlphaComponent(0.3 + 0.7 * a).setFill()
                NSRect(x: g.minX + CGFloat(t / beats) * g.width + 1, y: g.maxY - CGFloat(a) * (g.height - 10), width: max(3, CGFloat(grid / beats) * g.width - 3), height: CGFloat(a) * (g.height - 10)).fill()
                t += grid; k += 1
            }
            return
        }
        // dry hit + echoes
        Theme.text.setFill(); NSRect(x: g.minX + 2, y: g.minY + 6, width: 8, height: g.height - 12).fill()
        for (side, top) in [("L", true), ("R", false)] {
            let dt = param("\(side) Time") != nil || param("\(side) 16th") != nil ? delayBeats(side) : delayBeats("L")
            var t = dt, a = 1.0, k = 0
            while t < beats && k < 40 && a > 0.03 {
                let h = (g.height / 2 - 12) * CGFloat(a)
                let x = g.minX + CGFloat(t / beats) * g.width
                tcolor.withAlphaComponent(0.25 + 0.75 * a).setFill()
                NSRect(x: x - 4, y: top ? g.midY - 6 - h : g.midY + 6, width: 8, height: h).fill()
                t += dt; a *= max(0.05, fb); k += 1
            }
        }
        drawText("L", NSPoint(x: g.maxX - 24, y: g.minY + 8), size: 14, color: Theme.dim, weight: .bold)
        drawText("R", NSPoint(x: g.maxX - 24, y: g.maxY - 26), size: 14, color: Theme.dim, weight: .bold)
        drawText("drag: sideways = mix · up/down = feedback", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }

    // REVERB: pre-delay gap, early reflections, the tail fading over the decay time
    func drawReverb(_ r: NSRect) {
        let cls = device?["class"] as? String ?? ""
        let decayName = cls == "Hybrid" ? "Decay" : "Decay Time", sizeName = cls == "Hybrid" ? "Size" : "Room Size"
        let dt = ptext(decayName).lowercased(), decay = max(0.1, dt.contains("ms") ? number(dt) / 1000 : number(dt))
        let pt = ptext("Predelay").lowercased(), pre = max(0, pt.contains("ms") || !pt.contains("s") ? number(pt) / 1000 : number(pt))
        vizCard(r, "decay \(ptext(decayName))  ·  size \(ptext(sizeName))  ·  pre-delay \(ptext("Predelay"))" + (wetName.map { "  ·  mix \(ptext($0))" } ?? ""))
        let g = NSRect(x: r.minX + 16, y: r.minY + 44, width: r.width - 32, height: r.height - 60)
        hex(0x163440).setFill(); g.fill()
        let total = max(1.0, decay * 1.4 + pre)
        func x(_ s: Double) -> CGFloat { g.minX + CGFloat(s / total) * g.width }
        Theme.text.setFill(); NSRect(x: g.minX + 2, y: g.minY + 6, width: 8, height: g.height - 12).fill()
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for k in 0..<10 {                                        // early reflections
            let t = pre + 0.01 + Double(k) * 0.012 * (0.5 + pnorm(sizeName)) + rnd() * 0.01
            let a = 0.85 - Double(k) * 0.06
            tcolor.setFill(); NSRect(x: x(t), y: g.maxY - CGFloat(a) * (g.height - 12), width: 3, height: CGFloat(a) * (g.height - 12)).fill()
        }
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: x(pre + 0.05), y: g.maxY))
        for k in 0...120 { let t = pre + 0.05 + Double(k) / 120 * (total - pre - 0.05); let a = 0.6 * exp(-6.9 * (t - pre) / (decay + 0.001))
            tail.line(to: NSPoint(x: x(t), y: g.maxY - CGFloat(a) * (g.height - 12))) }
        tail.line(to: NSPoint(x: g.maxX, y: g.maxY)); tail.close()
        tcolor.withAlphaComponent(0.45).setFill(); tail.fill()
        drawText(String(format: "%.1f s", total), NSPoint(x: g.maxX - 70, y: g.minY + 8), size: 13, color: Theme.dim, weight: .bold)
        drawText("drag: sideways = decay · up/down = mix", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }

    // MODULATION (Chorus, Phaser, Auto Pan, Shifter): the LFO wave at its rate and depth
    func drawModulation(_ r: NSRect) {
        let (rateN, amtN) = vizAxes
        let rate = rateN.map { pnorm($0) } ?? 0.3, amt = amtN.map { pnorm($0) } ?? 0.5
        vizCard(r, "rate \(rateN.map { ptext($0) } ?? "")  ·  amount \(amtN.map { ptext($0) } ?? "")" + (wetName.map { "  ·  mix \(ptext($0))" } ?? ""))
        let g = NSRect(x: r.minX + 16, y: r.minY + 44, width: r.width - 32, height: r.height - 60)
        hex(0x163440).setFill(); g.fill()
        NSColor(white: 1, alpha: 0.15).setFill(); NSRect(x: g.minX, y: g.midY, width: g.width, height: 1).fill()
        let cycles = 1 + rate * 7
        let wave = ptext(firstParam(["Waveform", "Mod Wave", "Shape", "Lfo Waveform"]) ?? "").lowercased()
        let w = NSBezierPath()
        for i in 0...300 {
            let t = Double(i) / 300, ph = t * cycles
            var v = sin(ph * 2 * .pi)
            if wave.contains("tri") { v = 1 - 4 * abs(ph - floor(ph + 0.5)) }
            else if wave.contains("square") { v = sin(ph * 2 * .pi) >= 0 ? 1 : -1 }
            else if wave.contains("saw") { v = 2 * (ph - floor(ph)) - 1 }
            let p = NSPoint(x: g.minX + CGFloat(t) * g.width, y: g.midY - CGFloat(v * (0.1 + 0.85 * amt)) * g.height / 2)
            if i == 0 { w.move(to: p) } else { w.line(to: p) }
        }
        tcolor.setStroke(); w.lineWidth = 4; w.stroke()
        drawText("drag: sideways = rate · up/down = amount", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }

    // UTILITY: stereo field (width), balance and gain
    func drawUtility(_ r: NSRect) {
        vizCard(r, "width \(ptext("Stereo Width"))  ·  gain \(ptext("Output"))  ·  balance \(ptext("Balance"))" + (pval("Bass Mono") > 0.5 ? "  ·  bass mono below \(ptext("Bass Freq"))" : ""))
        let c = NSPoint(x: r.midX, y: r.maxY - 24), rad = r.height - 80
        hex(0x163440).setFill()
        let half = NSBezierPath(); half.move(to: c); half.appendArc(withCenter: c, radius: rad, startAngle: 180, endAngle: 360, clockwise: false); half.close(); half.fill()   // (flipped view: 180→360 = the upper half)
        let width = min(4, number(ptext("Stereo Width")) / 100), spread = CGFloat(min(85, 45 * width))
        let bal = CGFloat(pnorm("Balance") - 0.5) * 60
        let wedge = NSBezierPath(); wedge.move(to: c)
        wedge.appendArc(withCenter: c, radius: rad * CGFloat(0.4 + 0.6 * pnorm("Output")), startAngle: 270 - spread + bal, endAngle: 270 + spread + bal, clockwise: false)
        wedge.close(); tcolor.withAlphaComponent(0.75).setFill(); wedge.fill()
        drawText("L", NSPoint(x: c.x - rad - 4, y: c.y - 30), size: 16, color: Theme.dim, weight: .bold)
        drawText("R", NSPoint(x: c.x + rad - 10, y: c.y - 30), size: 16, color: Theme.dim, weight: .bold)
        if pval("Mono") > 0.5 { drawText("MONO", NSPoint(x: c.x - 30, y: c.y - 40), size: 16, color: .black, weight: .bold) }
        drawText("drag: sideways = width · up/down = gain", NSPoint(x: r.minX + 14, y: r.maxY - 26), size: 13, color: hex(0xc9ced2), weight: .regular, width: r.width - 28)
    }

    // finger on the graphic
    var vizStart: (p: NSPoint, x: Double, y: Double) = (.zero, 0, 0)
    func vizDown(_ p: NSPoint) -> Bool {
        let r = vizRect
        guard vizKind != nil, r.contains(p) else { return false }
        switch vizKind {
        case "eq":
            var best: (Int, CGFloat)? = nil
            for b in 1...8 { let q = eqDot(b, r); let dd = hypot(q.x - p.x, q.y - p.y); if best == nil || dd < best!.1 { best = (b, dd) } }
            if let (b, dd) = best, dd < 50 {
                drag = .viz(b); if !eqBand(b).on { setParam("\(b) Filter On A", 1) }
                if qlinkPage != b - 1 {                     // the knobs + Q-Links follow the band you touch
                    link.send(["cmd": "qlink_page", "bank": b - 1])
                    if var dd = device { dd["qlink_page"] = b - 1; state["device"] = dd }
                }
                return true
            }
            return false
        case "comp":
            knobStart = (p.y, pval("Ratio")); vizStartX = p.x; drag = .viz(0); return true
        case "eq3":                                           // the nearest band dot: up/down = its gain
            let g = NSRect(x: r.minX + 16, y: r.minY + 40, width: r.width - 32, height: r.height - 56)
            let bands = eq3Bands()
            if let k = bands.indices.min(by: { abs(xFor(bands[$0].f, g) - p.x) < abs(xFor(bands[$1].f, g) - p.x) }) {
                vizStart = (p, Double(k), pnorm(bands[k].name)); drag = .viz(100 + k); return true
            }
            return false
        case "dyn", "shape", "delay", "reverb", "mod", "util":  // relative drag on the two main controls
            let (ax, ay) = vizAxes
            vizStart = (p, ax.map { pnorm($0) } ?? 0, ay.map { pnorm($0) } ?? 0); drag = .viz(200); return true
        default:
            drag = .viz(0); vizMove(p); return true
        }
    }
    var vizStartX: CGFloat = 0
    func vizMove(_ p: NSPoint) {
        guard case let .viz(b) = drag else { return }
        let r = vizRect
        switch vizKind {
        case "eq":
            let f = max(10, min(22000, freqFor(max(r.minX, min(r.maxX, p.x)), r)))
            setParam("\(b) Frequency A", ScreenView.norm(f))
            if ["lowshelf", "bell", "highshelf"].contains(eqBand(b).kind) {
                let scale = param("Scale") != nil && pval("Scale") != 0 ? pval("Scale") : 1
                let db = Double((r.midY - p.y) / (r.height / 2)) * 18
                setParam("\(b) Gain A", max(-15, min(15, db / scale)))
            }
        case "comp":
            if abs(p.x - vizStartX) > abs(p.y - knobStart.y) {
                let sq = NSRect(x: r.minX + 20, y: r.minY + 14, width: r.height - 28, height: r.height - 28)
                let db = max(-60, min(0, Double((p.x - sq.minX) / sq.width) * 60 - 60))
                if let v = tableValue("Threshold", target: db) { setParam("Threshold", v) }
            } else {
                let v = max(0, min(1, knobStart.value + Double(knobStart.y - p.y) / 300))
                setParam("Ratio", v)
            }
        case "eq3":
            let bands = eq3Bands(), k = b - 100
            if k >= 0 && k < bands.count { setNorm(bands[k].name, vizStart.y + Double(vizStart.p.y - p.y) / Double(r.height * 0.8)) }
        case "dyn", "shape", "delay", "reverb", "mod", "util":
            let (ax, ay) = vizAxes
            if let ax { setNorm(ax, vizStart.x + Double(p.x - vizStart.p.x) / Double(r.width * 0.9)) }
            if let ay { setNorm(ay, vizStart.y + Double(vizStart.p.y - p.y) / Double(r.height * 0.9)) }
        default:
            let f = max(20, min(20000, freqFor(max(r.minX, min(r.maxX, p.x)), r)))
            setParam("Frequency", ScreenView.norm(f))
            setParam("Resonance", max(0, min(1, Double(1 - (p.y - r.minY) / r.height))))
        }
        needsDisplay = true
    }

    // MARK: touches (mouse events from touchmouse)
    override func mouseDown(with e: NSEvent) {
        ScreenView.blankCursor.set()
        let p = convert(e.locationInWindow, from: nil)
        let lag = ProcessInfo.processInfo.systemUptime - e.timestamp       // how long the touch waited for us (main thread busy?)
        let hit = buttons.contains { $0.0.contains(p) } || holdables.contains { $0.0.contains(p) }
        ScreenView.touchLog(String(format: "down %.0f,%.0f lag %.0f ms %@ page %@", p.x, p.y, lag * 1000, hit ? "hit" : "MISS", page.rawValue))
        touchDown(p)
    }
    // every touch, for "sometimes it doesn't react": ~/Library/Logs/MPCScreen-touch.log (kept small)
    static func touchLog(_ line: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MPCScreen-touch.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!)
            if h.offsetInFile > 2_000_000 { h.truncateFile(atOffset: 0) }
            try? h.close()
        } else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
    override func mouseDragged(with e: NSEvent) { touchMoved(convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { touchUp(convert(e.locationInWindow, from: nil)) }
    override func scrollWheel(with e: NSEvent) {
        scrollBy(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, at: convert(e.locationInWindow, from: nil), began: e.phase == .began)
    }

    // MARK: direct touch gestures (MPC style): tap / press acts after a 20 ms settle, one finger drags, two fingers scroll
    enum Gesture { case idle, pending(Date, [NSPoint]), pressed(NSPoint), multi(NSPoint, Bool, CGFloat) }
    var gesture: Gesture = .idle
    var lastTouchMsg = Date.distantPast
    func handleTouches(_ pts: [NSPoint]) {
        if ProcessInfo.processInfo.environment["MPCSCREEN_DEBUG"] == "1" { print("touch", pts, gesture) }
        // safety: a lost "fingers up" must not leave a stale two-finger gesture behind
        if case .multi = gesture, Date().timeIntervalSince(lastTouchMsg) > 1.0 { gesture = .idle }
        lastTouchMsg = Date()
        switch gesture {
        case .idle:
            if pts.count >= 2 { gesture = .multi(center(pts), true, spread(pts)) }
            else if let p = pts.first { gesture = .pending(Date(), [p]) }
        case let .pending(at, seen):
            if pts.count >= 2 { gesture = .multi(center(pts), true, spread(pts)); return }
            if pts.isEmpty {                                      // quick tap
                let p = average(seen); touchDown(p); touchUp(p); gesture = .idle; return
            }
            let all = seen + [pts[0]]
            if Date().timeIntervalSince(at) >= 0.02 {           // settled: press where the finger is
                let p = average(Array(all.suffix(3))); touchDown(p); gesture = .pressed(p)
            } else { gesture = .pending(at, all) }
        case let .pressed(last):
            if pts.count >= 2 { touchUp(last); gesture = .multi(center(pts), true, spread(pts)); return }
            guard let p = pts.first else { touchUp(last); gesture = .idle; return }
            let s = NSPoint(x: last.x * 0.4 + p.x * 0.6, y: last.y * 0.4 + p.y * 0.6)   // light smoothing
            touchMoved(s); gesture = .pressed(s)
        case let .multi(prev, first, dist):
            if pts.isEmpty { gesture = .idle; return }
            guard pts.count >= 2 else { return }
            let c = center(pts), d = spread(pts)
            var nd = dist
            if dist > 30 && abs(d / dist - 1) > 0.04 { pinchBy(d / dist, at: c); nd = d }      // fingers apart / together = zoom
            let dx = (c.x - prev.x) * 0.8, dy = (c.y - prev.y) * 0.8
            if abs(dx) >= 1 || abs(dy) >= 1 { scrollBy(dx: dx, dy: dy, at: c, began: first); gesture = .multi(c, false, nd) }
            else { gesture = .multi(prev, first, nd) }
        }
    }
    func spread(_ p: [NSPoint]) -> CGFloat { hypot(p[0].x - p[1].x, p[0].y - p[1].y) }
    func pinchBy(_ k: CGFloat, at c: NSPoint) {
        if page == .session && arrangement != nil { arrZoom(Double(k), at: c.x); needsDisplay = true }
        else if page == .sample { scrollBy(dx: 0, dy: 200 * log(k), at: c, began: false) }
    }
    func center(_ p: [NSPoint]) -> NSPoint { NSPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2) }
    func average(_ p: [NSPoint]) -> NSPoint {
        NSPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
    }

    var lastDown = NSPoint.zero
    var lastSentView: (Double, Double) = (-1, -1)
    var waveFocus: Double? = nil, waveFocusAt = Date.distantPast                          // where the current press started (for buttons that care)
    func touchDown(_ p: NSPoint) {
        lastDown = p; lastMove = p
        if isRollPage && rollRect.contains(p) && choice == nil && !showPicker && !tempoEdit && !keyEdit { rollDown(p); return }
        // arrangement loop brace (top strip of the ruler): drag its ends or its middle (MPC)
        if page == .session && arrangement != nil && !showPicker && rulerRect.contains(p) && p.y < rulerRect.minY + 20 {
            let l = arrLoop, x0 = beatToX(l.start), x1 = beatToX(l.start + l.length)
            if abs(p.x - x0) < 18 { drag = .loopStart; arrLoopDrag = (l.start, l.length); return }
            if abs(p.x - x1) < 18 { drag = .loopEnd; arrLoopDrag = (l.start, l.length); return }
            if p.x > x0 && p.x < x1 { drag = .loopMove(xToBeat(p.x) - l.start); arrLoopDrag = (l.start, l.length); return }
        }
        pendingHold?.work.cancel(); pendingHold = nil
        if page == .session && arrangement != nil && !showPicker && choice == nil, let h = arrVolHits.first(where: { $0.0.contains(p) }) {
            arrVolDrag = (h.1, p.x, h.2, h.0.width); jogFocusId = "avol\(h.1)"; return
        }
        if page == .sample, choice == nil, !showPicker, !buttons.contains(where: { $0.0.contains(p) }),
           let sl = sliders.first(where: { $0.0.contains(p) }), let s = simpler {
            switch sl.1 {
            case "filter": soundDrag = ("Filter Freq", sv(s, "Filter Freq").0, p.x, p.y, "xy")
            case "gain": soundDrag = ("gain", s["gain"] as? Double ?? 0.4, p.x, p.y, "x")
            default: soundDrag = (sl.1, sv(s, sl.1).0, p.x, p.y, "x")
            }
            soundResStart = sv(s, "Filter Res").0; soundRect = sl.0
            return
        }
        if page == .mixer && choice == nil && !showPicker && !buttons.contains(where: { $0.0.contains(p) }),
           let h = mixHits.last(where: { $0.0.contains(p) }) {                 // fader / knob: relative drag (no jump)
            mixDrag = (h.1, h.2, h.3, p.y, h.4, h.5, h.6, h.7)
            if h.2 == "volume" { jogFocusId = "vol\(h.1)" }                        // the wheel fine-tunes this fader now
            return
        }
        if !buttons.contains(where: { $0.0.contains(p) }), let h = holdables.last(where: { $0.0.contains(p) }) {
            let work = DispatchWorkItem { [weak self] in self?.pendingHold = nil; h.hold() }
            pendingHold = (h.tap, work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            return
        }
        for (r, action) in buttons.reversed() where r.contains(p) { action(); return }
        if page == .sample, let s = simpler, waveRect.insetBy(dx: -10, dy: -10).contains(p) { sampleDown(p, s); return }
        if page == .device, device != nil, !fxPick, let h = devFieldHits.first(where: { $0.0.contains(p) }) {   // drag a Q field = turn it
            let params = deviceParams
            if h.1 < params.count { let v = params[h.1]["value"] as? Double ?? 0; knobStart = (p.y, v); drag = .knob(index: h.1, y: p.y, value: v) }
            return
        }
        if page == .device, device != nil {
            if vizDown(p) { return }
            let params = deviceParams
            for (slot, idx) in visibleKnobs.enumerated() where knobRect(slot).contains(p) {
                guard let i = idx, i < params.count else { return }
                let v = params[i]["value"] as? Double ?? 0
                knobStart = (p.y, v); drag = .knob(index: i, y: p.y, value: v); return
            }
        }
    }

    func sampleDown(_ p: NSPoint, _ s: [String: Any]) {
        let r = waveRect
        let slices = (s["slices"] as? [Int]) ?? []
        let mode = s["mode"] as? String ?? ""
        let startM = s["start"] as? Int ?? 0, endM = s["end"] as? Int ?? (s["length"] as? Int ?? 0)
        // grab handles first: slice markers (top half zone), start/end (bottom zone)
        if p.y > r.maxY - 60 || mode != "Slice" {                   // S / E: their lines (Classic / One-Shot), the bottom strip in Slice
            if abs(frameToX(Double(startM)) - p.x) < 30 { drag = .start; dragFrame = startM; return }
            if abs(frameToX(Double(endM)) - p.x) < 30 { drag = .end; dragFrame = endM; return }
        }
        if mode == "Slice" && !addMode && p.y < r.minY + 70 {
            if let (i, f) = slices.enumerated().map({ ($0.offset, $0.element) }).min(by: { abs(frameToX(Double($0.1)) - p.x) < abs(frameToX(Double($1.1)) - p.x) }),
               abs(frameToX(Double(f)) - p.x) < 30 {
                drag = .slice(index: i, frame: f); dragFrame = f
                link.send(["cmd": "wave_slice", "frame": f]); waveFocus = Double(f); return
            }
        }
        let frame = Int(xToFrame(p.x))
        let style = s["style"] as? String ?? ""
        func chopHere() {                                    // a new chop at the finger (not on top of another one)
            let minGap = max(64.0, (viewEnd - viewStart) / 200)
            guard frame > startM, frame < endM, !slices.contains(where: { abs(Double($0 - frame)) < minGap }) else { return }
            link.send(["cmd": "insert_slice", "at": frame]); waveFocus = Double(frame); waveFocusAt = Date()
            noticeText = "Chop added · drag it off the bottom to remove"; noticeAt = Date(); needsDisplay = true
        }
        if addMode || (mode == "Slice" && style == "Manual") { chopHere(); return }       // MANUAL: tap = cut here
        // tap = play: the slice under the finger (Slice mode) or the sample (Classic/One-Shot plays C3 = 60); hold = cut here
        var note = (s["pad"] as? [String: Any])?["note"] as? Int ?? 60      // a drum pad's sample: that pad's note
        if mode == "Slice" { note = 36 + max(0, (slices.lastIndex(where: { $0 <= frame }) ?? 0)) }
        notes.on(note); drag = .audition(note: note)
        if mode == "Slice" {
            let down = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, case .audition(let n) = self.drag, n == note, hypot(self.lastMove.x - down.x, self.lastMove.y - down.y) < 20 else { return }
                self.notes.off(note); self.drag = .none; chopHere()
            }
        }
    }

    var lastMove = NSPoint.zero
    func touchMoved(_ p: NSPoint) {
        lastMove = p
        if rollDrag != nil { rollMoved(p); return }
        if let d = arrVolDrag {
            let v = max(0, min(1, d.start + Double(p.x - d.x) / Double(d.width)))
            link.send(["cmd": "mix_set", "track": d.track, "what": "volume", "value": v])
            if var a = state["arrangement"] as? [String: Any], var tr = a["tracks"] as? [[String: Any]], d.track < tr.count {
                tr[d.track]["volume"] = v; a["tracks"] = tr; state["arrangement"] = a; needsDisplay = true
            }
            return
        }
        if let d = soundDrag {
            let v = max(0, min(1, d.start + Double(p.x - d.x) / Double(soundRect.width * (d.axis == "xy" ? 1.0 : 0.9))))
            if d.name == "gain" { link.send(["cmd": "simpler_gain", "value": v]) }
            else { link.send(["cmd": "simpler_param", "name": d.name, "norm": v]) }
            if d.axis == "xy" {
                let res = max(0, min(1, soundResStart + Double(d.y - p.y) / Double(soundRect.height)))
                link.send(["cmd": "simpler_param", "name": "Filter Res", "norm": res])
            }
            return
        }
        if let d = mixDrag {
            let v = max(d.lo, min(d.hi, d.start + Double(d.y - p.y) / d.px * (d.hi - d.lo)))
            link.send(["cmd": "mix_set", "track": d.track, "what": d.what, "index": d.index, "value": v])
            setLocalMix(d.track, d.what, d.index, v); return
        }
        if case .loopStart = drag, let d = arrLoopDrag { let e = d.start + d.length, s0 = min(e - loopSnap, snapBeat(xToBeat(p.x))); arrLoopDrag = (max(0, s0), e - max(0, s0)); needsDisplay = true; return }
        if case .loopEnd = drag, let d = arrLoopDrag { let e = max(d.start + loopSnap, snapBeat(xToBeat(p.x))); arrLoopDrag = (d.start, e - d.start); needsDisplay = true; return }
        if case let .loopMove(off) = drag, let d = arrLoopDrag { arrLoopDrag = (max(0, snapBeat(xToBeat(p.x) - off)), d.length); needsDisplay = true; return }
        if let h = pendingHold, hypot(p.x - lastDown.x, p.y - lastDown.y) > 16 { h.work.cancel(); pendingHold = nil }
        let length = simpler?["length"] as? Int ?? 1
        switch drag {
        case .slice, .start, .end:
            dragFrame = max(0, min(length, Int(xToFrame(p.x)))); needsDisplay = true
        case .viz:
            vizMove(p)
        case let .knob(i, _, _):
            guard let params = device?["params"] as? [[String: Any]], i < params.count else { return }
            let mn = params[i]["min"] as? Double ?? 0, mx = params[i]["max"] as? Double ?? 1
            let v = max(mn, min(mx, knobStart.value + Double(knobStart.y - p.y) / 300.0 * (mx - mn)))   // 300 px = full range
            drag = .knob(index: i, y: knobStart.y, value: v)
            link.send(["cmd": "set_param", "index": i, "value": v]); needsDisplay = true
        default: break
        }
    }
    var knobStart: (y: CGFloat, value: Double) = (0, 0)
    var touchedKnob: Int? = nil
    var touchedAt = Date.distantPast

    var loopSnap: Double { (arrEnd - arrStart) / arrSig > 16 ? arrSig : 1 }       // bars when zoomed out, beats when in
    func snapBeat(_ b: Double) -> Double { (b / loopSnap).rounded() * loopSnap }
    var soundResStart = 0.0, soundRect = NSRect.zero
    func touchUp(_ p: NSPoint) {
        if rollDrag != nil { rollUp(p); return }
        if arrVolDrag != nil { arrVolDrag = nil; return }
        if soundDrag != nil { soundDrag = nil; return }
        if mixDrag != nil { mixDrag = nil; return }
        switch drag {
        case .loopStart, .loopEnd, .loopMove:
            if let d = arrLoopDrag { link.send(["cmd": "set_loop", "start": d.start, "length": d.length]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.arrLoopDrag = nil; self?.needsDisplay = true }
            drag = .none; return
        default: break
        }
        if let h = pendingHold { h.work.cancel(); pendingHold = nil; h.tap() }   // released before the hold time: a tap
        switch drag {
        case let .slice(_, f):
            let r = waveRect
            if p.y > r.maxY + 40 { link.send(["cmd": "remove_slice", "at": f]) }        // dragged off the bottom = delete
            else if dragFrame != f { link.send(["cmd": "move_slice", "from": f, "to": dragFrame]); link.send(["cmd": "wave_slice", "frame": dragFrame]) }
        case .start:                                         // let go of S: hear it play from there (the wheel fine-tunes it now)
            link.send(["cmd": "set_start", "at": dragFrame]); jogFocusId = "markerS"
            let sm = simpler ?? [:]
            let n = (sm["pad"] as? [String: Any])?["note"] as? Int ?? ((sm["mode"] as? String) == "Slice" ? 36 : 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.notes.on(n)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self?.notes.off(n) }
            }
        case .end: link.send(["cmd": "set_end", "at": dragFrame]); jogFocusId = "markerE"
        case let .audition(note): notes.off(note)
        default: break
        }
        drag = .none; needsDisplay = true
    }

    // two-finger swipe (scroll events from touchmouse): sideways = move, up/down = zoom, in the sample view
    func scrollBy(dx: CGFloat, dy: CGFloat, at: NSPoint, began: Bool) {
        if page == .mixer {
            if began { sessionScroll = .zero }
            sessionScroll.x += dx
            if abs(sessionScroll.x) > 90 { link.send(["cmd": "session_scroll", "by": sessionScroll.x < 0 ? 1 : -1]); sessionScroll = .zero }
            return
        }
        if page == .session && arrangement == nil {           // two fingers: sideways = tracks, up/down = scenes
            if began { sessionScroll = .zero }
            sessionScroll.x += dx; sessionScroll.y += dy
            if abs(sessionScroll.x) > 90 { link.send(["cmd": "session_scroll", "by": sessionScroll.x < 0 ? 1 : -1]); sessionScroll = .zero }
            if abs(sessionScroll.y) > 60 { link.send(["cmd": "scene_scroll", "by": sessionScroll.y < 0 ? 1 : -1]); sessionScroll = .zero }
            return
        }
        if page == .steps, steps?["melodic"] as? Bool ?? false {     // two fingers up/down: octave
            if began { octaveScroll = 0 }
            octaveScroll += dy
            if abs(octaveScroll) > 60 { stepOctave(octaveScroll > 0 ? 1 : -1); octaveScroll = 0 }
            return
        }
        if page == .browse {
            let rows = CGFloat(browseItems.count)
            browseScroll = max(0, min(max(0, rows * browseRowH - (browseListRect.height - 12)), browseScroll - dy))
            needsDisplay = true; return
        }
        if page == .session && arrangement != nil {          // arrangement: sideways = through time, up/down = through tracks
            let span = arrEnd - arrStart
            let sh = -Double(dx) / Double(arrRect.width) * span; arrStart += sh; arrEnd += sh
            if arrStart < 0 { arrEnd -= arrStart; arrStart = 0 }
            arrTrackScroll -= dy
            if abs(dx) > 2 { arrFollow = false }              // you moved the view yourself: stop following (FOLLOW turns it back on)
            needsDisplay = true; return
        }
        guard page == .sample, let s = simpler else { return }
        let length = Double(s["length"] as? Int ?? 1)
        let span = viewEnd - viewStart
        if abs(dy) > abs(dx) {
            let p = at
            let anchor = xToFrame(p.x), k = exp(-Double(dy) / 200)
            let newSpan = max(256, min(length, span * k))
            let a = (anchor - viewStart) / span
            viewStart = anchor - a * newSpan; viewEnd = viewStart + newSpan
        } else {
            let shift = -Double(dx) / Double(waveRect.width) * span
            viewStart += shift; viewEnd += shift
        }
        clampView(length)
        needsDisplay = true
    }
}

// MARK: - window on the MPC Touch display, never takes focus away from Ableton
final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The MPC Touch panel is cold: neutral greys come out blue-purple (photo 2026-10-08). Warm it up on the Touch
// display only (restored when the app quits): MPCSCREEN_WB="r,g,b" gains (default 0.96,1,0.80; "1,1,1" = off),
// MPCSCREEN_GAMMA = optional mid-tone curve (off unless set).
func applyPanelCurve() {
    let env = ProcessInfo.processInfo.environment
    let wb = (env["MPCSCREEN_WB"] ?? "0.97,1,0.90").split(separator: ",").compactMap { Float($0) }
    let gains: [Float] = wb.count == 3 ? wb : [0.97, 1, 0.90]
    let gamma: Float = env["MPCSCREEN_GAMMA"].flatMap { $0 == "0" ? nil : Float($0) } ?? 1
    if gains == [1, 1, 1] && gamma == 1 { CGDisplayRestoreColorSyncSettings(); return }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0; CGGetOnlineDisplayList(16, &ids, &n)
    guard let id = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == 0x5109 && CGDisplayModelNumber($0) == 0x1021 }) else { return }
    let size = 256
    func table(_ gain: Float) -> [CGGammaValue] {
        (0..<size).map { i in pow(Float(i) / Float(size - 1), gamma) * gain }
    }
    CGSetDisplayTransferByTable(id, UInt32(size), table(gains[0]), table(gains[1]), table(gains[2]))
}

func touchScreen() -> NSScreen? {
    NSScreen.screens.first { s in
        guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
        return CGDisplayVendorNumber(id) == 0x5109 && CGDisplayModelNumber(id) == 0x1021
    }
}

// MARK: - MPC kit (2026-10-09): the MPC-2 look of the mockups
// thin line icons on a 24 grid, written in a tiny path language:
//   M x y · L x y · H x · V y · Z · O cx cy r (circle) · E cx cy rx ry (ellipse) · R x y w h rx (rounded rect) ·
//   A cx cy r a0 a1 (arc in degrees, y down, a0 → a1 increasing)
enum Glyph {
    static let paths: [String: String] = [
        "wave": "M3 12L3 12M6.5 9V15M10 5V19M13.5 8V16M17 10V14M20.5 11.5V12.5",
        "kit": "R4 4 7 7 1R13 4 7 7 1R4 13 7 7 1R13 13 7 7 1",
        "steps": "R3 6 4 4 1R10 6 4 4 1R17 6 4 4 1R3 14 4 4 1R10 14 4 4 1R17 14 4 4 1",
        "notes": "M3 4V20M6 7H13M10 12H19M7 17H13",
        "chords": "R3 5 18 14 2M7.5 5V13M12 5V13M16.5 5V13",
        "device": "O12 12 7.5M12 12L15.5 8",
        "session": "R3 3 5 5 1R9.5 3 5 5 1R16 3 5 5 1R3 9.5 5 5 1R9.5 9.5 5 5 1R16 9.5 5 5 1R3 16 5 5 1R9.5 16 5 5 1R16 16 5 5 1",
        "arrange": "M3 6H11M14 6H21M3 12H8M11 12H21M3 18H15",
        "mixer": "M6 4V20M12 4V20M18 4V20M4 13H8M10 7H14M16 15H20",
        "browse": "M3 6H9L11 8H21V19H3Z",
        "audition": "A12 13 8 180 360M4 13V16M20 13V16R3 14 4 6 1.5R17 14 4 6 1.5",
        "draw": "M4 20L5 16L16 5L19 8L8 19ZM14 7L17 10",
        "erase": "M8 20H20M3.5 14.5L12.5 5.5L18.5 11.5L12 18H7.5Z",
        "zoom": "O10.5 10.5 6M15 15L20 20M10.5 8V13M8 10.5H13",
        "select": "M4 8V4H8M16 4H20V8M20 16V20H16M8 20H4V16M11 4H13M11 20H13M4 11V13M20 11V13",
        "search": "O10.5 10.5 6M15 15L20 20",
        "chop": "O6 7 2.5O6 17 2.5M8 8.5L20 17M8 15.5L20 7",
        "reverse": "M19 8H5L8 5M5 8L8 11M5 16H19L16 13M19 16L16 19",
        "normalize": "M4 12V12M8 8V16M12 5V19M16 8V16M20 11V13M3 3H5M7 3H9M11 3H13M15 3H17M19 3H21",
        "crop": "M6 2V18H22M2 6H18V22",
        "stretch": "M3 12H21M7 8L3 12L7 16M17 8L21 12L17 16",
        "pitch": "M12 20V5M6 11L12 5L18 11",
        "copy": "R8 8 12 12 2M16 8V4H4V16H8",
        "delete": "M4 7H20M9 7V4H15V7M6 7L7 20H17L18 7",
        "capture": "O12 12 8M12 8V16M8 12H16",
        "loop": "M17 2L20 5L17 8M4 11V5H20M7 22L4 19L7 16M20 13V19H4",
        "follow": "M12 3V21M5 9L2 12L5 15M19 9L22 12L19 15",
        "metro": "M9 3H15L19 21H5ZM12 15L17 7",
        "repeat": "M4 12H7M10 12H13M16 12H20M7 8V16M13 8V16",
        "fx": "M4 20L14 10M15 3L16.4 5.8L19.2 7.2L16.4 8.6L15 11.4L13.6 8.6L10.8 7.2L13.6 5.8Z",
        "key": "M9 18V5L20 3V16O6.5 18 2.5O17.5 16 2.5",
        "sidechain": "E12 8 8 3M4 8V16M20 8V16A12 16 8 0 180",
        "power": "M12 3V11A12 13 8 300 600",
        "add": "M12 5V19M5 12H19",
        "load": "M12 4V16M7 11L12 16L17 11M5 20H19",
        "play": "M7 4L20 12L7 20Z",
        "stop": "R6 6 12 12 1",
        "rec": "O12 12 7",
        "down": "M6 9L12 15L18 9",
        "up": "M6 15L12 9L18 15",
        "left": "M15 5L8 12L15 19",
        "right": "M9 5L16 12L9 19",
        "star": "M12 3L14.7 8.6L20.8 9.5L16.4 13.8L17.4 19.9L12 17L6.6 19.9L7.6 13.8L3.2 9.5L9.3 8.6Z",
        "keyboard": "R2 6 20 12 2M7 14H17M6 10H6.5M10 10H10.5M14 10H14.5M18 10H18.5",
        "pads": "R4 4 7 7 1R13 4 7 7 1R4 13 7 7 1R13 13 7 7 1",
        "mic": "R9 3 6 11 3M5.5 11A12 11 6.5 0 180M12 17.5V21M8.5 21H15.5",
    ]
    static let filled: Set<String> = ["play", "stop", "rec"]
    static var cache: [String: NSBezierPath] = [:]
    static func path(_ name: String) -> NSBezierPath {
        if let p = cache[name] { return p }
        let p = NSBezierPath()
        let src = paths[name] ?? ""
        // tokens: a letter, then its numbers
        var tokens: [(Character, [CGFloat])] = []
        var cur: Character? = nil, num = "", nums: [CGFloat] = []
        func flushNum() { if !num.isEmpty, let v = Double(num) { nums.append(CGFloat(v)) }; num = "" }
        for ch in src {
            if ch.isLetter {
                flushNum(); if let c = cur { tokens.append((c, nums)) }
                cur = ch; nums = []
            } else if ch == " " || ch == "," {
                flushNum()
            } else if ch == "-" && !num.isEmpty {
                flushNum(); num = "-"
            } else { num.append(ch) }
        }
        flushNum(); if let c = cur { tokens.append((c, nums)) }
        var last = NSPoint.zero
        for (c, a) in tokens {
            switch c {
            case "M" where a.count >= 2: last = NSPoint(x: a[0], y: a[1]); p.move(to: last)
            case "L" where a.count >= 2: last = NSPoint(x: a[0], y: a[1]); p.line(to: last)
            case "H" where a.count >= 1: last = NSPoint(x: a[0], y: last.y); p.line(to: last)
            case "V" where a.count >= 1: last = NSPoint(x: last.x, y: a[0]); p.line(to: last)
            case "Z": p.close()
            case "O" where a.count >= 3: p.appendOval(in: NSRect(x: a[0] - a[2], y: a[1] - a[2], width: 2 * a[2], height: 2 * a[2]))
            case "E" where a.count >= 4: p.appendOval(in: NSRect(x: a[0] - a[2], y: a[1] - a[3], width: 2 * a[2], height: 2 * a[3]))
            case "R" where a.count >= 5: p.appendRoundedRect(NSRect(x: a[0], y: a[1], width: a[2], height: a[3]), xRadius: a[4], yRadius: a[4])
            case "A" where a.count >= 5:
                let steps = max(4, Int(abs(a[4] - a[3]) / 8))
                for i in 0...steps {
                    let t = (a[3] + (a[4] - a[3]) * CGFloat(i) / CGFloat(steps)) * .pi / 180
                    let q = NSPoint(x: a[0] + a[2] * cos(t), y: a[1] + a[2] * sin(t))
                    if i == 0 { p.move(to: q) } else { p.line(to: q) }
                }
            default: break
            }
        }
        cache[name] = p
        return p
    }
}
func drawGlyph(_ name: String, _ r: NSRect, _ color: NSColor, lw: CGFloat = 1.6) {
    guard let p = Glyph.path(name).copy() as? NSBezierPath else { return }
    let k = r.width / 24
    p.transform(using: AffineTransform(m11: k, m12: 0, m21: 0, m22: k, tX: r.minX, tY: r.minY))
    color.set()
    if Glyph.filled.contains(name) { p.fill() } else {
        p.lineWidth = lw * k * (name == "arrange" ? 1.5 : 1); p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
    }
}

extension ScreenView {
    // one colour per page, only in the header band (MPC); the F-bar's active tab gets a brighter stripe of it
    static let pageColour: [Page: (NSColor, NSColor)] = [
        .sample: (hex(0xa93744), hex(0xd9534f)), .pads: (hex(0xa8612b), hex(0xe08a3c)), .steps: (hex(0x2f5f94), hex(0x4f8fd6)),
        .device: (hex(0x2b7470), hex(0x4fb0a8)), .session: (hex(0x394a56), hex(0x7fa8c4)), .mixer: (hex(0x394a56), hex(0x7fa8c4)),
        .browse: (hex(0x4a5056), hex(0xa9b0b6))]

    // the status strip (34): track · instrument ········ ▶ position · BPM · KEY · SWING · CPU — tap them like the old chips
    func mpcStrip() {
        Theme.strip.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 34).fill()
        let t = state["track"] as? [String: Any]
        let tcol = Theme.live(t?["color"] as? Int)
        var x: CGFloat = 16
        tcol.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: 12, width: 10, height: 10)).fill(); x += 18
        let name = (t?["name"] as? String ?? "…")
            .replacingOccurrences(of: #"\s*\[\d{4}-\d{2}-\d{2} \d{6}\]$"#, with: "", options: .regularExpression).uppercased()   // (CROP / REVERSE copies' date)
        drawTextV(name, NSRect(x: x, y: 0, width: 220, height: 34), size: 15, color: Theme.text, weight: .regular, tracking: 0.03)
        let nw = textW(name, size: 15, weight: .regular, tracking: 0.03)
        buttons.append((NSRect(x: 8, y: 0, width: nw + 40, height: 34), { [weak self] in self?.showPicker.toggle(); self?.tempoEdit = false; self?.needsDisplay = true }))
        x += nw + 14
        let inst = page == .browse && !browseInto.isEmpty ? "loading into: " + browseInto : (trackKind == "drum" ? "Drum Rack" : (isSamplerTrack ? "Simpler" : currentInstrument))
        drawTextV(inst, NSRect(x: x, y: 0, width: 260, height: 34), size: 15, color: Theme.faint, weight: .regular)
        // right side, laid out from the right
        let si = songInfo
        let playing = state["playing"] as? Bool ?? false, rec = si["recording"] as? Bool ?? state["recording"] as? Bool ?? false
        var rx = bounds.width - 16
        func item(_ label: String, _ value: String, _ id: String?, _ action: (() -> Void)?) {
            let vw = textW(value, size: 15, weight: .regular), lw = label.isEmpty ? 0 : textW(label, size: 12, weight: .regular, tracking: 0.1) + 6
            let r = NSRect(x: rx - vw - lw, y: 0, width: vw + lw, height: 34)
            if !label.isEmpty { drawTextV(label, NSRect(x: r.minX, y: 0, width: lw, height: 34), size: 12, color: Theme.faint, weight: .regular, tracking: 0.1) }
            drawTextV(value, NSRect(x: r.minX + lw, y: 0, width: vw + 2, height: 34), size: 15, color: Theme.text, weight: .regular)
            if let action { buttons.append((r.insetBy(dx: -8, dy: 0), action)) }
            if let id { focusable(r.insetBy(dx: -6, dy: 4), id, radius: 3) { [weak self] d in self?.stripTurn(id, d) } }
            rx = r.minX - 22
        }
        item("CPU", String(format: "%.0f%%", cpu), nil, nil)
        item("SWING", "\(si["swing"] as? Int ?? 50)%", "swing") { [weak self] in
            guard let self else { return }
            if self.jogFocusId == "swing" { self.jogFocusId = nil; self.pickSwing() } else { self.jogFocusId = "swing"; self.needsDisplay = true } }
        let root = si["root"] as? Int ?? 0
        item("KEY", ScreenView.rootNames[max(0, min(11, root))] + " " + (si["scale"] as? String ?? "").lowercased(), nil) { [weak self] in self?.pickKey() }
        let tempo = si["tempo"] as? Double ?? 120
        item("BPM", String(format: tempo.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", tempo), "bpm") { [weak self] in
            guard let self else { return }
            self.keyEdit = false; self.tempoEdit.toggle(); self.jogFocusId = self.tempoEdit ? "bpm" : nil; self.needsDisplay = true }
        let pos = barText(songTime).replacingOccurrences(of: ".", with: " . ")
        let pcol = rec && playing ? Theme.red : (playing ? Theme.value : Theme.text)
        let pw = textW(pos, size: 15, weight: .regular)
        drawTextV(pos, NSRect(x: rx - pw, y: 0, width: pw + 2, height: 34), size: 15, color: pcol, weight: .regular)
        drawGlyph(rec && playing ? "rec" : (playing ? "play" : "stop"), NSRect(x: rx - pw - 22, y: 10, width: 14, height: 14), pcol)
    }
    func stripTurn(_ id: String, _ d: Int) {
        if id == "bpm" {
            let v = (((songInfo["tempo"] as? Double ?? 120) + Double(d)) * 100).rounded() / 100   // ±1 BPM, the decimals stay
            link.send(["cmd": "song_set", "what": "tempo", "value": v])
            if var si = state["song"] as? [String: Any] { si["tempo"] = v; state["song"] = si }
        } else if id == "swing" {
            let v = max(50, min(75, (songInfo["swing"] as? Int ?? 50) + d))
            link.send(["cmd": "swing", "value": v])
            if var si = state["song"] as? [String: Any] { si["swing"] = v; state["song"] = si }
        }
    }

    // the page header (70, at y 34): mode icon · a name field (with ▾) · small fields · ····· the tool group · icon buttons
    struct HeaderField { let label: String; let value: String; let action: (() -> Void)? }
    struct Tool { let glyph: String; let on: Bool; let action: () -> Void; var hold: (() -> Void)? = nil; var tint: NSColor? = nil }
    func mpcHeader(_ colour: NSColor, icon: String, name: HeaderField, fields: [HeaderField] = [], tools: [Tool] = [], buttons extra: [Tool] = [], nameWidth: CGFloat? = nil) {
        let y: CGFloat = 34, h: CGFloat = 70
        colour.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: h).fill()
        let ib = NSRect(x: 16, y: y + 12, width: 46, height: 46)
        NSColor.white.withAlphaComponent(0.75).setStroke(); let ibp = NSBezierPath(roundedRect: ib.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5); ibp.lineWidth = 1.5; ibp.stroke()
        drawGlyph(icon, NSRect(x: ib.midX - 13, y: ib.midY - 13, width: 26, height: 26), .white)
        var x = ib.maxX + 18
        func label(_ s: String, _ at: CGFloat) { drawText(s.uppercased(), NSPoint(x: at, y: y + 10), size: 12, color: NSColor.white.withAlphaComponent(0.8), weight: .regular, tracking: 0.12) }
        // the name field: a box with ▾
        label(name.label, x)
        let nw = nameWidth ?? max(300, min(440, textW(name.value, size: 22, weight: .regular) + 60))
        let nb = NSRect(x: x, y: y + 10 + lineH(12) + 3, width: nw, height: 34)
        NSColor.black.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: nb, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke(); let nbo = NSBezierPath(roundedRect: nb.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); nbo.lineWidth = 1; nbo.stroke()
        drawTextV(name.value, NSRect(x: nb.minX + 12, y: nb.minY, width: nb.width - 40, height: nb.height), size: 22, color: .white, weight: .regular)
        if name.action != nil { drawGlyph("down", NSRect(x: nb.maxX - 26, y: nb.midY - 8, width: 16, height: 16), .white, lw: 1.8) }
        if let a = name.action { buttons.append((nb.insetBy(dx: -4, dy: -14), a)) }
        x = nb.maxX + 22
        for f in fields {
            label(f.label, x)
            let vw = textW(f.value, size: 22, weight: .light) + 4
            let vr = NSRect(x: x, y: nb.minY, width: max(vw, textW(f.label, size: 12, weight: .regular, tracking: 0.12)), height: 34)
            drawTextV(f.value, vr, size: 22, color: .white, weight: .light)
            if let a = f.action { buttons.append((NSRect(x: x - 6, y: y + 4, width: vr.width + 12, height: h - 8), a)) }
            x = vr.maxX + 24
        }
        // right: icon buttons (outlined), then the tool group to their left
        var rx = bounds.width - 16
        for t in extra.reversed() {
            let r = NSRect(x: rx - 46, y: y + 12, width: 46, height: 46)
            (t.on ? NSColor.white : NSColor.white.withAlphaComponent(0.75)).setStroke()
            let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5); o.lineWidth = 1.5; o.stroke()
            if t.on { NSColor.white.setFill(); o.fill() }
            drawGlyph(t.glyph, NSRect(x: r.midX - 11, y: r.midY - 11, width: 22, height: 22), t.on ? colour : (t.tint ?? .white))
            if let hold = t.hold { holdables.append((r, tap: t.action, hold: hold)) } else { buttons.append((r, t.action)) }
            rx = r.minX - 10
        }
        if !tools.isEmpty {
            let gw = CGFloat(tools.count) * 54
            let g = NSRect(x: rx - gw, y: y + 13, width: gw, height: 44)
            NSGraphicsContext.saveGraphicsState()
            let gp = NSBezierPath(roundedRect: g, xRadius: 5, yRadius: 5); gp.setClip()
            for (i, t) in tools.enumerated() {
                let r = NSRect(x: g.minX + CGFloat(i) * 54, y: g.minY, width: 54, height: 44)
                if t.on { hex(0xf2f3f4).setFill(); r.fill() } else if let tint = t.tint { tint.setFill(); r.fill() }   // tint: armed (e.g. remove: tap again)
                drawGlyph(t.glyph, NSRect(x: r.midX - 11, y: r.midY - 11, width: 22, height: 22), t.on ? hex(0x2a2b2d) : .white)
                if i > 0 { NSColor.white.withAlphaComponent(0.45).setFill(); NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill() }
                buttons.append((r, t.action))
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.8).setStroke(); let go = NSBezierPath(roundedRect: g.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5); go.lineWidth = 1.5; go.stroke()
        }
    }

    // a field: small label, big thin value; the Q-Link it's on gets an orange outline + "Q1" tag (MPC)
    // CROP / REVERSE copies get "[2026-10-09 162304]" appended by Live: not worth showing
    static func undated(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\[\d{4}-\d{2}-\d{2} \d{6}\]$"#, with: "", options: .regularExpression)
    }
    // Live's terse Simpler / Sampler names, said the way a musician would
    static let friendlyParam: [String: String] = [
        "F On": "Filter", "Filter Freq": "Cutoff", "Filter Res": "Reso", "Filter Drive": "Drive", "Fe < Env": "Filter env",
        "L On": "LFO", "L Rate": "LFO rate", "Filt < LFO": "LFO > filter", "Vol < LFO": "LFO > volume", "Pitch < LFO": "LFO > pitch", "Pan < LFO": "LFO > pan",
        "Ve Attack": "Attack", "Ve Decay": "Decay", "Ve Sustain": "Sustain", "Ve Release": "Release",
        "S Start": "Start", "S Length": "Length", "S Loop On": "Loop", "Glide Time": "Glide", "Vol < Vel": "Velocity"]
    func mpcField(_ r: NSRect, label: String, value: String, q: Int? = nil, active: Bool = false, mint: Bool = false, valueSize: CGFloat = 30,
                  fill: NSColor? = Theme.panel2, action: (() -> Void)? = nil) {
        if let fill { fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill() }
        if active { Theme.accent.setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3); o.lineWidth = 1.5; o.stroke() }
        drawText((ScreenView.friendlyParam[label] ?? label).uppercased(), NSPoint(x: r.minX + 14, y: r.minY + 10), size: 12, color: Theme.dim, weight: .regular, width: r.width - 44, tracking: 0.11)
        drawText(value, NSPoint(x: r.minX + 14, y: r.minY + 10 + lineH(12) + 2), size: valueSize, color: active || mint ? Theme.value : Theme.text, weight: .light, width: r.width - 22)
        if let q {
            let t = "Q\(q)", w = textW(t, size: 11, weight: .bold) + 12
            let tr = NSRect(x: r.maxX - w, y: r.minY, width: w, height: lineH(11) + 4)
            if active { Theme.accent.setFill(); NSBezierPath(roundedRect: tr, xRadius: 3, yRadius: 3).fill(); drawTextV(t, tr, size: 11, color: Theme.darkInk, weight: .bold, center: true) }
            else { drawTextV(t, tr, size: 11, color: Theme.faint, weight: .regular, center: true) }
        }
        if let action { buttons.append((r, action)) }
    }

    // a segmented choice: dark track, the chosen option a white pill (MPC). Returns the box and each option's rect.
    @discardableResult
    func mpcSeg(_ x: CGFloat, _ y: CGFloat, label: String? = nil, _ options: [String], selected: Int?, h: CGFloat = 44, minW: CGFloat = 0,
                rightAligned: Bool = false, action: @escaping (Int) -> Void) -> (NSRect, [NSRect]) {
        var top = y
        let widths = options.map { max(minW, textW($0, size: 15, weight: .bold, tracking: 0.07) + 30) }
        let w = widths.reduce(0, +) + CGFloat(max(0, options.count - 1)) * 3 + 8
        let x0 = rightAligned ? x - w : x
        if let label { drawText(label.uppercased(), NSPoint(x: x0, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); top += lineH(12) + 6 }
        let box = NSRect(x: x0, y: top, width: w, height: h)
        hex(0x1c1e20).setFill(); NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        hex(0x474b4f).setStroke(); let b = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); b.lineWidth = 1; b.stroke()
        var ox = x0 + 4, rects: [NSRect] = []
        for (i, o) in options.enumerated() {
            let r = NSRect(x: ox, y: top + 4, width: widths[i], height: h - 8)
            if i == selected { Theme.active.setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill() }
            drawTextV(o, r, size: 15, color: i == selected ? Theme.darkInk : hex(0xd9dde0), weight: .bold, center: true, tracking: 0.07)
            buttons.append((r.insetBy(dx: -1, dy: -4), { action(i) }))
            rects.append(r); ox += widths[i] + 3
        }
        return (box, rects)
    }
    enum BtnStyle { case dark, light, red }
    func mpcButton(_ r: NSRect, _ title: String, glyph: String? = nil, style: BtnStyle = .dark, size: CGFloat = 14, action: @escaping () -> Void) {
        let fill: NSColor = style == .light ? hex(0xdcdfe1) : (style == .red ? Theme.red : Theme.panel2)
        let ink: NSColor = style == .light ? hex(0x1e2022) : (style == .red ? .white : hex(0xe6e9eb))
        fill.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        if style == .dark { hex(0x4a4e52).setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); o.lineWidth = 1; o.stroke() }
        let tw = textW(title, size: size, weight: .bold, tracking: 0.07), gw: CGFloat = glyph == nil ? 0 : 26
        let x0 = r.midX - (tw + gw) / 2
        if let g = glyph { drawGlyph(g, NSRect(x: x0, y: r.midY - 9, width: 18, height: 18), ink) }
        drawTextV(title, NSRect(x: x0 + gw, y: r.minY, width: tw + 4, height: r.height), size: size, color: ink, weight: .bold, tracking: 0.07)
        buttons.append((r, action))
    }

    // the F-key bar (56): page tabs (icon + name, the active one with a stripe in the page colour) · then this page's actions
    struct FKey { let glyph: String?; let title: String; var on: Bool = false; var weight: CGFloat = 1; let action: () -> Void; var minus: (() -> Void)? = nil; var plus: (() -> Void)? = nil
                  var note: String? = nil }                    // a hint in small text instead of a title (no action)
    func mpcFBar(tabs: [FKey], actions: [FKey], stripe: NSColor) {
        let y = bounds.height - 56
        Theme.fbar.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: 56).fill()
        let all = tabs + actions
        let gaps = CGFloat(all.count - 1) * 6 + (actions.isEmpty ? 0 : 12)
        let unit = (bounds.width - 16 - gaps) / all.map { $0.weight }.reduce(0, +)
        var x: CGFloat = 8
        for (i, k) in all.enumerated() {
            if i == tabs.count && !actions.isEmpty { x += 12 }
            let r = NSRect(x: x, y: y + 6, width: unit * k.weight, height: 44)
            // what a finger hits: the whole bar height (down to the screen's edge) and half of each gap — fingers land low
            let hit = NSRect(x: i == 0 ? 0 : r.minX - 3, y: y, width: r.width + (i == 0 ? r.minX : 3) + (i == all.count - 1 ? bounds.width - r.maxX : 3), height: 56)
            let pill = k.on && i >= tabs.count
            (pill ? Theme.active : (k.on ? hex(0x4a4e52) : Theme.fkey)).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            let kink = pill ? Theme.darkInk : Theme.text
            if k.on && i < tabs.count { stripe.setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: 4), xRadius: 2, yRadius: 2).fill() }
            if let note = k.note {
                for (li, ln) in note.components(separatedBy: " · ").prefix(2).enumerated() {        // two centred lines
                    drawText(li == 0 ? ln + " ·" : ln, NSPoint(x: r.minX, y: r.midY - 19 + CGFloat(li) * 19), size: 15, color: Theme.dim, weight: .regular, center: true, width: r.width)
                }
            } else if let minus = k.minus, let plus = k.plus {             // − NAME +
                drawTextV("−", NSRect(x: r.minX + 16, y: r.minY, width: 30, height: r.height), size: 24, color: Theme.text, weight: .light)
                drawTextV("+", NSRect(x: r.maxX - 34, y: r.minY, width: 30, height: r.height), size: 24, color: Theme.text, weight: .light)
                drawTextV(k.title, r, size: 16, color: Theme.text, weight: .regular, center: true, tracking: 0.08)
                buttons.append((NSRect(x: hit.minX, y: hit.minY, width: r.midX - hit.minX, height: hit.height), minus))
                buttons.append((NSRect(x: r.midX, y: hit.minY, width: hit.maxX - r.midX, height: hit.height), plus))
            } else {
                let tw = textW(k.title, size: 16, weight: .regular, tracking: 0.08), gw: CGFloat = k.glyph == nil ? 0 : 29
                let x0 = r.midX - (tw + gw) / 2
                if let g = k.glyph { drawGlyph(g, NSRect(x: x0, y: r.midY - 10, width: 20, height: 20), kink) }
                drawTextV(k.title, NSRect(x: x0 + gw, y: r.minY, width: tw + 4, height: r.height), size: 16, color: kink, weight: .regular, tracking: 0.08)
                buttons.append((hit, k.action))
            }
            x = r.maxX + 6
        }
    }
    // an MPC pop-up window: the screen dimmed, a panel with a title bar (+ ×). Returns the content rect.
    @discardableResult
    func mpcWindow(_ title: String, width: CGFloat, height: CGFloat, close: @escaping () -> Void) -> NSRect {
        let area = NSRect(x: 0, y: 34, width: bounds.width, height: bounds.height - 34)
        NSColor.black.withAlphaComponent(0.62).setFill(); area.fill()
        buttons.append((area, close))
        let w = min(width, bounds.width - 32), h = min(height, bounds.height - 34 - 32)
        let r = NSRect(x: (bounds.width - w) / 2, y: 34 + (bounds.height - 34 - h) / 2, width: w, height: h)
        Theme.panel.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        hex(0x4a4e52).setStroke(); let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); o.lineWidth = 1; o.stroke()
        buttons.append((r, {}))                                  // taps inside don't close it
        let tb = NSRect(x: r.minX, y: r.minY, width: r.width, height: 48)
        hex(0x3a3e42).setFill(); NSBezierPath(roundedRect: tb, xRadius: 4, yRadius: 4).fill(); NSRect(x: tb.minX, y: tb.maxY - 4, width: tb.width, height: 4).fill()
        drawTextV(title.uppercased(), NSRect(x: tb.minX + 18, y: tb.minY, width: tb.width - 80, height: tb.height), size: 14, color: Theme.text, weight: .bold, tracking: 0.1)
        let x = NSRect(x: tb.maxX - 48, y: tb.minY, width: 48, height: 48)
        drawText("×", NSPoint(x: x.minX, y: x.midY - lineH(26) / 2), size: 26, color: Theme.dim, weight: .light, center: true, width: x.width)
        buttons.append((x, close))
        return NSRect(x: r.minX + 18, y: tb.maxY + 16, width: r.width - 36, height: r.maxY - tb.maxY - 32)
    }

    // a label + rule in the parameter area
    func mpcRule(_ y: CGFloat) { Theme.line.setFill(); NSRect(x: 18, y: y, width: bounds.width - 36, height: 1).fill() }
}

// MARK: NOTES — the melody composer (mockup "Notes"): a piano roll of the song's key, notes with their own start + length
extension ScreenView {
    // instruments, and a Simpler that plays pitches (Classic / One-Shot): the melody composer · a Simpler in Slice mode: the step grid (chops = rows)
    var isRollPage: Bool { page == .steps && (trackKind == "instrument" || trackKind == "empty" || trackKind == "simpler") }
    var rollRect: NSRect { NSRect(x: 74, y: topH, width: bounds.width - 74 - 290, height: bounds.height - topH - 56) }
    var rollWindow: (Double, Double) { let w = Double(rollBars) * 4; return (Double(rollPage) * w, Double(rollPage) * w + w) }
    var rollGrid: Double { (steps?["length"] as? Double) ?? 0.25 }

    // the notes on screen: ours for a moment after a change (no flicker while Live answers), else Live's
    var rollNotes: [[Double]] {
        if let l = rollLocal, Date().timeIntervalSince(rollLocalAt) < 1.2 { return l }
        return ((steps?["roll"] as? [String: Any])?["notes"] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }.filter { $0.count >= 4 }
    }
    var rollSelected: (Int, Double)? {
        if Date().timeIntervalSince(rollLocalAt) < 1.2 { return rollSel }
        if let s = (steps?["roll"] as? [String: Any])?["sel"] as? [Any], s.count == 2, let p = (s[0] as? NSNumber)?.intValue, let t = (s[1] as? NSNumber)?.doubleValue { return (p, t) }
        return nil
    }
    func rollChange(_ notes: [[Double]], sel: (Int, Double)?) { rollLocal = notes; rollSel = sel; rollLocalAt = Date(); setNeedsDisplay(NSRect(x: 0, y: topH, width: bounds.width, height: bounds.height - topH - 56)) }

    // 14 rows, high note on top: the scale (IN KEY) or every semitone, from the pads' lowest note up
    func rollPitches() -> [Int] {
        let st = steps ?? [:], roll = st["roll"] as? [String: Any] ?? [:]
        let root = roll["root"] as? Int ?? 0, iv = (roll["intervals"] as? [Int]) ?? [0, 2, 3, 5, 7, 8, 10]
        let inKey = st["in_key"] as? Bool ?? true, oct = st["octave"] as? Int ?? 3
        var n = 12 * (oct + 2) + root, out: [Int] = []
        while out.count < 14 && n < 128 { if !inKey || iv.contains(((n - root) % 12 + 12) % 12) { out.append(n) }; n += 1 }
        return out.reversed()
    }
    func rollName(_ n: Int) -> String {
        let roll = steps?["roll"] as? [String: Any] ?? [:]
        let root = roll["root"] as? Int ?? 0, iv = (roll["intervals"] as? [Int]) ?? []
        let minor = iv.contains(3) && !iv.contains(4)
        let flat = [5, 10, 3, 8, 1, 6].contains(minor ? (root + 3) % 12 : root)       // F B♭ E♭ A♭ D♭ G♭ (and their minors)
        let names = flat ? ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"] : ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[n % 12] + "\(n / 12 - 2)"
    }

    func drawRoll() {
        let st = steps ?? [:], roll = st["roll"] as? [String: Any] ?? [:]
        let pcol = hex(0x5f4b9b), pstripe = hex(0x8d74d6)
        mpcStrip()
        let clipLen = roll["len"] as? Double ?? 4, bars = max(1, Int((clipLen + 3.99) / 4))
        let clipName = (st["clip"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((st["has_clip"] as? Bool ?? false) ? "Clip" : "No clip yet · draw a note")
        let grids: [Double] = [0.125, 0.25, 0.5, 1.0]
        mpcHeader(pcol, icon: "notes", name: HeaderField(label: "Clip", value: clipName, action: nil),
                  fields: [HeaderField(label: "Length", value: "\(bars) bar\(bars == 1 ? "" : "s")", action: nil),
                           HeaderField(label: "Grid", value: stepLengthName, action: { [weak self] in        // tap = the next grid
                               guard let self else { return }
                               let i = grids.firstIndex(of: self.rollGrid) ?? 1
                               self.link.send(["cmd": "step_length", "value": grids[(i + 1) % grids.count]]) })],
                  tools: [Tool(glyph: "draw", on: rollTool == "draw", action: { [weak self] in self?.rollTool = "draw"; self?.needsDisplay = true }),
                          Tool(glyph: "erase", on: rollTool == "erase", action: { [weak self] in self?.rollTool = "erase"; self?.needsDisplay = true }),
                          Tool(glyph: "select", on: rollTool == "select", action: { [weak self] in self?.rollTool = "select"; self?.needsDisplay = true }),
                          Tool(glyph: "zoom", on: false, action: { [weak self] in                              // 2 → 4 → 1 → 2 bars on screen
                              guard let self else { return }
                              let first = self.rollWindow.0
                              self.rollBars = self.rollBars == 2 ? 4 : (self.rollBars == 4 ? 1 : 2)
                              self.rollPage = Int(first / Double(self.rollBars * 4)); self.needsDisplay = true })])
        // F-keys: the track's tabs · four bar pages · QUANTIZE
        var acts: [FKey] = (0..<4).map { k in
            let a = k * rollBars + 1, b = a + rollBars - 1
            return FKey(glyph: nil, title: rollBars == 1 ? "BAR \(a)" : "BAR \(a)–\(b)", on: rollPage == k, weight: 0.62,
                        action: { [weak self] in self?.rollPage = k; self?.rollFollowOff = Date(); self?.needsDisplay = true }) }
        acts.append(FKey(glyph: "arrange", title: "QUANTIZE", weight: 0.9, action: { [weak self] in
            guard let self else { return }; self.link.send(["cmd": "roll_quantize", "grid": self.rollGrid]) }))
        let tabs = trackTabs(.steps)
        defer { mpcFBar(tabs: tabs, actions: acts, stripe: pstripe) }

        // keys column + lanes
        let r = rollRect, pitches = rollPitches(); rollRows = pitches
        let rh = r.height / CGFloat(max(1, pitches.count))
        let rootN = roll["root"] as? Int ?? 0
        hex(0x202325).setFill(); NSRect(x: 0, y: r.minY, width: r.minX, height: r.height).fill()
        for (i, n) in pitches.enumerated() {
            let y = r.minY + CGFloat(i) * rh
            let isRoot = ((n - rootN) % 12 + 12) % 12 == 0
            if isRoot { hex(0x263a33).setFill(); NSRect(x: 0, y: y, width: r.minX, height: rh).fill() }
            hex(0x2c3034).setFill(); NSRect(x: 0, y: y, width: r.minX, height: 1).fill()
            drawTextV(rollName(n), NSRect(x: 12, y: y, width: r.minX - 14, height: rh), size: 14, color: isRoot ? Theme.value : Theme.hint, weight: .regular, tracking: 0.04)
            (i % 2 == 1 ? hex(0x1d2a33) : hex(0x202e38)).setFill(); NSRect(x: r.minX, y: y, width: r.width, height: rh).fill()
            hex(0x2a3740).setFill(); NSRect(x: r.minX, y: y, width: r.width, height: 1).fill()
        }
        let (w0, w1) = rollWindow, span = w1 - w0
        func bx(_ beat: Double) -> CGFloat { r.minX + CGFloat((beat - w0) / span) * r.width }
        let cols = Int(span / 0.25)
        for c in 0..<cols {                                      // beat lines, bar lines brighter; beyond the clip: dimmer lanes
            let beat = w0 + Double(c) * 0.25
            if c % 16 == 0 { hex(0x58687a).setFill() } else if c % 4 == 0 { hex(0x34444f).setFill() } else { continue }
            NSRect(x: bx(beat), y: r.minY, width: 1, height: r.height).fill()
        }
        if clipLen < w1 { NSColor.black.withAlphaComponent(0.28).setFill(); NSRect(x: bx(max(w0, clipLen)), y: r.minY, width: r.maxX - bx(max(w0, clipLen)), height: r.height).fill() }
        // notes
        let tc = tcolor, sel = rollSelected
        var above = 0, below = 0
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r).setClip()
        for nt in rollNotes {
            var p = Int(nt[0]), s0 = nt[1], d = nt[2]
            let isSel = sel.map { $0.0 == p && abs($0.1 - s0) < 0.003 } ?? false
            if isSel, let dr = rollDrag, dr.moved {                // being dragged: where the finger has it
                if let i = pitches.firstIndex(of: dr.pitch) { p = pitches[max(0, min(pitches.count - 1, i - dr.dRows))] }
                if dr.mode == "len" { d = max(rollGrid / 2, dr.dur + dr.dBeats) } else { s0 = max(0, dr.start + dr.dBeats) }
            }
            guard s0 < w1 && s0 + d > w0 else { continue }
            guard let row = pitches.firstIndex(of: p) else { if p > (pitches.first ?? 0) { above += 1 } else { below += 1 }; continue }
            let nr = NSRect(x: bx(s0) + 1, y: r.minY + CGFloat(row) * rh + 3, width: max(6, bx(s0 + d) - bx(s0) - 2), height: rh - 6)
            (isSel ? Theme.active : tc.withAlphaComponent(0.85)).setFill(); NSBezierPath(roundedRect: nr, xRadius: 2, yRadius: 2).fill()
            if isSel {
                Theme.accent.setStroke(); let o = NSBezierPath(roundedRect: nr.insetBy(dx: -0.75, dy: -0.75), xRadius: 2, yRadius: 2); o.lineWidth = 1.5; o.stroke()
                Theme.darkInk.withAlphaComponent(0.5).setFill(); NSRect(x: nr.maxX - 6, y: nr.minY + 4, width: 2, height: nr.height - 8).fill()   // the grip: drag = length
            }
        }
        if let b = rollBeat, b >= w0, b < w1, Date().timeIntervalSince(lastPlayheadAt) < 0.6 {
            Theme.value.setFill(); NSRect(x: bx(b), y: r.minY, width: 1.5, height: r.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if above > 0 { drawText("▲ \(above)", NSPoint(x: 12, y: r.minY + 2), size: 12, color: Theme.accent, weight: .regular) }
        if below > 0 { drawText("▼ \(below)", NSPoint(x: 12, y: r.maxY - 16), size: 12, color: Theme.accent, weight: .regular) }

        // right panel: the selected note on Q1–Q4 · pads play · octave · chord pads
        let px = bounds.width - 290, pw: CGFloat = 290 - 28
        Theme.panel.setFill(); NSRect(x: px, y: r.minY, width: 290, height: r.height).fill()
        let x = px + 14
        var y = r.minY + 14
        let selNote = sel.flatMap { s in rollNotes.first { Int($0[0]) == s.0 && abs($0[1] - s.1) < 0.003 } }
        drawText("NOTE", NSPoint(x: x, y: y), size: 12, color: Theme.dim, weight: .regular, tracking: 0.11); y += lineH(12) + 2
        let title: String = {
            guard let n = selNote else { return rollTool == "erase" ? "Tap a note to erase" : (rollTool == "draw" ? "Tap the grid to draw" : "Tap a note") }
            let bar = Int(n[1] / 4) + 1, beat = Int(n[1].truncatingRemainder(dividingBy: 4)) + 1
            return rollName(Int(n[0])) + " · bar \(bar).\(beat)"
        }()
        drawText(title, NSPoint(x: x, y: y), size: 26, color: Theme.text, weight: .light, width: pw); y += lineH(26) + 12
        let fw = (pw - 8) / 2, fh: CGFloat = 70
        let tempo = songInfo["tempo"] as? Double ?? 120
        let vals: [(String, String)] = selNote.map { n in
            let off = n[1] - (n[1] / rollGrid).rounded() * rollGrid, ms = Int((off * 60000 / tempo).rounded())
            return [("Pitch", rollName(Int(n[0]))), ("Velocity", "\(Int(n[3]))"), ("Length", ScreenView.exactLength(n[2])),
                    ("Nudge", ms == 0 ? "on grid" : String(format: "%+d ms", ms))] } ?? [("Pitch", "–"), ("Velocity", "–"), ("Length", "–"), ("Nudge", "–")]
        for (k, v) in vals.enumerated() {
            mpcField(NSRect(x: x + CGFloat(k % 2) * (fw + 8), y: y + CGFloat(k / 2) * (fh + 8), width: fw, height: fh), label: v.0, value: v.1, q: k + 1,
                     active: selNote != nil && touchedQ == k, mint: selNote != nil && touchedQ == k, valueSize: 28)
        }
        y += 2 * fh + 8 + 14
        let inKey = st["in_key"] as? Bool ?? true, oct = st["octave"] as? Int ?? 3
        let (kb, _) = mpcSeg(x, y, label: "Pads play", ["IN KEY", "CHROMATIC"], selected: inKey ? 0 : 1, h: 44, minW: (pw - 11) / 2) { [weak self] k in
            guard let self, (k == 0) != inKey else { return }
            self.link.send(["cmd": "step_inkey"]) }
        y = kb.maxY + 12
        mpcSeg(x, y, label: "Octave", ["−", "C\(oct)", "+"], selected: 1, h: 44, minW: (pw - 14) / 3) { [weak self] k in
            if k != 1 { self?.stepOctave(k == 0 ? -1 : 1) } }
        if trackKind == "instrument" {
            mpcButton(NSRect(x: x, y: r.maxY - 14 - 48, width: pw, height: 48), chordsOn ? "CHORD PADS ON" : "CHORD PADS", glyph: "chords", style: chordsOn ? .light : .dark) { [weak self] in
                guard let self else { return }; self.setChords(!self.chordsOn) }
        }
    }

    // touch on the roll: draw = tap empty → a note · tap a note → select it (again → remove) · drag → move · drag its end → length
    func rollHit(_ p: NSPoint) -> (row: Int, beat: Double, note: [Double]?) {
        let r = rollRect, rh = r.height / CGFloat(max(1, rollRows.count))
        let row = max(0, min(rollRows.count - 1, Int((p.y - r.minY) / rh)))
        let (w0, w1) = rollWindow, beat = w0 + Double((p.x - r.minX) / r.width) * (w1 - w0)
        let pitch = rollRows.isEmpty ? 60 : rollRows[row]
        let note = rollNotes.first { Int($0[0]) == pitch && beat >= $0[1] - 0.02 && beat < $0[1] + max($0[2], 0.12) }
        return (row, beat, note)
    }
    func rollDown(_ p: NSPoint) {
        guard !rollRows.isEmpty else { return }
        let h = rollHit(p)
        var notes = rollNotes
        if let n = h.note {
            let key = (Int(n[0]), n[1])
            if rollTool == "erase" {
                notes.removeAll { Int($0[0]) == key.0 && abs($0[1] - key.1) < 0.003 }
                link.send(["cmd": "roll_delete", "pitch": key.0, "start": key.1]); rollChange(notes, sel: nil); return
            }
            let wasSel = rollSelected.map { $0.0 == key.0 && abs($0.1 - key.1) < 0.003 } ?? false
            link.send(["cmd": "roll_select", "pitch": key.0, "start": key.1]); rollChange(notes, sel: key)
            if rollTool == "draw" || wasSel {
                let r = rollRect, (w0, w1) = rollWindow
                let x0 = r.minX + CGFloat((n[1] - w0) / (w1 - w0)) * r.width, endX = r.minX + CGFloat((n[1] + n[2] - w0) / (w1 - w0)) * r.width
                let grip = min(14, (endX - x0) * 0.25)                    // the end of the note (its last quarter) = drag its length
                rollDrag = RollDrag(pitch: key.0, start: n[1], dur: n[2], p0: p, mode: p.x > endX - grip ? "len" : "move", wasSel: wasSel)
            }
            return
        }
        if rollTool != "draw" { link.send(["cmd": "roll_select"]); rollChange(notes, sel: nil); return }
        let g = rollGrid, start = max(0, (h.beat / g).rounded(.down) * g), pitch = rollRows[h.row]
        notes.append([Double(pitch), start, g, 100])
        link.send(["cmd": "roll_add", "pitch": pitch, "start": start, "dur": g, "vel": 100]); rollChange(notes, sel: (pitch, start))
    }
    func rollMoved(_ p: NSPoint) {
        guard var d = rollDrag else { return }
        let r = rollRect, rh = r.height / CGFloat(max(1, rollRows.count)), (w0, w1) = rollWindow, g = rollGrid
        let rows = Int(((d.p0.y - p.y) / rh).rounded()), beats = (Double((p.x - d.p0.x) / r.width) * (w1 - w0) / g).rounded() * g
        if rows != d.dRows || beats != d.dBeats || (!d.moved && hypot(p.x - d.p0.x, p.y - d.p0.y) > 8) {
            d.dRows = d.mode == "len" ? 0 : rows; d.dBeats = beats; d.moved = d.moved || hypot(p.x - d.p0.x, p.y - d.p0.y) > 8
            rollDrag = d; setNeedsDisplay(rollRect)
        }
    }
    func rollUp(_ p: NSPoint) {
        guard let d = rollDrag else { return }
        rollDrag = nil
        var notes = rollNotes
        guard let i = notes.firstIndex(where: { Int($0[0]) == d.pitch && abs($0[1] - d.start) < 0.003 }) else { return }
        if !d.moved {                                        // a tap on the note you had picked: remove it (draw)
            if d.wasSel && rollTool == "draw" {
                notes.remove(at: i); link.send(["cmd": "roll_delete", "pitch": d.pitch, "start": d.start]); rollChange(notes, sel: nil)
            }
            return
        }
        var np = d.pitch, ns = d.start, nd = d.dur
        if let ri = rollRows.firstIndex(of: d.pitch) { np = rollRows[max(0, min(rollRows.count - 1, ri - d.dRows))] }
        if d.mode == "len" { nd = max(rollGrid / 2, d.dur + d.dBeats) } else { ns = max(0, d.start + d.dBeats) }
        notes[i][0] = Double(np); notes[i][1] = ns; notes[i][2] = nd
        link.send(["cmd": "roll_move", "pitch": d.pitch, "start": d.start, "new_pitch": np, "new_start": ns, "new_dur": nd])
        rollChange(notes, sel: (np, ns))
    }
    // the clip plays: the playhead line, and the bar pages follow it (unless you just picked a page)
    func rollPlayhead(_ beat: Double?) {
        let old = rollBeat; rollBeat = beat
        guard isRollPage else { return }
        let r = rollRect, (w0, w1) = rollWindow
        if let b = beat, (b < w0 || b >= w1), Date().timeIntervalSince(rollFollowOff) > 4, (steps?["follow"] as? Bool ?? true) {
            rollPage = max(0, min(3, Int(b / Double(rollBars * 4)))); needsDisplay = true; return
        }
        for v in [old, beat].compactMap({ $0 }) where v >= w0 && v < w1 {
            let x = r.minX + CGFloat((v - w0) / (w1 - w0)) * r.width
            setNeedsDisplay(NSRect(x: x - 3, y: r.minY, width: 8, height: r.height))
        }
    }
}
struct RollDrag { var pitch: Int; var start: Double; var dur: Double; var p0: NSPoint; var mode: String; var wasSel: Bool; var dRows = 0; var dBeats = 0.0; var moved = false }


let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// MPCSCREEN_MAIN=1 shows it on the Mac's own screen (for testing the DisplayLink latency)
let onMain = ProcessInfo.processInfo.environment["MPCSCREEN_MAIN"] == "1"
let screen = onMain ? NSScreen.main! : (touchScreen() ?? NSScreen.screens.last!)
let frame = onMain ? NSRect(x: screen.frame.midX - 640, y: screen.frame.midY - 400, width: 1280, height: 800) : screen.frame
let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.setFrame(frame, display: false)
panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)   // above the menu bar on the Touch
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
panel.hidesOnDeactivate = false
panel.isOpaque = true
panel.backgroundColor = Theme.bg
let view = ScreenView(frame: NSRect(origin: .zero, size: frame.size))
panel.contentView = view
let touchInput = TouchInput()                      // touches straight from touchmouse (no pointer)
touchInput.onTouches = { view.handleTouches($0) }
// only ever show on the Touch: when it disconnects, hide instead of falling back onto the Mac's screen
if onMain || touchScreen() != nil { panel.orderFrontRegardless() }
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
    if onMain { return }
    if let s = touchScreen() { panel.setFrame(s.frame, display: true); view.frame = NSRect(origin: .zero, size: s.frame.size); panel.orderFrontRegardless(); applyPanelCurve() }
    else { panel.orderOut(nil) }
}
applyPanelCurve()
signal(SIGINT) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
signal(SIGTERM) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
app.run()
