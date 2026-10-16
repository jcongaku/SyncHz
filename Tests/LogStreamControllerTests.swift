import XCTest

final class LogStreamControllerTests: XCTestCase {
    func testRepeatedThreadIDsDoNotProduceSampleRateEvidence() {
        let line = #"{"eventMessage":"audio buffer scheduled","threadID":48000}"#
        XCTAssertEqual(sampleRates(from: Array(repeating: line, count: 6)), [])
    }

    func testUnrelatedNumericMetadataIsIgnoredAtEveryDepth() {
        let lines = [
            #"{"eventMessage":"audio buffer scheduled","processID":44100}"#,
            #"{"eventMessage":"audio buffer scheduled","count":96}"#,
            #"{"eventMessage":"audio buffer scheduled","duration":192}"#,
            #"{"eventMessage":"audio buffer scheduled","threadID":"48000"}"#,
            #"{"metadata":{"threadID":48000}}"#,
            #"{"metadata":[{"processID":"44100"},48000,"96",[192000]]}"#,
        ]
        for line in lines {
            XCTAssertEqual(sampleRates(from: [line]), [], line)
        }
    }

    func testMetadataTextIsNotReparsedAsAnAudioMessage() {
        let lines = [
            #"{"eventMessage":"audio route unchanged","metadata":"48 kHz"}"#,
            #"{"metadata":{"description":"sample rate: 96000"}}"#,
            #"{"metadata":["44100 Hz"]}"#,
        ]
        for line in lines {
            XCTAssertEqual(sampleRates(from: [line]), [], line)
        }
    }

    func testSampleRateCountersAreNotSampleRateFields() {
        for key in ["sampleRateCount", "sampleRateChangeCount"] {
            XCTAssertEqual(sampleRates(from: ["{\"\(key)\":48000}"]), [])
        }
    }

    func testExplicitSampleRateFieldsSurviveNestedContainersAndMetadata() {
        let cases: [(String, Double)] = [
            (#"{"sampleRate":48000}"#, 48000),
            (#"{"SampleRate":"44.1"}"#, 44100),
            (#"{"format":{"mSampleRate":96000},"threadID":48000}"#, 96000),
            (#"{"formats":[48000,"44.1",{"sampleRate":"192000"}]}"#, 192000),
            (#"{"metadata":{"threadID":48000},"format":{"sampleRate":88200}}"#, 88200),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(sampleRates(from: [line]), [expected], line)
        }
    }

    func testRecognizedJSONMessagesStillProduceSampleRates() {
        let cases: [(String, Double)] = [
            (#"{"eventMessage":"sample rate: 44100","threadID":48000}"#, 44100),
            (#"{"message":"audio format: 96 kHz","processID":44100}"#, 96000),
            (#"{"formattedMessage":"audio format: 192000 Hz"}"#, 192000),
            (#"{"eventMessage":"sample rate: 48000","sampleRate":96000}"#, 48000),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(sampleRates(from: [line]), [expected], line)
        }
    }

    func testPlainTextAudioMessagesRemainSupported() {
        XCTAssertEqual(sampleRates(from: [
            "sample rate = 48000",
            "audio format: 44.1 kHz",
            "audio format: 96000 Hz",
            "audio route unchanged",
        ]), [48000, 44100, 96000])
    }

    func testActiveFormatLineYieldsCodecBitDepthAndTier() {
        // Shape of the line as captured from Music.app's log on macOS 27.
        let line = "|2026-10-15 02:38:23.882-0400 mus:nePSnYoK7  4 ┃┃┃┃  ╲╭ activeFormat: tier: Lossless; "
            + "groupID: audio-alac-stereo-48000-24; bitDepth: 24-bit; sampleRate: 48kh"
        let format = TrackFormat(logMessage: line)
        XCTAssertEqual(format?.codec, "ALAC")
        XCTAssertEqual(format?.bitDepth, 24)
        XCTAssertEqual(format?.tier, "Lossless")

        // The same line still votes for its sample rate.
        XCTAssertEqual(sampleRates(from: [line]), [48000])
    }

    func testActiveFormatTierSpellingsAreNormalised() {
        XCTAssertEqual(TrackFormat(logMessage: "activeFormat: tier: HiResLossless; bitDepth: 24-bit")?.tier,
                       "Hi-Res Lossless")
        XCTAssertEqual(TrackFormat(logMessage: "activeFormat: tier: Hi-Res Lossless")?.tier,
                       "Hi-Res Lossless")
        // A tier equal to the codec is not repeated.
        let atmos = TrackFormat(logMessage: "activeFormat: tier: Atmos; groupID: audio-atmos-2048")
        XCTAssertEqual(atmos?.codec, "Dolby Atmos")
        XCTAssertNil(atmos?.tier)
    }

    func testFormatLessLinesAreIgnored() {
        XCTAssertNil(TrackFormat(logMessage: "sample rate: 44100"))
        XCTAssertNil(TrackFormat(logMessage: "activeFormat: nothing useful here"))
        // An unknown group ID is not guessed at.
        XCTAssertNil(TrackFormat(logMessage: "activeFormat: groupID: audio-mystery-48000")?.codec)
    }

    func testActiveFormatIsReportedThroughTheCallback() {
        let controller = LogStreamController()
        var formats: [TrackFormat] = []
        controller.onTrackFormat = { formats.append($0) }
        controller.handleLogLine(#"{"eventMessage":"activeFormat: tier: Lossless; groupID: audio-alac-stereo-44100-16; bitDepth: 16-bit; sampleRate: 44.1kh"}"#)
        XCTAssertEqual(formats.count, 1)
        XCTAssertEqual(formats.first?.bitDepth, 16)
    }

    private func sampleRates(from lines: [String]) -> [Double] {
        let controller = LogStreamController()
        var rates: [Double] = []
        controller.onSampleRate = { rate, _ in rates.append(rate) }
        for line in lines {
            controller.handleLogLine(line)
        }
        return rates
    }
}
