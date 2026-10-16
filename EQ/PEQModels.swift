import Foundation

/// Limits applied to band parameters. They exist to keep the math finite, not
/// to second-guess a preset: anything a PEQ generator emits must survive an
/// import unchanged, or the correction it fitted is silently altered.
enum PEQConstraints {
    static let maximumBands = 32
    /// AutoEq fits 20 Hz–10 kHz; other generators go lower and higher. A band
    /// at or above the playback Nyquist frequency is bypassed when coefficients
    /// are made, rather than clamped here.
    static let frequencyRange = 10.0...22_000.0
    /// AutoEq's default is ±20 dB; leave room above it.
    static let gainRange = -24.0...24.0
    static let preampRange = -30.0...12.0
    /// AutoEq's own app presets reach Q 12 (Poweramp) and its default lower
    /// bound is 0.18; IEM notch fits go higher still.
    static let peakQRange = 0.05...20.0
    /// AutoEq's default shelves use Q 0.4–0.7, but its app presets and other
    /// tools export shelf Q outside that. RBJ shelves stay well defined there —
    /// above 0.707 they overshoot, which is exactly what such a preset asks for.
    static let shelfQRange = 0.1...10.0

    /// AutoEq's published results are fitted at 44.1 kHz (`DEFAULT_FS`); its
    /// web app fits at the browser's rate instead, so profiles carry their own.
    static let defaultDesignRate = 44_100.0
    static let designRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    static let designRateRange = 8_000.0...768_000.0

    static func qRange(for type: PEQFilterType) -> ClosedRange<Double> {
        type == .peak ? peakQRange : shelfQRange
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>,
                      fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Filter vocabulary

/// The parametric filter shapes SyncHz supports. The raw values mirror
/// AutoEQ's `ParametricEQ.txt` tokens so profiles round-trip cleanly.
enum PEQFilterType: String, Codable, CaseIterable, Identifiable {
    case peak       // AutoEQ: PK
    case lowShelf   // AutoEQ: LSC / LS
    case highShelf  // AutoEQ: HSC / HS

    var id: String { rawValue }

    /// The token written into an AutoEQ-style export.
    var autoEQToken: String {
        switch self {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        }
    }

    var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }
}

// MARK: - Band

/// A single parametric EQ band: one biquad's worth of parameters.
struct PEQBand: Identifiable, Codable, Equatable {
    var id: UUID
    var isEnabled: Bool
    var type: PEQFilterType
    /// Peak centre, or shelf midpoint (the half-gain point, as in RBJ and
    /// AutoEq — not a corner frequency), in Hz.
    var frequency: Double
    var gainDB: Double
    /// RBJ quality factor, for shelves too (AutoEq's LSC/HSC use RBJ Q, not
    /// shelf slope S). AutoEQ shelves default to ~0.707.
    var q: Double

    init(id: UUID = UUID(),
         isEnabled: Bool = true,
         type: PEQFilterType = .peak,
         frequency: Double = 1000,
         gainDB: Double = 0,
         q: Double = 0.707) {
        self.id = id
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }

    func sanitized() -> PEQBand {
        var result = self
        result.frequency = PEQConstraints.clamp(frequency,
                                                to: PEQConstraints.frequencyRange,
                                                fallback: 1_000)
        result.gainDB = PEQConstraints.clamp(gainDB,
                                             to: PEQConstraints.gainRange,
                                             fallback: 0)
        result.q = PEQConstraints.clamp(q,
                                        to: PEQConstraints.qRange(for: type),
                                        fallback: type == .peak ? 1 : 0.7)
        return result
    }
}

// MARK: - Profile

/// A named set of bands plus a preamp — typically one per headphone.
/// AutoEQ presets are mono curves applied identically to both channels.
struct PEQProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Global gain applied before the bands, in dB. AutoEQ ships this negative
    /// to leave headroom for the boosts and avoid clipping.
    var preampDB: Double
    var bands: [PEQBand]
    /// The sample rate the band parameters were fitted at. The response at
    /// this rate is the profile's definition: the graph draws it, and
    /// `PEQRateMatcher` reproduces it at whatever rate the device plays.
    var designSampleRate: Double

    init(id: UUID = UUID(),
         name: String,
         preampDB: Double = 0,
         bands: [PEQBand] = [],
         designSampleRate: Double = PEQConstraints.defaultDesignRate) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
        self.designSampleRate = designSampleRate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, preampDB, bands, designSampleRate
    }

    /// Profiles saved before `designSampleRate` existed decode with the
    /// AutoEq default, so existing libraries keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        preampDB = try container.decode(Double.self, forKey: .preampDB)
        bands = try container.decode([PEQBand].self, forKey: .bands)
        designSampleRate = try container.decodeIfPresent(Double.self, forKey: .designSampleRate)
            ?? PEQConstraints.defaultDesignRate
    }

    static let flat = PEQProfile(name: "Flat")

    func sanitized() -> PEQProfile {
        var result = self
        result.preampDB = PEQConstraints.clamp(preampDB,
                                               to: PEQConstraints.preampRange,
                                               fallback: 0)
        result.bands = bands.prefix(PEQConstraints.maximumBands).map { $0.sanitized() }
        result.designSampleRate = PEQConstraints.clamp(designSampleRate,
                                                       to: PEQConstraints.designRateRange,
                                                       fallback: PEQConstraints.defaultDesignRate)
        return result
    }
}
