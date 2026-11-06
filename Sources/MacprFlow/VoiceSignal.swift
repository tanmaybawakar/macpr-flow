import Foundation
import Synchronization

/// Voice level and three frequency bands, measured on the real-time audio thread every I/O cycle (~10 ms).
///
/// Lock-free and allocation-free: the audio thread writes float bits into atomics, the orb reads them each frame.
final class VoiceSignal: Sendable {
    private let level = Atomic<UInt32>(0)
    private let low = Atomic<UInt32>(0)
    private let mid = Atomic<UInt32>(0)
    private let high = Atomic<UInt32>(0)
    private let filter = Mutex(Filter())

    private struct Filter {
        var sampleRate: Float = 0
        var a1: Float = 0, a2: Float = 0
        var lp1: Float = 0, lp2: Float = 0
    }

    struct Frame { var level: Float = 0, low: Float = 0, mid: Float = 0, high: Float = 0 }

    func read() -> Frame {
        Frame(level: Float(bitPattern: level.load(ordering: .relaxed)),
              low: Float(bitPattern: low.load(ordering: .relaxed)),
              mid: Float(bitPattern: mid.load(ordering: .relaxed)),
              high: Float(bitPattern: high.load(ordering: .relaxed)))
    }

    func reset() {
        level.store(0, ordering: .relaxed); low.store(0, ordering: .relaxed)
        mid.store(0, ordering: .relaxed); high.store(0, ordering: .relaxed)
    }

    /// Called from the audio I/O thread with one channel of samples.
    func process(_ samples: UnsafePointer<Float>, count: Int, stride: Int, sampleRate: Float) {
        guard count > 0 else { return }
        var sum: Float = 0, sumLow: Float = 0, sumMid: Float = 0, sumHigh: Float = 0
        filter.withLock { f in
            if f.sampleRate != sampleRate {
                f.sampleRate = sampleRate
                f.a1 = 1 - exp(-2 * .pi * 320 / sampleRate)
                f.a2 = 1 - exp(-2 * .pi * 2200 / sampleRate)
            }
            for i in 0..<count {
                let x = samples[i * stride]
                f.lp1 += (x - f.lp1) * f.a1
                f.lp2 += (x - f.lp2) * f.a2
                let l = f.lp1, m = f.lp2 - f.lp1, h = x - f.lp2
                sum += x * x; sumLow += l * l; sumMid += m * m; sumHigh += h * h
            }
        }
        let n = Float(count)
        level.store(Self.scale(sum / n, floor: -54, range: 44).bitPattern, ordering: .relaxed)
        low.store(Self.scale(sumLow / n, floor: -58, range: 44).bitPattern, ordering: .relaxed)
        mid.store(Self.scale(sumMid / n, floor: -58, range: 42).bitPattern, ordering: .relaxed)
        high.store(Self.scale(sumHigh / n, floor: -64, range: 40).bitPattern, ordering: .relaxed)
    }

    /// Mean square → 0…1 on a decibel scale, so a whisper and a shout both read.
    private static func scale(_ meanSquare: Float, floor: Float, range: Float) -> Float {
        let db = 10 * log10(max(meanSquare, 1e-12))
        return min(1, max(0, (db - floor) / range))
    }
}
