import Foundation
import Photos

enum PhotoSaveError: Error {
    case denied
}

/// Saves finished images to the Photos library.
///
/// Permissions: PhotoKit only lets an app create/fetch albums with *full* (read-write) access; with add-only or
/// limited access we can still save, just not into the per-child album. One save never shows two system prompts:
/// - album wanted + full access not decided yet → the app shows a short explanation first (AppModel.photosPrimer),
///   then asks for full access once; if that is refused we stop (no second, add-only prompt right after).
/// - album wanted but full access already refused → no prompt for full access; save with add-only (asking for it
///   only if it was never decided).
/// - no album → add-only.
final class PhotoLibrarySaver: Sendable {
    struct Outcome: Sendable {
        var savedToAlbum: Bool
    }

    /// The album needs a full-access decision the app should explain first.
    static var needsAlbumPrimer: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    func save(jpeg: Data, albumTitle: String?, creationDate: Date?) async throws -> Outcome {
        var albumID: String?
        var canAdd = false
        var prompted = false
        if let albumTitle {
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                prompted = true
            }
            switch status {
            case .authorized:
                albumID = try? await ensureAlbum(titled: albumTitle)
                canAdd = true
            case .limited:
                canAdd = true   // limited library can still add new photos (no album)
            default:
                if prompted { throw PhotoSaveError.denied }
            }
        }
        if !canAdd {
            var add = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if add == .notDetermined {
                if prompted { throw PhotoSaveError.denied }
                add = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            guard add == .authorized || add == .limited else { throw PhotoSaveError.denied }
        }
        let targetAlbum = albumID
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: jpeg, options: nil)
            if let creationDate { request.creationDate = creationDate }
            if let targetAlbum,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [targetAlbum], options: nil).firstObject,
               let placeholder = request.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
        }
        return Outcome(savedToAlbum: targetAlbum != nil)
    }

    /// Finds or creates a regular album with this exact title. Requires read-write access.
    private func ensureAlbum(titled title: String) async throws -> String? {
        if let id = fetchAlbumID(titled: title) { return id }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
        }
        return fetchAlbumID(titled: title)
    }

    private func fetchAlbumID(titled title: String) -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle = %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject?.localIdentifier
    }
}
