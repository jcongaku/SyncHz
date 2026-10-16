import Foundation
import Accelerate
import Synchronization
import Observation

/// Real-time spectrum analyzer for the EQ window, drawn as bars behind the
/// response curve. The audio engine pushes post-EQ output samples in via
/// `append` (audio thread, lock-free ring write); a 24 fps timer on the main
/// run loop runs a windowed FFT and folds it into 1/3-octave bands. Because it
/// analyses the processed output, the bars reflect the EQ live.
///
/// Each band sums the power of every FFT bin inside it — like a hardware RTA —
/// rather than sampling one bin per band, so no energy between sample points
/// is lost at the top end. The FFT length grows with the sample rate (2048 at
/// 44.1/48 kHz up to 8192 at 176.4/192 kHz) to keep ~23 Hz resolution, so the
/// lowest bands stay distinct at hi-res rates.
@Observable
final class SpectrumAnalyzer: @unchecked Sendable {
    /// Normalised band levels (0…1), one per band, log-spaced 20 Hz–20 kHz.
    /// The only observed property: `SpectrumView` is the one view that reads it.
    private(set) var levels: [Float]

    /// Updated by the engine when the device sample rate changes (for bin→freq).
    @ObservationIgnored var sampleRate: Double = 48_000

    /// 32 bands across 20 Hz–20 kHz: ~1/3 octave each.
    let bandCount = 32
    private static let maxLog2n: vDSP_Length = 13            // 8192-point FFT
    private static let maxFFTSize = 1 << 13
    private static let ringSize = 65_536 // power of two; prevents reader overrun

    private let fftSetup: FFTSetup
    // DSP scratch is ignored: observed arrays would be copied on every
    // inout pass to vDSP, 24 times a second.
    @ObservationIgnored private var fftSize = 0
    @ObservationIgnored private var window: [Float]
    @ObservationIgnored private var windowed: [Float]
    @ObservationIgnored private var realp: [Float]
    @ObservationIgnored private var imagp: [Float]
    @ObservationIgnored private var power: [Float]
    @ObservationIgnored private var smoothed: [Float]

    private let ring: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    @ObservationIgnored private var timer: Timer?

    init() {
        fftSetup = vDSP_create_fftsetup(Self.maxLog2n, FFTRadix(kFFTRadix2))!
        window = []
        windowed = [Float](repeating: 0, count: Self.maxFFTSize)
        realp = [Float](repeating: 0, count: Self.maxFFTSize / 2)
        imagp = [Float](repeating: 0, count: Self.maxFFTSize / 2)
        power = [Float](repeating: 0, count: Self.maxFFTSize / 2)
        smoothed = [Float](repeating: 0, count: bandCount)
        ring = .allocate(capacity: Self.ringSize)
        ring.initialize(repeating: 0, count: Self.ringSize)
        levels = [Float](repeating: 0, count: bandCount)
    }

    deinit {
        timer?.invalidate()
        ring.deinitialize(count: Self.ringSize)
        ring.deallocate()
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Audio thread: copy samples into the ring buffer. No allocation/locks.
    func append(_ samples: UnsafePointer<Float>, count: Int) {
        var w = writeIndex.load(ordering: .relaxed)
        let mask = Self.ringSize - 1
        for i in 0..<count {
            ring[w & mask] = samples[i]
            w &+= 1
        }
        writeIndex.store(w, ordering: .releasing)
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        smoothed = [Float](repeating: 0, count: bandCount)
        levels = [Float](repeating: 0, count: bandCount)
    }

    /// ~23 Hz bins at any rate: 2048 points at 44.1/48 kHz, 8192 at 192 kHz.
    private func configureFFT() {
        let wanted = sampleRate > 96_000 ? 8_192 : (sampleRate > 48_000 ? 4_096 : 2_048)
        guard wanted != fftSize else { return }
        fftSize = wanted
        window = [Float](repeating: 0, count: wanted)
        vDSP_hann_window(&window, vDSP_Length(wanted), Int32(vDSP_HANN_NORM))
    }

    private func tick() {
        configureFFT()
        let n = fftSize
        let half = n / 2
        let log2n = vDSP_Length(n.trailingZeroBitCount)

        let end = writeIndex.load(ordering: .acquiring)
        let mask = Self.ringSize - 1
        for i in 0..<n {
            windowed[i] = ring[(end - n + i) & mask]
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(n))

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))     // |X|²
            }
        }

        // Fold bins into bands. A band narrower than one bin (the lowest ones)
        // takes the bin under its centre.
        let binHz = sampleRate / Double(n)
        let amplitudeScale = 2.0 / Double(n)
        for band in 0..<bandCount {
            let low = 20.0 * pow(1_000.0, Double(band) / Double(bandCount))
            let high = 20.0 * pow(1_000.0, Double(band + 1) / Double(bandCount))
            var first = Int((low / binHz).rounded(.up))
            var last = Int((high / binHz).rounded(.down))
            if last < first {
                first = Int((sqrt(low * high) / binHz).rounded())
                last = first
            }
            first = min(max(first, 1), half - 1)
            last = min(max(last, first), half - 1)
            var sum: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_sve(p.baseAddress! + first, 1, &sum, vDSP_Length(last - first + 1))
            }
            let amplitude = Double(sum).squareRoot() * amplitudeScale
            let db = 20 * log10(amplitude + 1e-7)
            let level = Float(min(max((db + 80) / 80, 0), 1))       // −80…0 dB → 0…1

            // Ballistics: quick attack, slower release, so bars read as music
            // rather than flicker.
            let coefficient: Float = level > smoothed[band] ? 0.6 : 0.18
            smoothed[band] += (level - smoothed[band]) * coefficient
        }
        levels = smoothed
    }
}
