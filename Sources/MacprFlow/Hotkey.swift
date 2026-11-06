import AppKit
import ApplicationServices

/// Global trigger listener.
///
/// The tap lives on its own thread with its own run loop. Every keystroke on the Mac passes through an active
/// event tap, so the callback only updates a tiny state machine and hops to the main actor asynchronously.
/// A busy main thread can no longer stall typing system-wide or get the tap disabled by macOS.
final class HotkeyTap: @unchecked Sendable {
    private let lock = NSLock()
    private var machine = TriggerMachine(key: .controlCommand)
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private let deliver: @MainActor @Sendable (HotkeyIntent) -> Void

    init(deliver: @escaping @MainActor @Sendable (HotkeyIntent) -> Void) {
        self.deliver = deliver
    }

    var isRunning: Bool { lock.withLock { port != nil } }

    func setKey(_ key: TriggerKey) {
        lock.withLock { if machine.key != key { machine = TriggerMachine(key: key) } }
    }

    /// Starts the tap, or re-enables it if macOS switched it off. Returns false when Accessibility is missing.
    @discardableResult
    func ensureRunning() -> Bool {
        if let port = lock.withLock({ port }) {
            if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: hotkeyCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal(); return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.withLock { self.port = port; self.runLoop = loop }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Macpr Flow shortcut"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        return isRunning
    }

    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { self.port = nil; self.runLoop = nil; machine = TriggerMachine(key: machine.key) }
            return (self.port, self.runLoop)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        var intent: HotkeyIntent?
        lock.lock()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // Events may have been missed while disabled. Resync so a held key can't get stuck.
            let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
            intent = machine.modifiers(ModifierState(flags: flags), at: now)
            if intent == .pressed { intent = nil; machine = TriggerMachine(key: machine.key) }
        case .flagsChanged:
            intent = machine.modifiers(ModifierState(flags: event.flags.rawValue), at: now)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                intent = machine.keyDown(code: event.getIntegerValueField(.keyboardEventKeycode), at: now)
            }
        default:
            break
        }
        lock.unlock()
        if let intent {
            let deliver = self.deliver
            Task { @MainActor in deliver(intent) }
        }
    }
}

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let context {
        Unmanaged<HotkeyTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
