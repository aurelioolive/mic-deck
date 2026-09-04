import AppKit
import AVFoundation
import CoreAudio
import Carbon.HIToolbox
import ServiceManagement

// ============================================================
// CoreAudio: low-level access to the input device
// ============================================================

enum CA {
    static let inputScope = kAudioObjectPropertyScopeInput
    static let globalScope = kAudioObjectPropertyScopeGlobal
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = globalScope,
                     _ element: UInt32 = 0) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope, _ elem: UInt32 = 0) -> Bool {
        var a = addr(sel, scope, elem)
        return AudioObjectHasProperty(obj, &a)
    }

    static func isSettable(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope, _ elem: UInt32 = 0) -> Bool {
        var a = addr(sel, scope, elem)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &a, &settable) == noErr && settable.boolValue
    }

    static func float(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope, _ elem: UInt32 = 0) -> Float32? {
        var a = addr(sel, scope, elem)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func uint(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope, _ elem: UInt32 = 0) -> UInt32? {
        var a = addr(sel, scope, elem)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setFloat(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope, _ elem: UInt32, _ value: Float32) -> Bool {
        var a = addr(sel, scope, elem)
        var v = value
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    @discardableResult
    static func setUInt(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope, _ elem: UInt32, _ value: UInt32) -> Bool {
        var a = addr(sel, scope, elem)
        var v = value
        return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = globalScope) -> [AudioObjectID] {
        var a = addr(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }

    static var defaultInputDevice: AudioObjectID {
        uint(system, kAudioHardwarePropertyDefaultInputDevice, globalScope) ?? kAudioObjectUnknown
    }

    /// CoreAudio creates a per-process private aggregate whenever an app opens
    /// the input (CADefaultDeviceAggregate-<pid>-0). It is not a real device and
    /// must not show up in the list. The aggregate composition flags it as private.
    static func isPrivateAggregate(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioAggregateDevicePropertyComposition)
        guard AudioObjectHasProperty(id, &a) else { return false }
        var dict: CFDictionary? = nil
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &dict) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr,
              let composition = dict as? [String: Any],
              let flag = composition[kAudioAggregateDeviceIsPrivateKey as String] else { return false }
        if let number = flag as? Int { return number != 0 }
        if let boolean = flag as? Bool { return boolean }
        return false
    }

    static func inputDevices() -> [AudioObjectID] {
        ids(system, kAudioHardwarePropertyDevices).filter {
            !ids($0, kAudioDevicePropertyStreams, inputScope).isEmpty && !isPrivateAggregate($0)
        }
    }

    /// Bundle identifiers of the processes capturing audio right now.
    /// Returns raw ids so the caller can exclude this app itself.
    static func bundleIDsCapturingInput() -> [String] {
        var result: [String] = []
        for proc in ids(system, kAudioHardwarePropertyProcessObjectList) {
            guard (uint(proc, kAudioProcessPropertyIsRunningInput, globalScope) ?? 0) == 1 else { continue }
            if let bundle = string(proc, kAudioProcessPropertyBundleID), !bundle.isEmpty {
                result.append(bundle)
            } else {
                var a = addr(kAudioProcessPropertyPID)
                var pid: pid_t = 0
                var size = UInt32(MemoryLayout<pid_t>.size)
                if AudioObjectGetPropertyData(proc, &a, 0, nil, &size, &pid) == noErr {
                    result.append("pid:\(pid)")
                }
            }
        }
        return Array(Set(result))
    }

    static func friendlyName(_ bundleID: String) -> String {
        let map: [String: String] = [
            "com.google.Chrome": "Chrome",
            "com.google.Chrome.helper": "Chrome",
            "com.apple.Safari": "Safari",
            "com.hnc.Discord": "Discord",
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams2": "Teams",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.apple.FaceTime": "FaceTime",
            "com.apple.Sound-Settings.extension": "Sound Settings",
            "com.obsproject.obs-studio": "OBS",
            "com.apple.QuickTimePlayerX": "QuickTime",
            "com.apple.WebKit.GPU": "Safari"
        ]
        if let nice = map[bundleID] { return nice }
        if bundleID.hasPrefix("pid:") { return bundleID }
        if let last = bundleID.split(separator: ".").last, bundleID.contains(".") {
            return String(last).capitalized
        }
        return bundleID
    }
}

// ============================================================
// Input device
// ============================================================

struct InputDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
    /// Element that exposes the gain. 0 is the master element.
    let volumeElement: UInt32?
    let supportsMute: Bool

    init(id: AudioObjectID) {
        self.id = id
        self.name = CA.string(id, kAudioObjectPropertyName) ?? "Input"
        self.uid = CA.string(id, kAudioDevicePropertyDeviceUID) ?? "device-\(id)"

        var element: UInt32? = nil
        for candidate: UInt32 in [0, 1, 2] {
            if CA.has(id, kAudioDevicePropertyVolumeScalar, CA.inputScope, candidate),
               CA.isSettable(id, kAudioDevicePropertyVolumeScalar, CA.inputScope, candidate) {
                element = candidate
                break
            }
        }
        self.volumeElement = element
        self.supportsMute = CA.has(id, kAudioDevicePropertyMute, CA.inputScope, 0)
            && CA.isSettable(id, kAudioDevicePropertyMute, CA.inputScope, 0)
    }

    var canControlVolume: Bool { volumeElement != nil }

    var volume: Float? {
        guard let e = volumeElement else { return nil }
        return CA.float(id, kAudioDevicePropertyVolumeScalar, CA.inputScope, e)
    }

    var decibels: Float? {
        guard let e = volumeElement else { return nil }
        return CA.float(id, kAudioDevicePropertyVolumeDecibels, CA.inputScope, e)
    }

    /// Writes the gain to a SINGLE element. Writing to both the master and the
    /// channels fired two notifications, which duplicated every log entry.
    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        guard let e = volumeElement else { return false }
        return CA.setFloat(id, kAudioDevicePropertyVolumeScalar, CA.inputScope, e, max(0, min(1, value)))
    }

    var isMuted: Bool {
        guard supportsMute else { return false }
        return (CA.uint(id, kAudioDevicePropertyMute, CA.inputScope, 0) ?? 0) == 1
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard supportsMute else { return false }
        return CA.setUInt(id, kAudioDevicePropertyMute, CA.inputScope, 0, muted ? 1 : 0)
    }
}

// ============================================================
// Log of blocked changes
// ============================================================

struct BlockedChange {
    let at: Date
    let from: Float
    let to: Float
    let culprits: [String]

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var who: String { culprits.isEmpty ? "unknown source" : culprits.joined(separator: ", ") }

    var description: String {
        "\(BlockedChange.formatter.string(from: at))  \(Int(from * 100))% → \(Int(to * 100))%  ·  \(who)"
    }
}

// ============================================================
// Controller: gain, mute, lock and log
// ============================================================

final class AudioController {
    static let shared = AudioController()

    private(set) var device: InputDevice?
    private(set) var blocked: [BlockedChange] = []

    var onStateChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "micdeck.coreaudio")
    private let writeLock = NSLock()
    /// Values this app just wrote. The CoreAudio listener fires asynchronously,
    /// so a boolean flag does not work: by the time the notification arrives the
    /// flag is already back to normal. Keeping a short history is what separates
    /// our own echo from a genuine external change.
    private var recentSelfWrites: [(value: Float, at: Date)] = []
    private var listenersInstalled: (AudioObjectID, UInt32)?
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "local.micdeck"

    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MicDeck.log")

    // ---- preferences ----

    var lockEnabled: Bool {
        get { defaults.bool(forKey: "lockEnabled") }
        set {
            defaults.set(newValue, forKey: "lockEnabled")
            if newValue, let current = device?.volume { lockTarget = current }
            notify()
        }
    }

    var meterEnabled: Bool {
        get { defaults.object(forKey: "meterEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "meterEnabled"); notify() }
    }

    var storedLockTarget: Float? {
        guard let uid = device?.uid else { return nil }
        let stored = defaults.dictionary(forKey: "lockTargets") as? [String: Double] ?? [:]
        return stored[uid].map { Float($0) }
    }

    var lockTarget: Float {
        get { storedLockTarget ?? device?.volume ?? 1 }
        set {
            guard let uid = device?.uid else { return }
            var stored = defaults.dictionary(forKey: "lockTargets") as? [String: Double] ?? [:]
            stored[uid] = Double(max(0, min(1, newValue)))
            defaults.set(stored, forKey: "lockTargets")
        }
    }

    // ---- lifecycle ----

    private init() {
        refreshDevice()
        var a = CA.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &a, queue, defaultDeviceListenerBlock)
    }

    func refreshDevice() {
        removeDeviceListeners()
        let id = CA.defaultInputDevice
        device = id == kAudioObjectUnknown ? nil : InputDevice(id: id)
        installDeviceListeners()
        if lockEnabled, storedLockTarget == nil, let current = device?.volume {
            lockTarget = current
        }
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }

    // ---- listeners ----

    private lazy var deviceListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        guard let self else { return }
        for index in 0..<Int(count) where addresses[index].mSelector == kAudioDevicePropertyVolumeScalar {
            self.enforceLockIfNeeded()
        }
        self.notify()
    }

    private lazy var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshDevice() }
    }

    private func installDeviceListeners() {
        guard let device, let element = device.volumeElement else { return }
        var volumeAddr = CA.addr(kAudioDevicePropertyVolumeScalar, CA.inputScope, element)
        AudioObjectAddPropertyListenerBlock(device.id, &volumeAddr, queue, deviceListenerBlock)
        var muteAddr = CA.addr(kAudioDevicePropertyMute, CA.inputScope, 0)
        AudioObjectAddPropertyListenerBlock(device.id, &muteAddr, queue, deviceListenerBlock)
        listenersInstalled = (device.id, element)
    }

    private func removeDeviceListeners() {
        guard let (id, element) = listenersInstalled else { return }
        var volumeAddr = CA.addr(kAudioDevicePropertyVolumeScalar, CA.inputScope, element)
        AudioObjectRemovePropertyListenerBlock(id, &volumeAddr, queue, deviceListenerBlock)
        var muteAddr = CA.addr(kAudioDevicePropertyMute, CA.inputScope, 0)
        AudioObjectRemovePropertyListenerBlock(id, &muteAddr, queue, deviceListenerBlock)
        listenersInstalled = nil
    }

    // ---- own writes and echo detection ----

    /// Writes the gain and returns the value the device actually settled on.
    /// The MV7 only accepts steps of about 3%, so asking for 0.67 yields 0.6944.
    /// Storing the requested value as the target created an infinite loop: the
    /// lock would see a mismatch forever. The target must be the settled value.
    @discardableResult
    private func applyVolume(_ requested: Float) -> Float {
        guard let device else { return requested }
        device.setVolume(requested)
        let settled = device.volume ?? requested
        let now = Date()
        writeLock.lock()
        recentSelfWrites.removeAll { now.timeIntervalSince($0.at) > 1.5 }
        recentSelfWrites.append((requested, now))
        recentSelfWrites.append((settled, now))
        writeLock.unlock()
        return settled
    }

    private func isOwnEcho(_ value: Float) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        let now = Date()
        recentSelfWrites.removeAll { now.timeIntervalSince($0.at) > 1.5 }
        return recentSelfWrites.contains { abs($0.value - value) <= 0.005 }
    }

    // ---- lock ----

    private func enforceLockIfNeeded() {
        guard lockEnabled, let device, let current = device.volume else { return }
        guard !isOwnEcho(current) else { return }
        let target = lockTarget
        guard abs(current - target) > 0.005 else { return }

        applyVolume(target)

        let culprits = CA.bundleIDsCapturingInput()
            .filter { $0 != ownBundleID }
            .map(CA.friendlyName)
            .sorted()
        let event = BlockedChange(at: Date(), from: current, to: target, culprits: culprits)
        DispatchQueue.main.async { [weak self] in self?.record(event) }
    }

    private func record(_ event: BlockedChange) {
        if let last = blocked.first,
           abs(last.from - event.from) < 0.005,
           abs(last.to - event.to) < 0.005,
           event.at.timeIntervalSince(last.at) < 1.0 {
            return
        }
        blocked.insert(event, at: 0)
        if blocked.count > 40 { blocked.removeLast() }
        appendToLogFile(event)
        onStateChange?()
    }

    private func appendToLogFile(_ event: BlockedChange) {
        let stamp = ISO8601DateFormatter().string(from: event.at)
        let line = "\(stamp)  \(Int(event.from * 100))% -> \(Int(event.to * 100))%  \(event.who)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    // ---- actions ----

    func setVolumeFromUI(_ value: Float) {
        guard device != nil else { return }
        let settled = applyVolume(value)
        if lockEnabled { lockTarget = settled }
        notify()
    }

    func toggleMute() {
        guard let device, device.supportsMute else { NSSound.beep(); return }
        device.setMuted(!device.isMuted)
        notify()
    }

    func selectDevice(_ id: AudioObjectID) {
        var value = id
        var a = CA.addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(CA.system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    var isMuted: Bool { device?.isMuted ?? false }
    var volume: Float { device?.volume ?? 0 }
    var decibels: Float? { device?.decibels }
}

// ============================================================
// Level meter
// ============================================================

final class LevelMeter {
    private let engine = AVAudioEngine()
    private var running = false
    private(set) var permissionDenied = false
    var onLevel: ((Float) -> Void)?

    func start(deviceID: AudioObjectID?) {
        guard !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            reallyStart(deviceID: deviceID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.reallyStart(deviceID: deviceID) } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func reallyStart(deviceID: AudioObjectID?) {
        guard !running else { return }
        let input = engine.inputNode
        if let deviceID { try? input.auAudioUnit.setDeviceID(deviceID) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[i])) }
            let db = peak > 0 ? 20 * log10(peak) : -100
            DispatchQueue.main.async { self?.onLevel?(db) }
        }
        engine.prepare()
        do { try engine.start(); running = true } catch { running = false }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        onLevel?(-100)
    }
}

// ============================================================
// Global hotkey (Carbon, needs no accessibility permission)
// ============================================================

private var hotkeyAction: (() -> Void)?

final class GlobalHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        hotkeyAction = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            hotkeyAction?()
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4D494B45), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

// ============================================================
// Meter view
// ============================================================

final class MeterView: NSView {
    private var level: Float = -100
    private var peakHold: Float = -100
    private var peakSetAt = Date.distantPast
    private let floorDb: Float = -60

    /// When set, the meter shows this text instead of a level.
    var disabledMessage: String? { didSet { needsDisplay = true } }

    func update(db: Float) {
        level = db
        if db > peakHold || Date().timeIntervalSince(peakSetAt) > 1.6 {
            peakHold = db
            peakSetAt = Date()
        }
        needsDisplay = true
    }

    func reset() {
        level = -100
        peakHold = -100
        needsDisplay = true
    }

    private func fraction(_ db: Float) -> CGFloat {
        guard db > floorDb else { return 0 }
        return CGFloat(min(1, (db - floorDb) / (0 - floorDb)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = bounds
        let radius: CGFloat = 4

        NSColor.quaternaryLabelColor.withAlphaComponent(0.30).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        if let message = disabledMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let size = (message as NSString).size(withAttributes: attrs)
            (message as NSString).draw(at: NSPoint(x: (bar.width - size.width) / 2,
                                                   y: (bar.height - size.height) / 2),
                                       withAttributes: attrs)
            return
        }

        let filled = fraction(level) * bar.width
        if filled > 1 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: filled, height: bar.height),
                         xRadius: radius, yRadius: radius).setClip()
            let gradient = NSGradient(colors: [.systemGreen, .systemGreen, .systemYellow, .systemRed],
                                      atLocations: [0.0, 0.62, 0.84, 1.0], colorSpace: .sRGB)
            gradient?.draw(in: bar, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        for db in [Float(-40), -20, -12, -6] {
            NSRect(x: fraction(db) * bar.width, y: 0, width: 1, height: bar.height).fill()
        }

        if peakHold > floorDb {
            let x = min(fraction(peakHold) * bar.width, bar.width - 2)
            (peakHold > -1 ? NSColor.systemRed : NSColor.labelColor).setFill()
            NSRect(x: x, y: 0, width: 2, height: bar.height).fill()
        }
    }
}

// ============================================================
// Prominent mute button
// ============================================================

final class MuteButton: NSButton {
    var muted = false { didSet { needsDisplay = true } }
    var available = true { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        var fill: NSColor = muted ? .systemRed : .controlAccentColor
        if !available { fill = .quaternaryLabelColor }
        if isHighlighted { fill = fill.blended(withFraction: 0.25, of: .black) ?? fill }
        fill.setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()

        let label = muted ? "Unmute Microphone" : "Mute Microphone"
        let symbol = muted ? "mic.slash.fill" : "mic.fill"
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: textAttrs)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        let gap: CGFloat = 7
        let iconWidth = icon?.size.width ?? 0
        var x = (box.width - (iconWidth + gap + textSize.width)) / 2
        if let icon {
            icon.draw(in: NSRect(x: x, y: (box.height - icon.size.height) / 2,
                                 width: icon.size.width, height: icon.size.height))
            x += iconWidth + gap
        }
        (label as NSString).draw(at: NSPoint(x: x, y: (box.height - textSize.height) / 2),
                                 withAttributes: textAttrs)

        let hint = "⌃⌥M"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let hintSize = (hint as NSString).size(withAttributes: hintAttrs)
        (hint as NSString).draw(at: NSPoint(x: box.maxX - hintSize.width - 12,
                                            y: (box.height - hintSize.height) / 2),
                                withAttributes: hintAttrs)
    }
}

// ============================================================
// Panel embedded in the menu
// ============================================================

final class PanelView: NSView {
    private let deviceLabel = NSTextField(labelWithString: "")
    let meter = MeterView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    let muteButton = MuteButton(frame: .zero)

    private let controller = AudioController.shared

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 176))
        let inset: CGFloat = 16
        let width = frame.width - inset * 2

        deviceLabel.frame = NSRect(x: inset, y: 146, width: width, height: 17)
        deviceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        deviceLabel.lineBreakMode = .byTruncatingTail
        addSubview(deviceLabel)

        meter.frame = NSRect(x: inset, y: 118, width: width, height: 18)
        addSubview(meter)

        hintLabel.frame = NSRect(x: inset, y: 98, width: width, height: 14)
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        addSubview(hintLabel)

        slider.frame = NSRect(x: inset, y: 64, width: width - 92, height: 20)
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        addSubview(slider)

        valueLabel.frame = NSRect(x: inset + width - 88, y: 64, width: 88, height: 18)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        addSubview(valueLabel)

        muteButton.frame = NSRect(x: inset, y: 16, width: width, height: 34)
        addSubview(muteButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastDragAt = Date.distantPast

    @objc private func sliderMoved() {
        lastDragAt = Date()
        controller.setVolumeFromUI(Float(slider.doubleValue / 100))
        refresh()
    }

    func refresh() {
        muteButton.muted = controller.isMuted
        muteButton.available = controller.device?.supportsMute ?? false

        guard let device = controller.device else {
            deviceLabel.stringValue = "No audio input"
            slider.isEnabled = false
            valueLabel.stringValue = "—"
            hintLabel.stringValue = ""
            return
        }

        deviceLabel.stringValue = device.name
        deviceLabel.textColor = controller.isMuted ? .systemRed : .labelColor
        meter.disabledMessage = controller.meterEnabled ? nil : "meter off"

        slider.isEnabled = device.canControlVolume
        guard device.canControlVolume else {
            valueLabel.stringValue = "no gain"
            hintLabel.stringValue = "This device exposes no gain control."
            return
        }

        let percent = Int((device.volume ?? 0) * 100)
        // Repositioning the knob mid-drag makes it jump, because the device
        // rounds every value to its nearest step.
        if Date().timeIntervalSince(lastDragAt) > 0.4,
           abs(slider.doubleValue - Double(percent)) > 0.5 {
            slider.doubleValue = Double(percent)
        }
        if let db = device.decibels {
            valueLabel.stringValue = String(format: "%d%%  ·  %.0f dB", percent, db)
        } else {
            valueLabel.stringValue = "\(percent)%"
        }

        if controller.lockEnabled {
            hintLabel.stringValue = "Locked at \(Int(controller.lockTarget * 100))%. External changes are reverted."
            hintLabel.textColor = .systemBlue
        } else {
            hintLabel.stringValue = "Lock is off. Programs can change the gain."
            hintLabel.textColor = .secondaryLabelColor
        }
    }
}

// ============================================================
// Application
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let panel = PanelView()
    private let meterEngine = LevelMeter()
    private let hotkey = GlobalHotkey()
    private let controller = AudioController.shared

    private var lockItem: NSMenuItem!
    private var blockedItem: NSMenuItem!
    private var meterItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var repaintTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        buildMenu()
        statusItem.menu = menu

        panel.muteButton.target = self
        panel.muteButton.action = #selector(toggleMute)

        controller.onStateChange = { [weak self] in self?.refresh() }
        meterEngine.onLevel = { [weak self] db in self?.panel.meter.update(db: db) }

        hotkey.register(keyCode: UInt32(kVK_ANSI_M),
                        modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.controller.toggleMute()
            self?.flashIcon()
        }

        refresh()
    }

    private func buildMenu() {
        menu.delegate = self

        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        lockItem = NSMenuItem(title: "Lock Input Volume", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)

        blockedItem = NSMenuItem(title: "Blocked Changes", action: nil, keyEquivalent: "")
        blockedItem.submenu = NSMenu()
        menu.addItem(blockedItem)

        menu.addItem(.separator())

        meterItem = NSMenuItem(title: "Level Meter", action: #selector(toggleMeter), keyEquivalent: "")
        meterItem.target = self
        menu.addItem(meterItem)

        let devicesItem = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        devicesItem.submenu = NSMenu()
        devicesItem.submenu?.delegate = self
        menu.addItem(devicesItem)

        let soundItem = NSMenuItem(title: "Open Sound Settings…", action: #selector(openSoundSettings), keyEquivalent: "")
        soundItem.target = self
        menu.addItem(soundItem)

        let logItem = NSMenuItem(title: "Open Full Log…", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // ---- opening and closing ----

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            rebuildBlockedSubmenu()
            panel.meter.reset()
            if controller.meterEnabled {
                meterEngine.start(deviceID: controller.device?.id)
                repaintTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    self?.panel.meter.needsDisplay = true
                }
                RunLoop.main.add(repaintTimer!, forMode: .eventTracking)
            }
            refresh()
        } else if menu.supermenu === self.menu {
            rebuildDeviceSubmenu(menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        meterEngine.stop()
        repaintTimer?.invalidate()
        repaintTimer = nil
        panel.meter.reset()
    }

    private func rebuildDeviceSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()
        let current = controller.device?.id
        for id in CA.inputDevices() {
            let device = InputDevice(id: id)
            let item = NSMenuItem(title: device.name, action: #selector(pickDevice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.state = (id == current) ? .on : .off
            submenu.addItem(item)
        }
    }

    private func rebuildBlockedSubmenu() {
        guard let submenu = blockedItem.submenu else { return }
        submenu.removeAllItems()
        let events = controller.blocked
        if events.isEmpty {
            let empty = NSMenuItem(title: "None so far", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for event in events.prefix(15) {
                let item = NSMenuItem(title: event.description, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = NSAttributedString(
                    string: event.description,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
                submenu.addItem(item)
            }
        }
        blockedItem.title = events.isEmpty ? "Blocked Changes" : "Blocked Changes (\(events.count))"
    }

    // ---- actions ----

    @objc private func toggleMute() { controller.toggleMute() }

    @objc private func toggleLock() {
        controller.lockEnabled = !controller.lockEnabled
        refresh()
    }

    @objc private func toggleMeter() {
        controller.meterEnabled = !controller.meterEnabled
        if controller.meterEnabled {
            meterEngine.start(deviceID: controller.device?.id)
        } else {
            meterEngine.stop()
        }
        refresh()
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        controller.selectDevice(AudioObjectID(sender.tag))
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        let url = controller.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
        refresh()
    }

    private func flashIcon() {
        guard let button = statusItem.button else { return }
        button.alphaValue = 0.25
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            button.animator().alphaValue = 1.0
        }
    }

    // ---- state ----

    private func refresh() {
        let muted = controller.isMuted
        let image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill",
                            accessibilityDescription: muted ? "microphone muted" : "microphone")
        image?.isTemplate = !muted
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = muted ? .systemRed : nil

        var tip = "\(controller.device?.name ?? "no input") · \(Int(controller.volume * 100))%"
        if muted { tip += " · muted" }
        if controller.lockEnabled { tip += " · locked at \(Int(controller.lockTarget * 100))%" }
        tip += "\nControl+Option+M toggles mute"
        statusItem.button?.toolTip = tip

        lockItem?.state = controller.lockEnabled ? .on : .off
        lockItem?.title = controller.lockEnabled
            ? "Lock Input Volume (\(Int(controller.lockTarget * 100))%)"
            : "Lock Input Volume"
        lockItem?.isEnabled = controller.device?.canControlVolume ?? false

        meterItem?.state = controller.meterEnabled ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off

        panel.refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
