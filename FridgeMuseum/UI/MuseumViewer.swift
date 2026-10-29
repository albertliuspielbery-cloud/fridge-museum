import SwiftUI
import UIKit

/// What the full-screen viewer opens with: the museum's current (filtered, sorted) list and where to start.
struct MuseumViewerStart: Identifiable {
    /// The artwork to start on.
    let id: UUID
    let artworks: [Artwork]
}

/// 全螢幕看: swipe sideways through the museum's current list, pinch / double-tap to zoom one artwork.
/// Pages are lazy (LazyHStack + paging); each page decodes the 2400 px render downsampled to the screen and lets go
/// of it when it scrolls away, so only the visible page and its neighbours hold big bitmaps.
struct MuseumViewer: View {
    let artworks: [Artwork]
    let openDetail: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var currentID: UUID?
    private let startID: UUID

    init(artworks: [Artwork], startID: UUID, openDetail: @escaping (UUID) -> Void) {
        self.artworks = artworks
        self.startID = startID
        self.openDetail = openDetail
        _currentID = State(initialValue: startID)
    }

    /// `isAlive` first: never read a deleted model.
    private var alive: [Artwork] { artworks.filter { AppModel.isAlive($0) } }

    var body: some View {
        let list = alive
        let current = list.first { $0.id == currentID } ?? list.first
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let maxPixel = MuseumViewMode.viewerPixelSize(for: geo.size, scale: displayScale)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(list) { a in
                                MuseumViewerPage(artwork: a, maxPixel: maxPixel)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .id(a.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $currentID)
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(startID) }
                }
            }
            .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar(list: list, current: current)
                Spacer(minLength: 0)
                if let current { caption(current) }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .onDisappear { MuseumImageLoader.shared.trim() }
        .onChange(of: list.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }

    private func topBar(list: [Artwork], current: Artwork?) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("關閉"))
            Spacer()
            if let current, let i = list.firstIndex(where: { $0.id == current.id }) {
                Text(verbatim: "\(i + 1) / \(list.count)")
                    .font(.fm(15, bold: true))
                    .monospacedDigit()
            }
            Spacer()
            Button {
                if let current { openDetail(current.id) }
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("作品說明"))
            .disabled(current == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 4)
    }

    private func caption(_ a: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: a.placardTitle)
                .font(.fmDisplay(20, relativeTo: .headline))
                .lineLimit(1)
            Text(verbatim: a.placardArtist)
                .font(.fm(14, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter + 4)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One page: the thumbnail at once, the screen-sized decode when it arrives; released when the page scrolls away.
struct MuseumViewerPage: View {
    let artwork: Artwork
    let maxPixel: Int

    @State private var image: UIImage?

    var body: some View {
        ZoomableImage(image: image ?? ThumbnailCache.shared.image(for: artwork))
            .task(id: "\(artwork.renderVersion)-\(maxPixel)") {
                image = await MuseumImageLoader.shared.image(for: artwork, maxPixel: maxPixel)
            }
            .onDisappear { image = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(artwork.placardTitle), \(artwork.placardArtist), \(artwork.kind.title)"))
            .accessibilityAddTraits(.isImage)
    }
}

/// UIScrollView zoom (pinch, double-tap, pan when zoomed). At 1× the content fits the page exactly, so sideways
/// swipes go to the paging scroll view around it (the classic PhotoScroller arrangement).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        if view.imageView.image !== image { view.setImage(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    private var laidOutAspect: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        setNeedsLayout()
    }

    private var imageAspect: CGFloat {
        guard let s = imageView.image?.size, s.width > 0, s.height > 0 else { return 0 }
        return s.width / s.height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let aspect = imageAspect
        // Re-fit when the page size or the picture's shape changes (a sharper decode of the same picture keeps the zoom).
        if bounds.size != laidOutSize || abs(aspect - laidOutAspect) > 0.01 {
            laidOutSize = bounds.size
            laidOutAspect = aspect
            if zoomScale != 1 { setZoomScale(1, animated: false) }
            let fit = fitRect(imageView.image?.size ?? .zero, in: bounds.size)
            imageView.frame = CGRect(origin: .zero, size: fit.size)
            contentSize = fit.size
        }
        centerContent()
    }

    private func centerContent() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        if contentInset != inset { contentInset = inset }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = gesture.location(in: imageView)
            let w = bounds.width / 2.5, h = bounds.height / 2.5
            zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }
}
