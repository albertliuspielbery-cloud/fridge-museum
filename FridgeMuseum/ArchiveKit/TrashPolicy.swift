import Foundation

/// 最近刪除 (1.4.0): how long a deleted museum artwork waits before it is deleted for good.
enum TrashPolicy {
    static let days = 30

    /// Days left before the purge, counted like Photos (30 right after deleting, 1 on the last day); nil = not deleted.
    static func daysLeft(deletedAt: Date?, now: Date, calendar: Calendar = .current) -> Int? {
        guard let deletedAt else { return nil }
        let end = deletedAt.addingTimeInterval(TimeInterval(days) * 86_400)
        let seconds = end.timeIntervalSince(now)
        return max(1, Int(ceil(seconds / 86_400)))
    }

    /// One extra day before the purge, so a restore made on another device on the last day can arrive first.
    static let graceDays = 1

    static func isExpired(deletedAt: Date?, now: Date) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) >= TimeInterval(days + graceDays) * 86_400
    }
}
