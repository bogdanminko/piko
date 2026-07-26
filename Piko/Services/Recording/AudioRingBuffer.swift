import Darwin
import Foundation

/// Single-producer / single-consumer float ring buffer between a realtime
/// audio callback and the disk writer.
///
/// The producer side runs on a Core Audio IOProc / AVAudioEngine tap, so the
/// critical section does nothing but two memcpys — no allocation, no I/O, no
/// Swift runtime calls that could block. Overflow drops the newest samples and
/// counts them; that only happens if the consumer stalls for seconds.
final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var readIndex = 0
    private var filled = 0
    private var dropped = 0

    /// - Parameter capacity: in frames. 48 kHz × 4 s is a generous cushion for
    ///   a consumer that drains every 100 ms.
    init(capacity: Int = 48_000 * 4) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Producer side — safe to call from a realtime audio thread.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        let free = capacity - filled
        if count > free {
            dropped += count - free
        }
        let toWrite = min(count, free)
        if toWrite > 0 {
            let writeIndex = (readIndex + filled) % capacity
            let firstChunk = min(toWrite, capacity - writeIndex)
            (storage + writeIndex).update(from: samples, count: firstChunk)
            if firstChunk < toWrite {
                storage.update(from: samples + firstChunk, count: toWrite - firstChunk)
            }
            filled += toWrite
        }
        os_unfair_lock_unlock(lock)
    }

    /// Consumer side — returns everything buffered since the last drain.
    func drain() -> [Float] {
        os_unfair_lock_lock(lock)
        let count = filled
        guard count > 0 else {
            os_unfair_lock_unlock(lock)
            return []
        }
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            let firstChunk = min(count, capacity - readIndex)
            base.update(from: storage + readIndex, count: firstChunk)
            if firstChunk < count {
                (base + firstChunk).update(from: storage, count: count - firstChunk)
            }
        }
        readIndex = (readIndex + count) % capacity
        filled -= count
        os_unfair_lock_unlock(lock)
        return out
    }

    /// Frames lost to overflow so far (diagnostics only).
    var droppedFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return dropped
    }
}
