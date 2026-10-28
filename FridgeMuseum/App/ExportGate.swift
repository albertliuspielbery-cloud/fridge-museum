import Foundation

/// One final (up to 4096 px) export at a time, first come, first served. A single 存到手機 that arrives while a
/// 全部存到照片 item is exporting goes next — before the batch's following item — because the slot is handed
/// straight to the longest waiter instead of being released and re-grabbed.
@MainActor
final class ExportGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many callers are waiting for the slot (tests).
    var waitingCount: Int { waiters.count }

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Stays busy: the slot passes to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}
