import Foundation

/// 備份提醒: artworks live only on this phone until they are saved to Photos. The home screen shows a gentle card
/// (還有 N 張只在 App 裡) when enough of them pile up, or one has waited a while.
enum BackupReminder {
    /// Show once this many museum artworks are not in Photos…
    static let unsavedThreshold = 10
    /// …or the oldest of them was kept more than this many days ago.
    static let maxAgeDays = 14
    /// 之後再說 hides the card this long.
    static let snoozeDays = 14

    /// A museum artwork (kept, not a sample) that was never saved to Photos.
    static func needsBackup(_ artwork: Artwork) -> Bool {
        artwork.isInMuseum && artwork.lastSavedToPhotosAt == nil
    }

    /// `unsavedKeptDates`: when each unsaved museum artwork was kept. `launchedAt`: start of this launch — artworks
    /// kept during this visit alone never trigger it (so a brand-new user isn't nagged in their first session).
    static func shouldShow(unsavedKeptDates: [Date], now: Date, launchedAt: Date, snoozedUntil: Date?) -> Bool {
        guard let oldest = unsavedKeptDates.min(), oldest < launchedAt else { return false }
        if let snoozedUntil, now < snoozedUntil { return false }
        if unsavedKeptDates.count >= unsavedThreshold { return true }
        return now.timeIntervalSince(oldest) > Double(maxAgeDays) * 86_400
    }

    static func snoozeEnd(from now: Date) -> Date {
        now.addingTimeInterval(Double(snoozeDays) * 86_400)
    }
}
