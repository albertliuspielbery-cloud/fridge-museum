import UIKit

/// Adds the optional caption band (title on the left; name · age · date on the right) under an exported image.
@MainActor
enum CaptionComposer {
    static func composeJPEG(_ data: Data, title: String, detail: String, background rgb: RGBColor = RGBColor(r: 1, g: 1, b: 1)) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let background = UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        let band = (w * 0.1).rounded()
        let pad = (band * 0.4).rounded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h + band), format: format)
        let out = renderer.image { ctx in
            background.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h + band))
            img.draw(in: CGRect(x: 0, y: 0, width: w, height: h))

            let titleFont = rounded(size: band * 0.36, weight: .semibold)
            let detailFont = rounded(size: band * 0.26, weight: .regular)
            let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: UIColor(red: 0.16, green: 0.2, blue: 0.28, alpha: 1)]
            let detailAttr: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: UIColor(red: 0.42, green: 0.45, blue: 0.52, alpha: 1)]
            let t = NSAttributedString(string: title, attributes: titleAttr)
            let d = NSAttributedString(string: detail, attributes: detailAttr)
            let ts = t.size(), ds = d.size()
            t.draw(at: CGPoint(x: pad, y: h + (band - ts.height) / 2))
            d.draw(at: CGPoint(x: w - pad - ds.width, y: h + (band - ds.height) / 2))
        }
        return out.jpegData(compressionQuality: 0.92)
    }

    private static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: desc, size: size)
    }
}
