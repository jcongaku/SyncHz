import XCTest
import Foundation

/// SyncHz's EQ against the conventions of the PEQ generators it imports from —
/// AutoEq (RBJ cookbook, shelves with RBJ Q and Fc at the half-gain midpoint,
/// fitted at 44.1 kHz) and PEQdB (same math, fitted at 48 kHz) — and the
/// real-time processor actually playing the designed response.
final class PEQCompatibilityTests: XCTestCase {

    // MARK: - Filter math

    /// Golden values from an independent NumPy implementation of the RBJ
    /// cookbook — the formulas AutoEq's `peq.py` and PEQdB's client both use.
    func testBiquadMatchesIndependentReference() {
        let frequencies = [50.0, 105, 1_000, 3_400, 10_000, 15_000]
        let cases: [(Double, PEQBand, [Double])] = [
            (44_100, PEQBand(type: .lowShelf, frequency: 105, gainDB: 6.5, q: 0.70),
             [6.130895687153, 3.249999999999, 0.002350495568, 0.000130437815, 0.000010224124, 0.000002293315]),
            (44_100, PEQBand(type: .peak, frequency: 3_400, gainDB: 3.2, q: 3.4),
             [0.000058871999, 0.000259984462, 0.027858650546, 3.200000000000, 0.027236329278, 0.005400156483]),
            (44_100, PEQBand(type: .highShelf, frequency: 10_000, gainDB: -3.1, q: 0.70),
             [-0.000001082684, -0.000004788538, -0.000581525526, -0.026130138030, -1.550000000000, -2.935777234084]),
            (44_100, PEQBand(type: .peak, frequency: 15_000, gainDB: -5.0, q: 1.8),
             [-0.000006237031, -0.000027506688, -0.002509550974, -0.030928994669, -0.538439084482, -5.000000000000]),
            (96_000, PEQBand(type: .lowShelf, frequency: 105, gainDB: 6.5, q: 0.70),
             [6.130880636349, 3.250000000004, 0.002358994314, 0.000134788037, 0.000013986456, 0.000005623023]),
            (96_000, PEQBand(type: .peak, frequency: 3_400, gainDB: 3.2, q: 3.4),
             [0.000060748893, 0.000268278465, 0.028813419236, 3.200000000000, 0.038095874362, 0.013466638591]),
            (96_000, PEQBand(type: .highShelf, frequency: 10_000, gainDB: -3.1, q: 0.70),
             [-0.000001479467, -0.000006550173, -0.000864986819, -0.043311475224, -1.550000000000, -2.645169285106]),
            (96_000, PEQBand(type: .peak, frequency: 15_000, gainDB: -5.0, q: 1.8),
             [-0.000015273620, -0.000067360601, -0.006151436284, -0.076547621590, -1.320305304542, -5.000000000000]),
        ]
        for (rate, band, expected) in cases {
            let coefficients = BiquadCoefficients(band: band, sampleRate: rate)
            for (frequency, value) in zip(frequencies, expected) {
                XCTAssertEqual(decibels(coefficients, frequency, rate), value, accuracy: 1e-9,
                               "\(band.type) \(band.frequency) Hz at \(rate) Hz, probe \(frequency) Hz")
            }
        }
    }

    /// AutoEq and PEQdB place shelf Fc at the half-gain point (RBJ's f0), not
    /// at a corner frequency.
    func testShelfFrequencyIsTheHalfGainMidpoint() {
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            let low = BiquadCoefficients(band: PEQBand(type: .lowShelf, frequency: 105, gainDB: 6.5, q: 0.7),
                                         sampleRate: rate)
            let high = BiquadCoefficients(band: PEQBand(type: .highShelf, frequency: 10_000, gainDB: -3.1, q: 2.5),
                                          sampleRate: rate)
            XCTAssertEqual(decibels(low, 105, rate), 3.25, accuracy: 1e-9)
            XCTAssertEqual(decibels(high, 10_000, rate), -1.55, accuracy: 1e-9)
        }
    }

    // MARK: - Files

    /// oratory1990's Sennheiser HD 600 preset, verbatim from AutoEq's results/
    /// (MIT licence), fitted at AutoEq's default 44.1 kHz.
    private let autoEqHD600 = """
    Preamp: -6.3 dB
    Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
    Filter 2: ON PK Fc 125 Hz Gain -2.7 dB Q 0.55
    Filter 3: ON PK Fc 8445 Hz Gain 3.3 dB Q 1.61
    Filter 4: ON PK Fc 522 Hz Gain 0.7 dB Q 1.02
    Filter 5: ON PK Fc 1298 Hz Gain -1.2 dB Q 2.14
    Filter 6: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
    Filter 7: ON PK Fc 3158 Hz Gain -1.8 dB Q 3.67
    Filter 8: ON PK Fc 2166 Hz Gain 0.9 dB Q 3.32
    Filter 9: ON PK Fc 6639 Hz Gain 2.2 dB Q 5.82
    Filter 10: ON PK Fc 5433 Hz Gain -1.2 dB Q 5.70
    """

    func testAutoEqPresetImportsExactlyAndReproducesItsOwnPreamp() {
        let result = AutoEQParser.parse(autoEqHD600)
        XCTAssertEqual(result.preampDB, -6.3)
        XCTAssertTrue(result.skippedLines.isEmpty)
        XCTAssertEqual(result.bands.map(\.type),
                       [.lowShelf, .peak, .peak, .peak, .peak, .highShelf, .peak, .peak, .peak, .peak])
        XCTAssertEqual(result.bands[0].frequency, 105)
        XCTAssertEqual(result.bands[0].gainDB, 6.5)
        XCTAssertEqual(result.bands[0].q, 0.70)
        XCTAssertEqual(result.bands[9].q, 5.70)

        // Nothing a generator emits may be altered on import.
        let profile = PEQProfile(name: "HD 600", preampDB: result.preampDB, bands: result.bands)
        XCTAssertEqual(profile.sanitized().bands, profile.bands)

        // AutoEq writes Preamp = −(max of the summed response) over 20 Hz–20 kHz
        // in ×1.02 steps at 44.1 kHz, from unrounded parameters. Recomputing it
        // from the rounded file must land within that rounding.
        let bandsOnly = PEQProfile(name: "", bands: result.bands)
        var frequency = 20.0
        var maximum = -Double.infinity
        while frequency <= 20_000 {
            maximum = max(maximum, PEQResponse.magnitudeDB(profile: bandsOnly, frequency: frequency,
                                                           sampleRate: 44_100))
            frequency *= 1.02
        }
        XCTAssertEqual(-maximum, result.preampDB, accuracy: 0.06)
    }

    /// The shape of a PEQdB export (values invented within its observed ranges):
    /// gains with two decimals, Q with three, shelves placed anywhere, and shelf
    /// Q far above AutoEq's 0.4–0.7 — all of which must survive untouched.
    func testPEQdBStyleFileImportsWithoutClamping() {
        let text = """
        Preamp: -8.9 dB
        Filter 1: ON HSC Fc 55 Hz Gain -2.96 dB Q 0.668
        Filter 2: ON PK Fc 6761 Hz Gain -15.89 dB Q 0.400
        Filter 3: ON LSC Fc 15945 Hz Gain 2.10 dB Q 2.999
        Filter 4: ON PK Fc 16000 Hz Gain 8.00 dB Q 0.732
        """
        let result = AutoEQParser.parse(text, designRate: 48_000)
        XCTAssertEqual(result.bands.count, 4)
        XCTAssertEqual(result.bands[2].type, .lowShelf)
        XCTAssertEqual(result.bands[2].q, 2.999)
        let profile = PEQProfile(name: "PEQdB", preampDB: result.preampDB, bands: result.bands,
                                 designSampleRate: 48_000)
        XCTAssertEqual(profile.sanitized(), profile)
    }

    func testOtherExportSpellingsParse() {
        let text = """
        # comment lines are ignored
        Preamp: -6.35 dB
        Preamp: -1 dB
        Filter 1: ON LSC Fc 105.0 Hz Gain 6.5 dB Q 0.70
        Filter 2: ON LS Fc 105.0 Hz Gain 6.5 dB Q 0.70
        filter 3: on pk fc 1000hz gain -3db q 1.41
        Filter 4: OFF HS Fc 10000 Hz Gain -3.1 dB Q 0.70
        Filter 5: ON LP Fc 18000 Hz
        Filter 6: ON PK Fc 2000,5 Hz Gain 1,5 dB Q 2
        """
        let result = AutoEQParser.parse(text)
        XCTAssertEqual(result.preampDB, -7.35, accuracy: 1e-12, "APO adds repeated Preamp lines")
        XCTAssertEqual(result.bands.count, 5)
        XCTAssertEqual(result.bands[0].type, .lowShelf)
        XCTAssertEqual(result.bands[1].type, .lowShelf, "SoundSource-style LS means the same shelf")
        XCTAssertEqual(result.bands[2].frequency, 1_000)
        XCTAssertEqual(result.bands[2].gainDB, -3)
        XCTAssertEqual(result.bands[2].q, 1.41)
        XCTAssertFalse(result.bands[3].isEnabled)
        XCTAssertEqual(result.bands[4].frequency, 2_000.5)
        XCTAssertEqual(result.bands[4].gainDB, 1.5)
        XCTAssertEqual(result.skippedLines, ["Filter 5: ON LP Fc 18000 Hz"], "unsupported types are reported")
    }

    /// Equalizer APO's "BW Oct" form, converted with the RBJ cookbook relation
    /// 1/Q = 2·sinh(ln2/2 · BW · w0/sin w0) at the design rate.
    func testBandwidthInOctavesConvertsWithTheRBJFormula() {
        let q = AutoEQParser.parse("Filter: ON PK Fc 1000 Hz Gain -3 dB BW Oct 1.0",
                                   designRate: 44_100).bands.first?.q
        let w0 = 2 * Double.pi * 1_000 / 44_100
        let expected = 1 / (2 * sinh(log(2) / 2 * 1 * w0 / sin(w0)))
        XCTAssertEqual(try XCTUnwrap(q), expected, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(q), 2.squareRoot(), accuracy: 0.01, "≈ the analog √2 at 1 kHz")
    }

    func testProfilesSavedBeforeDesignRatesStillLoad() throws {
        let json = #"{"id":"4F2C6A33-1D8B-4C53-9D6E-6C2B8E0A9A11","name":"Old","preampDB":-3,"bands":[]}"#
        let profile = try JSONDecoder().decode(PEQProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.designSampleRate, PEQConstraints.defaultDesignRate)
        let roundTrip = try JSONDecoder().decode(PEQProfile.self,
                                                 from: JSONEncoder().encode(PEQProfile(name: "New", designSampleRate: 48_000)))
        XCTAssertEqual(roundTrip.designSampleRate, 48_000)
    }

    // MARK: - Sample-rate matching

    private var hd600WithHighBands: [PEQBand] {
        AutoEQParser.parse(autoEqHD600).bands + [
            PEQBand(type: .peak, frequency: 14_500, gainDB: -5, q: 1.8),
            PEQBand(type: .peak, frequency: 18_000, gainDB: 4, q: 3),
            PEQBand(type: .highShelf, frequency: 16_000, gainDB: 2, q: 0.7),
        ]
    }

    func testRateMatchingKeepsAPresetsResponseAtEveryRate() {
        let bands = hd600WithHighBands
        let design = bands.map { BiquadCoefficients(band: $0, sampleRate: 44_100) }

        let unmatchedAt96k = maxCascadeError(bands.map { BiquadCoefficients(band: $0, sampleRate: 96_000) },
                                             rate: 96_000, design: design, designRate: 44_100)
        XCTAssertGreaterThan(unmatchedAt96k, 0.5, "re-using the parameters at 96 kHz audibly moves the curve")

        for rate in [48_000.0, 88_200, 96_000, 176_400, 192_000] {
            let matched = bands.flatMap { PEQRateMatcher.sections(for: $0, designRate: 44_100, playbackRate: rate) }
            XCTAssertLessThan(maxCascadeError(matched, rate: rate, design: design, designRate: 44_100), 0.06,
                              "at \(rate) Hz")
            matched.forEach { assertStable($0) }
        }
    }

    /// A wide, deep cut fitted at 48 kHz is pulled back toward 0 dB near
    /// 24 kHz; no single section at 96 kHz follows that, two do.
    func testRateMatchingSplitsBandsOneSectionCannotFollow() {
        let band = PEQBand(type: .peak, frequency: 6_761, gainDB: -15.89, q: 0.4)
        let single = PEQRateMatcher.match(band: band, designRate: 48_000, playbackRate: 96_000, maxSections: 1)
        let split = PEQRateMatcher.match(band: band, designRate: 48_000, playbackRate: 96_000, maxSections: 2)
        XCTAssertEqual(single.sections.count, 1)
        XCTAssertGreaterThan(single.maxErrorDB, 1)
        XCTAssertEqual(split.sections.count, 2)
        XCTAssertLessThan(split.maxErrorDB, 0.1)
        split.sections.forEach { assertStable($0) }
    }

    func testRateMatchingIsExactAtTheDesignRate() {
        let band = PEQBand(type: .highShelf, frequency: 10_000, gainDB: -3.1, q: 0.7)
        XCTAssertEqual(PEQRateMatcher.sections(for: band, designRate: 48_000, playbackRate: 48_000),
                       [BiquadCoefficients(band: band, sampleRate: 48_000)])
    }

    // MARK: - The real-time path

    /// Sine probes through `BiquadProcessor` at 96 kHz with the matched
    /// sections of a 44.1 kHz AutoEq preset: what comes out must be the
    /// preset's design-rate response.
    func testProcessorPlaysTheDesignedResponse() {
        let rate = 96_000.0
        let bands = AutoEQParser.parse(autoEqHD600).bands
        let profile = PEQProfile(name: "HD 600", bands: bands)
        let sections = bands.flatMap { PEQRateMatcher.sections(for: $0, designRate: 44_100, playbackRate: rate) }

        let processor = BiquadProcessor()
        processor.setSections(sections, preampDB: 0, sampleRate: rate)
        processor.setActive(true)

        for frequency in [40.0, 125, 1_000, 3_158, 6_639, 8_445, 12_000, 17_000] {
            processor.requestReset()
            let measured = measuredGainDB(processor, frequency: frequency, sampleRate: rate)
            let expected = PEQResponse.magnitudeDB(profile: profile, frequency: frequency, sampleRate: 44_100)
            XCTAssertEqual(measured, expected, accuracy: 0.06, "\(frequency) Hz")
        }
    }

    func testHeadroomCoversLowShelfPlateauBelow20Hz() {
        let rate = 48_000.0
        let shelf = BiquadCoefficients(band: PEQBand(type: .lowShelf, frequency: 30, gainDB: 14.54, q: 0.431),
                                       sampleRate: rate)
        let at10Hz = decibels(shelf, 10, rate)
        XCTAssertGreaterThan(at10Hz, decibels(shelf, 20, rate) + 0.5, "the plateau keeps rising below 20 Hz")
        let headroom = PEQResponse.requiredAutomaticHeadroomDB(sections: [shelf], preampDB: -13, sampleRate: rate)
        XCTAssertGreaterThanOrEqual(headroom, at10Hz - 13 + 0.2 - 1e-9)
    }

    // MARK: - Helpers

    private func decibels(_ c: BiquadCoefficients, _ frequency: Double, _ rate: Double) -> Double {
        20 * log10(c.magnitude(atFrequency: frequency, sampleRate: rate))
    }

    private func maxCascadeError(_ sections: [BiquadCoefficients], rate: Double,
                                 design: [BiquadCoefficients], designRate: Double) -> Double {
        (0..<240).reduce(0) { worst, index in
            let frequency = 20 * pow(1_000, Double(index) / 239)   // 20 Hz–20 kHz
            let played = sections.reduce(0) { $0 + decibels($1, frequency, rate) }
            let wanted = design.reduce(0) { $0 + decibels($1, frequency, designRate) }
            return max(worst, abs(played - wanted))
        }
    }

    /// Poles inside the unit circle: |a2| < 1 and |a1| < 1 + a2.
    private func assertStable(_ c: BiquadCoefficients, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(abs(c.a2), 1, file: file, line: line)
        XCTAssertLessThan(abs(c.a1), 1 + c.a2, file: file, line: line)
    }

    /// Steady-state gain of a sine through the processor, by quadrature
    /// correlation over the second half of a one-second probe.
    private func measuredGainDB(_ processor: BiquadProcessor, frequency: Double, sampleRate: Double) -> Double {
        let amplitude = 0.1
        let total = Int(sampleRate)
        let settle = total / 2
        let block = 512
        var sumSin = 0.0, sumCos = 0.0
        var frame = 0
        var input = [Float](repeating: 0, count: block)
        var output = [Float](repeating: 0, count: block)
        while frame < total {
            let count = min(block, total - frame)
            for offset in 0..<count {
                input[offset] = Float(amplitude * sin(2 * Double.pi * frequency * Double(frame + offset) / sampleRate))
            }
            processor.beginRender(frameCount: count)
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    processor.process(channel: 0, input: source.baseAddress!,
                                      output: destination.baseAddress!, frameCount: count)
                }
            }
            processor.endRender(frameCount: count)
            for offset in 0..<count where frame + offset >= settle {
                let phase = 2 * Double.pi * frequency * Double(frame + offset) / sampleRate
                sumSin += Double(output[offset]) * sin(phase)
                sumCos += Double(output[offset]) * cos(phase)
            }
            frame += count
        }
        let n = Double(total - settle)
        let outAmplitude = 2 / n * (sumSin * sumSin + sumCos * sumCos).squareRoot()
        return 20 * log10(outAmplitude / amplitude)
    }
}
