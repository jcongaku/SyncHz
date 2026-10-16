import Foundation
import AppKit
import CoreAudio
import Observation

/// `@Observable`, so each panel card re-renders only for the properties it
/// reads. The 1 Hz poll writes through `assign`, which skips unchanged values —
/// every write to an observed property would otherwise invalidate its readers.
@Observable
final class SampleRateModel {
    var currentTrackTitle: String = "Not playing"
    var artistName: String = ""
    var albumName: String = ""
    var artwork: NSImage?
    var isPlaying: Bool = false
    var elapsedSeconds: Double?
    var durationSeconds: Double?
    var trackSampleRateDisplay: String = "Unknown"
    var outputDeviceName: String = "Unknown"
    var outputDeviceIcon: String = "speaker.wave.2.fill"
    var outputSampleRateDisplay: String = "Unknown"
    var outputSampleRate: Double?
    var outputDevices: [AudioOutputDevice] = []
    var currentOutputDeviceID: AudioDeviceID?
    var availableSampleRates: [Double] = []
    var outputVolume: Double = 0.5
    var volumeAvailable: Bool = false
    var sampleRateSourceDisplay: String = "Unknown"
    /// Codec, bit depth and tier from Music's `activeFormat` log line, when seen.
    var trackFormat: TrackFormat?
    var logStatusMessage: String = ""
    var statusMessage: String = ""
    var autoSwitchEnabled: Bool = true
    var logParserEnabled: Bool = true {
        didSet {
            if logParserEnabled {
                startLogParser()
            } else {
                logController.stop()
                logStatusMessage = L10n.string("Log parser disabled")
            }
        }
    }

    private let mediaRemoteController = MediaRemoteController()
    private let musicController = MusicController()
    private let logController = LogStreamController()
    private let audioController = AudioDeviceController()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var latestLogCandidateRate: Double?
    @ObservationIgnored private var stableLogSampleRate: Double?
    @ObservationIgnored private var latestTrackInfo: TrackInfo?
    @ObservationIgnored private var latestTrackInfoError: String?
    @ObservationIgnored private var trackInfoFetchInFlight = false
    @ObservationIgnored private var artworkFetchInFlight = false
    /// The track whose cover the AppleScript fallback still owes us, if any.
    @ObservationIgnored private var pendingArtworkTitle: String?

    /// A log-derived vote, buffered off the main thread before being folded
    /// into `logRateWindow`. See `enqueueLogVote`.
    private struct LogVote {
        let rate: Double
        let weight: Int
    }

    private let logVoteQueue = DispatchQueue(label: "com.garykong.choritsu.logvotes")
    @ObservationIgnored private var pendingLogVotes: [LogVote] = []
    @ObservationIgnored private var logFlushScheduled = false
    private static let logFlushInterval: TimeInterval = 0.05
    @ObservationIgnored private var stableLogSampleRateAt: Date?
    @ObservationIgnored private var logRateWindow: [(rate: Double, date: Date, weight: Int)] = []
    @ObservationIgnored private var lastTrackTitle: String?
    @ObservationIgnored private var lastAppliedSampleRate: Double?
    @ObservationIgnored private var lastAppliedAt: Date?
    @ObservationIgnored private var lastArtworkData: Data?
    @ObservationIgnored private var artworkTrackTitle: String?
    @ObservationIgnored private var isAdjustingVolume = false
    @ObservationIgnored private var trackFormatAt: Date?

    init() {
        MediaAuthorizationController.requestIfNeeded { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.statusMessage = L10n.string("Media & Apple Music access denied in Privacy & Security.")
                }
            }
        }
        startLogParser()
        startPolling()
    }

    var menuBarTitle: String {
        trackSampleRateDisplay.contains("kHz") ? trackSampleRateDisplay : "SR"
    }

    func refreshNow() {
        updateState()
    }

    func togglePlayPause() {
        isPlaying.toggle()
        musicController.send(.playPause)
        scheduleQuickRefresh()
    }

    func nextTrack() {
        musicController.send(.nextTrack)
        scheduleQuickRefresh()
    }

    func previousTrack() {
        musicController.send(.previousTrack)
        scheduleQuickRefresh()
    }

    func beginVolumeAdjustment() {
        isAdjustingVolume = true
    }

    func endVolumeAdjustment() {
        isAdjustingVolume = false
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        outputVolume = clamped
        _ = audioController.setOutputVolume(Float(clamped))
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID != currentOutputDeviceID else { return }

        if audioController.setDefaultOutputDevice(deviceID) {
            currentOutputDeviceID = deviceID
            statusMessage = L10n.string("Switched output device")
        } else {
            statusMessage = L10n.string("Failed to switch output device")
        }
        scheduleQuickRefresh()
    }

    func selectSampleRate(_ rate: Double) {
        guard OutputRateLock.shared.heldRate == nil else {
            statusMessage = L10n.string("Turn the EQ off to change the sample rate.")
            return
        }
        // Manual choice would be reverted by auto switch within a second,
        // so disengage it when they conflict.
        if autoSwitchEnabled,
           let stableLogSampleRate,
           abs(stableLogSampleRate - rate) >= 1.0 {
            autoSwitchEnabled = false
        }

        if audioController.setDefaultOutputSampleRate(rate) {
            outputSampleRate = rate
            outputSampleRateDisplay = formatSampleRate(rate)
            statusMessage = L10n.format("Output set to %@", formatSampleRate(rate))
        } else {
            statusMessage = L10n.string("Failed to set output sample rate")
        }
        scheduleQuickRefresh()
    }

    private func scheduleQuickRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateState()
        }
    }

    func dumpNowPlaying() {
        mediaRemoteController.dumpNowPlayingInfo()
    }

    func restartLogParser() {
        startLogParser()
    }

    func dumpRecentLogs() {
        logController.dumpRecentLines()
    }

    private func startPolling() {
        updateState()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateState()
        }
    }

    private func updateState() {
        let outputDevice = audioController.defaultOutputDeviceInfo()

        // Kick off an off-main refresh for the next pass. The AppleScript
        // round trip used to run inline here and block the main thread (and
        // therefore this timer) for tens of seconds; now it only ever updates
        // the cached value that `applyNowPlaying` reads.
        refreshTrackInfoIfNeeded()

        assign(\.outputDeviceName, outputDevice.name)
        assign(\.outputDeviceIcon, outputDevice.iconName)
        assign(\.outputSampleRate, outputDevice.sampleRate)
        assign(\.outputSampleRateDisplay, formatSampleRate(outputDevice.sampleRate))
        assign(\.currentOutputDeviceID, outputDevice.id)
        assign(\.outputDevices, audioController.outputDevices())
        if let deviceID = outputDevice.id {
            assign(\.availableSampleRates, audioController.availableSampleRates(deviceID: deviceID))
        } else {
            assign(\.availableSampleRates, [])
        }

        if !isAdjustingVolume {
            if let volumeInfo = audioController.outputVolumeInfo() {
                assign(\.volumeAvailable, volumeInfo.settable)
                assign(\.outputVolume, Double(volumeInfo.volume))
            } else {
                assign(\.volumeAvailable, false)
            }
        }

        mediaRemoteController.nowPlayingInfo { [weak self] result in
            DispatchQueue.main.async {
                self?.applyNowPlaying(result, outputDevice: outputDevice)
            }
        }
    }

    /// Refreshes the Music.app fallback metadata without blocking. At most one
    /// fetch is ever in flight; the result lands on the main queue.
    private func refreshTrackInfoIfNeeded() {
        guard !trackInfoFetchInFlight else { return }
        trackInfoFetchInFlight = true

        musicController.fetchTrackInfo { [weak self] result in
            guard let self else { return }
            self.trackInfoFetchInFlight = false
            self.latestTrackInfo = result.track
            self.latestTrackInfoError = result.errorMessage
        }
    }

    private func applyNowPlaying(_ result: NowPlayingResult,
                                 outputDevice: OutputDeviceInfo) {
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            assign(\.currentTrackTitle, "Unavailable")
            assign(\.trackSampleRateDisplay, "Unknown")
            assign(\.statusMessage, errorMessage)
            return
        }

        let info = result.info
        let fallbackTrack = latestTrackInfo

        var resolvedTitle = info?.title ?? ""
        if resolvedTitle.isEmpty || resolvedTitle == "Unknown", let fallbackTrack {
            resolvedTitle = fallbackTrack.title
        }

        guard !resolvedTitle.isEmpty else {
            assign(\.currentTrackTitle, "Not playing")
            assign(\.artistName, "")
            assign(\.albumName, "")
            assign(\.isPlaying, false)
            assign(\.elapsedSeconds, nil)
            assign(\.durationSeconds, nil)
            assign(\.trackFormat, nil)
            updateArtwork(nil)
            updateCurrentSampleRateDisplay()
            assign(\.statusMessage, latestTrackInfoError ?? "")
            return
        }

        updateTrackTitle(resolvedTitle)
        assign(\.currentTrackTitle, resolvedTitle)
        assign(\.artistName, info?.artist ?? fallbackTrack?.artist ?? "")
        assign(\.albumName, info?.album ?? fallbackTrack?.album ?? "")
        assign(\.isPlaying, info?.isPlaying ?? fallbackTrack?.isPlaying ?? false)
        assign(\.durationSeconds, info?.duration ?? fallbackTrack?.duration)
        updateElapsed(info: info, fallback: fallbackTrack)
        updateArtwork(info?.artworkData)

        updateCurrentSampleRateDisplay()

        guard isPlaying else {
            assign(\.statusMessage, L10n.string("Paused"))
            return
        }

        if let held = OutputRateLock.shared.heldRate {
            assign(\.statusMessage, L10n.format("EQ on — output held at %@", formatSampleRate(held)))
            return
        }

        guard autoSwitchEnabled else {
            assign(\.statusMessage, L10n.string("Auto switch disabled"))
            return
        }

        guard let targetSampleRate = stableLogSampleRate else {
            assign(\.statusMessage, L10n.string("Waiting for log sample rate"))
            return
        }

        if let currentOutputRate = outputDevice.sampleRate,
           abs(currentOutputRate - targetSampleRate) < 1.0 {
            assign(\.statusMessage, L10n.format("Output already at %@", formatSampleRate(targetSampleRate)))
            return
        }

        if audioController.setDefaultOutputSampleRate(targetSampleRate) {
            assign(\.statusMessage, L10n.format("Switched output to %@", formatSampleRate(targetSampleRate)))
        } else {
            assign(\.statusMessage, L10n.string("Failed to switch output sample rate"))
        }
    }

    /// Writes an observed property only when the value actually changes.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SampleRateModel, Value>,
                                          _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func updateElapsed(info: NowPlayingInfo?, fallback: TrackInfo?) {
        if let elapsed = info?.elapsed {
            if isPlaying, let timestamp = info?.timestamp {
                let projected = elapsed + Date().timeIntervalSince(timestamp)
                assign(\.elapsedSeconds, min(projected, durationSeconds ?? projected))
            } else {
                assign(\.elapsedSeconds, elapsed)
            }
        } else {
            assign(\.elapsedSeconds, fallback?.position)
        }
    }

    private func updateArtwork(_ data: Data?) {
        let trackChanged = artworkTrackTitle != currentTrackTitle
        artworkTrackTitle = currentTrackTitle

        if let data {
            pendingArtworkTitle = nil
            applyArtwork(data)
            return
        }

        // MediaRemote artwork is unavailable; ask Music directly, but only
        // once per track. The fetch runs off the main thread.
        guard trackChanged else { return }

        guard currentTrackTitle != "Not playing" else {
            pendingArtworkTitle = nil
            applyArtwork(nil)
            return
        }

        pendingArtworkTitle = currentTrackTitle
        fetchPendingArtwork()
    }

    /// At most one fetch is in flight. A track change mid-flight does not
    /// start a second one; the running fetch re-issues itself for the new
    /// track when it lands, so the new track is never left without a cover.
    private func fetchPendingArtwork() {
        guard !artworkFetchInFlight, let title = pendingArtworkTitle else { return }
        artworkFetchInFlight = true

        musicController.fetchArtwork { [weak self] data in
            guard let self else { return }
            self.artworkFetchInFlight = false

            // Drop the result if the track changed while we were fetching;
            // otherwise a slow reply would show the previous cover.
            guard self.pendingArtworkTitle == title else {
                self.fetchPendingArtwork()
                return
            }
            self.pendingArtworkTitle = nil
            self.applyArtwork(data)
        }
    }

    private func applyArtwork(_ data: Data?) {
        guard data != lastArtworkData else { return }
        lastArtworkData = data
        artwork = data.flatMap { NSImage(data: $0) }
    }

    func formatSampleRate(_ sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else {
            return "Unknown"
        }

        let khz = sampleRate / 1000.0
        let rounded = (khz * 10).rounded() / 10

        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(format: "%.0f kHz", rounded)
        }

        return String(format: "%.1f kHz", rounded)
    }

    private func startLogParser() {
        logController.onSampleRate = { [weak self] rate, message in
            let weight = (message?.contains("Derived from frames/duration") ?? false) ? 3 : 1
            self?.enqueueLogVote(rate: rate, weight: weight)
        }

        logController.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                // Known statuses ("Log stream started") are table keys; anything
                // else, such as raw `log` stderr, falls through unchanged.
                self?.logStatusMessage = L10n.string(status)
            }
        }

        logController.onTrackFormat = { [weak self] format in
            DispatchQueue.main.async {
                guard let self else { return }
                self.trackFormatAt = Date()
                self.assign(\.trackFormat, format)
            }
        }

        logController.start()
    }

    private func applyLogAutoSwitch(sampleRate: Double) {
        guard autoSwitchEnabled, OutputRateLock.shared.heldRate == nil else { return }

        let outputDevice = audioController.defaultOutputDeviceInfo()
        guard let currentOutputRate = outputDevice.sampleRate,
              abs(currentOutputRate - sampleRate) >= 1.0 else {
            return
        }

        if let lastAppliedSampleRate,
           let lastAppliedAt,
           abs(lastAppliedSampleRate - sampleRate) < 1.0,
           Date().timeIntervalSince(lastAppliedAt) < 2 {
            return
        }

        if audioController.setDefaultOutputSampleRate(sampleRate) {
            lastAppliedSampleRate = sampleRate
            lastAppliedAt = Date()
            outputSampleRateDisplay = formatSampleRate(sampleRate)
            statusMessage = L10n.format("Switched output to %@", formatSampleRate(sampleRate))
        } else {
            statusMessage = L10n.string("Failed to switch output sample rate")
        }
    }

    /// Buffers a vote off the main thread and flushes the batch at most every
    /// `logFlushInterval`. The votes themselves (rate + weight) and the
    /// dominance math downstream are unchanged — only the cadence at which
    /// `logRateWindow` grows is throttled.
    private func enqueueLogVote(rate: Double, weight: Int) {
        logVoteQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLogVotes.append(LogVote(rate: rate, weight: weight))

            guard !self.logFlushScheduled else { return }
            self.logFlushScheduled = true

            self.logVoteQueue.asyncAfter(deadline: .now() + Self.logFlushInterval) { [weak self] in
                guard let self else { return }
                let batch = self.pendingLogVotes
                self.pendingLogVotes.removeAll(keepingCapacity: true)
                self.logFlushScheduled = false

                guard !batch.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.ingestLogVotes(batch)
                }
            }
        }
    }

    private func ingestLogVotes(_ votes: [LogVote]) {
        let now = Date()

        var latestCandidate: Double?
        for vote in votes {
            guard let candidateRate = quantizeLogRate(vote.rate) else { continue }
            latestCandidate = candidateRate
            logRateWindow.append((rate: candidateRate, date: now, weight: vote.weight))
        }

        guard let latestCandidate else { return }
        latestLogCandidateRate = latestCandidate

        logRateWindow = logRateWindow.filter { now.timeIntervalSince($0.date) <= 6.0 }

        let totalWeight = logRateWindow.reduce(0) { $0 + $1.weight }
        let counts = Dictionary(grouping: logRateWindow, by: { $0.rate }).mapValues { $0.reduce(0) { $0 + $1.weight } }
        guard let dominant = counts.max(by: { $0.value < $1.value }) else {
            return
        }

        let dominantRate = dominant.key
        let dominantWeight = dominant.value
        let dominance = totalWeight > 0 ? Double(dominantWeight) / Double(totalWeight) : 0.0

        if stableLogSampleRate == nil {
            if dominantWeight >= 6 && dominance >= 0.7 {
                lockSampleRate(dominantRate, statusKey: "Log locked at %@")
            } else {
                sampleRateSourceDisplay = "Log (estimating)"
                trackSampleRateDisplay = "Estimating"
            }
        } else if dominantRate != stableLogSampleRate {
            let stableAge = now.timeIntervalSince(stableLogSampleRateAt ?? now)
            if dominantWeight >= 9 && dominance >= 0.85 && stableAge > 3 {
                lockSampleRate(dominantRate, statusKey: "Log switched at %@")
            }
        }

        if stableLogSampleRate == nil {
            logStatusMessage = L10n.format("Log estimating %@ (%ld/%ld)",
                                           formatSampleRate(dominantRate), dominantWeight, totalWeight)
        }
    }

    private func updateTrackTitle(_ title: String) {
        guard !title.isEmpty else { return }
        if let lastTrackTitle, lastTrackTitle != title {
            resetLogLock(reason: "Track changed")
            // Music logs the new stream's format as playback starts, and the
            // title poll can trail that by a second or so — keep a format that
            // just arrived, since it belongs to this track, and drop older ones.
            if let trackFormatAt, Date().timeIntervalSince(trackFormatAt) < 3 {
                // fresh: keep
            } else {
                trackFormat = nil
            }
        }
        lastTrackTitle = title
    }

    private func resetLogLock(reason: String) {
        stableLogSampleRate = nil
        stableLogSampleRateAt = nil
        logRateWindow.removeAll()
        latestLogCandidateRate = nil
        trackSampleRateDisplay = "Unknown"
        sampleRateSourceDisplay = "Unknown"
        logStatusMessage = L10n.string(reason)
    }

    private func updateCurrentSampleRateDisplay() {
        if let stableLogSampleRate {
            assign(\.trackSampleRateDisplay, formatSampleRate(stableLogSampleRate))
            assign(\.sampleRateSourceDisplay, "Log (locked)")
        } else if latestLogCandidateRate != nil {
            assign(\.trackSampleRateDisplay, "Estimating")
            assign(\.sampleRateSourceDisplay, "Log (estimating)")
        } else {
            assign(\.trackSampleRateDisplay, "Unknown")
            assign(\.sampleRateSourceDisplay, "Unknown")
        }
    }

    private func lockSampleRate(_ rate: Double, statusKey: String) {
        stableLogSampleRate = rate
        stableLogSampleRateAt = Date()
        trackSampleRateDisplay = formatSampleRate(rate)
        sampleRateSourceDisplay = "Log (locked)"
        logStatusMessage = L10n.format(statusKey, formatSampleRate(rate))
        applyLogAutoSwitch(sampleRate: rate)
    }

    private func quantizeLogRate(_ rate: Double) -> Double? {
        let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        let nearest = candidates.min(by: { abs($0 - rate) < abs($1 - rate) })
        guard let nearest else { return nil }

        let diffRatio = abs(nearest - rate) / nearest
        if diffRatio <= 0.008 {
            return nearest
        }

        return nil
    }
}
