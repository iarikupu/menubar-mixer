import SwiftUI

struct PanelView: View {
    @ObservedObject var model: MixerModel
    @State private var showDevices: Bool
    @State private var listHeight: CGFloat = 0
    /// Rows beyond this height scroll instead of growing the panel.
    private let maxListHeight: CGFloat = 330

    init(model: MixerModel, showDevices: Bool = false) {
        self.model = model
        _showDevices = State(initialValue: showDevices)
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            GlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    master
                    outputPicker
                    appsSection
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(width: Theme.panelWidth)
        .padding(.bottom, 12)
        .background(WindowVisibilityReader { model.panelVisible = $0 })
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.channels.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.permission)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showDevices)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Sound").font(.system(size: 17, weight: .bold))
            Spacer()
            Menu {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Live level meters", isOn: $model.liveMeters)
                Divider()
                Button("Open log file") { model.openLog() }
                Button("Quit Menubar Mixer") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .glassSurface(Circle(), interactive: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    // MARK: Master

    private var master: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MasterSlider(value: Binding(get: { model.masterMuted ? 0 : model.masterVolume }, set: { model.setMasterVolume($0) }),
                             symbol: masterSymbol, muted: model.masterMuted, enabled: model.masterAdjustable) { model.toggleMasterMute() }
                Text(model.masterMuted ? "Muted" : "\(Int((model.masterVolume * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(model.masterMuted ? .secondary : .primary)
                    .frame(width: 48, alignment: .trailing)
                    .animation(nil, value: model.masterVolume)
            }
            if !model.masterAdjustable {
                Text("This output has no volume control")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassCard()
    }

    private var masterSymbol: String {
        if model.masterMuted || model.masterVolume == 0 { return "speaker.slash.fill" }
        return model.masterVolume < 0.34 ? "speaker.wave.1.fill" : (model.masterVolume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }

    // MARK: Output picker

    private var outputPicker: some View {
        VStack(spacing: 0) {
            Button { showDevices.toggle() } label: {
                HStack(spacing: 10) {
                    GlyphCircle(symbol: model.currentOutput?.symbol ?? "speaker.wave.2", on: true, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Output").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.currentOutput?.name ?? "No output device")
                            .font(Theme.name).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showDevices ? 180 : 0))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            if showDevices {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14).padding(.bottom, 4)
                    ForEach(model.outputs) { d in
                        Button {
                            model.selectOutput(d)
                            withAnimation { showDevices = false }
                        } label: {
                            // 28 pt glyphs inset 16 so their centres line up with the 32 pt glyph above.
                            HStack(spacing: 12) {
                                GlyphCircle(symbol: d.symbol, on: d.id == model.currentOutputID, size: 28)
                                Text(d.name).font(.system(size: 13, weight: d.id == model.currentOutputID ? .semibold : .regular)).lineLimit(1)
                                Spacer()
                                if model.mutedOutputs.contains(d.id) {
                                    Image(systemName: "speaker.slash.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                                        .help("Muted in macOS")
                                }
                            }
                            .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassCard()
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps").font(Theme.label).foregroundStyle(.secondary)
                if !model.channels.isEmpty {
                    Text("\(model.channels.count)").font(Theme.label).foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)

            if model.showPermissionBanner {
                PermissionBanner(model: model).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.channels.isEmpty {
                emptyState.transition(.opacity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(model.channels) { ch in
                            AppRow(model: model, channel: ch)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).combined(with: .offset(y: -8)),
                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
                        }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 8)
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
                }
                .frame(height: min(max(listHeight, 1), maxListHeight))
                // When the list scrolls, fade the bottom edge instead of cutting a row in half.
                .mask(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(listHeight > maxListHeight ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 22)
                    }
                }
                .onPreferenceChange(ContentHeightKey.self) { h in
                    if abs(h - listHeight) > 0.5 { listHeight = h }
                }
            }
            if let err = model.loginItemError {
                Text(err).font(.system(size: 11)).foregroundStyle(Theme.hot).padding(.horizontal, 14).padding(.vertical, 8)
            } else if model.loginItemState == .requiresApproval {
                Text("Approve Menubar Mixer in System Settings → General → Login Items.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .glassCard()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.isLive && model.panelVisible)
            Text("Nothing is playing").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            Text("Apps show up here the moment they make sound.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.ink.opacity(configuration.isPressed ? 0.10 : 0))
    }
}

// MARK: - App row

struct AppRow: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var channel: AppChannel
    @State private var hovering = false

    private var enabled: Bool { channel.status != .needsPermission }

    /// Chooses which speaker this app plays through.
    private var routeMenu: some View {
        let routed = model.outputs.first { $0.uid == channel.outputUID }
        let destination = routed ?? model.currentOutput
        let silent = destination.map { model.mutedOutputs.contains($0.id) } ?? false
        return Menu {
            Button {
                model.setOutput(channel, uid: nil)
            } label: {
                Label("System output (\(model.currentOutput?.name ?? "—"))", systemImage: channel.outputUID == nil ? "checkmark" : "speaker.wave.2")
            }
            Divider()
            ForEach(model.outputs) { d in
                Button {
                    model.setOutput(channel, uid: d.uid)
                } label: {
                    Label(d.name, systemImage: channel.outputUID == d.uid ? "checkmark" : d.symbol)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: channel.routeMissing || silent ? "exclamationmark.triangle.fill" : (routed?.symbol ?? "airplayaudio"))
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(channel.routeMissing || silent ? Theme.hot : (channel.outputUID == nil ? Color.secondary : Theme.accent))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.ink.opacity(channel.outputUID == nil ? 0.07 : 0.0)))
            .overlay(Capsule().strokeBorder((channel.routeMissing || silent ? Theme.hot : Theme.accent).opacity(channel.outputUID == nil && !silent ? 0 : 0.5), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(silent ? "\(destination?.name ?? "This output") is muted in macOS, so \(channel.host.name) is silent. Unmute it in System Settings → Sound."
                     : channel.routeMissing ? "The chosen output isn’t connected; playing through the system output for now."
                                    : (routed.map { "\(channel.host.name) plays through \($0.name)" } ?? "Choose the speaker for \(channel.host.name)"))
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: channel.icon)
                .resizable().interpolation(.high)
                .frame(width: 32, height: 32)
                .opacity(channel.muted ? 0.45 : 1)
                .saturation(channel.muted ? 0.2 : 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(channel.host.name).font(Theme.name).lineLimit(1)
                        .foregroundStyle(channel.muted ? .secondary : .primary)
                    routeMenu
                    Spacer(minLength: 4)
                    Text(channel.muted ? "Muted" : "\(Int((channel.volume * 100).rounded()))%")
                        .font(Theme.value).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(nil, value: channel.volume)
                        .onTapGesture(count: 2) { model.resetVolume(channel) }
                        .help("Double-click to reset to 100%")
                }
                MixerSlider(value: Binding(get: { channel.muted ? 0 : channel.volume }, set: { model.setVolume(channel, $0) }),
                            thickness: 20, enabled: enabled, dimmed: channel.muted, label: "\(channel.host.name) volume", bar: true)
                LevelDots(meter: channel.meter, active: !channel.muted)
                if case .failed = channel.status {
                    Text("Couldn’t intercept this app’s audio — it will retry. See the log for details.")
                        .font(.system(size: 11)).foregroundStyle(Theme.hot).padding(.top, 2)
                }
            }
            IconButton(symbol: channel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 28,
                       active: channel.muted, help: channel.muted ? "Unmute \(channel.host.name)" : "Mute \(channel.host.name)") {
                model.toggleMute(channel)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reset to 100%") { model.resetVolume(channel) }
            Button(channel.muted ? "Unmute" : "Mute") { model.toggleMute(channel) }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.18), value: channel.muted)
    }
}

// MARK: - Permission banner

struct PermissionBanner: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.permission == .denied ? "lock.slash" : "lock.shield")
                .font(.system(size: 15)).foregroundStyle(Theme.accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.permission == .denied ? "Per-app volume is off" : "Allow per-app volume")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.permission == .denied
                     ? "Apps that are playing are listed, but macOS hasn’t let Menubar Mixer capture their audio, so the sliders are disabled. Turn on Menubar Mixer under Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then restart the app."
                     : "To change one app’s volume, Menubar Mixer needs “System Audio Recording” access. macOS will ask once; the audio never leaves your Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if model.permission == .denied {
                        PillButton(title: "Open Settings", prominent: true) { model.openPermissionSettings() }
                        PillButton(title: "Restart app") { model.relaunch() }
                    } else {
                        PillButton(title: "Allow…", prominent: true) { model.requestPermission() }
                        PillButton(title: "Open Settings") { model.openPermissionSettings() }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.10)))
    }
}
