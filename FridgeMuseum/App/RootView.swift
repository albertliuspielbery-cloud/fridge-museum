import SwiftData
import SwiftUI

enum Route: Hashable {
    case gallery
    case artwork(UUID)
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            CaptureView(
                openGallery: { path.append(Route.gallery) },
                openArtwork: { path.append(Route.artwork($0)) }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .gallery:
                    GalleryView(openArtwork: { path.append(Route.artwork($0)) })
                case .artwork(let id):
                    ArtworkEditLoader(id: id)
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = app.toast {
                Text(toast.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Palette.ink.opacity(0.92)))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: app.toast)
    }
}

/// Resolves an artwork id to the model and opens the editor.
struct ArtworkEditLoader: View {
    @Query private var matches: [Artwork]

    init(id: UUID) {
        let target = id
        _matches = Query(filter: #Predicate<Artwork> { $0.id == target })
    }

    var body: some View {
        if let artwork = matches.first {
            EditView(artwork: artwork)
        } else {
            ContentUnavailableView("找不到這件作品", systemImage: "photo")
        }
    }
}
