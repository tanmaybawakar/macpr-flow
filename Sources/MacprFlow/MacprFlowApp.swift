import AppKit
import Combine
import SwiftUI

@main
struct MacprFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            MenuLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences()
    lazy var controller = FlowController(prefs: prefs)
    private var window: NSWindow?
    private var hud: HUDPanel?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        if Diagnostics.run(arguments: arguments, controller: controller) { return }

        // Two copies listening to the same shortcut would start and stop each other.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            others.forEach { $0.terminate() }
        }

        controller.openSettings = { [weak self] in self?.showSettings() }
        let hud = HUDPanel(controller: controller)
        self.hud = hud
        controller.$hudVisible.combineLatest(controller.$phase, prefs.$orbStyle, prefs.$orbSensitivity)
            .sink { [weak hud] visible, phase, style, sensitivity in
                hud?.sync(hudVisible: visible, phase: phase, style: style, sensitivity: sensitivity)
            }
            .store(in: &bag)
        controller.$handsFree.sink { [weak hud] free in hud?.ignoresMouseEvents = !free }.store(in: &bag)

        controller.launch()
        prefs.enableLoginItemOnFirstRun()
        if !controller.setup.accessibility || controller.setup.microphone != .granted { showSettings() }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in self.showSettings() }
        return true
    }

    func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Macpr Flow"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Settings")
            window.contentViewController = NSHostingController(rootView: SettingsRoot(controller: controller, prefs: prefs))
            window.setContentSize(NSSize(width: 760, height: 580))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
}

private struct MenuLabel: View {
    @ObservedObject var controller: FlowController
    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Macpr Flow, \(controller.statusLine)")
    }
    private var symbol: String {
        switch controller.phase {
        case .starting, .listening: return "mic.fill"
        case .finishing: return "ellipsis"
        case .idle: return controller.setup.ready ? "waveform" : "waveform.badge.exclamationmark"
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: FlowController

    var body: some View {
        Text(controller.statusLine)

        switch controller.phase {
        case .idle:
            Button("Start Dictation") { controller.toggleFromUI() }
                .disabled(!controller.setup.ready)
        case .starting, .listening:
            Button("Finish Dictation") { controller.finish() }
            Button("Cancel") { controller.cancel() }
        case .finishing:
            Button("Writing\u{2026}") {}.disabled(true)
        }

        Divider()

        Button("Paste Last Dictation") { controller.pasteLast() }
            .disabled(controller.history.isEmpty)
        Button("Copy Last Dictation") { controller.history.first.map { controller.copy($0.text) } }
            .disabled(controller.history.isEmpty)
        if controller.history.count > 1 {
            Menu("Recent") {
                ForEach(controller.history.prefix(8)) { item in
                    Button(preview(item.text)) { controller.copy(item.text) }
                }
            }
        }

        Divider()

        Button("Settings\u{2026}") { controller.openSettings?() }
            .keyboardShortcut(",")
        Button("Quit Macpr Flow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 48 ? String(flat.prefix(47)) + "\u{2026}" : flat
    }
}
