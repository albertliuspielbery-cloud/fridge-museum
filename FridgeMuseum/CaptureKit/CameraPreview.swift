import AVFoundation
import SwiftUI
import UIKit

/// UIView backed by an AVCaptureVideoPreviewLayer, with the live paper outline drawn on top.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }

    private let outline = CAShapeLayer()
    private var lastQuad: LiveQuad?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        outline.fillColor = UIColor(red: 0.18, green: 0.36, blue: 1, alpha: 0.18).cgColor
        outline.strokeColor = UIColor.white.cgColor
        outline.lineWidth = 3
        outline.lineJoin = .round
        outline.shadowColor = UIColor.black.cgColor
        outline.shadowOpacity = 0.35
        outline.shadowRadius = 3
        outline.shadowOffset = .zero
        layer.addSublayer(outline)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outline.frame = bounds
        show(lastQuad)
    }

    func show(_ quad: LiveQuad?) {
        lastQuad = quad
        guard let quad, quad.points.count == 4 else {
            outline.path = nil
            return
        }
        let pts = quad.points.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
        let path = UIBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        path.close()
        outline.path = path.cgPath
    }
}

struct CameraPreview: UIViewRepresentable {
    let model: CameraModel
    /// Passed explicitly so SwiftUI re-runs updateUIView when it changes.
    let quad: LiveQuad?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(frame: .zero)
        view.previewLayer.session = model.controller.session
        model.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.show(quad)
    }
}
