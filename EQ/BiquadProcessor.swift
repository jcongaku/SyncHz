import Foundation
import Accelerate
import Synchronization

/// Real-time-safe stereo biquad cascade, processed in blocks with Accelerate.
///
/// Each bank is one `vDSP_biquadD` call per block: the whole cascade in double
/// precision (direct form I), which Accelerate pipelines across sections — on
/// Apple Silicon about 6× faster than running the sections one by one with
/// `vDSP_deq22D` (measured), and ~17× faster than the previous per-sample
/// loop. Double precision is not optional: in single precision, low-frequency
/// or high-Q sections at 96–192 kHz have poles so close to z = 1 that
/// `vDSP.Biquad<Float>` measured only −11 dB of signal-to-error on a real
/// preset, against −188 dB in double.
///
/// A double-precision vDSP setup can't have its coefficients changed in place,
/// so every configuration gets a new one, handed over RCU-style: the control
/// queue builds it (allocating there) and publishes it with an atomic pointer
/// exchange; the audio thread takes it with another exchange and puts the
/// configuration it replaced in a lock-free retired list, which only the
/// control queue frees. The audio thread therefore never allocates, frees,
/// retains, or locks. Filter histories live in our own preallocated buffer —
/// exactly vDSP's `Delay` layout — so the crossfade between banks, per-channel
/// state, and resets stay under our control. Parameter changes crossfade two
/// complete cascades over 20 ms; rapid edits coalesce to the newest one.
final class BiquadProcessor {
    static let maximumSections = PEQConstraints.maximumBands
    static let maximumChannels = 2
    /// Largest block processed in one pass; longer renders are split.
    static let blockFrames = 1_024

    /// Per bank and channel: the cascade input's history, then each section's
    /// output history — vDSP_biquadD's `Delay` array (2·S + 2 values).
    private static let historySlots = maximumSections + 1
    private static let retiredCapacity = 8

    /// One bank's cascade. Built and freed only on the control queue; owned by
    /// exactly one side at a time.
    private struct Configuration {
        var setup: vDSP_biquad_SetupD?     // nil for an empty cascade
        var sectionCount: Int
        var preamp: Double
        var sampleRate: Double
    }

    // MARK: Control-thread <-> audio-thread handoff

    /// Newest configuration the audio thread hasn't taken yet (pointer bits, 0 = none).
    private let incoming = Atomic<UInt>(0)
    /// Configurations the audio thread replaced, waiting for the control queue to free.
    private let retired: UnsafeMutablePointer<Atomic<UInt>>
    private let requestedWet = Atomic<UInt64>(0)
    private let requestedResetEpoch = Atomic<UInt64>(0)
    private let clippingEpoch = Atomic<UInt64>(0)

    // MARK: Audio-thread-owned state

    private var bankConfigurations: (UnsafeMutablePointer<Configuration>?,
                                     UnsafeMutablePointer<Configuration>?) = (nil, nil)
    /// [bank][channel][slot][x(n-2), x(n-1)].
    private let history: UnsafeMutablePointer<Double>

    // Block scratch, `blockFrames + 2` long each.
    private let dry: UnsafeMutablePointer<Double>
    private let ping: UnsafeMutablePointer<Double>
    private let pong: UnsafeMutablePointer<Double>
    private let fromWet: UnsafeMutablePointer<Double>
    private let toWet: UnsafeMutablePointer<Double>
    private let ramp: UnsafeMutablePointer<Double>
    private let mixed: UnsafeMutablePointer<Double>

    private var activeBank = 0
    private var transitionFromBank = 0
    private var transitionToBank = 1
    private var transitionPosition = 0
    private var transitionFrames = 0
    private var renderTransitionStart = 0
    private var hasConfiguration = false
    private var consumedResetEpoch: UInt64 = 0

    private var wetMix = 0.0
    private var wetRampStart = 0.0
    private var wetRampTarget = 0.0
    private var wetRampPosition = 0
    private var wetRampFrames = 1
    private var renderWetRampStart = 0
    private var renderClipped = false

    init() {
        retired = .allocate(capacity: Self.retiredCapacity)
        for index in 0..<Self.retiredCapacity {
            retired.advanced(by: index).initialize(to: Atomic(0))
        }

        let historyCount = 2 * Self.maximumChannels * Self.historySlots * 2
        history = .allocate(capacity: historyCount)
        history.initialize(repeating: 0, count: historyCount)

        let scratch = Self.blockFrames + 2
        func buffer() -> UnsafeMutablePointer<Double> {
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: scratch)
            pointer.initialize(repeating: 0, count: scratch)
            return pointer
        }
        dry = buffer()
        ping = buffer()
        pong = buffer()
        fromWet = buffer()
        toWet = buffer()
        ramp = buffer()
        mixed = buffer()
    }

    deinit {
        // No render can be running any more: everything is ours to free.
        Self.destroy(Self.pointer(incoming.exchange(0, ordering: .acquiring)))
        Self.destroy(bankConfigurations.0)
        Self.destroy(bankConfigurations.1)
        freeRetired()
        for index in 0..<Self.retiredCapacity {
            retired.advanced(by: index).deinitialize(count: 1)
        }
        retired.deallocate()
        history.deallocate()
        for pointer in [dry, ping, pong, fromWet, toWet, ramp, mixed] {
            pointer.deallocate()
        }
    }

    // MARK: Control queue

    /// Publishes a new cascade. Call from one control queue only (it is the
    /// sole consumer of the retired list).
    func setSections(_ newCoefficients: [BiquadCoefficients],
                     preampDB: Double,
                     sampleRate: Double) {
        freeRetired()

        let sections = Array(newCoefficients.prefix(Self.maximumSections))
        let flat = sections.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
        let preamp = pow(10, preampDB / 20)
        let configuration = UnsafeMutablePointer<Configuration>.allocate(capacity: 1)
        configuration.initialize(to: Configuration(
            setup: sections.isEmpty ? nil : vDSP_biquad_CreateSetupD(flat, vDSP_Length(sections.count)),
            sectionCount: sections.count,
            preamp: preamp.isFinite ? preamp : 1,
            sampleRate: sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000))
        if configuration.pointee.setup == nil { configuration.pointee.sectionCount = 0 }

        // Release: the audio thread's acquiring exchange sees a complete value.
        let unconsumed = incoming.exchange(UInt(bitPattern: configuration), ordering: .acquiringAndReleasing)
        // Replaced before the audio thread ever took it, so it is still ours.
        Self.destroy(Self.pointer(unconsumed))
    }

    func setActive(_ active: Bool) {
        requestedWet.store(active ? 1 : 0, ordering: .releasing)
    }

    func requestReset() {
        let next = requestedResetEpoch.load(ordering: .relaxed) &+ 1
        requestedResetEpoch.store(next, ordering: .releasing)
    }

    func clippingEventCount() -> UInt64 {
        clippingEpoch.load(ordering: .acquiring)
    }

    // MARK: Audio render thread

    /// Call once per render cycle, before `process` for each channel.
    func beginRender(frameCount: Int) {
        renderClipped = false

        let resetEpoch = requestedResetEpoch.load(ordering: .acquiring)
        if resetEpoch != consumedResetEpoch {
            clearAllHistory()
            consumedResetEpoch = resetEpoch
        }

        if transitionFrames == 0 {
            let destination = hasConfiguration ? 1 - activeBank : activeBank
            if takeIncomingConfiguration(into: destination) {
                clearHistory(for: destination)
                if hasConfiguration {
                    transitionFromBank = activeBank
                    transitionToBank = destination
                    transitionPosition = 0
                    transitionFrames = max(64, Int(sampleRate(of: destination) * 0.020))
                } else {
                    activeBank = destination
                    hasConfiguration = true
                }
            }
        }
        renderTransitionStart = transitionPosition

        let newWetTarget = requestedWet.load(ordering: .acquiring) == 0 ? 0.0 : 1.0
        if newWetTarget != wetRampTarget {
            wetMix = currentWetMix()
            wetRampStart = wetMix
            wetRampTarget = newWetTarget
            wetRampPosition = 0
            wetRampFrames = max(32, Int(sampleRate(of: activeBank) * 0.005))
        }
        renderWetRampStart = wetRampPosition
    }

    /// Processes `frameCount` frames of one channel. `input` is contiguous;
    /// `output` may be strided (interleaved device buffers). `frameOffset` is
    /// where this span starts within the current render cycle, so ramps line
    /// up across channels and across spans.
    func process(channel: Int,
                 input: UnsafePointer<Float>,
                 output: UnsafeMutablePointer<Float>,
                 outputStride: Int = 1,
                 frameOffset: Int = 0,
                 frameCount: Int) {
        var done = 0
        while done < frameCount {
            let count = min(Self.blockFrames, frameCount - done)
            processBlock(channel: channel,
                         input: input + done,
                         output: output + done * outputStride,
                         outputStride: outputStride,
                         frameOffset: frameOffset + done,
                         count: count)
            done += count
        }
    }

    /// Call once per render cycle, after every channel was processed.
    func endRender(frameCount: Int) {
        if transitionFrames > 0 {
            transitionPosition += frameCount
            if transitionPosition >= transitionFrames {
                activeBank = transitionToBank
                transitionPosition = 0
                transitionFrames = 0
            }
        }

        if wetRampPosition < wetRampFrames {
            wetRampPosition = min(wetRampFrames, wetRampPosition + frameCount)
            wetMix = currentWetMix()
        }

        if renderClipped {
            let next = clippingEpoch.load(ordering: .relaxed) &+ 1
            clippingEpoch.store(next, ordering: .releasing)
        }
    }

    // MARK: Block processing

    private func processBlock(channel: Int,
                              input: UnsafePointer<Float>,
                              output: UnsafeMutablePointer<Float>,
                              outputStride: Int,
                              frameOffset: Int,
                              count: Int) {
        let n = vDSP_Length(count)
        guard channel >= 0, channel < Self.maximumChannels else {
            // Unknown channel: pass through, clamped.
            vDSP_vspdp(input, 1, mixed, 1, n)
            protectAndStore(mixed, to: output, stride: outputStride, count: count)
            return
        }

        vDSP_vspdp(input, 1, dry, 1, n)

        // Wet signal: one cascade, or both while crossfading between banks.
        let wet: UnsafeMutablePointer<Double>
        if transitionFrames > 0 {
            runCascade(bank: transitionFromBank, channel: channel, count: count, into: fromWet)
            runCascade(bank: transitionToBank, channel: channel, count: count, into: toWet)
            let start = renderTransitionStart + frameOffset
            for index in 0..<count {
                ramp[index] = smoothstep(Double(start + index + 1) / Double(transitionFrames))
            }
            blend(from: fromWet, to: toWet, by: ramp, into: fromWet, count: count)
            wet = fromWet
        } else {
            runCascade(bank: activeBank, channel: channel, count: count, into: fromWet)
            wet = fromWet
        }

        // Dry/wet ramp for enabling and bypassing.
        let rampStart = renderWetRampStart + frameOffset
        if rampStart >= wetRampFrames, wetRampTarget == 1 {
            protectAndStore(wet, to: output, stride: outputStride, count: count)
        } else if rampStart >= wetRampFrames, wetRampTarget == 0 {
            protectAndStore(dry, to: output, stride: outputStride, count: count)
        } else {
            for index in 0..<count {
                ramp[index] = wetMix(at: rampStart + index)
            }
            blend(from: dry, to: wet, by: ramp, into: mixed, count: count)
            protectAndStore(mixed, to: output, stride: outputStride, count: count)
        }
    }

    /// Runs `dry` through one bank's preamp and cascade for `channel`, leaving
    /// the result in `destination[0..<count]`.
    private func runCascade(bank: Int, channel: Int, count: Int,
                            into destination: UnsafeMutablePointer<Double>) {
        let n = vDSP_Length(count)
        guard let configuration = bank == 0 ? bankConfigurations.0 : bankConfigurations.1 else {
            destination.update(from: dry, count: count)
            return
        }
        var preamp = configuration.pointee.preamp
        guard let setup = configuration.pointee.setup else {
            vDSP_vsmulD(dry, 1, &preamp, destination, 1, n)
            return
        }
        vDSP_vsmulD(dry, 1, &preamp, ping, 1, n)
        let delay = history + ((bank * Self.maximumChannels + channel) * Self.historySlots) * 2
        vDSP_biquadD(setup, delay, ping, 1, destination, 1, n)
    }

    /// destination = from + (to − from) · weight, element-wise. `destination`
    /// may alias `from`.
    private func blend(from: UnsafeMutablePointer<Double>, to: UnsafeMutablePointer<Double>,
                       by weight: UnsafeMutablePointer<Double>,
                       into destination: UnsafeMutablePointer<Double>, count: Int) {
        let n = vDSP_Length(count)
        vDSP_vsubD(from, 1, to, 1, pong, 1, n)                  // pong = to − from
        vDSP_vmaD(pong, 1, weight, 1, from, 1, destination, 1, n)
    }

    /// Clamps to full scale (flagging a clip), recovers from a non-finite
    /// block, and converts to the device's Float samples.
    private func protectAndStore(_ samples: UnsafeMutablePointer<Double>,
                                 to output: UnsafeMutablePointer<Float>,
                                 stride: Int, count: Int) {
        let n = vDSP_Length(count)
        var sum = 0.0
        vDSP_sveD(samples, 1, &sum, n)
        if !sum.isFinite {
            // A NaN/Inf would otherwise live on in the filter histories.
            vDSP_vclrD(samples, 1, n)
            clearAllHistory()
            renderClipped = true
        } else {
            var peak = 0.0
            vDSP_maxmgvD(samples, 1, &peak, n)
            if peak > 1 {
                var low = -1.0, high = 1.0
                vDSP_vclipD(samples, 1, &low, &high, samples, 1, n)
                renderClipped = true
            }
        }
        vDSP_vdpsp(samples, 1, output, vDSP_Stride(stride), n)
    }

    // MARK: Configuration handoff

    /// Audio thread: takes the newest published cascade into `bank`, retiring
    /// what was there. Skips (and retries next cycle) if the retired list is
    /// full, so nothing is ever freed here.
    private func takeIncomingConfiguration(into bank: Int) -> Bool {
        guard incoming.load(ordering: .acquiring) != 0 else { return false }
        let previous = bank == 0 ? bankConfigurations.0 : bankConfigurations.1
        if let previous, !retire(previous) { return false }
        // Only this thread ever clears `incoming`, so it is still non-zero.
        let taken = Self.pointer(incoming.exchange(0, ordering: .acquiringAndReleasing))
        if bank == 0 { bankConfigurations.0 = taken } else { bankConfigurations.1 = taken }
        return taken != nil
    }

    private func retire(_ configuration: UnsafeMutablePointer<Configuration>) -> Bool {
        let bits = UInt(bitPattern: configuration)
        for index in 0..<Self.retiredCapacity {
            if retired[index].compareExchange(expected: 0, desired: bits,
                                              ordering: .acquiringAndReleasing).exchanged {
                return true
            }
        }
        return false
    }

    /// Control queue: frees configurations the audio thread has let go of.
    private func freeRetired() {
        for index in 0..<Self.retiredCapacity {
            Self.destroy(Self.pointer(retired[index].exchange(0, ordering: .acquiringAndReleasing)))
        }
    }

    private static func pointer(_ bits: UInt) -> UnsafeMutablePointer<Configuration>? {
        UnsafeMutablePointer<Configuration>(bitPattern: bits)
    }

    private static func destroy(_ configuration: UnsafeMutablePointer<Configuration>?) {
        guard let configuration else { return }
        if let setup = configuration.pointee.setup { vDSP_biquad_DestroySetupD(setup) }
        configuration.deinitialize(count: 1)
        configuration.deallocate()
    }

    // MARK: Helpers

    private func sampleRate(of bank: Int) -> Double {
        (bank == 0 ? bankConfigurations.0 : bankConfigurations.1)?.pointee.sampleRate ?? 48_000
    }

    @inline(__always)
    private func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    private func wetMix(at position: Int) -> Double {
        guard position < wetRampFrames else { return wetRampTarget }
        let progress = Double(position + 1) / Double(wetRampFrames)
        return wetRampStart + (wetRampTarget - wetRampStart) * smoothstep(progress)
    }

    private func currentWetMix() -> Double {
        wetMix(at: wetRampPosition)
    }

    private func clearHistory(for bank: Int) {
        let span = Self.maximumChannels * Self.historySlots * 2
        (history + bank * span).update(repeating: 0, count: span)
    }

    private func clearAllHistory() {
        history.update(repeating: 0, count: 2 * Self.maximumChannels * Self.historySlots * 2)
    }
}
