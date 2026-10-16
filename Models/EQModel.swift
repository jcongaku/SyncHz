import Foundation
import AppKit
import AVFoundation
import Observation

/// While the EQ runs, the output device belongs to it: the engine holds the
/// device at its processing rate, and automatic or manual sample-rate
/// switching stands aside (`SampleRateModel` checks this). Main thread only.
@Observable
final class OutputRateLock {
    static let shared = OutputRateLock()
    /// The rate the EQ holds the output at, or nil while the EQ is off.
    var heldRate: Double?
}

/// Owns the EQ profile library, drives the audio engine and spectrum analyzer,
/// and persists everything. One instance is shared by the menu-bar panel and
/// the Equalizer window.
///
/// `@Observable`, so a view re-renders only for the properties it reads; the
/// bookkeeping below is `@ObservationIgnored` and never invalidates anything.
@MainActor
@Observable
final class EQModel {
    var profiles: [PEQProfile]
    var profile: PEQProfile {
        didSet { profileChanged() }
    }
    private(set) var isEnabled = false
    private(set) var engineRunning = false
    private(set) var currentSampleRate: Double?
    private(set) var automaticHeadroomDB = 0.0
    private(set) var clippingDetected = false
    var statusMessage = ""

    @ObservationIgnored let analyzer = SpectrumAnalyzer()
    /// Whether the spectrum can be seen: panel on screen with the EQ side
    /// open. The analyzer's 24 fps FFT and redraws only run then.
    @ObservationIgnored private var spectrumVisible = false

    /// Hold the output at `ProcessTapEngine.processingRate` (48 kHz) while the
    /// EQ runs, instead of following each track's rate. Off by default.
    var holdsFixedRate = UserDefaults.standard.bool(forKey: EQModel.holdsFixedRateKey) {
        didSet {
            guard holdsFixedRate != oldValue else { return }
            UserDefaults.standard.set(holdsFixedRate, forKey: Self.holdsFixedRateKey)
            if isEnabled {
                OutputRateLock.shared.heldRate = holdsFixedRate ? ProcessTapEngine.processingRate : nil
            }
            let engine = self.engine
            let hold = holdsFixedRate
            engine.controlQueue.async { engine.setHoldsProcessingRate(hold) }
        }
    }
    @ObservationIgnored private static let holdsFixedRateKey = "eqHoldsFixedRate"
    @ObservationIgnored private let engine = ProcessTapEngine()
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var engineApplyWork: DispatchWorkItem?
    @ObservationIgnored private var clippingTimer: Timer?
    @ObservationIgnored private var lastClippingEpoch: UInt64 = 0
    @ObservationIgnored private var clippingVisibleUntil = Date.distantPast

    init() {
        let store = EQModel.load()
        profiles = store.profiles
        profile = store.profiles.first(where: { $0.id == store.selectedID }) ?? store.profiles[0]
        let hold = holdsFixedRate
        let engine = self.engine
        engine.controlQueue.async { engine.setHoldsProcessingRate(hold) }

        engine.onSampleRateChange = { [weak self] rate in
            Task { @MainActor in
                self?.currentSampleRate = rate
                self?.analyzer.sampleRate = rate
                if self?.isEnabled == true, self?.holdsFixedRate == true {
                    OutputRateLock.shared.heldRate = rate
                }
            }
        }
        engine.onHeadroomChange = { [weak self] attenuation in
            Task { @MainActor in
                guard let self, self.automaticHeadroomDB != attenuation else { return }
                self.automaticHeadroomDB = attenuation
            }
        }
        engine.onInputSilence = { [weak self] silent in
            guard let self, self.isEnabled else { return }
            if silent {
                self.statusMessage = self.loc("No audio from Apple Music is reaching the EQ.")
            } else if self.statusMessage == self.loc("No audio from Apple Music is reaching the EQ.") {
                self.statusMessage = self.loc("Equalizer on — Apple Music is no longer bit-perfect.")
            }
        }
        engine.onRuntimeError = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                OutputRateLock.shared.heldRate = nil
                self.engineRunning = false
                self.isEnabled = false
                self.currentSampleRate = nil
                self.automaticHeadroomDB = 0
                self.analyzer.stop()
                self.stopClippingMonitoring()
                self.statusMessage = message
            }
        }
    }

    // MARK: - Enable / engine

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled   // optimistic — the switch stays responsive

        let engine = self.engine
        let analyzer = self.analyzer

        if enabled {
            // The tap is read through an aggregate device's input, which macOS
            // gates as audio input (microphone) access. Without it the tap
            // delivers silence while Music stays muted, so the engine never
            // starts unless access is granted.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                startEngine()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isEnabled else { return }
                        if granted { self.startEngine() } else { self.failAudioInputAccess() }
                    }
                }
            default:
                failAudioInputAccess()
            }
        } else {
            engineRunning = false
            currentSampleRate = nil
            automaticHeadroomDB = 0
            analyzer.stop()
            stopClippingMonitoring()
            statusMessage = loc("Equalizer off — bit-perfect playback restored.")
            OutputRateLock.shared.heldRate = nil
            engine.controlQueue.async {
                engine.setActive(false)
                engine.stop()
                engine.restoreOutputRate()
                engine.setSampleSink(nil)
            }
        }
    }

    private func failAudioInputAccess() {
        OutputRateLock.shared.heldRate = nil
        isEnabled = false
        statusMessage = loc("SyncHz needs audio input access to run the EQ. Allow it in System Settings → Privacy & Security → Microphone.")
    }

    private func startEngine() {
        let engine = self.engine
        let analyzer = self.analyzer
        statusMessage = loc("Equalizer on — Apple Music is no longer bit-perfect.")
        // When holding a fixed rate, take the output before the engine changes
        // it, so automatic switching can't race it back to the track's rate.
        OutputRateLock.shared.heldRate = holdsFixedRate ? ProcessTapEngine.processingRate : nil
        let snapshot = profile
        engine.controlQueue.async { [weak self] in
            engine.setSampleSink(analyzer)
            engine.apply(profile: snapshot)
            engine.setActive(true)
            let started = engine.start()
            let rate = engine.sampleRate
            let error = engine.lastError
            DispatchQueue.main.async {
                guard let self, self.isEnabled else { return }   // user may have toggled back off
                if started {
                    if self.holdsFixedRate { OutputRateLock.shared.heldRate = rate }
                    self.engineRunning = true
                    self.currentSampleRate = rate
                    analyzer.sampleRate = rate
                    if self.spectrumVisible { analyzer.start() }
                    self.startClippingMonitoring()
                } else {
                    OutputRateLock.shared.heldRate = nil
                    engine.setSampleSink(nil)
                    engine.controlQueue.async { engine.restoreOutputRate() }
                    self.isEnabled = false
                    self.statusMessage = error ?? self.loc("Couldn't start the EQ engine.")
                }
            }
        }
    }

    func toggleEnabled() { setEnabled(!isEnabled) }

    func setSpectrumVisible(_ visible: Bool) {
        guard visible != spectrumVisible else { return }
        spectrumVisible = visible
        guard engineRunning else { return }
        if visible { analyzer.start() } else { analyzer.stop() }
    }

    // MARK: - Profile library

    func selectProfile(_ id: PEQProfile.ID) {
        guard let match = profiles.first(where: { $0.id == id }) else { return }
        profile = match
    }

    func newProfile() {
        let new = PEQProfile(name: uniqueName(loc("New Profile")))
        profiles.append(new)
        profile = new
    }

    func duplicateProfile() {
        let copy = PEQProfile(name: uniqueName(profile.name + " " + loc("copy")),
                              preampDB: profile.preampDB,
                              bands: profile.bands,
                              designSampleRate: profile.designSampleRate)
        profiles.append(copy)
        profile = copy
    }

    func deleteProfile(_ id: PEQProfile.ID) {
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [PEQProfile(name: "Flat")] }
        if !profiles.contains(where: { $0.id == profile.id }) {
            profile = profiles[0]
        }
        scheduleSave()
    }

    // MARK: - Band editing

    func addBand() {
        guard profile.bands.count < PEQConstraints.maximumBands else {
            statusMessage = String(format: loc("Maximum %1$ld EQ bands."),
                                   PEQConstraints.maximumBands)
            return
        }
        profile.bands.append(PEQBand(type: .peak, frequency: 1000, gainDB: 0, q: 1.0))
    }

    func removeBand(_ id: PEQBand.ID) {
        profile.bands.removeAll { $0.id == id }
    }

    func resetFlat() {
        profile = PEQProfile(id: profile.id, name: profile.name)
    }

    // MARK: - AutoEQ import (creates a new profile)

    func importAutoEQ(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = String(format: loc("Couldn't read %1$@."), url.lastPathComponent)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let designRate = Self.designRate(forImportedFile: url)
        let result = AutoEQParser.parse(text, designRate: designRate)
        guard !result.bands.isEmpty else {
            statusMessage = String(format: loc("No filters found in %1$@."), url.lastPathComponent)
            return
        }
        let raw = PEQProfile(name: uniqueName(name),
                             preampDB: result.preampDB,
                             bands: result.bands,
                             designSampleRate: designRate)
        let imported = raw.sanitized()
        profiles.append(imported)
        profile = imported

        let truncatedCount = max(0, result.bands.count - imported.bands.count)
        // Anything clamped changes the curve the generator fitted, so say so.
        let limitedCount = zip(raw.bands, imported.bands).filter { $0 != $1 }.count
            + (raw.preampDB == imported.preampDB ? 0 : 1)
        if !result.skippedLines.isEmpty || truncatedCount > 0 {
            statusMessage = String(format: loc("Imported %1$ld bands from %2$@ (%3$ld skipped or over limit)."),
                                   imported.bands.count,
                                   name,
                                   result.skippedLines.count + truncatedCount)
        } else if limitedCount > 0 {
            statusMessage = String(format: loc("Imported %1$ld bands from %2$@ (%3$ld values limited to the supported range)."),
                                   imported.bands.count, name, limitedCount)
        } else {
            statusMessage = String(format: loc("Imported %1$ld bands from %2$@."),
                                   imported.bands.count, name)
        }
    }

    /// The rate a preset file was fitted at, so its response is reproduced
    /// faithfully. PEQdB designs at 48 kHz (its preview runs a 48 kHz
    /// AudioContext and its files match the 48 kHz response to 0.004 dB) and
    /// names downloads "PEQdB-…"; AutoEq's published results — and anything
    /// else — default to AutoEq's 44.1 kHz. The EQ panel can change it.
    static func designRate(forImportedFile url: URL) -> Double {
        url.lastPathComponent.lowercased().hasPrefix("peqdb") ? 48_000 : PEQConstraints.defaultDesignRate
    }

    // MARK: - Reactions / persistence

    private func profileChanged() {
        let validated = profile.sanitized()
        if validated != profile {
            profile = validated
            return
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        }
        if isEnabled {
            let engine = self.engine
            let snapshot = profile
            engineApplyWork?.cancel()
            let work = DispatchWorkItem {
                engine.controlQueue.async { engine.apply(profile: snapshot) }
            }
            engineApplyWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
        }
        scheduleSave()
    }

    private func startClippingMonitoring() {
        stopClippingMonitoring()
        lastClippingEpoch = engine.clippingEventCount()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClippingState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clippingTimer = timer
    }

    private func stopClippingMonitoring() {
        clippingTimer?.invalidate()
        clippingTimer = nil
        if clippingDetected { clippingDetected = false }
    }

    private func pollClippingState() {
        let epoch = engine.clippingEventCount()
        if epoch != lastClippingEpoch {
            lastClippingEpoch = epoch
            clippingVisibleUntil = Date().addingTimeInterval(2)
            if !clippingDetected { clippingDetected = true }
        } else if clippingDetected, Date() >= clippingVisibleUntil {
            // Polled 4×/s: only write on a real change, since every write to an
            // observed property invalidates the views that read it.
            clippingDetected = false
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = EQStore(profiles: profiles, selectedID: profile.id)
        let work = DispatchWorkItem { EQModel.save(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var counter = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    /// Follows the in-app language, not just the macOS one.
    private func loc(_ key: String) -> String { L10n.string(key) }

    private struct EQStore: Codable {
        var profiles: [PEQProfile]
        var selectedID: UUID
    }

    private static var storeURL: URL? {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory,
                                      in: .userDomainMask).first else { return nil }
        // Still "Choritsu" — the app's former name — so profiles saved by
        // earlier versions keep loading after the rename to SyncHz.
        let folder = base.appendingPathComponent("Choritsu", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("eq-profiles.json")
    }

    private static func load() -> EQStore {
        if let url = storeURL,
           let data = try? Data(contentsOf: url),
           var store = try? JSONDecoder().decode(EQStore.self, from: data),
           !store.profiles.isEmpty {
            store.profiles = store.profiles.map { $0.sanitized() }
            return store
        }
        let fallback = PEQProfile(name: "Flat")
        return EQStore(profiles: [fallback], selectedID: fallback.id)
    }

    private static func save(_ store: EQStore) {
        guard let url = storeURL, let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

#if DEBUG
extension EQModel {
    /// Previews and screenshot rendering only: show the EQ as running at
    /// `sampleRate` without starting the audio engine. Not in release builds.
    func stagePreview(enabled: Bool, sampleRate: Double?) {
        isEnabled = enabled
        engineRunning = enabled
        currentSampleRate = sampleRate
    }
}
#endif
