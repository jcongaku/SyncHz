import Foundation

final class LogStreamController {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "logstream.controller")
    private var recentLines: [String] = []
    private let maxRecentLines = 200
    private var lastFrameCount: Int?
    private var lastFrameTimestamp: Date?
    private var lastDurationSeconds: Double?
    private var lastDurationTimestamp: Date?
    private var isStopping = false
    private var restartAttempts = 0
    private var restartWorkItem: DispatchWorkItem?
    private var launchedAt: Date?

    var onSampleRate: ((Double, String?) -> Void)?
    var onStatus: ((String) -> Void)?

    /// Deliberately narrow. Matching `CONTAINS[c] "audio"` and
    /// `CONTAINS[c] "format"` turned this into a firehose — Music.app alone
    /// emitted thousands of matching debug events every few seconds, and each
    /// one was dispatched to the main queue.
    var predicate: String = "(process == \"Music\" OR subsystem == \"com.apple.Music\" OR subsystem == \"com.apple.mediaremoted\") AND (eventMessage CONTAINS[c] \"sample rate\" OR eventMessage CONTAINS[c] \"samplerate\" OR eventMessage CONTAINS[c] \"lossless\" OR eventMessage CONTAINS[c] \"hi-res\" OR eventMessage CONTAINS[c] \"kHz\" OR eventMessage CONTAINS[c] \"frames\" OR eventMessage CONTAINS[c] \"duration\")"
    var logLevel: String = "debug"

    /// Stop retrying after this many consecutive failures so a permanently
    /// broken `log stream` cannot spawn processes forever.
    private static let maxRestartAttempts = 5

    /// A stream that stays up this long counts as healthy, so its eventual
    /// exit starts the backoff over instead of using up another attempt.
    private static let healthyUptime: TimeInterval = 30

    // MARK: - Lifecycle
    //
    // All process state lives behind `queue`. Both `start()` and `stop()` are
    // safe to call from any thread; they hand the work to `queue` and return
    // immediately.

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = false
            self.restartAttempts = 0
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.teardownStream()
            self.launchStream()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.restartAttempts = 0
            self.teardownStream()
        }
    }

    /// Must be called on `queue`.
    private func launchStream() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            // `ndjson` emits one compact JSON object per line. `json` emits
            // pretty-printed multi-line objects, which cannot be framed by
            // newline — every `json` event used to be split across many bogus
            // "lines" and dropped.
            "--style", "ndjson",
            "--level", logLevel,
            "--predicate", predicate
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        outputHandle = outHandle
        errorHandle = errHandle

        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // EOF: the child closed stdout, i.e. it exited or was killed.
                self.queue.async { self.handleStreamEnded() }
                return
            }
            self.queue.async {
                self.buffer.append(data)
                self.drainBuffer()
            }
        }

        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.onStatus?(trimmed) }
        }

        // Without this, a crashed or SIGKILLed `log stream` left the app
        // silently receiving no events forever — the auto-switch simply
        // stopped working with no indication why.
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleStreamEnded() }
        }

        do {
            try proc.run()
            process = proc
            launchedAt = Date()
            DispatchQueue.main.async { self.onStatus?("Log stream started") }
        } catch {
            process = nil
            DispatchQueue.main.async {
                self.onStatus?("Failed to start log stream: \(error.localizedDescription)")
            }
            scheduleRestart()
        }
    }

    /// Must be called on `queue`. Idempotent: the EOF path and the
    /// `terminationHandler` both funnel here, and the first one wins.
    private func handleStreamEnded() {
        guard !isStopping else { return }
        guard process != nil || outputHandle != nil else { return }
        // Only a stream that ran for a while resets the budget. Resetting on
        // every successful `run()` let a `log stream` that exits right after
        // launch (a rejected predicate, say) respawn every second forever.
        if let launchedAt, Date().timeIntervalSince(launchedAt) >= Self.healthyUptime {
            restartAttempts = 0
        }
        teardownStream()
        scheduleRestart()
    }

    /// Must be called on `queue`.
    private func scheduleRestart() {
        guard !isStopping else { return }
        guard restartAttempts < Self.maxRestartAttempts else {
            let attempts = restartAttempts
            DispatchQueue.main.async {
                self.onStatus?("Log stream stopped after \(attempts) failed restarts")
            }
            return
        }

        restartAttempts += 1
        let delay = min(pow(2.0, Double(restartAttempts - 1)), 30.0)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopping else { return }
            self.launchStream()
        }
        restartWorkItem?.cancel()
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Must be called on `queue`.
    private func teardownStream() {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        outputHandle = nil
        errorHandle = nil
        launchedAt = nil
        buffer.removeAll(keepingCapacity: false)

        if let process {
            // Clear first: terminating fires the handler, and we do not want
            // a deliberate teardown to look like a crash.
            process.terminationHandler = nil
            process.terminate()
            self.process = nil
        }
    }

    private func drainBuffer() {
        while let range = buffer.firstRange(of: Data([0x0A])) { // newline
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
                continue
            }

            appendRecent(line)
            handleLogLine(line)
        }
    }

    func handleLogLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            _ = processMessage(line)
            return
        }

        let message = (json["eventMessage"] as? String)
            ?? (json["message"] as? String)
            ?? (json["formattedMessage"] as? String)

        if let message, processMessage(message) {
            return
        }

        if let rate = SampleRateParser.extractSampleRate(from: json) {
            onSampleRate?(rate, message ?? "JSON sampleRate")
            return
        }

        // Other JSON fields are metadata, not audio-format messages.
    }

    @discardableResult
    private func processMessage(_ message: String) -> Bool {
        if let rate = SampleRateParser.extractSampleRate(from: message) {
            onSampleRate?(rate, message)
            return true
        }

        if let rate = deriveSampleRate(from: message) {
            onSampleRate?(rate, "Derived from frames/duration: \(message)")
            return true
        }

        return false
    }

    private func deriveSampleRate(from message: String) -> Double? {
        let now = Date()

        if let frames = SampleRateParser.extractFrameCount(from: message) {
            lastFrameCount = frames
            lastFrameTimestamp = now
        }

        if let duration = SampleRateParser.extractDuration(from: message) {
            lastDurationSeconds = duration
            lastDurationTimestamp = now
        }

        guard let frames = lastFrameCount,
              let duration = lastDurationSeconds,
              duration > 0 else {
            return nil
        }

        let maxAge: TimeInterval = 5.0
        if let frameTime = lastFrameTimestamp,
           now.timeIntervalSince(frameTime) > maxAge {
            return nil
        }
        if let durationTime = lastDurationTimestamp,
           now.timeIntervalSince(durationTime) > maxAge {
            return nil
        }

        let minFrames = 1000
        let minDuration: Double = 0.05
        let maxDuration: Double = 5.0

        guard frames >= minFrames,
              duration >= minDuration,
              duration <= maxDuration else {
            return nil
        }

        let estimated = Double(frames) / duration
        return estimated
    }

    private func appendRecent(_ line: String) {
        recentLines.append(line)
        if recentLines.count > maxRecentLines {
            recentLines.removeFirst(recentLines.count - maxRecentLines)
        }
    }

    func dumpRecentLines() {
        queue.async { [recentLines] in
            print("MediaRemote LogStream: Recent \(recentLines.count) lines")
            for line in recentLines {
                print(line)
            }
        }
    }
}

private enum SampleRateParser {
    private static let sampleRatePattern = try! NSRegularExpression(
        pattern: "(?i)(?:sample\\s*rate|samplerate)\\s*[:=]\\s*([0-9]+(?:\\.[0-9]+)?)",
        options: []
    )

    private static let khzPattern = try! NSRegularExpression(
        pattern: "(?i)([0-9]+(?:\\.[0-9]+)?)\\s*kHz",
        options: []
    )

    private static let hzPattern = try! NSRegularExpression(
        pattern: "(?i)([0-9]{4,6})\\s*Hz",
        options: []
    )

    private static let framesPattern = try! NSRegularExpression(
        pattern: "(?i)([0-9]{3,7})\\s*frames",
        options: []
    )

    private static let durationPattern = try! NSRegularExpression(
        pattern: "(?i)duration\\s*:?\\s*([0-9]+(?:\\.[0-9]+)?)",
        options: []
    )

    static func extractSampleRate(from message: String) -> Double? {
        if let value = firstMatch(message, regex: sampleRatePattern) {
            return normalize(value, unit: nil)
        }

        if let value = firstMatch(message, regex: khzPattern) {
            return normalize(value, unit: "kHz")
        }

        if let value = firstMatch(message, regex: hzPattern) {
            return normalize(value, unit: "Hz")
        }

        return nil
    }

    static func extractFrameCount(from message: String) -> Int? {
        guard let value = firstMatch(message, regex: framesPattern) else {
            return nil
        }
        return Int(value)
    }

    static func extractDuration(from message: String) -> Double? {
        return firstMatch(message, regex: durationPattern)
    }

    static func extractSampleRate(from json: [String: Any]) -> Double? {
        for (key, value) in json {
            if ["samplerate", "msamplerate"].contains(key.lowercased()),
               let numeric = numericValue(value) {
                return normalize(numeric, unit: nil)
            }
        }

        for value in json.values {
            if let nested = extractSampleRate(from: value) {
                return nested
            }
        }

        return nil
    }

    private static func extractSampleRate(from value: Any) -> Double? {
        if let dict = value as? [String: Any] {
            return extractSampleRate(from: dict)
        }

        if let array = value as? [Any] {
            for item in array {
                if let nested = extractSampleRate(from: item) {
                    return nested
                }
            }
        }

        // Numeric leaves are evidence only under an explicit sample-rate key.
        return nil
    }

    private static func firstMatch(_ text: String, regex: NSRegularExpression) -> Double? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Double(text[capture])
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let doubleValue = value as? Double {
            return doubleValue
        }

        if let string = value as? String, let doubleValue = Double(string) {
            return doubleValue
        }

        return nil
    }

    private static func normalize(_ value: Double, unit: String?) -> Double? {
        if value <= 0 { return nil }

        if let unit, unit.lowercased() == "khz" {
            return value * 1000.0
        }

        if let unit, unit.lowercased() == "hz" {
            return value
        }

        if value < 1000 {
            return value * 1000.0
        }

        return value
    }

    static func snapToCommonSampleRate(_ value: Double) -> Double? {
        let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        let nearest = candidates.min(by: { abs($0 - value) < abs($1 - value) })
        guard let nearest else { return value }
        if abs(nearest - value) <= 250 {
            return nearest
        }
        return nil
    }
}
