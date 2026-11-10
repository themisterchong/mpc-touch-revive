// mapcapture: guided capture of every MPC Touch control.
// Listens to all "MPC Touch" MIDI sources (also the hidden private ones). Every time a control that hasn't been seen
// before sends something, the window shows what came in and asks for the name printed on the hardware.
// Results go to mapping.json next to this tool.
import Cocoa
import CoreMIDI

struct Control: Codable { var name: String; var port: String; var kind: String; var channel: Int; var number: Int; var example: String }

final class Capture {
    var controls: [Control] = []
    var seen = Set<String>()
    var queue: [(key: String, c: Control)] = []
    var onNew: (() -> Void)?
    let outURL: URL

    init(outURL: URL) {
        self.outURL = outURL
        if let d = try? Data(contentsOf: outURL), let old = try? JSONDecoder().decode([Control].self, from: d) {
            controls = old
            for c in old { seen.insert(Capture.key(c.port, c.kind, c.channel, c.number)) }
        }
    }
    static func key(_ p: String, _ k: String, _ ch: Int, _ n: Int) -> String { "\(p)|\(k)|\(ch)|\(n)" }

    func handle(port: String, bytes: [UInt8]) {
        guard let s = bytes.first else { return }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        if s == 0xF0 { if !hex.hasPrefix("F0 47 00 37 53") { print("sysex [\(port)] \(hex)") }; return }
        guard bytes.count >= 2 else { return }
        let type = s & 0xF0, ch = Int(s & 0x0F) + 1, n = Int(bytes[1])
        let kind: String
        switch type {
        case 0x90: if bytes.count > 2 && bytes[2] == 0 { return }; kind = "note"
        case 0xB0: kind = "cc"
        case 0xE0: kind = "pitchbend"
        default: return   // note off, aftertouch: not a new control
        }
        let k = Capture.key(port, kind, ch, n)
        if seen.contains(k) || queue.contains(where: { $0.key == k }) { return }
        queue.append((k, Control(name: "", port: port, kind: kind, channel: ch, number: n, example: hex)))
        onNew?()
    }

    func name(_ name: String) {
        guard !queue.isEmpty else { return }
        var item = queue.removeFirst()
        seen.insert(item.key)
        if !name.isEmpty { item.c.name = name; controls.append(item.c); save() }
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(controls).write(to: outURL)
    }
}

let outURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("mapping.json")
let capture = Capture(outURL: outURL)

// MIDI
var client = MIDIClientRef(), inPort = MIDIPortRef()
MIDIClientCreateWithBlock("mapcapture" as CFString, &client, nil)
MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { list, src in
    let port = src.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
    var msgs: [[UInt8]] = []
    list.unsafeSequence().forEach { pkt in
        let p = pkt.pointee
        withUnsafeBytes(of: p.words) { raw in
            for w in raw.bindMemory(to: UInt32.self).prefix(Int(p.wordCount)) where w >> 28 == 2 {   // MIDI 1.0 channel voice
                msgs.append([UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F)])
            }
        }
    }
    DispatchQueue.main.async { for m in msgs { capture.handle(port: port, bytes: m) } }
}
func name(_ o: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? ""
}
var connected: [String] = []
for di in 0..<MIDIGetNumberOfDevices() {
    let dev = MIDIGetDevice(di)
    for ei in 0..<MIDIDeviceGetNumberOfEntities(dev) {
        let e = MIDIDeviceGetEntity(dev, ei)
        for si in 0..<MIDIEntityGetNumberOfSources(e) {
            let ep = MIDIEntityGetSource(e, si), n = name(ep)
            if n.contains("MPC Touch") {
                MIDIPortConnectSource(inPort, ep, Unmanaged.passRetained(n as NSString).toOpaque())
                connected.append(n)
            }
        }
    }
}
print("listening on: \(connected)")

// UI
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "MPC Touch – map controls"
win.level = .floating
let big = NSTextField(labelWithString: "")
big.font = .systemFont(ofSize: 26, weight: .semibold)
big.alignment = .center
big.maximumNumberOfLines = 3
let small = NSTextField(labelWithString: "")
small.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
small.alignment = .center
small.textColor = .secondaryLabelColor
let field = NSTextField(string: "")
field.font = .systemFont(ofSize: 20)
field.placeholderString = "name on the button, e.g. PLAY or Pad 1"
let count = NSTextField(labelWithString: "")
count.alignment = .center
count.textColor = .secondaryLabelColor

final class Target: NSObject {
    @objc func submit(_ sender: NSTextField) {
        guard !capture.queue.isEmpty else { return }
        capture.name(sender.stringValue.trimmingCharacters(in: .whitespaces))
        sender.stringValue = ""
        refresh()
    }
}
let target = Target()
field.target = target
field.action = #selector(Target.submit(_:))

func refresh() {
    count.stringValue = "\(capture.controls.count) controls saved  ·  leave empty + Enter to skip  ·  close window when done"
    if let first = capture.queue.first {
        big.stringValue = "New control! What is it called?"
        small.stringValue = "\(first.c.kind) \(first.c.number), channel \(first.c.channel)  [\(first.c.port)]   \(first.c.example)" + (capture.queue.count > 1 ? "   (+\(capture.queue.count - 1) waiting)" : "")
        field.isEnabled = true
        win.makeFirstResponder(field)
    } else {
        big.stringValue = "Press, turn or touch the next control"
        small.stringValue = "pads, buttons, Q-Links (turn and touch), jog wheel (turn and press)"
        field.isEnabled = false
    }
}
capture.onNew = { refresh(); NSApp.activate(ignoringOtherApps: true) }

let stack = NSStackView(views: [big, small, field, count])
stack.orientation = .vertical
stack.spacing = 18
stack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
win.contentView = stack
win.center()
win.makeKeyAndOrderFront(nil)
refresh()

final class Delegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { capture.save(); print("saved \(capture.controls.count) controls to \(outURL.path)"); exit(0) }
}
let delegate = Delegate()
win.delegate = delegate
NSApp.activate(ignoringOtherApps: true)
app.run()
