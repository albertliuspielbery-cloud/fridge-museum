import Foundation
import Photos

enum PhotoSaveError: Error {
    case denied
}

/// Saves finished images to the Photos library.
///
/// Note on permissions: PhotoKit only lets an app create/fetch albums with *full* (read-write) access.
/// With add-only (or limited) access we can still save, just not into the per-child album.
/// So: we ask for read-write when the per-child album is wanted; if the parent declines,
/// we fall back to add-only and save into Recents.
final class PhotoLibrarySaver: Sendable {
    struct Outcome: Sendable {
        var savedToAlbum: Bool
    }

    func save(jpeg: Data, albumTitle: String?, creationDate: Date?) async throws -> Outcome {
        var albumID: String?
        if let albumTitle {
            var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .notDetermined {
                status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            if status == .authorized {
                albumID = try? await ensureAlbum(titled: albumTitle)
            }
        }
        if albumID == nil {
            var add = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if add == .notDetermined {
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
