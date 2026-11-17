import AppKit
import SwiftUI

enum Theme {
    /// Text/ink colour as an explicit dynamic AppKit colour (stays correct under the panel's glass).
    static let ink = Color(nsColor: .labelColor)
    /// The system accent colour, so the mixer follows the user's choice in System Settings.
    static let accent = Color.accentColor
    static let hot = Color(nsColor: .systemRed)
    static let track = Theme.ink.opacity(0.12)
    static let hairline = Theme.ink.opacity(0.08)
    static let panelWidth: CGFloat = 340
    /// Offscreen renders can't draw Liquid Glass, so snapshots stand in a translucent fill to judge layout.
    nonisolated(unsafe) static var snapshotMode = false

    static let label = Font.system(size: 12, weight: .semibold)
    static let name = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()
}

// MARK: - Liquid Glass

extension View {
    /// A Liquid Glass surface on macOS 26, a system material on earlier releases.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        let rim = LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.06), Color.white.opacity(0.14)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
        if Theme.snapshotMode {
            self.background(Theme.ink.opacity(0.07), in: shape)
        } else if #available(macOS 26, *) {
            // A faint lift under the glass plus a bright rim, so each tile reads against the panel like Control Center's.
            self.background(shape.fill(Color.white.opacity(0.055)))
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .overlay(shape.strokeBorder(rim, lineWidth: 1))
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    func glassCard(cornerRadius: CGFloat = 24) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Groups neighbouring glass surfaces so they blend and sample the same backdrop.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Sliders

/// A slim capsule slider that tracks the pointer 1:1 while dragging and glides when set programmatically.
struct MixerSlider: View {
    @Binding var value: Float
    var thickness: CGFloat = 6
    var knob: CGFloat = 16
    var enabled = true
    var dimmed = false
    var label = "Volume"
    /// Control Center look: a thick capsule filled edge to edge, with no separate knob.
    var bar = false
    var onEditing: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let k = bar ? 0 : knob
            let travel = max(1, w - k)
            let x = k / 2 + CGFloat(value) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: thickness)
                Capsule()
                    .fill(dimmed ? AnyShapeStyle(Theme.ink.opacity(0.28)) : AnyShapeStyle(Theme.accent))
                    .frame(width: max(thickness, x), height: thickness)
                if !bar {
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(dragging ? 0.30 : 0.20), radius: dragging ? 4 : 2, y: 1)
                        .frame(width: dragging ? knob + 6 : knob, height: knob)
                        .offset(x: x - (dragging ? knob + 6 : knob) / 2)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    if !dragging { dragging = true; onEditing(true) }
                    var v = Float((g.location.x - k / 2) / travel)
                    v = max(0, min(1, v))
                    if v > 0.985 { v = 1 } else if v < 0.015 { v = 0 }
                    value = v
                }
                .onEnded { _ in dragging = false; onEditing(false) })
            .onHover { hovering = $0 }
        }
        .frame(height: bar ? thickness : max(knob + 6, 20))
        .opacity(enabled ? 1 : 0.45)
        .animation(dragging ? nil : .smooth(duration: 0.22), value: value)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: dragging)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            switch dir {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

/// The large Control Center–style volume bar: the fill runs edge to edge and the speaker button sits inside it.
struct MasterSlider: View {
    @Binding var value: Float
    let symbol: String
    var muted = false
    var enabled = true
    let onToggleMute: () -> Void

    @State private var dragging = false
    private let height: CGFloat = 38

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillW = max(height, CGFloat(value) * w)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(muted ? AnyShapeStyle(Theme.ink.opacity(0.22)) : AnyShapeStyle(Theme.accent))
                    .frame(width: fillW)
                Button(action: onToggleMute) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(value > 0.06 && !muted ? Color.white : Theme.ink)
                        .frame(width: height, height: height)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(muted ? "Unmute" : "Mute")
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    guard enabled else { return }
                    dragging = true
                    var v = Float(g.location.x / w)
                    v = max(0, min(1, v))
                    if v > 0.985 { v = 1 } else if v < 0.015 { v = 0 }
                    value = v
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.5)
        .animation(dragging ? nil : .smooth(duration: 0.22), value: value)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Master volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            switch dir {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

// MARK: - Level meter

/// A hairline bar that fills with the app's live output level (green, then amber, then red near clipping).
struct LevelDots: View {
    @ObservedObject var meter: MeterModel
    var active = true

    private static let ramp = LinearGradient(
        stops: [.init(color: Color(nsColor: .systemGreen), location: 0), .init(color: Color(nsColor: .systemGreen), location: 0.6),
                .init(color: Color(nsColor: .systemYellow), location: 0.82), .init(color: Color(nsColor: .systemRed), location: 1)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            let level = active ? CGFloat(min(1, max(0, meter.level))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.07))
                Self.ramp
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) { Capsule().frame(width: max(0, geo.size.width * level)) }
                    .opacity(0.9)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

// MARK: - Control Center glyph

/// The round icon used for devices and toggles: filled with the accent when on, a faint disc when off.
struct GlyphCircle: View {
    let symbol: String
    var on = false
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(on ? Color.white : Theme.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.ink.opacity(0.12))))
    }
}

// MARK: - Buttons

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 30
    var tint: Color = .primary
    var active = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(active ? Theme.accent : tint)
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
                .glassSurface(Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear)))
                .glassSurface(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layout helpers

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Reports whether the hosting window is actually on screen, so meters only run while the panel is open.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: TrackingView, context: Context) { nsView.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { onChange(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
            for n in names {
                observers.append(NotificationCenter.default.addObserver(forName: n, object: window, queue: .main) { [weak self] _ in
                    self?.evaluate()
                })
            }
            evaluate()
        }

        private func evaluate() {
            guard let window else { return }
            // Occlusion state can lag behind ordering-in, but a key window is always on screen.
            onChange(window.isVisible && (window.occlusionState.contains(.visible) || window.isKeyWindow))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
