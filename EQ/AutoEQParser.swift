import Foundation

/// Parses AutoEQ / Squiglink `ParametricEQ.txt` files into a `PEQProfile`.
///
/// Expected shape:
///
///     Preamp: -6.85 dB
///     Filter 1: ON LSC Fc 105.0 Hz Gain 4.7 dB Q 0.70
///     Filter 2: ON PK  Fc 70.5  Hz Gain 0.3 dB Q 4.73
///     ...
///
/// Filter types: PK (peaking), LSC/LS/LSQ (low shelf), HSC/HS/HSQ (high shelf),
/// all with AutoEq's semantics — RBJ cookbook biquads, shelf Fc at the
/// half-gain midpoint, Q as RBJ Q. Lines with an unsupported filter type
/// (LP, HP, notch…) are collected in `Result.skippedLines` rather than failing
/// the whole import, and reported to the user.
enum AutoEQParser {
    struct Result {
        var preampDB: Double
        var bands: [PEQBand]
        var skippedLines: [String]
    }

    /// - Parameter designRate: the rate the generator fitted at; used only to
    ///   convert Equalizer APO "BW Oct" bandwidths to Q.
    static func parse(_ text: String,
                      designRate: Double = PEQConstraints.defaultDesignRate) -> Result {
        var preampDB = 0.0
        var bands: [PEQBand] = []
        var skipped: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let lowercased = line.lowercased()
            if lowercased.hasPrefix("preamp") {
                // Equalizer APO adds up repeated Preamp lines; so do we.
                if let value = firstSignedNumber(in: line) {
                    preampDB += value
                }
            } else if lowercased.hasPrefix("filter") {
                if let band = parseFilterLine(line, designRate: designRate) {
                    bands.append(band)
                } else {
                    skipped.append(line)
                }
            }
        }

        return Result(preampDB: preampDB, bands: bands, skippedLines: skipped)
    }

    /// Convenience: parse straight into an enabled profile.
    static func profile(from text: String, name: String) -> PEQProfile {
        let result = parse(text)
        return PEQProfile(name: name, preampDB: result.preampDB, bands: result.bands)
    }

    // MARK: - Line parsing

    // "Filter 1: ON PK Fc 105 Hz Gain 4.7 dB Q 0.70"
    // "Filter: ON PK Fc 1000 Hz Gain -3 dB BW Oct 1.0"   (Equalizer APO bandwidth form)
    private static func parseFilterLine(_ line: String, designRate: Double) -> PEQBand? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let upper = tokens.map { $0.uppercased() }
        guard let statusIndex = upper.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
              statusIndex + 1 < tokens.count,
              let type = filterType(upper[statusIndex + 1]),
              let frequency = value(after: "FC", in: upper),
              frequency > 0 else {
            return nil
        }

        let gain = value(after: "GAIN", in: upper) ?? 0
        let q: Double
        if let explicitQ = value(after: "Q", in: upper) {
            q = explicitQ
        } else if type == .peak, let octaves = bandwidthOctaves(in: upper) {
            q = qFromBandwidth(octaves, frequency: frequency, sampleRate: designRate)
        } else {
            q = 0.707
        }

        return PEQBand(isEnabled: upper[statusIndex] == "ON",
                       type: type,
                       frequency: frequency,
                       gainDB: gain,
                       q: q)
    }

    /// Shelf tokens: AutoEq writes LSC/HSC; its web app's SoundSource export
    /// and other tools write LS/HS (or LSQ/HSQ) with the same RBJ-Q, midpoint
    /// meaning. A shelf line without a Q falls back to Q 0.707.
    private static func filterType(_ token: String) -> PEQFilterType? {
        switch token {
        case "PK", "PEQ": return .peak
        case "LS", "LSC", "LSQ": return .lowShelf
        case "HS", "HSC", "HSQ": return .highShelf
        default: return nil
        }
    }

    /// The number following `key` (case-insensitive tokens, already
    /// upper-cased). Accepts a unit glued to the number ("105HZ", "4.7DB")
    /// and a decimal comma.
    private static func value(after key: String, in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(of: key), index + 1 < tokens.count else {
            return nil
        }
        return number(tokens[index + 1])
    }

    /// "BW OCT 1.5" — Equalizer APO's bandwidth syntax, in octaves.
    private static func bandwidthOctaves(in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(of: "BW"), index + 1 < tokens.count else { return nil }
        let valueIndex = tokens[index + 1] == "OCT" ? index + 2 : index + 1
        guard valueIndex < tokens.count, let octaves = number(tokens[valueIndex]), octaves > 0 else {
            return nil
        }
        return octaves
    }

    /// RBJ cookbook bandwidth → Q for a peaking filter, including its digital
    /// w0/sin(w0) term: 1/Q = 2·sinh(ln2/2 · BW · w0/sin w0). Evaluated at the
    /// profile's design rate, the rate whose response SyncHz reproduces.
    static func qFromBandwidth(_ octaves: Double, frequency: Double, sampleRate: Double) -> Double {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let digital = w0 > 0 && w0 < .pi ? w0 / sin(w0) : 1
        return 1 / (2 * sinh(log(2) / 2 * octaves * digital))
    }

    private static func number(_ token: String) -> Double? {
        var text = token.replacingOccurrences(of: ",", with: ".")
        while let last = text.last, last.isLetter || last == ":" || last == ";" {
            text.removeLast()
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// First signed decimal in a string — used for the "Preamp: -6.85 dB" line.
    private static func firstSignedNumber(in line: String) -> Double? {
        var buffer = ""
        for character in line {
            if character.isNumber || character == "." || character == "-" || character == "+" {
                buffer.append(character)
            } else if !buffer.isEmpty {
                if let value = Double(buffer) { return value }
                buffer = ""
            }
        }
        return Double(buffer)
    }
}
