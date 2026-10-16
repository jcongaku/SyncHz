import Foundation

/// Keeps a profile's frequency response the same at every sample rate.
///
/// PEQ generators such as AutoEq fit their (Fc, gain, Q) values against the
/// *digital* RBJ response at one design rate, bilinear-transform cramping near
/// Nyquist included. Reusing the same three numbers at another rate moves the
/// curve: a typical preset fitted at 44.1 kHz is off by ~1 dB below 10 kHz and
/// ~2 dB around 17 kHz when played at 96–192 kHz. SyncHz follows every track's
/// sample rate, so without correction the same preset would sound different
/// from one track to the next.
///
/// Each band is therefore re-fitted at the playback rate to that band's own
/// design-rate magnitude over 20 Hz – 20 kHz (the cascade's dB response is the
/// sum of the bands', so matching bands matches the whole). Three candidates
/// are compared and the closest is used:
///
/// 1. the unchanged parameters (exact when the rates match; fine for low bands),
/// 2. an RBJ re-fit of (Fc, gain, Q),
/// 3. a general stable, minimum-phase second-order section, which can also
///    reproduce the asymmetric squeeze of bands whose skirts reach Nyquist —
///    including wide (Q < 0.5) bands, whose roots are real.
///
/// Some bands cannot be reproduced by any single section: a wide, deep cut
/// fitted at 48 kHz is pulled back toward 0 dB as it nears 24 kHz, and no
/// one biquad at 96 kHz follows that within 1.6 dB (checked with 40 random
/// restarts). When the best single section is still off by more than
/// `splitThresholdDB` and the processor has spare sections, the band is fitted
/// as two cascaded sections instead, which matches it essentially exactly.
///
/// Measured against an independent reference: a realistic 44.1 kHz AutoEq
/// preset stays within ≈0.04 dB at 96 and 192 kHz (vs ~1.9 dB unmatched), and
/// five real peqdb presets (48 kHz) within ≈0.04 dB (vs up to 4.3 dB).
enum PEQRateMatcher {
    /// Sections for `band` at `playbackRate` that reproduce its response at
    /// `designRate`: usually one; two when one cannot and `maxSections` ≥ 2.
    static func sections(for band: PEQBand,
                         designRate: Double,
                         playbackRate: Double,
                         maxSections: Int = 2) -> [BiquadCoefficients] {
        let direct = BiquadCoefficients(band: band, sampleRate: playbackRate)
        guard designRate.isFinite, designRate > 0,
              abs(designRate - playbackRate) >= 0.5,
              abs(band.gainDB) >= 0.001 else {
            return [direct]
        }

        let key = CacheKey(band: band, designRate: designRate,
                           playbackRate: playbackRate, maxSections: maxSections)
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let result = match(band: band, designRate: designRate, playbackRate: playbackRate,
                           maxSections: maxSections, direct: direct)
        cache.withLock { storage in
            if storage.count > 512 { storage.removeAll(keepingCapacity: true) }
            storage[key] = result.sections
        }
        return result.sections
    }

    /// The fitted sections plus the worst-case magnitude error (dB) over the
    /// matching grid. Exposed for tests.
    static func match(band: PEQBand,
                      designRate: Double,
                      playbackRate: Double,
                      maxSections: Int = 2) -> (sections: [BiquadCoefficients], maxErrorDB: Double) {
        match(band: band, designRate: designRate, playbackRate: playbackRate,
              maxSections: maxSections,
              direct: BiquadCoefficients(band: band, sampleRate: playbackRate))
    }

    // MARK: - Fitting

    /// Errors below this are inaudible and not worth fitting for.
    private static let goodEnoughDB = 0.005
    /// A single section further off than this gets a second one, if allowed.
    private static let splitThresholdDB = 0.1

    private static func match(band: PEQBand,
                              designRate: Double,
                              playbackRate: Double,
                              maxSections: Int,
                              direct: BiquadCoefficients) -> (sections: [BiquadCoefficients], maxErrorDB: Double) {
        let grid = matchingGrid(designRate: designRate, playbackRate: playbackRate)
        let designCoefficients = BiquadCoefficients(band: band, sampleRate: designRate)
        let target = grid.map { decibels(designCoefficients, $0, designRate) }

        let single = bestSingleSection(band: band, grid: grid, target: target,
                                       playbackRate: playbackRate, direct: direct)
        guard single.maxErrorDB > splitThresholdDB, maxSections >= 2 else {
            return ([single.coefficients], single.maxErrorDB)
        }

        // Two sections, each started as half the band.
        var half = band
        half.gainDB /= 2
        guard let halfStart = StableSection.parameters(from: BiquadCoefficients(band: half, sampleRate: playbackRate)) else {
            return ([single.coefficients], single.maxErrorDB)
        }
        let pairFit = LevenbergMarquardt.minimize(
            start: halfStart + halfStart,
            lower: [Double](repeating: -80, count: 10),
            upper: [Double](repeating: 80, count: 10)) { x in
                let first = StableSection.coefficients(Array(x[0..<5]))
                let second = StableSection.coefficients(Array(x[5..<10]))
                return zip(grid, target).map {
                    decibels(first, $0.0, playbackRate) + decibels(second, $0.0, playbackRate) - $0.1
                }
            }
        let pair = [StableSection.coefficients(Array(pairFit[0..<5])),
                    StableSection.coefficients(Array(pairFit[5..<10]))]
        let pairError = zip(grid, target).reduce(0.0) { worst, point in
            let response = pair.reduce(0) { $0 + decibels($1, point.0, playbackRate) }
            return max(worst, abs(response - point.1))
        }
        return pairError < single.maxErrorDB ? (pair, pairError) : ([single.coefficients], single.maxErrorDB)
    }

    private static func bestSingleSection(band: PEQBand,
                                          grid: [Double],
                                          target: [Double],
                                          playbackRate: Double,
                                          direct: BiquadCoefficients) -> (coefficients: BiquadCoefficients, maxErrorDB: Double) {
        var best = (coefficients: direct, maxErrorDB: maxError(direct, grid, target, playbackRate))
        guard best.maxErrorDB > goodEnoughDB else { return best }

        // 2. RBJ re-fit in (log Fc, gain, log Q).
        let nyquistGuard = 0.49 * playbackRate
        let x0 = [log(min(band.frequency, nyquistGuard * 0.99)), band.gainDB, log(max(band.q, 0.02))]
        let rbjFit = LevenbergMarquardt.minimize(
            start: x0,
            lower: [log(5), -60, log(0.02)],
            upper: [log(nyquistGuard), 60, log(80)]) { x in
                let fitted = rbjCoefficients(band.type, x, playbackRate)
                return zip(grid, target).map { decibels(fitted, $0.0, playbackRate) - $0.1 }
            }
        let rbj = rbjCoefficients(band.type, rbjFit, playbackRate)
        let rbjError = maxError(rbj, grid, target, playbackRate)
        if rbjError < best.maxErrorDB { best = (rbj, rbjError) }
        guard best.maxErrorDB > goodEnoughDB else { return best }

        // 3. General section, started from the RBJ re-fit.
        if let start = StableSection.parameters(from: rbj) {
            let generalFit = LevenbergMarquardt.minimize(
                start: start,
                lower: [-80, -30, -30, -30, -30],
                upper: [80, 30, 30, 30, 30]) { x in
                    let fitted = StableSection.coefficients(x)
                    return zip(grid, target).map { decibels(fitted, $0.0, playbackRate) - $0.1 }
                }
            let general = StableSection.coefficients(generalFit)
            let generalError = maxError(general, grid, target, playbackRate)
            if generalError < best.maxErrorDB { best = (general, generalError) }
        }
        return best
    }

    /// Log-spaced from 20 Hz to the top of the band both rates can represent.
    private static func matchingGrid(designRate: Double, playbackRate: Double) -> [Double] {
        let upper = min(20_000, 0.49 * min(designRate, playbackRate))
        let count = 160
        let logLow = log10(20.0), logHigh = log10(upper)
        return (0..<count).map { pow(10, logLow + (logHigh - logLow) * Double($0) / Double(count - 1)) }
    }

    private static func rbjCoefficients(_ type: PEQFilterType, _ x: [Double], _ rate: Double) -> BiquadCoefficients {
        BiquadCoefficients(band: PEQBand(type: type, frequency: exp(x[0]), gainDB: x[1], q: exp(x[2])),
                           sampleRate: rate)
    }

    @inline(__always)
    private static func decibels(_ c: BiquadCoefficients, _ frequency: Double, _ rate: Double) -> Double {
        20 * log10(max(c.magnitude(atFrequency: frequency, sampleRate: rate), 1e-12))
    }

    private static func maxError(_ c: BiquadCoefficients, _ grid: [Double], _ target: [Double],
                                 _ rate: Double) -> Double {
        zip(grid, target).reduce(0) { max($0, abs(decibels(c, $1.0, rate) - $1.1)) }
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let type: PEQFilterType
        let frequency: Double
        let gainDB: Double
        let q: Double
        let designRate: Double
        let playbackRate: Double
        let maxSections: Int

        init(band: PEQBand, designRate: Double, playbackRate: Double, maxSections: Int) {
            type = band.type
            frequency = band.frequency
            gainDB = band.gainDB
            q = band.q
            self.designRate = designRate
            self.playbackRate = playbackRate
            self.maxSections = maxSections
        }
    }

    private static let cache = LockedCache()

    private final class LockedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CacheKey: [BiquadCoefficients]] = [:]

        func withLock<T>(_ body: (inout [CacheKey: [BiquadCoefficients]]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }
}

/// A second-order section parametrised so that every parameter value is a
/// stable, minimum-phase filter: each quadratic z² + c1·z + c2 is written as
/// c2 = tanh(u), c1 = (1 + c2)·tanh(v). That maps all of ℝ² onto the open
/// stability triangle (|c2| < 1, |c1| < 1 + c2), so roots stay inside the unit
/// circle whether they are a complex pair or two real roots.
private enum StableSection {
    /// [gain dB, u_num, v_num, u_den, v_den], or nil if `c` is not stable and
    /// minimum-phase to begin with.
    static func parameters(from c: BiquadCoefficients) -> [Double]? {
        guard c.b0 > 0,
              let numerator = encode(c.b1 / c.b0, c.b2 / c.b0),
              let denominator = encode(c.a1, c.a2) else { return nil }
        return [20 * log10(c.b0), numerator.u, numerator.v, denominator.u, denominator.v]
    }

    static func coefficients(_ p: [Double]) -> BiquadCoefficients {
        let k = pow(10, p[0] / 20)
        let numerator = decode(p[1], p[2])
        let denominator = decode(p[3], p[4])
        return BiquadCoefficients(b0: k, b1: k * numerator.c1, b2: k * numerator.c2,
                                  a1: denominator.c1, a2: denominator.c2)
    }

    private static func encode(_ c1: Double, _ c2: Double) -> (u: Double, v: Double)? {
        guard abs(c2) < 1, abs(c1) < 1 + c2 else { return nil }
        let limit = 1 - 1e-12
        return (atanh(min(max(c2, -limit), limit)),
                atanh(min(max(c1 / (1 + c2), -limit), limit)))
    }

    private static func decode(_ u: Double, _ v: Double) -> (c1: Double, c2: Double) {
        let c2 = tanh(u)
        return ((1 + c2) * tanh(v), c2)
    }
}

/// Small dense Levenberg–Marquardt least-squares solver with box bounds, for
/// the 3–5 parameter band fits above. Runs on the control queue, never on the
/// audio thread.
enum LevenbergMarquardt {
    static func minimize(start: [Double],
                         lower: [Double],
                         upper: [Double],
                         maxIterations: Int = 120,
                         residuals: ([Double]) -> [Double]) -> [Double] {
        let n = start.count
        func clamp(_ x: [Double]) -> [Double] {
            (0..<n).map { min(max(x[$0], lower[$0]), upper[$0]) }
        }
        func cost(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }

        var x = clamp(start)
        var r = residuals(x)
        var currentCost = cost(r)
        var lambda = 1e-3

        for _ in 0..<maxIterations {
            // Forward-difference Jacobian.
            var jacobian = [[Double]](repeating: [], count: n)
            for j in 0..<n {
                var probe = x
                let step = 1e-6 * max(1, abs(x[j]))
                probe[j] += step
                if probe[j] > upper[j] { probe[j] = x[j] - step }
                let delta = probe[j] - x[j]
                let rp = residuals(probe)
                jacobian[j] = zip(rp, r).map { ($0 - $1) / delta }
            }

            // Normal equations: (JᵀJ + λ·diag(JᵀJ)) δ = −Jᵀr.
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var jtr = [Double](repeating: 0, count: n)
            for a in 0..<n {
                for b in a..<n {
                    let value = zip(jacobian[a], jacobian[b]).reduce(0) { $0 + $1.0 * $1.1 }
                    jtj[a][b] = value
                    jtj[b][a] = value
                }
                jtr[a] = zip(jacobian[a], r).reduce(0) { $0 + $1.0 * $1.1 }
            }

            var improved = false
            for _ in 0..<12 {
                var system = jtj
                for d in 0..<n { system[d][d] += lambda * max(jtj[d][d], 1e-12) }
                guard let step = solve(system, jtr.map { -$0 }) else { lambda *= 4; continue }
                let candidate = clamp(zip(x, step).map { $0 + $1 })
                let candidateResiduals = residuals(candidate)
                let candidateCost = cost(candidateResiduals)
                if candidateCost.isFinite, candidateCost < currentCost {
                    let relative = (currentCost - candidateCost) / max(currentCost, 1e-300)
                    x = candidate
                    r = candidateResiduals
                    currentCost = candidateCost
                    lambda = max(lambda / 3, 1e-12)
                    improved = true
                    if relative < 1e-10 { return x }
                    break
                }
                lambda *= 4
            }
            if !improved { break }
        }
        return x
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-300 else { return nil }
            a.swapAt(column, pivot)
            b.swapAt(column, pivot)
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let sum = ((row + 1)..<n).reduce(0) { $0 + a[row][$1] * x[$1] }
            x[row] = (b[row] - sum) / a[row][row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}
