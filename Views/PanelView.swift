import SwiftUI
import AppKit

// MARK: - Rate mark (app logo)

/// Brand colours of the app icon. The mark keeps them in both appearances so
/// it always matches the icon; the rest of the panel uses `Theme`.
private enum Brand {
    static let rikyu = Color(red: 0.714, green: 0.753, blue: 0.478)
    static let paper = Color(red: 0.949, green: 0.933, blue: 0.894)
    static let sumiTop = Color(red: 0.173, green: 0.169, blue: 0.180)
    static let sumiBottom = Color(red: 0.082, green: 0.078, blue: 0.086)
}

/// The brand mark, a small copy of the app icon: a "96 kHz" readout with two
/// faded sine waves running in phase behind it (source and output at the same
/// frequency). Geometry follows `branding/render_icon.swift`, which works on
/// an 824 pt tile; everything here is scaled from that.
private struct RateMark: View {
    var size: CGFloat = 22

    var body: some View {
        let corner = size * 0.225
        Canvas { context, canvasSize in
            let s = canvasSize.width / 824
            // Icon coordinates are y-up with the tile at (100, 100).
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x - 100) * s, y: canvasSize.height - (y - 100) * s)
            }
            for (midY, colour, alpha) in [(CGFloat(600), Brand.paper, 0.14), (420, Brand.rikyu, 0.20)] {
                var wave = Path()
                for i in 0...96 {
                    let t = Double(i) / 96
                    let p = point(60 + 904 * CGFloat(t), midY + 120 * CGFloat(sin(t * 2 * .pi * 1.25 + 0.4)))
                    if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                }
                context.stroke(wave, with: .color(colour.opacity(alpha)),
                               style: StrokeStyle(lineWidth: max(30 * s, 0.75), lineCap: .round))
            }
            // Centres of the glyphs: "96" at 440 pt, "kHz" at 118 pt.
            context.draw(Text(verbatim: "96").font(.system(size: 440 * s, weight: .semibold))
                            .tracking(-16 * s).foregroundStyle(Brand.paper),
                         at: point(512, 584), anchor: .center)
            context.draw(Text(verbatim: "kHz").font(.system(size: 118 * s, weight: .medium))
                            .foregroundStyle(Brand.rikyu),
                         at: point(512, 304), anchor: .center)
        }
        .frame(width: size, height: size)
        .background(
            LinearGradient(colors: [Brand.sumiTop, Brand.sumiBottom], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityLabel(Text(verbatim: "SyncHz"))
    }
}

// MARK: - Panel

/// The menu-bar panel. Each card is its own view so a change only re-renders
/// the card that reads it — the 1 Hz playback clock, for one, touches nothing
/// but `PlaybackProgress`.
struct PanelView: View {
    var model: SampleRateModel
    @Bindable var eq: EQModel
    var updates: UpdateChecker
    @State private var showEQ = false
    /// MenuBarExtra keeps this view tree alive while its window is ordered
    /// out, so anything animated would keep redrawing unseen.
    @State private var isOnScreen = true
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 10) {
                PanelHeader(model: model, eq: eq, updates: updates, showEQ: $showEQ)
                SignalCard(model: model, eqEnabled: eq.isEnabled, animates: isOnScreen)
                NowPlayingCard(model: model)
                OutputCard(model: model)
                StatusFooter(model: model)
            }
            .padding(14)
            .frame(width: 340)

            if showEQ {
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                EQView(eq: eq)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.background.ignoresSafeArea())
        .background(WindowVisibilityReader(isVisible: $isOnScreen))
        .onChange(of: isOnScreen, initial: true) { eq.setSpectrumVisible(isOnScreen && showEQ) }
        .onChange(of: showEQ) { eq.setSpectrumVisible(isOnScreen && showEQ) }
        // Every `Text` below resolves its strings against this locale, so the
        // in-app language applies live; the EQ panel inherits it too.
        .environment(\.locale, language.resolvedLocale)
    }
}

/// Reports whether the hosting window is actually visible — on screen and
/// not fully covered — from its occlusion state.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                report(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in self?.reportCurrent() }
            reportCurrent()
        }

        private func reportCurrent() {
            report(window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        }

        /// Deferred so it never mutates SwiftUI state during a view update.
        private func report(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - Sync state

private enum SyncState {
    case inSync, switching, mismatch, detecting, standby, resampled

    init(model: SampleRateModel) {
        let source = model.trackSampleRateDisplay
        if OutputRateLock.shared.heldRate != nil {
            // The EQ holds the output at its own rate; Core Audio resamples.
            self = .resampled
        } else if source.contains("kHz") {
            if source == model.outputSampleRateDisplay {
                self = .inSync
            } else {
                self = model.autoSwitchEnabled ? .switching : .mismatch
            }
        } else if source == "Estimating" {
            self = .detecting
        } else {
            self = .standby
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .inSync: return "In sync"
        case .switching: return "Switching"
        case .mismatch: return "Mismatch"
        case .detecting: return "Detecting"
        case .standby: return "Standby"
        case .resampled: return "Resampled"
        }
    }

    var color: Color {
        switch self {
        case .inSync: return Theme.ok
        case .switching, .mismatch, .detecting: return Theme.warn
        case .standby: return Theme.textMuted
        case .resampled: return Theme.accent
        }
    }
}

// MARK: - Header

private struct PanelHeader: View {
    @Bindable var model: SampleRateModel
    var eq: EQModel
    var updates: UpdateChecker
    @Binding var showEQ: Bool
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system

    var body: some View {
        HStack(spacing: 8) {
            RateMark(size: 22)
            Text(verbatim: "SyncHz")
                .font(.system(size: 13, weight: .semibold))
            // The small tag beside the name: 調律 ("tuning"), the app's first
            // name, in most languages; its Chinese name 同频 in Chinese.
            Text("調律")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)

            Spacer()

            eqButton

            Menu {
                Toggle("Auto switch", isOn: $model.autoSwitchEnabled)
                Toggle("Log parser", isOn: $model.logParserEnabled)
                Divider()
                Button("Refresh now") { model.refreshNow() }
                Button("Restart log parser") { model.restartLogParser() }
                Button("Dump recent logs") { model.dumpRecentLogs() }
                Button("Dump now playing") { model.dumpNowPlaying() }
                Divider()
                Picker("Language", selection: $language) {
                    Text("Follow System").tag(AppLanguage.system)
                    ForEach(AppLanguage.allCases.filter { $0 != .system }) { option in
                        Text(verbatim: option.nativeName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Divider()
                updateMenuItems
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(GhostButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private var eqButton: some View {
        Button {
            showEQ.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text("EQ")
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .foregroundStyle(eq.isEnabled ? Theme.onAccent : Theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(eq.isEnabled ? Theme.accent : Theme.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(showEQ && !eq.isEnabled ? 0.7 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Headphone EQ")
    }

    @ViewBuilder
    private var updateMenuItems: some View {
        switch updates.state {
        case let .available(version, _):
            Button("Update available — \(version)") { updates.openReleasePage() }
        case .checking:
            Text("Checking for updates…")
        case .upToDate:
            Text("SyncHz is up to date")
        case let .failed(message):
            Text("Update check failed: \(message)")
        case .idle:
            EmptyView()
        }

        Button("Check for Updates…") { updates.check(userInitiated: true) }
    }
}

// MARK: - Signal card

private struct SignalCard: View {
    @Bindable var model: SampleRateModel
    let eqEnabled: Bool
    /// False while the panel is off screen: the arrow then stops drawing.
    let animates: Bool

    var body: some View {
        let state = SyncState(model: model)
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Signal")
                Spacer()
                StatusPill(text: state.label, color: state.color)
            }

            Grid(horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    SectionLabel("Source")
                        .gridColumnAlignment(.leading)
                    Color.clear.frame(width: 1, height: 1)
                    SectionLabel("Output")
                        .gridColumnAlignment(.trailing)
                }
                GridRow(alignment: .center) {
                    RateValue(display: model.trackSampleRateDisplay)
                    SignalFlowArrow(color: state == .standby ? Theme.textMuted : state.color,
                                    isFlowing: animates && model.isPlaying && state != .standby,
                                    speed: state == .inSync ? 0.55 : 0.9)
                        .frame(maxWidth: .infinity)
                    outputRatePicker
                }
            }
            .padding(.top, 10)

            // Outside the grid so a long format line truncates instead of
            // widening the source column and squeezing the arrow.
            HStack(spacing: 6) {
                sourceDetail
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .help(Text(LocalizedStringKey(model.sampleRateSourceDisplay)))
                Spacer(minLength: 4)
                eqTag
            }
            .padding(.top, 3)

            Hairline()
                .padding(.horizontal, -12)
                .padding(.top, 12)

            Toggle(isOn: $model.autoSwitchEnabled) {
                Text("Auto switch")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.accent)
            .padding(.top, 9)
        }
        .themeCard()
    }

    /// "ALAC · 24-bit · Lossless" once Music has logged the stream format;
    /// until then, how the source rate was found ("Log (locked)").
    @ViewBuilder
    private var sourceDetail: some View {
        if let format = model.trackFormat {
            formatText(format)
        } else {
            Text(LocalizedStringKey(model.sampleRateSourceDisplay))
        }
    }

    private func formatText(_ format: TrackFormat) -> Text {
        var parts: [Text] = []
        if let codec = format.codec { parts.append(Text(verbatim: codec)) }
        if let bits = format.bitDepth { parts.append(Text("\(bits)-bit")) }
        if let tier = format.tier { parts.append(Text(LocalizedStringKey(tier))) }
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }

    /// The EQ sits in the signal path between source and output, so it is
    /// flagged on the output side — and it means playback is no longer bit-perfect.
    @ViewBuilder
    private var eqTag: some View {
        if eqEnabled {
            Text("EQ")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 5)
                .frame(height: 14)
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 0.5))
                .help("EQ is on — playback is no longer bit-perfect")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var outputRatePicker: some View {
        Menu {
            ForEach(model.availableSampleRates, id: \.self) { rate in
                Button {
                    model.selectSampleRate(rate)
                } label: {
                    if let current = model.outputSampleRate, abs(current - rate) < 1.0 {
                        Label(model.formatSampleRate(rate), systemImage: "checkmark")
                    } else {
                        Text(model.formatSampleRate(rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                RateValue(display: model.outputSampleRateDisplay)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.availableSampleRates.isEmpty || OutputRateLock.shared.heldRate != nil)
        .help(OutputRateLock.shared.heldRate == nil ? Text("Output sample rate")
                                                     : Text("Turn the EQ off to change the sample rate."))
    }
}

/// A sample rate as a large tabular figure with a small unit ("96 kHz"); any
/// non-rate status ("Unknown", "Estimating") shows as a muted dash.
private struct RateValue: View {
    let display: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if display.hasSuffix(" kHz") {
                Text(display.dropLast(4))
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .tracking(-0.5)
                Text(verbatim: "kHz")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display)
    }
}

// MARK: - Now playing

private struct NowPlayingCard: View {
    var model: SampleRateModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                artwork

                VStack(alignment: .leading, spacing: 2) {
                    titleText
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                transport
            }

            PlaybackProgress(model: model)
        }
        .themeCard()
    }

    /// The model's placeholder titles are translated; real titles never are,
    /// so a song called "Play" is not shown as "播放".
    private var titleText: Text {
        switch model.currentTrackTitle {
        case "Not playing": return Text("Not playing")
        case "Unavailable": return Text("Unavailable")
        default: return Text(verbatim: model.currentTrackTitle)
        }
    }

    private var subtitle: String {
        [model.artistName, model.albumName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var artwork: some View {
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.fill
                    Image(systemName: "music.note")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
    }

    private var transport: some View {
        HStack(spacing: 2) {
            Button { model.previousTrack() } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(GhostButtonStyle(size: 28))
            .accessibilityLabel("Previous track")

            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

            Button { model.nextTrack() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(GhostButtonStyle(size: 28))
            .accessibilityLabel("Next track")
        }
    }
}

/// The only view that reads the playback clock, so its 1 Hz ticks stay local.
private struct PlaybackProgress: View {
    var model: SampleRateModel

    var body: some View {
        HStack(spacing: 8) {
            Text(timeString(model.elapsedSeconds))
                .frame(minWidth: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 3)
            Text(timeString(model.durationSeconds))
                .frame(minWidth: 30, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.textMuted)
    }

    private var progress: Double {
        guard let elapsed = model.elapsedSeconds,
              let duration = model.durationSeconds,
              duration > 0 else {
            return 0
        }
        return min(max(elapsed / duration, 0), 1)
    }

    private func timeString(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else {
            return "–:––"
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Output device & volume

private struct OutputCard: View {
    var model: SampleRateModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.outputDevices) { device in
                        Button {
                            model.selectOutputDevice(device.id)
                        } label: {
                            if device.id == model.currentOutputDeviceID {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: model.outputDeviceIcon)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 18)
                        (model.outputDeviceName == "Unknown" ? Text("Unknown") : Text(verbatim: model.outputDeviceName))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Output device")

                Spacer(minLength: 0)

                Text(model.outputSampleRateDisplay)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 18)

                FlatVolumeSlider(
                    value: Binding(
                        get: { model.outputVolume },
                        set: { model.setVolume($0) }
                    ),
                    isEnabled: model.volumeAvailable,
                    onEditingChanged: { editing in
                        if editing {
                            model.beginVolumeAdjustment()
                        } else {
                            model.endVolumeAdjustment()
                        }
                    }
                )

                (model.volumeAvailable ? Text(verbatim: "\(Int((model.outputVolume * 100).rounded()))%") : Text("Fixed"))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .themeCard()
    }
}

private struct FlatVolumeSlider: View {
    @Binding var value: Double
    var isEnabled: Bool
    var onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let knob: CGFloat = 12
            let x = (width - knob) * CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill).frame(height: 4)
                Capsule().fill(Theme.textSecondary).frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(Theme.card)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .overlay(Circle().strokeBorder(Theme.textSecondary.opacity(isDragging ? 0.6 : 0.3), lineWidth: 1))
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = min(max((gesture.location.x - knob / 2) / (width - knob), 0), 1)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 16)
        .opacity(isEnabled ? 1 : 0.35)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, 1)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
        }
    }
}

// MARK: - Footer

private struct StatusFooter: View {
    var model: SampleRateModel

    var body: some View {
        let lines = [model.statusMessage, model.logStatusMessage].filter { !$0.isEmpty }
        if !lines.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(SyncState(model: model).color)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text(verbatim: $0.element).lineLimit(1) }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }
}
