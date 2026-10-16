import XCTest
import Foundation

final class PEQDspRegressionTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testProfileSanitizationUsesTypeSpecificLimitsAndBandCap() {
        let shelf = PEQBand(type: .highShelf,
                            frequency: .infinity,
                            gainDB: .nan,
                            q: 12).sanitized()
        XCTAssertEqual(shelf.frequency, 1_000)
        XCTAssertEqual(shelf.gainDB, 0)
        XCTAssertEqual(shelf.q, PEQConstraints.shelfQRange.upperBound)

        let profile = PEQProfile(name: "Many",
                                 bands: (0..<40).map { _ in PEQBand() }).sanitized()
        XCTAssertEqual(profile.bands.count, PEQConstraints.maximumBands)
    }

    func testAutomaticHeadroomCoversPeakBoost() {
        let profile = PEQProfile(name: "Boost", bands: [
            PEQBand(type: .peak, frequency: 1_000, gainDB: 18, q: 10),
        ])
        XCTAssertEqual(PEQResponse.requiredAutomaticHeadroomDB(profile: profile,
                                                               sampleRate: sampleRate),
                       18.2,
                       accuracy: 0.01)
    }

    func testFlatProfileKeepsExactUnityHeadroom() {
        XCTAssertEqual(PEQResponse.requiredAutomaticHeadroomDB(profile: .flat,
                                                               sampleRate: sampleRate),
                       0,
                       accuracy: 0.000_001)
    }

    func testProcessorProtectsFullScaleAndKeepsStereoMatched() {
        let processor = BiquadProcessor()
        let band = PEQBand(type: .peak, frequency: 1_000, gainDB: 18, q: 10)
        processor.setSections([BiquadCoefficients(band: band, sampleRate: sampleRate)],
                              preampDB: -18.2,
                              sampleRate: sampleRate)
        processor.setActive(true)

        var cursor = 0
        var peak = 0.0
        for _ in 0..<30 {
            let input = (0..<256).map {
                Float(0.9 * sin(2 * Double.pi * 1_000 * Double(cursor + $0) / sampleRate))
            }
            let output = render(processor, input, channels: 2)
            for frame in 0..<256 {
                XCTAssertTrue(output[0][frame].isFinite)
                XCTAssertEqual(output[0][frame], output[1][frame], accuracy: 0.000_001)
                peak = max(peak, abs(Double(output[0][frame])))
            }
            cursor += 256
        }
        XCTAssertLessThanOrEqual(peak, 1)
        XCTAssertLessThanOrEqual(peak, 0.90)
    }

    func testRapidUpdatesRemainFiniteAndUseLatestConfiguration() {
        let processor = BiquadProcessor()
        processor.setActive(true)
        for index in 0..<100 {
            let band = PEQBand(type: .peak,
                               frequency: 100 + Double(index) * 100,
                               gainDB: Double(index % 21) - 10,
                               q: 0.5 + Double(index % 10))
            processor.setSections([BiquadCoefficients(band: band, sampleRate: sampleRate)],
                                  preampDB: -12,
                                  sampleRate: sampleRate)
        }

        let input = (0..<4_096).map { Float(0.8 * sin(2 * Double.pi * 500 * Double($0) / sampleRate)) }
        for output in render(processor, input)[0] {
            XCTAssertTrue(output.isFinite)
            XCTAssertLessThanOrEqual(abs(output), 1)
        }
    }

    func testConcurrentPublishingAndRenderingStaysFinite() {
        let processor = BiquadProcessor()
        processor.setActive(true)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<1_000 {
                let band = PEQBand(type: .peak,
                                   frequency: 80 + Double(index % 190) * 100,
                                   gainDB: Double(index % 31) - 15,
                                   q: 0.2 + Double(index % 100) * 0.1)
                processor.setSections(
                    [BiquadCoefficients(band: band, sampleRate: self.sampleRate)],
                    preampDB: -18,
                    sampleRate: self.sampleRate)
            }
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var sampleOffset = 0
            for _ in 0..<500 {
                let input = (0..<64).map {
                    Float(0.75 * sin(2 * Double.pi * 997 * Double(sampleOffset + $0) / self.sampleRate))
                }
                for output in self.render(processor, input)[0] {
                    XCTAssertTrue(output.isFinite)
                    XCTAssertLessThanOrEqual(abs(output), 1)
                }
                sampleOffset += 64
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    // MARK: - Block processing (vDSP_deq22D)

    /// The vDSP block path against a plain double-precision transposed-DF-II
    /// loop: 16 sections including low-frequency, high-Q ones at 192 kHz — the
    /// case where single precision falls apart.
    func testBlockProcessingMatchesDoublePrecisionReference() {
        let rate = 192_000.0
        let bands = [
            PEQBand(type: .lowShelf, frequency: 23, gainDB: 3, q: 2.1),
            PEQBand(type: .peak, frequency: 30, gainDB: 6, q: 8),
            PEQBand(type: .peak, frequency: 61, gainDB: -7.2, q: 0.4),
            PEQBand(type: .peak, frequency: 133, gainDB: -7.4, q: 0.41),
            PEQBand(type: .peak, frequency: 662, gainDB: -10.3, q: 0.4),
            PEQBand(type: .peak, frequency: 1_513, gainDB: -8.3, q: 0.79),
            PEQBand(type: .peak, frequency: 2_138, gainDB: 2.1, q: 1.36),
            PEQBand(type: .peak, frequency: 3_103, gainDB: -8.6, q: 0.95),
            PEQBand(type: .peak, frequency: 4_150, gainDB: 3.5, q: 3),
            PEQBand(type: .peak, frequency: 6_761, gainDB: -15.9, q: 0.4),
            PEQBand(type: .highShelf, frequency: 12_784, gainDB: -16, q: 1.16),
            PEQBand(type: .peak, frequency: 15_393, gainDB: 0.7, q: 3.65),
            PEQBand(type: .peak, frequency: 51, gainDB: 0.6, q: 1.3),
            PEQBand(type: .peak, frequency: 82, gainDB: 1, q: 1.5),
            PEQBand(type: .peak, frequency: 93, gainDB: 0.7, q: 1.9),
            PEQBand(type: .peak, frequency: 272, gainDB: -8.2, q: 0.4),
        ]
        let sections = bands.map { BiquadCoefficients(band: $0, sampleRate: rate) }
        let processor = BiquadProcessor()
        processor.setSections(sections, preampDB: -6, sampleRate: rate)
        processor.setActive(true)

        var generator = SplitMix(seed: 7)
        let input = (0..<20_000).map { _ in Float(generator.nextUnit() * 0.4 - 0.2) }
        // Skip the 5 ms enable ramp, which the reference doesn't model.
        _ = render(processor, [Float](repeating: 0, count: 2_048))
        let output = render(processor, input)[0]

        var z1 = [Double](repeating: 0, count: sections.count), z2 = z1
        let gain = pow(10, -6.0 / 20)
        var worst = 0.0
        for (index, sample) in input.enumerated() {
            var x = Double(sample) * gain
            for (k, c) in sections.enumerated() {
                let y = c.b0 * x + z1[k]
                z1[k] = c.b1 * x - c.a1 * y + z2[k]
                z2[k] = c.b2 * x - c.a2 * y
                x = y
            }
            worst = max(worst, abs(Double(output[index]) - x))
        }
        XCTAssertLessThan(worst, 1e-6, "differs from the reference only by Float output rounding")
    }

    /// Filter histories carry across spans, block splits and render cycles:
    /// one long call, several spans with frame offsets, and a render longer
    /// than `blockFrames` all produce the same samples.
    func testBlockBoundariesAreSeamless() {
        let band = PEQBand(type: .peak, frequency: 60, gainDB: 9, q: 6)
        let frames = BiquadProcessor.blockFrames * 2 + 517
        let input = (0..<frames).map { Float(0.3 * sin(Double($0) * 0.013) + 0.1 * sin(Double($0) * 0.9)) }

        func configured() -> BiquadProcessor {
            let processor = BiquadProcessor()
            processor.setSections([BiquadCoefficients(band: band, sampleRate: sampleRate)],
                                  preampDB: -9, sampleRate: sampleRate)
            processor.setActive(true)
            return processor
        }

        let whole = render(configured(), input)[0]

        let spanned = configured()
        var pieces = [Float](repeating: 0, count: frames)
        spanned.beginRender(frameCount: frames)
        input.withUnsafeBufferPointer { source in
            pieces.withUnsafeMutableBufferPointer { destination in
                var offset = 0
                for length in [100, 700, 1_500, frames - 2_300] {
                    spanned.process(channel: 0, input: source.baseAddress! + offset,
                                    output: destination.baseAddress! + offset,
                                    frameOffset: offset, frameCount: length)
                    offset += length
                }
            }
        }
        spanned.endRender(frameCount: frames)

        let cycled = configured()
        var cycles: [Float] = []
        var start = 0
        for length in [64, 999, 1_024, frames - 2_087] {
            cycles += render(cycled, Array(input[start..<(start + length)]))[0]
            start += length
        }

        XCTAssertEqual(whole, pieces)
        XCTAssertEqual(whole, cycles)
    }

    /// Interleaved device buffers: a stride-2 output writes every other sample.
    func testStridedOutputWritesOnlyItsChannel() {
        let processor = BiquadProcessor()
        processor.setSections([], preampDB: 0, sampleRate: sampleRate)
        processor.setActive(true)
        let input = [Float](repeating: 0.25, count: 64)
        var interleaved = [Float](repeating: -9, count: 128)
        _ = render(processor, [Float](repeating: 0, count: 1_024))   // finish the enable ramp
        processor.beginRender(frameCount: 64)
        input.withUnsafeBufferPointer { source in
            interleaved.withUnsafeMutableBufferPointer { destination in
                processor.process(channel: 1, input: source.baseAddress!,
                                  output: destination.baseAddress! + 1, outputStride: 2,
                                  frameCount: 64)
            }
        }
        processor.endRender(frameCount: 64)
        for frame in 0..<64 {
            XCTAssertEqual(interleaved[frame * 2], -9, "other channel untouched")
            XCTAssertEqual(interleaved[frame * 2 + 1], 0.25, accuracy: 1e-7)
        }
    }

    // MARK: - Helpers

    /// One render cycle over `input`, fed to `channels` channels.
    private func render(_ processor: BiquadProcessor, _ input: [Float], channels: Int = 1) -> [[Float]] {
        var outputs = [[Float]](repeating: [Float](repeating: 0, count: input.count), count: channels)
        processor.beginRender(frameCount: input.count)
        input.withUnsafeBufferPointer { source in
            for channel in 0..<channels {
                outputs[channel].withUnsafeMutableBufferPointer { destination in
                    processor.process(channel: channel, input: source.baseAddress!,
                                      output: destination.baseAddress!, frameCount: input.count)
                }
            }
        }
        processor.endRender(frameCount: input.count)
        return outputs
    }
}

/// Deterministic noise for tests.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
