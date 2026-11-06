import AppKit
import SwiftUI

/// Floating orb at the bottom of the screen. Never takes focus, so typing stays in your app.
///
/// The orb is a Metal view; the controls and notices are a SwiftUI layer on top that only changes
/// when state changes, never per frame. That split is what keeps it smooth.
final class HUDPanel: NSPanel {
    // nonisolated: AppKit asks these from deep inside event routing; a constant needs no main-actor check.
    nonisolated override var canBecomeKey: Bool { false }
    nonisolated override var canBecomeMain: Bool { false }

    static let size = NSSize(width: 420, height: 170)
    static let orbSide: CGFloat = 132
    private var orb: OrbView?

    convenience init(controller: FlowController) {
        self.init(contentRect: NSRect(origin: .zero, size: Self.size),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        let orb = OrbView(signal: controller.recorder.signal)
        orb.frame = NSRect(x: (Self.size.width - Self.orbSide) / 2, y: 0, width: Self.orbSide, height: Self.orbSide)
        root.addSubview(orb)
        self.orb = orb

        let host = NSHostingView(rootView: HUDOverlay(controller: controller))
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        root.addSubview(host)
        contentView = root
    }

    /// Called on every relevant state change, so the orb can never be left asleep while you're dictating.
    func sync(hudVisible: Bool, phase: Phase, style: OrbStyle, sensitivity: Double) {
        let orbVisible = hudVisible && phase.busy
        if hudVisible && !wasVisible { moveToActiveScreen() }
        wasVisible = hudVisible
        if hudVisible { orderFrontRegardless() }
        orb?.state = OrbState(visible: orbVisible, thinking: phase == .finishing,
                              reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, style: style,
                              sensitivity: Float(sensitivity))
    }

    private var wasVisible = false

    /// Bottom-centre of the screen you're working on, just above the Dock.
    private func moveToActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 4))
    }
}

/// Controls and notices around the orb. Real system glass, real system buttons.
private struct HUDOverlay: View {
    @ObservedObject var controller: FlowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let notice = controller.notice, !controller.phase.busy, controller.hudVisible {
                NoticeContent(notice: notice)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 46)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                if controller.handsFree {
                    Button { controller.cancel() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("Cancel dictation")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Color.clear
                    .frame(width: 96, height: HUDPanel.orbSide)
                    .accessibilityElement()
                    .accessibilityLabel(statusText)
                if controller.handsFree {
                    Button { controller.finish() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .tint(.red)
                    .accessibilityLabel("Finish dictation")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .frame(width: HUDPanel.size.width, height: HUDPanel.size.height, alignment: .bottom)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.32, dampingFraction: 0.86), value: controller.handsFree)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 1), value: controller.notice)
    }

    private var statusText: String {
        switch controller.phase {
        case .finishing: return "Writing your text"
        case .starting, .listening: return controller.handsFree ? "Listening hands-free" : "Listening"
        case .idle: return ""
        }
    }
}

private struct NoticeContent: View {
    let notice: Notice
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(notice.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .accessibilityElement(children: .combine)
    }
    private var symbol: String {
        switch notice.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }
    private var tint: Color {
        switch notice.kind {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
