import Foundation

/// A listener that was added.
public final class DakSubscription: @unchecked Sendable {
    private let onRemove: Locked<(() -> Void)?>

    init(_ onRemove: @escaping () -> Void) {
        self.onRemove = Locked(onRemove)
    }

    /// Stops the listener. Later calls do nothing.
    public func remove() {
        onRemove.update { f -> (() -> Void)? in
            let g = f
            f = nil
            return g
        }?()
    }
}

/// Listeners in the order they were added; each call runs on the main queue.
final class DakListeners<Listener>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(id: UInt64, listener: Listener)] = []
    private var next: UInt64 = 0

    func add(_ listener: Listener) -> DakSubscription {
        lock.lock()
        next += 1
        let id = next
        items.append((id, listener))
        lock.unlock()
        return DakSubscription { [weak self] in self?.remove(id) }
    }

    var all: [Listener] {
        lock.lock()
        defer { lock.unlock() }
        return items.map(\.listener)
    }

    var isEmpty: Bool { all.isEmpty }

    private func remove(_ id: UInt64) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
    }
}

/// Taps: those that come before the first listener (the tap that started the
/// app) are kept for it, 20 at most.
final class DakOpenedListeners: @unchecked Sendable {
    static let maxKept = 20

    private let listeners = DakListeners<DakOpenedListener>()
    private let kept = Locked<[DakNotification]>([])

    func add(_ listener: @escaping DakOpenedListener) -> DakSubscription {
        let subscription = listeners.add(listener)
        let waiting = kept.update { k -> [DakNotification] in
            let all = k
            k = []
            return all
        }
        if !waiting.isEmpty {
            DispatchQueue.main.async { for n in waiting { listener(n) } }
        }
        return subscription
    }

    func dispatch(_ n: DakNotification) {
        let all = listeners.all
        if all.isEmpty {
            kept.update { k in
                k.append(n)
                if k.count > Self.maxKept { k.removeFirst(k.count - Self.maxKept) }
            }
            return
        }
        DispatchQueue.main.async { for l in all { l(n) } }
    }
}

/// The device id: a new listener gets the current one at once, then each new
/// one, never the same twice in a row.
final class DakDeviceIdListeners: @unchecked Sendable {
    private let listeners = DakListeners<DakDeviceIdListener>()
    private let last = Locked<String?>(nil)
    private let current: () -> String?

    init(current: @escaping () -> String?) {
        self.current = current
    }

    func add(_ listener: @escaping DakDeviceIdListener) -> DakSubscription {
        let subscription = listeners.add(listener)
        if let id = current() { DispatchQueue.main.async { listener(id) } }
        return subscription
    }

    func dispatch(_ id: String) {
        let changed = last.update { l -> Bool in
            if l == id { return false }
            l = id
            return true
        }
        guard changed else { return }
        let all = listeners.all
        DispatchQueue.main.async { for l in all { l(id) } }
    }
}

/// Taps on notifications. See ``Dak/addOpenedListener(_:)``.
public typealias DakOpenedListener = @MainActor (DakNotification) -> Void

/// Messages that arrive while the app is open. See ``Dak/addForegroundListener(_:)``.
public typealias DakForegroundListener = @MainActor (DakNotification) -> Void

/// This device's id on the DakPush server. See ``Dak/addDeviceIdListener(_:)``.
public typealias DakDeviceIdListener = @MainActor (String) -> Void

/// Changes the server refused. See ``Dak/addErrorListener(_:)``.
public typealias DakErrorListener = @MainActor (DakError) -> Void
