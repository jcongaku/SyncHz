import Foundation

struct TrackInfo {
    let title: String
    let artist: String?
    let album: String?
    let isPlaying: Bool
    let position: Double?
    let duration: Double?
}

struct TrackFetchResult {
    let track: TrackInfo?
    let errorMessage: String?
}

enum MusicCommand: String {
    case playPause = "playpause"
    case nextTrack = "next track"
    case previousTrack = "back track"
}

/// Sends Apple Events to Music.app.
///
/// Every method here is an inter-process round trip: `executeAndReturnError`
/// blocks the calling thread until Music.app replies or the AppleScript
/// timeout expires. Music.app is routinely busy — especially right after a
/// track change or a skip — and a synchronous call from the main thread
/// therefore froze the menu bar popover and starved the 1 Hz polling timer
/// for tens of seconds at a time.
///
/// So all script execution happens on a private serial queue, and every script
/// carries its own short `with timeout` block to cap the wait at
/// `scriptTimeoutSeconds` instead of the much longer AppleScript default.
/// `NSAppleScript` is not thread-safe, but each script is created and used
/// entirely within a single block on that one serial queue and is never shared.
final class MusicController {
    private let scriptQueue = DispatchQueue(label: "com.garykong.choritsu.applescript")

    /// Kept short on purpose. This is a fallback path — MediaRemote is the
    /// primary source of track metadata — so a slow reply is worse than a
    /// slightly stale one.
    private static let scriptTimeoutSeconds = 5

    // MARK: - Async API

    /// Fire-and-forget transport command. Never blocks the caller.
    func send(_ command: MusicCommand) {
        scriptQueue.async {
            let source = """
            with timeout of \(Self.scriptTimeoutSeconds) seconds
                tell application \"Music\"
                    if it is running then
                        \(command.rawValue)
                    end if
                end tell
            end timeout
            """

            guard let script = NSAppleScript(source: source) else { return }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
        }
    }

    /// Fetches the current track off the main thread. `completion` is delivered
    /// on the main queue.
    func fetchTrackInfo(completion: @escaping (TrackFetchResult) -> Void) {
        scriptQueue.async {
            let result = Self.performTrackInfoFetch()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Fetches artwork off the main thread. `completion` is delivered on the
    /// main queue.
    func fetchArtwork(completion: @escaping (Data?) -> Void) {
        scriptQueue.async {
            let data = Self.performArtworkFetch()
            DispatchQueue.main.async { completion(data) }
        }
    }

    // MARK: - Script execution

    private static func performArtworkFetch() -> Data? {
        let scriptSource = """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application \"Music\"
                if it is running then
                    try
                        return (get data of artwork 1 of current track)
                    end try
                end if
            end tell
        end timeout
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return nil
        }

        let data = output.data
        return data.isEmpty ? nil : data
    }

    private static func performTrackInfoFetch() -> TrackFetchResult {
        // Note: "st" is a reserved abbreviation in AppleScript and cannot be
        // used as a variable name.
        let scriptSource = """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application \"Music\"
                if it is running then
                    set stateText to (player state as text)
                    if stateText is \"playing\" or stateText is \"paused\" then
                        set t to current track
                        set trackName to name of t
                        set artistName to \"\"
                        set albumName to \"\"
                        set posText to \"\"
                        set durText to \"\"
                        try
                            set artistName to artist of t
                        end try
                        try
                            set albumName to album of t
                        end try
                        try
                            set posText to (player position as text)
                        end try
                        try
                            set durText to ((duration of t) as text)
                        end try
                        return trackName & \"||\" & artistName & \"||\" & albumName & \"||\" & stateText & \"||\" & posText & \"||\" & durText
                    end if
                end if
            end tell
            return \"\"
        end timeout
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return TrackFetchResult(track: nil, errorMessage: "Failed to create AppleScript.")
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorCode = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if errorCode == -1743 {
                return TrackFetchResult(track: nil,
                                        errorMessage: "Apple Music access denied. Enable it in System Settings > Privacy & Security > Automation.")
            }

            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript error."
            return TrackFetchResult(track: nil, errorMessage: message)
        }

        guard let outputString = output.stringValue,
              !outputString.isEmpty else {
            return TrackFetchResult(track: nil, errorMessage: nil)
        }

        let parts = outputString.components(separatedBy: "||")
        guard let title = parts.first, !title.isEmpty else {
            return TrackFetchResult(track: nil, errorMessage: nil)
        }

        let artist = parts.count > 1 ? nonEmpty(parts[1]) : nil
        let album = parts.count > 2 ? nonEmpty(parts[2]) : nil
        let isPlaying = parts.count > 3 && parts[3] == "playing"
        let position = parts.count > 4 ? numeric(parts[4]) : nil
        let duration = parts.count > 5 ? numeric(parts[5]) : nil

        return TrackFetchResult(track: TrackInfo(title: title,
                                                 artist: artist,
                                                 album: album,
                                                 isPlaying: isPlaying,
                                                 position: position,
                                                 duration: duration),
                                errorMessage: nil)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func numeric(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(trimmed)
    }
}
