import Foundation
import os

/// Something scheduled that can still be called off.
protocol DakCancelable {
    func cancel()
}

/// The SDK's one worker: everything that reads or changes the client's state
/// runs here, in order, so there is no locking and a change made while a
/// sync runs simply waits for the next round.
protocol DakScheduler: AnyObject {
    func execute(_ task: @escaping () -> Void)
    func schedule(after seconds: TimeInterval, _ task: @escaping () -> Void) -> DakCancelable
}

/// [DakScheduler] on a serial dispatch queue.
final class QueueScheduler: DakScheduler {
    private let queue: DispatchQueue

    init(label: String = "dakpush.worker") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func execute(_ task: @escaping () -> Void) {
        queue.async(execute: task)
    }

    func schedule(after seconds: TimeInterval, _ task: @escaping () -> Void) -> DakCancelable {
        let item = DispatchWorkItem(block: task)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return DispatchItem(item: item)
    }
}

/// [DakScheduler] on the main queue: where the in-app messages live, next to
/// UIKit.
final class MainQueueScheduler: DakScheduler {
    func execute(_ task: @escaping () -> Void) {
        DispatchQueue.main.async(execute: task)
    }

    func schedule(after seconds: TimeInterval, _ task: @escaping () -> Void) -> DakCancelable {
        let item = DispatchWorkItem(block: task)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return DispatchItem(item: item)
    }
}

private struct DispatchItem: DakCancelable {
    let item: DispatchWorkItem
    func cancel() { item.cancel() }
}

/// Logs to the unified log (subsystem "dakpush"): debug lines only with
/// DakOptions(debugLogs), warnings always.
final class DakLog: @unchecked Sendable {
    enum Level { case debug, warning }

    private let debug: Bool
    private let sink: (Level, String) -> Void

    init(debug: Bool, sink: ((Level, String) -> Void)? = nil) {
        self.debug = debug
        self.sink =
            sink ?? { level, message in
                switch level {
                case .debug: DakLog.logger.debug("\(message, privacy: .public)")
                case .warning: DakLog.logger.warning("\(message, privacy: .public)")
                }
            }
    }

    static let logger = Logger(subsystem: "dakpush", category: "sdk")

    func d(_ message: @autoclosure () -> String) {
        if debug { sink(.debug, message()) }
    }

    /// Setup mistakes and failures the developer should see.
    func w(_ message: String) {
        sink(.warning, message)
    }
}

/// A value read from any thread, written by the worker.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { update { $0 } }
        set { update { $0 = newValue } }
    }

    // NSLock.withLock needs iOS 16.
    @discardableResult
    func update<T>(_ change: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return change(&stored)
    }
}

/// The server counts lengths in UTF-8 bytes.
func utf8Length(_ s: String) -> Int { s.utf8.count }

/// [s] cut to at most [max] UTF-8 bytes, never inside a character (an
/// emoji made of several code points included).
func clampUtf8(_ s: String, _ max: Int) -> String {
    if utf8Length(s) <= max { return s }
    var out = ""
    var used = 0
    for ch in s {
        let n = ch.utf8.count
        if used + n > max { break }
        out.append(ch)
        used += n
    }
    return out
}

/// Lower-case hex of [data]: how APNs device tokens travel.
func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
