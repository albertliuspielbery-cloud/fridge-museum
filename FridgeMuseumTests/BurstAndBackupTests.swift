import Foundation
import SwiftData
import Testing
@testable import FridgeMuseum

/// 1.1.0: 連拍 (burst holds exports, then they run one at a time), 繼續 stepping through pending captures, and the
/// 備份提醒 rules.
@MainActor
struct BurstAndBackupTests {
    private func makeArtwork(_ kind: ArtworkKind = .flat, kept: Bool = false, sample: Bool = false,
                             createdAt: Date = Date(), in context: ModelContext) -> Artwork {
        let a = Artwork(kind: kind, child: nil, capturedAt: day(2026, 10, 28), originalImageData: Data([0, 1, 2]))
        a.isKept = kept
        a.isSample = sample
        a.createdAt = createdAt
        context.insert(a)
        return a
    }

    // MARK: 連拍

    /// While bursting, a shot keeps its original but doesn't export; after the burst the held exports run.
    /// (The test data isn't a real image, so each export ends as `.failed` — that's how we see it ran.)
    @Test func burstHoldsExportsThenRunsThem() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let first = makeArtwork(.craft, createdAt: day(2026, 10, 28), in: context)   // craft: straight to the export step
        let second = makeArtwork(.craft, createdAt: day(2026, 10, 29), in: context)
        try context.save()

        app.beginBurst()
        #expect(app.isBursting)
        #expect(app.isEditorBusy)
        await app.autoProcess(first, context: context)
        await app.autoProcess(second, context: context)
        #expect(first.renderVersion == 0 && first.processingState == .pending)
        #expect(second.renderVersion == 0 && second.processingState == .pending)

        app.endBurst(context: context)
        #expect(!app.isBursting)
        #expect(!app.isEditorBusy)
        for _ in 0..<200 where first.processingState != .failed || second.processingState != .failed {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(first.processingState == .failed)
        #expect(second.processingState == .failed)
    }

    /// Held exports pause again as soon as an editor opens.
    @Test func heldExportsWaitForAnOpenEditorAfterTheBurst() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let open = makeArtwork(.craft, kept: true, in: context)
        let shot = makeArtwork(.craft, in: context)
        try context.save()

        app.beginBurst()
        await app.autoProcess(shot, context: context)
        app.beginEditing(open.id)
        app.endBurst(context: context)
        #expect(app.isEditorBusy)
        try await Task.sleep(for: .milliseconds(300))
        #expect(shot.processingState == .pending)
        app.endEditing(open.id, context: context)
    }

    /// At launch, unfinished captures (e.g. a burst cut short) go through the queue: nothing starts while an editor
    /// is open, and afterwards they run one at a time.
    @Test func launchQueuesUnfinishedCapturesInsteadOfStartingThemAll() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let open = makeArtwork(.craft, kept: true, createdAt: day(2026, 10, 1), in: context)
        let shots = (2...4).map { makeArtwork(.craft, createdAt: day(2026, 10, $0), in: context) }
        try context.save()

        app.beginEditing(open.id)
        app.processUnfinished(context: context)
        try await Task.sleep(for: .milliseconds(300))
        let allHeld = shots.allSatisfy { $0.processingState == .pending }
        #expect(allHeld)
        #expect(app.processingIDs.isEmpty)

        app.endEditing(open.id, context: context)
        var mostAtOnce = 0
        for _ in 0..<200 where shots.contains(where: { $0.processingState != .failed }) {
            mostAtOnce = max(mostAtOnce, app.processingIDs.count)
            try await Task.sleep(for: .milliseconds(20))
        }
        let allRan = shots.allSatisfy { $0.processingState == .failed }
        #expect(allRan)
        #expect(mostAtOnce <= 1)
    }

    /// Stepping through pending captures: an edited artwork's render waits for the open editor, then runs even
    /// though an older render exists.
    @Test func renderLaterWaitsForTheEditorAndRerendersAnEditedArtwork() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let edited = makeArtwork(.craft, kept: true, in: context)
        edited.renderedImageData = Data([9])
        edited.processingState = .done
        let next = makeArtwork(.craft, in: context)
        try context.save()

        app.beginEditing(next.id)
        app.renderLater(edited, context: context, stale: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(edited.processingState == .done)

        app.endEditing(next.id, context: context)
        for _ in 0..<200 where edited.processingState != .failed {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(edited.processingState == .failed)   // the render ran (test data isn't a real image)
    }

    /// Nothing edited and already rendered: renderLater has nothing to do.
    @Test func renderLaterSkipsAnUneditedRenderedArtwork() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let rendered = makeArtwork(.craft, kept: true, in: context)
        rendered.renderedImageData = Data([9])
        rendered.processingState = .done
        try context.save()

        app.renderLater(rendered, context: context, stale: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rendered.processingState == .done)
        #expect(rendered.renderedImageData == Data([9]))
    }

    /// 全部存到照片 waits while an editor is open, then carries on.
    @Test func saveAllWaitsWhileAnEditorIsOpen() async throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let open = makeArtwork(.craft, kept: true, in: context)
        let a = makeArtwork(.craft, kept: true, in: context)
        let b = makeArtwork(.craft, kept: true, in: context)
        try context.save()

        let openID = open.id
        app.beginEditing(openID)
        // The editor closes 0.4 s from now (only Sendable values cross into the task).
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            app.endEditing(openID, context: ModelContext(container))
        }
        let started = Date()
        // primed: skip the album explanation (the test data can't be exported, so nothing reaches Photos).
        await app.saveAll([a, b], context: context, primed: true, addsToSession: false)
        #expect(Date().timeIntervalSince(started) >= 0.35)   // it waited for the editor
        #expect(app.saveAllProgress == nil)
        #expect(a.processingState == .failed)
        #expect(b.processingState == .failed)
        #expect(app.sessionArtworkIDs.isEmpty)
    }

    @Test func endBurstWithoutABurstIsANoOp() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        app.endBurst(context: context)
        #expect(!app.isBursting)
        #expect(!app.isEditorBusy)
    }

    // MARK: 繼續

    @Test func pendingWalkGoesOldestFirstAndStopsAtTheEnd() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let a = makeArtwork(createdAt: day(2026, 10, 1), in: context)
        let b = makeArtwork(createdAt: day(2026, 10, 2), in: context)
        let c = makeArtwork(.craft, createdAt: day(2026, 10, 3), in: context)
        _ = makeArtwork(kept: true, createdAt: day(2026, 9, 1), in: context)
        _ = makeArtwork(sample: true, createdAt: day(2026, 9, 2), in: context)
        try context.save()

        #expect(app.startPendingWalk(context: context) == a.id)
        #expect(app.isWalkingPending)

        a.isKept = true
        #expect(app.continuePendingWalk(after: a.id, context: context))
        #expect(app.pendingRoute == .edit(b.id))
        #expect(app.isEditorBusy)   // the next one is claimed before the editor closes

        // 不要這張 on b: it's still in the store when the editor asks for the next one.
        #expect(app.continuePendingWalk(after: b.id, context: context))
        #expect(app.pendingRoute == .edit(c.id))

        c.isKept = true
        app.delete(b, context: context)
        #expect(!app.continuePendingWalk(after: c.id, context: context))
        #expect(!app.isWalkingPending)
    }

    @Test func singlePendingDoesNotWalk() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let only = makeArtwork(in: context)
        try context.save()

        #expect(app.startPendingWalk(context: context) == only.id)
        #expect(!app.isWalkingPending)
        #expect(!app.continuePendingWalk(after: only.id, context: context))
        #expect(app.pendingRoute == nil)
    }

    @Test func endPendingWalkStopsStepping() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let a = makeArtwork(createdAt: day(2026, 10, 1), in: context)
        _ = makeArtwork(createdAt: day(2026, 10, 2), in: context)
        try context.save()

        _ = app.startPendingWalk(context: context)
        app.endPendingWalk()
        #expect(!app.continuePendingWalk(after: a.id, context: context))
        #expect(app.pendingRoute == nil)
    }

    // MARK: 備份提醒

    private let launch = day(2026, 10, 28)

    @Test func backupReminderNeedsAnArtworkFromBeforeThisLaunch() {
        // Ten kept during this very visit (e.g. the first session): no card.
        let today = Array(repeating: launch.addingTimeInterval(60), count: 12)
        #expect(!BackupReminder.shouldShow(unsavedKeptDates: today, now: launch.addingTimeInterval(120),
                                           launchedAt: launch, snoozedUntil: nil))
        #expect(!BackupReminder.shouldShow(unsavedKeptDates: [], now: launch, launchedAt: launch, snoozedUntil: nil))
    }

    @Test func backupReminderAtTenUnsavedOrAfterTwoWeeks() {
        let yesterday = day(2026, 10, 27)
        let nine = Array(repeating: yesterday, count: 9)
        #expect(!BackupReminder.shouldShow(unsavedKeptDates: nine, now: launch, launchedAt: launch, snoozedUntil: nil))
        #expect(BackupReminder.shouldShow(unsavedKeptDates: nine + [launch], now: launch, launchedAt: launch, snoozedUntil: nil))

        let old = day(2026, 10, 13)   // 15 days before
        #expect(BackupReminder.shouldShow(unsavedKeptDates: [old], now: launch, launchedAt: launch, snoozedUntil: nil))
        let recent = day(2026, 10, 15)   // 13 days before
        #expect(!BackupReminder.shouldShow(unsavedKeptDates: [recent], now: launch, launchedAt: launch, snoozedUntil: nil))
    }

    @Test func backupReminderSnoozeHidesItForTwoWeeks() {
        let old = day(2026, 9, 1)
        let until = BackupReminder.snoozeEnd(from: launch)
        #expect(until == launch.addingTimeInterval(14 * 86_400))
        #expect(!BackupReminder.shouldShow(unsavedKeptDates: [old], now: launch, launchedAt: launch, snoozedUntil: until))
        #expect(BackupReminder.shouldShow(unsavedKeptDates: [old], now: until.addingTimeInterval(1),
                                          launchedAt: until, snoozedUntil: until))
    }

    @Test func unsavedMuseumArtworksSkipsSavedPendingAndSamples() throws {
        let container = ArchiveStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let app = AppModel()
        let newer = makeArtwork(kept: true, in: context)
        newer.keptAt = day(2026, 10, 20)
        let older = makeArtwork(kept: true, in: context)
        older.keptAt = day(2026, 10, 1)
        let saved = makeArtwork(kept: true, in: context)
        saved.lastSavedToPhotosAt = day(2026, 10, 2)
        _ = makeArtwork(in: context)                          // pending
        _ = makeArtwork(kept: true, sample: true, in: context) // sample
        try context.save()

        #expect(app.unsavedMuseumArtworks(context: context).map(\.id) == [older.id, newer.id])
        #expect(!BackupReminder.needsBackup(saved))
        #expect(BackupReminder.needsBackup(older))
    }
}
