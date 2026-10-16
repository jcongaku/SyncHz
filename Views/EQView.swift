import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Equalizer panel

struct EQView: View {
    @Bindable var eq: EQModel
    @State private var selectedBand: PEQBand.ID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            EQGraph(profile: $eq.profile,
                    analyzer: eq.analyzer,
                    selectedBand: $selectedBand,
                    // The design-rate response is what plays at every
                    // device rate (see PEQRateMatcher), so it is what we draw.
                    sampleRate: eq.profile.designSampleRate)
                .frame(height: 220)
                .padding(.horizontal, 14)
            hint
                .padding(.top, 6)
                .padding(.bottom, 8)
            Hairline()
            bandTable
                .frame(height: 160)
            Hairline()
            statusBar
        }
        .frame(width: 470)
    }

    // MARK: Toolbar (three rows)

    /// The first two rows share two columns: title over the profile menu, and
    /// "Fitted at" — a property of the preset's parameters — over its name.
    private static let profileColumn: CGFloat = 130
    private static let nameColumn: CGFloat = 140
    private static let columnSpacing: CGFloat = 8

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: Self.columnSpacing) {
                Text("Parametric EQ")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: Self.profileColumn, alignment: .leading)

                designRateMenu

                Spacer()

                processingRateMenu

                Toggle("", isOn: Binding(get: { eq.isEnabled },
                                         set: { eq.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    .labelsHidden()
                    .accessibilityLabel("Equalizer")
            }

            HStack(spacing: Self.columnSpacing) {
                profileMenu
                TextField("Profile name", text: $eq.profile.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(width: Self.nameColumn, height: 26)
                    .background(Theme.card,
                                in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    )

                Spacer()

                Button { importAutoEQ() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(ToolButtonStyle())
                .help("Import AutoEQ…")
                .accessibilityLabel("Import AutoEQ…")
                Button { eq.addBand() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(ToolButtonStyle())
                .disabled(eq.profile.bands.count >= PEQConstraints.maximumBands)
                .help(eq.profile.bands.count >= PEQConstraints.maximumBands
                      ? "Maximum \(PEQConstraints.maximumBands) bands"
                      : "Add")
                .accessibilityLabel("Add")
                Button { eq.resetFlat() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(ToolButtonStyle())
                .help("Flat")
                .accessibilityLabel("Flat")
            }

            HStack(spacing: 10) {
                Text("Preamp")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                Slider(value: $eq.profile.preampDB, in: -24...12)
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text(String(format: "%+.1f dB", eq.profile.preampDB))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 56, alignment: .trailing)
                if eq.automaticHeadroomDB > 0.05 {
                    Label(String(format: "Auto −%.1f", eq.automaticHeadroomDB),
                          systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .help("Automatic headroom prevents output clipping")
                }
            }
        }
    }

    /// Follow each track's rate (no resampling; the EQ path is rebuilt at
    /// every rate change) or hold the output at 48 kHz while the EQ runs.
    private var processingRateMenu: some View {
        Menu {
            Picker("Processing rate", selection: $eq.holdsFixedRate) {
                Text("Follow track rate").tag(false)
                Text("Hold at \(sampleRateText(ProcessTapEngine.processingRate))").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            // Fixed width so toggling the engine never reflows the row.
            HStack(spacing: 4) {
                Image(systemName: eq.holdsFixedRate ? "lock" : "waveform.path")
                Text(eq.currentSampleRate.map { sampleRateText($0) } ?? "—")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
            .frame(width: 86, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(eq.holdsFixedRate ? Text("Hold at \(sampleRateText(ProcessTapEngine.processingRate))")
                                : Text("Follow track rate"))
    }

    /// The rate the preset's parameters were fitted at. SyncHz reproduces that
    /// rate's response at every playback rate, so this must match the
    /// generator: 44.1 kHz for AutoEq's published presets.
    private var designRateMenu: some View {
        Menu {
            Picker("Fitted at", selection: $eq.profile.designSampleRate) {
                ForEach(PEQConstraints.designRates, id: \.self) { rate in
                    Text(verbatim: sampleRateText(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text("Fitted at \(sampleRateText(eq.profile.designSampleRate))")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(width: Self.nameColumn, height: 26)
            .background(Theme.fill,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The sample rate this preset was fitted at — 44.1 kHz for AutoEq's published presets. SyncHz reproduces this response at every playback rate.")
    }

    private var profileMenu: some View {
        Menu {
            ForEach(eq.profiles) { item in
                Button {
                    eq.selectProfile(item.id)
                } label: {
                    if item.id == eq.profile.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            Divider()
            Button { eq.newProfile() } label: { Label("New Profile", systemImage: "plus") }
            Button { eq.duplicateProfile() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { eq.deleteProfile(eq.profile.id) } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(eq.profiles.count <= 1)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(Theme.textMuted)
                Text(eq.profile.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            // Fixed width, so the name field beside it — and "Fitted at" above
            // that — stay in one column whatever the profile is called.
            .frame(width: Self.profileColumn, height: 26)
            .background(Theme.fill,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: Self.profileColumn, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hint: some View {
        Text("Drag: frequency × gain · Hover point + scroll: Q · Shift: fine")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textMuted)
    }

    // MARK: Band table

    private var bandTable: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach($eq.profile.bands) { $band in
                    BandRow(band: $band,
                            isSelected: selectedBand == band.id,
                            onSelect: { selectedBand = band.id },
                            onDelete: { eq.removeBand(band.id) })
                    Hairline().padding(.horizontal, 8)
                }
                if eq.profile.bands.isEmpty {
                    Text("No bands. Add one, or import an AutoEQ ParametricEQ.txt.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(eq.clippingDetected ? Theme.warn
                      : (eq.isEnabled ? Theme.accent : Theme.textMuted.opacity(0.6)))
                .frame(width: 6, height: 6)
            statusText
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Fixed captions go through `Text` so they follow the in-app language;
    /// the model's message is already localized when it is made.
    private var statusText: Text {
        if eq.clippingDetected { return Text("Output peak protected — lower boost or preamp") }
        if !eq.statusMessage.isEmpty { return Text(verbatim: eq.statusMessage) }
        return eq.isEnabled ? Text("Equalizer active") : Text("Bypassed — bit-perfect")
    }

    // MARK: Actions / helpers

    private func importAutoEQ() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.message = L10n.string("Choose an AutoEQ ParametricEQ.txt file")

        // SyncHz runs as a menu-bar accessory app, so it's never the active
        // app — without this the open panel opens *behind* the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            eq.importAutoEQ(from: url)
        }
    }

    private func sampleRateText(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz == khz.rounded()
            ? String(format: "%.0f kHz", khz)
            : String(format: "%.1f kHz", khz)
    }
}

// MARK: - One editable band row

private struct BandRow: View {
    @Binding var band: PEQBand
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $band.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(Theme.accent)

            Picker("", selection: $band.type) {
                ForEach(PEQFilterType.allCases) { type in
                    Text(typeKey(type)).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 104)

            field("Freq", value: $band.frequency, unit: "Hz", width: 64)
            field("Gain", value: $band.gainDB, unit: "dB", width: 50)
            field("Q", value: $band.q, unit: "", width: 44)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(GhostButtonStyle(size: 24))
            .accessibilityLabel("Delete")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Theme.accent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .opacity(band.isEnabled ? 1 : 0.45)
    }

    private func typeKey(_ type: PEQFilterType) -> LocalizedStringKey {
        switch type {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    private func field(_ label: LocalizedStringKey, value: Binding<Double>,
                       unit: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            HStack(spacing: 3) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11).monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(width: width, height: 22)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel(label)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
    }
}

// MARK: - Interactive response graph + spectrum

private struct EQGraph: View {
    private struct BandDragState {
        let id: PEQBand.ID
        let band: PEQBand
        let controlFrequency: Double
        let controlDB: Double
    }

    @Binding var profile: PEQProfile
    /// Held, not observed: the spectrum repaints inside `SpectrumView` so its
    /// 24 fps updates don't drag the static grid + curve into every frame.
    let analyzer: SpectrumAnalyzer
    @Binding var selectedBand: PEQBand.ID?
    let sampleRate: Double
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragState: BandDragState?

    private let dbRange: Double = 24
    private let fMin: Double = 20
    private let fMax: Double = 20_000
    private let space = "eqgraph"

    private var displaySampleRate: Double { max(sampleRate, 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Dynamic layer: the spectrum repaints ~24×/s, isolated in its
                // own analyzer-observing view.
                SpectrumView(analyzer: analyzer, colorScheme: colorScheme)

                // Static layer: grid + response curve, repainted only when the
                // profile or appearance changes — not on every spectrum frame.
                Canvas { context, size in
                    drawGrid(context, size)
                    drawCurve(context, size)
                }

                ForEach($profile.bands) { $band in
                    if band.isEnabled {
                        handle($band, size: geo.size)
                    }
                }
            }
            .coordinateSpace(name: space)
            .background(
                ScrollCatcher { deltaY, location, isPrecise, isFineAdjustment in
                    adjustQ(by: deltaY,
                            at: location,
                            size: geo.size,
                            isPrecise: isPrecise,
                            isFineAdjustment: isFineAdjustment)
                }
            )
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
        }
    }

    // MARK: Drawing

    private var gridColor: Color { (colorScheme == .dark ? Color.white : Color.black).opacity(0.10) }

    private func drawGrid(_ context: GraphicsContext, _ size: CGSize) {
        for f in [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000] {
            let x = xPos(f, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
        for g in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = yPos(g, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(g == 0 ? gridColor.opacity(2) : gridColor),
                           lineWidth: g == 0 ? 0.9 : 0.5)
        }
        for (f, label) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
            context.draw(Text(label).font(.system(size: 9)).foregroundStyle(Theme.textMuted),
                         at: CGPoint(x: xPos(f, width: size.width), y: size.height - 8))
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ size: CGSize) {
        let points = PEQResponse.curve(profile: profile, sampleRate: displaySampleRate,
                                       fMin: fMin, fMax: fMax, points: 480)
        guard points.count > 1 else { return }
        var line = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: xPos(point.frequency, width: size.width),
                            y: yPos(point.db, height: size.height))
            if index == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.stroke(line, with: .color(Theme.accent), lineWidth: 2)
    }

    // MARK: Handles

    private func handle(_ band: Binding<PEQBand>, size: CGSize) -> some View {
        let value = band.wrappedValue
        let id = value.id
        let isSelected = selectedBand == id
        let controlFrequency = PEQResponse.controlFrequency(for: value,
                                                            sampleRate: displaySampleRate,
                                                            fMin: fMin,
                                                            fMax: fMax)
        let controlDB = PEQResponse.magnitudeDB(profile: profile,
                                                frequency: controlFrequency,
                                                sampleRate: displaySampleRate)
        let position = CGPoint(x: xPos(controlFrequency, width: size.width),
                               y: yPos(controlDB, height: size.height))
        return ZStack {
            // Flat handles: a card-coloured ring separates the dot from the
            // curve instead of a drop shadow.
            Circle()
                .fill(Theme.accent.opacity(isSelected ? 1 : 0.8))
                .overlay(Circle().strokeBorder(Theme.card, lineWidth: isSelected ? 2.5 : 1.5))
                .overlay(Circle().strokeBorder(Theme.accent.opacity(isSelected ? 0.45 : 0), lineWidth: 1)
                    .padding(-2))
                .frame(width: isSelected ? 16 : 13, height: isSelected ? 16 : 13)

            if isSelected {
                Text(String(format: "Q %.2f", value.q))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .offset(y: position.y < 34 ? 25 : -25)
                    .allowsHitTesting(false)
            }
        }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        selectedBand = id
                        if dragState?.id != id {
                            dragState = BandDragState(id: id,
                                                      band: band.wrappedValue,
                                                      controlFrequency: controlFrequency,
                                                      controlDB: controlDB)
                        }
                        guard let dragState, dragState.id == id else { return }
                        updateBand(band,
                                   from: dragState,
                                   translation: value.translation,
                                   size: size)
                    }
                    .onEnded { _ in dragState = nil }
            )
            .help("Drag: frequency and gain · Scroll: Q")
            .accessibilityLabel("\(value.type.displayName) EQ band")
            .accessibilityValue("\(Int(value.frequency.rounded())) hertz, \(String(format: "%+.1f", value.gainDB)) decibels, Q \(String(format: "%.2f", value.q))")
    }

    private func updateBand(_ binding: Binding<PEQBand>,
                            from state: BandDragState,
                            translation: CGSize,
                            size: CGSize) {
        let startX = xPos(state.controlFrequency, width: size.width)
        let startY = yPos(state.controlDB, height: size.height)
        let targetFrequency = freqAt(startX + translation.width, width: size.width)
        let targetDB = min(max(dbAt(startY + translation.height, height: size.height),
                               -dbRange), dbRange)

        var candidate = state.band
        switch candidate.type {
        case .peak:
            candidate.frequency = clampFreq(targetFrequency)
            candidate.gainDB = solvedGain(for: candidate,
                                          at: candidate.frequency,
                                          targetTotalDB: targetDB)

        case .lowShelf, .highShelf:
            // Preserve the visual shoulder-to-centre ratio while moving, then
            // refine it after the gain solution so the handle tracks the cursor.
            let startRatio = state.controlFrequency / max(state.band.frequency, fMin)
            candidate.frequency = clampFreq(targetFrequency / max(startRatio, 0.0001))
            for _ in 0..<3 {
                candidate.gainDB = solvedGain(for: candidate,
                                              at: targetFrequency,
                                              targetTotalDB: targetDB)
                let actualControlFrequency = PEQResponse.controlFrequency(for: candidate,
                                                                          sampleRate: displaySampleRate,
                                                                          fMin: fMin,
                                                                          fMax: fMax)
                guard actualControlFrequency > 0 else { break }
                candidate.frequency = clampFreq(candidate.frequency * targetFrequency / actualControlFrequency)
            }
            candidate.gainDB = solvedGain(for: candidate,
                                          at: targetFrequency,
                                          targetTotalDB: targetDB)
        }

        candidate.gainDB = clampGain(candidate.gainDB)
        binding.wrappedValue = candidate
    }

    private func solvedGain(for band: PEQBand,
                            at frequency: Double,
                            targetTotalDB: Double) -> Double {
        let otherDB = PEQResponse.magnitudeDB(profile: profile,
                                              frequency: frequency,
                                              sampleRate: displaySampleRate,
                                              excluding: band.id)
        let targetBandDB = targetTotalDB - otherDB
        var lower = -dbRange
        var upper = dbRange

        // At a bell apex or shelf shoulder, response is monotonic in gain.
        // Solving instead of assigning gain directly keeps the dot under the
        // cursor when preamp and overlapping bands contribute to the curve.
        for _ in 0..<18 {
            let midpoint = (lower + upper) / 2
            var probe = band
            probe.gainDB = midpoint
            let coefficients = BiquadCoefficients(band: probe, sampleRate: displaySampleRate)
            let magnitude = coefficients.magnitude(atFrequency: frequency,
                                                   sampleRate: displaySampleRate)
            let responseDB = magnitude > 0 ? 20 * log10(magnitude) : -dbRange
            if responseDB < targetBandDB {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return (lower + upper) / 2
    }

    private func adjustQ(by deltaY: CGFloat,
                         at location: CGPoint,
                         size: CGSize,
                         isPrecise: Bool,
                         isFineAdjustment: Bool) {
        let hoveredID = profile.bands
            .filter(\.isEnabled)
            .map { band -> (PEQBand.ID, CGFloat) in
                let frequency = PEQResponse.controlFrequency(for: band,
                                                             sampleRate: displaySampleRate,
                                                             fMin: fMin,
                                                             fMax: fMax)
                let db = PEQResponse.magnitudeDB(profile: profile,
                                                 frequency: frequency,
                                                 sampleRate: displaySampleRate)
                let point = CGPoint(x: xPos(frequency, width: size.width),
                                    y: yPos(db, height: size.height))
                return (band.id, hypot(point.x - location.x, point.y - location.y))
            }
            .filter { $0.1 <= 30 }
            .min { $0.1 < $1.1 }?.0

        guard let id = hoveredID ?? selectedBand,
              let index = profile.bands.firstIndex(where: { $0.id == id }) else { return }
        selectedBand = id
        var effectiveDelta = Double(deltaY)
        if isPrecise { effectiveDelta *= 0.35 }
        if isFineAdjustment { effectiveDelta *= 0.2 }
        let factor = pow(1.04, effectiveDelta)
        let newQ = profile.bands[index].q * factor
        let range = PEQConstraints.qRange(for: profile.bands[index].type)
        profile.bands[index].q = (min(max(newQ, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }

    // MARK: Coordinate mapping

    private func xPos(_ freq: Double, width: CGFloat) -> CGFloat {
        let t = (log10(max(freq, fMin)) - log10(fMin)) / (log10(fMax) - log10(fMin))
        return CGFloat(t) * width
    }

    private func freqAt(_ x: CGFloat, width: CGFloat) -> Double {
        let t = Double(max(0, min(1, width == 0 ? 0 : x / width)))
        return pow(10, log10(fMin) + t * (log10(fMax) - log10(fMin)))
    }

    private func yPos(_ db: Double, height: CGFloat) -> CGFloat {
        let clamped = max(-dbRange, min(dbRange, db))
        return height / 2 - CGFloat(clamped / dbRange) * (height / 2)
    }

    private func dbAt(_ y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height / 2 - y) / (height / 2)) * dbRange
    }

    private func clampFreq(_ f: Double) -> Double {
        min(max(f, PEQConstraints.frequencyRange.lowerBound),
            PEQConstraints.frequencyRange.upperBound)
    }

    private func clampGain(_ g: Double) -> Double {
        let range = PEQConstraints.gainRange
        return (min(max(g, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }
}

// MARK: - Spectrum layer

/// The live spectrum as 1/3-octave bars laid side by side like piano keys:
/// no gaps, and alternate bands a shade apart, so neighbours read as distinct
/// layers without a separator line. Isolated in its own view that observes
/// the analyzer, so its ~24 fps repaints don't invalidate the static grid +
/// curve `Canvas` stacked above it. Light and dark keys are one path each:
/// two fills per frame, whatever the band count.
///
/// Bands are log-spaced over 20 Hz–20 kHz like the graph's x axis, so each
/// bar sits exactly under the frequencies it measures.
private struct SpectrumView: View {
    var analyzer: SpectrumAnalyzer
    let colorScheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let levels = analyzer.levels
            guard !levels.isEmpty else { return }

            // Topping out below the graph's edge keeps the spectrum a backdrop
            // to the EQ curve rather than a wall.
            let slot = size.width / CGFloat(levels.count)
            let ceiling = size.height * 0.82
            var lightKeys = Path()
            var darkKeys = Path()
            for index in levels.indices {
                let height = CGFloat(levels[index]) * ceiling
                guard height >= 0.5 else { continue }
                let key = CGRect(x: CGFloat(index) * slot, y: size.height - height,
                                 width: slot, height: height)
                if index.isMultiple(of: 2) {
                    lightKeys.addRoundedRect(in: key, cornerSize: CGSize(width: 1.5, height: 1.5),
                                             style: .continuous)
                } else {
                    darkKeys.addRoundedRect(in: key, cornerSize: CGSize(width: 1.5, height: 1.5),
                                            style: .continuous)
                }
            }
            let dark = colorScheme == .dark
            context.fill(lightKeys, with: .color(Theme.indigo.opacity(dark ? 0.17 : 0.09)))
            context.fill(darkKeys, with: .color(Theme.indigo.opacity(dark ? 0.30 : 0.17)))
        }
    }
}

// MARK: - Scroll-wheel capture (for Q on the graph)

private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint, Bool, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? CatcherView)?.removeMonitor()
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGPoint, Bool, Bool) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.window === self.window else {
                    return event
                }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                self.onScroll?(event.scrollingDeltaY,
                               location,
                               event.hasPreciseScrollingDeltas,
                               event.modifierFlags.contains(.shift))
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
