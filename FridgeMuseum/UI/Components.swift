import SwiftUI
import UIKit

// MARK: Kitchen wall

/// Warm wallpaper: a cream wall with a small diamond + dot motif (night kitchen: navy with faint stars).
struct Wallpaper: View {
    var body: some View {
        Palette.wall
            .overlay {
                Canvas { ctx, size in
                    let t: CGFloat = 28
                    var diamonds = Path()
                    var dots = Path()
                    var y: CGFloat = 0
                    while y < size.height + t {
                        var x: CGFloat = 0
                        while x < size.width + t {
                            diamonds.move(to: CGPoint(x: x + 14, y: y + 9))
                            diamonds.addLine(to: CGPoint(x: x + 16.2, y: y + 12))
                            diamonds.addLine(to: CGPoint(x: x + 14, y: y + 15))
                            diamonds.addLine(to: CGPoint(x: x + 11.8, y: y + 12))
                            diamonds.closeSubpath()
                            dots.addEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
                            x += t
                        }
                        y += t
                    }
                    ctx.fill(diamonds, with: .color(Palette.wallMotif))
                    ctx.fill(dots, with: .color(Palette.wallMotif))
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

// MARK: Fridge

/// One fridge door: mint enamel with a darker side panel (3D), a highlight strip and a handle.
struct FridgeDoorShape: View {
    var top: CGFloat
    var bottom: CGFloat
    var handleHeight: CGFloat = 70

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Palette.doorLo).offset(x: 10, y: 4)
            shape.fill(Palette.door)
            Capsule().fill(Palette.doorHi.opacity(0.85))
                .frame(width: 11, height: min(120, handleHeight * 1.4))
                .padding(.leading, 18).padding(.top, max(16, top * 0.6))
        }
        .overlay(alignment: .topTrailing) {
            Capsule().fill(Palette.doorLo)
                .frame(width: 9, height: handleHeight)
                .padding(.trailing, 18).padding(.top, max(18, top * 0.6))
        }
    }
}

/// The two-door fridge: freezer (Bibi's face lives here) on top, main door below.
struct Fridge<Freezer: View, Main: View>: View {
    @ViewBuilder var freezer: Freezer
    @ViewBuilder var main: Main

    var body: some View {
        VStack(spacing: 7) {
            freezer
                .frame(maxWidth: .infinity)
                .background(FridgeDoorShape(top: 40, bottom: 12, handleHeight: 64))
            main
                .frame(maxWidth: .infinity)
                .background(FridgeDoorShape(top: 12, bottom: 40, handleHeight: 120))
        }
        .padding(.trailing, 10)
        .overlay(alignment: .topLeading) {
            Image("fridge-bow").resizable().scaledToFit().frame(width: 44).offset(x: 10, y: -12)
                .accessibilityHidden(true)
        }
    }
}

/// Speech bubble with a tail on the leading side, pointing at Bibi.
struct SpeechBubble: Shape {
    var tail: CGFloat = 12

    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: CGRect(x: r.minX + tail, y: r.minY, width: r.width - tail, height: r.height),
                     cornerRadius: 20, style: .continuous)
        let cy = r.midY
        p.move(to: CGPoint(x: r.minX + tail + 1, y: cy - 9))
        p.addLine(to: CGPoint(x: r.minX, y: cy))
        p.addLine(to: CGPoint(x: r.minX + tail + 1, y: cy + 9))
        p.closeSubpath()
        return p
    }
}

// MARK: Prints, tape, magnets, placards

enum TapeStyle: String, CaseIterable {
    case stripe = "tape-stripe", dots = "tape-dots", check = "tape-check", mint = "tape-mint"

    static func pick(_ id: UUID) -> TapeStyle {
        allCases[Int((wobble(id, salt: 3) + 1) * 1.999)]
    }
}

struct Tape: View {
    var style: TapeStyle = .stripe
    var width: CGFloat = 86
    var angle: Double = -3

    var body: some View {
        Image(style.rawValue)
            .resizable()
            .frame(width: width, height: width * 26 / 120)
            .rotationEffect(.degrees(angle))
            .shadow(color: Palette.shadow.opacity(0.5), radius: 1, y: 1)
            .accessibilityHidden(true)
    }
}

/// A white photo print hung on the fridge with washi tape (or a magnet), slightly crooked.
struct HungPrint<Content: View>: View {
    var id: UUID
    var tilt: Double = 2.2
    var magnet: String? = nil
    var tape: TapeStyle? = nil
    var padding: CGFloat = 7
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Palette.print)
            .compositingGroup()
            .shadow(color: Palette.printShadow, radius: 7, x: 0, y: 5)
            .overlay(alignment: .top) {
                if let magnet {
                    Image(magnet).resizable().scaledToFit().frame(width: 34).offset(y: -16).accessibilityHidden(true)
                } else {
                    Tape(style: tape ?? TapeStyle.pick(id), width: 80, angle: wobble(id, salt: 7) * 4).offset(y: -9)
                }
            }
            .rotationEffect(.degrees(wobble(id) * tilt))
    }
}

/// Museum label: title in red display type, artist · age, medium · date.
struct Placard: View {
    var title: String
    var lines: [String]
    var action: String? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            Text(verbatim: title)
                .font(.fmDisplay(compact ? 16 : 21, relativeTo: .headline))
                .foregroundStyle(Palette.placardRed)
                .lineLimit(2)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.fm(compact ? 12.5 : 14.5, relativeTo: .subheadline))
                    .foregroundStyle(Palette.cardMuted)
                    .lineLimit(2)
            }
            if let action {
                Text(verbatim: action)
                    .font(.fm(compact ? 12.5 : 14.5, bold: true, relativeTo: .subheadline))
                    .foregroundStyle(Palette.teal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 10 : 16)
        .padding(.vertical, compact ? 8 : 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardLine, lineWidth: 2))
        .shadow(color: Palette.shadow, radius: 4, y: 3)
        .environment(\.colorScheme, .light)
    }
}

extension Placard {
    init(artwork a: Artwork, compact: Bool = false) {
        self.init(title: a.placardTitle, lines: [a.placardArtist, a.placardMedium], compact: compact)
    }
}

// MARK: Crayon text

/// Multi-coloured crayon lettering (已掛上冰箱！): one crayon per character, grainy edges.
struct CrayonText: View {
    var text: String
    var size: CGFloat = 34
    /// Deeper crayons than the UI accents so every letter keeps ≥ 3:1 against the cream (light) / navy (dark) toast.
    static let crayons: [Color] = [
        Color(0xC63A22, 0xFF8A70), Color(0xB45A0C, 0xFFB45E), Color(0x23845A, 0x5EDCA6),
        Color(0x2F5CC4, 0x9DB6FF), Color(0x7646B5, 0xC6A8F7), Color(0xB83A70, 0xFFA6C8),
    ]

    var body: some View {
        let chars = Array(text)
        var t = Text(verbatim: "")
        var colorIndex = 0
        for ch in chars {
            let isSpace = ch == " "
            t = t + Text(verbatim: String(ch)).foregroundColor(isSpace ? .clear : Self.crayons[colorIndex % Self.crayons.count])
            if !isSpace { colorIndex += 1 }
        }
        let styled = t.font(.fmDisplay(size, relativeTo: .largeTitle)).tracking(1.5)
        // Solid letters at 85 % with the crayon grain on top: textured, but the flecks never drop the contrast.
        return ZStack {
            styled.opacity(0.85)
            styled.mask {
                Rectangle().fill(ImagePaint(image: Image("crayon-grain"), scale: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// Section header in crayon: a strip of washi tape + Huninn headline.
struct CrayonHeader: View {
    var title: String
    var subtitle: String?
    var count: Int?
    var tape: TapeStyle = .mint
    var ink: Color = Palette.doorInk

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.fmDisplay(23, relativeTo: .title2))
                    .foregroundStyle(ink)
                    .background(alignment: .bottomLeading) {
                        Capsule().fill(Palette.yellow.opacity(0.55)).frame(height: 8).offset(y: 3)
                            .mask { Rectangle().fill(ImagePaint(image: Image("crayon-grain"), scale: 0.5)) }
                    }
                if let subtitle {
                    Text(verbatim: subtitle).font(.fm(14)).foregroundStyle(ink.opacity(0.75))
                }
            }
            Spacer(minLength: 8)
            if let count {
                CountBadge(count: count)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct CountBadge: View {
    var count: Int

    var body: some View {
        Text("\(count) 張")
            .font(.fm(14, bold: true))
            .foregroundStyle(Palette.cardInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.card))
            .shadow(color: Palette.shadow, radius: 2, y: 2)
    }
}

// MARK: Controls

struct PrimaryCapsuleStyle: ButtonStyle {
    var tint: Color = Palette.primary
    var deep: Color = Palette.primaryDeep
    var ink: Color = Palette.primaryInk
    /// false for buttons that already restyle their disabled state (keeps text contrast readable).
    var dimsWhenDisabled = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fm(18, bold: true, relativeTo: .headline))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
            .background {
                ZStack {
                    Capsule().fill(deep).offset(y: configuration.isPressed ? 1 : 4)
                    Capsule().fill(tint).offset(y: configuration.isPressed ? 2 : 0)
                }
            }
            .offset(y: configuration.isPressed ? 2 : 0)
            .opacity(isEnabled || !dimsWhenDisabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryCapsuleStyle: ButtonStyle {
    var ink: Color = Palette.tealInk
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fm(18, bold: true, relativeTo: .headline))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Palette.surface).shadow(color: Palette.shadow, radius: 5, y: 3))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Small pill on a cream surface (復原一筆 / 清除所有筆刷 / 重新自動找四角).
struct SoftPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fm(15.5, bold: true))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 10)
            .background(Capsule().fill(Palette.surface2))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Round cream knob (tool buttons, rotate buttons).
struct RoundKnob: View {
    var systemImage: String
    var selected = false
    var size: CGFloat = 54

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Palette.ink)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(selected ? Color(0x1B6D5F, 0x2F8F7D) : Palette.surface2).offset(y: 3)
                    Circle().fill(selected ? Palette.teal : Palette.surface)
                }
            }
            .shadow(color: Palette.shadow, radius: 3, y: 2)
    }
}

/// 平面畫作 ● / 立體勞作 ● — the pill mode switch used on the counter and in the editor.
struct KindSwitch: View {
    @Binding var kind: ArtworkKind
    var long = true
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ArtworkKind.allCases) { k in
                let selected = kind == k
                Button {
                    withAnimation(.spring(duration: 0.25)) { kind = k }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(selected ? Palette.color(for: k) : Palette.faint.opacity(0.7))
                            .frame(width: 9, height: 9)
                        Text(verbatim: long ? k.longTitle : k.title)
                            .font(.fm(compact ? 15.5 : 17, bold: true))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                    .padding(.horizontal, compact ? 12 : 16)
                    .frame(height: compact ? 38 : 44)
                    .background {
                        if selected {
                            Capsule().fill(Palette.dockRaise).shadow(color: Palette.shadow, radius: 3, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.counter2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("作品類型"))
    }
}

/// A child's avatar: the photo avatar if there is one, else the colour circle with the initial.
/// Every place that shows a child uses this, so they all stay in step.
struct ChildAvatar: View {
    var child: Child
    var size: CGFloat = 26

    var body: some View {
        AvatarDot(hex: child.avatarColorHex, name: child.displayName, size: size,
                  image: AvatarImageCache.shared.image(for: child))
    }
}

/// Decorative (hidden from VoiceOver): the child's name is always shown next to it.
struct AvatarDot: View {
    var hex: String
    var name: String
    var size: CGFloat = 26
    var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: size, height: size)
                    .overlay(
                        Text(verbatim: Self.initial(of: name))
                            .font(.fm(size * 0.48, bold: true))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(size * 0.08)
                    )
            }
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: size > 30 ? 2.5 : 1.5))
        .accessibilityHidden(true)
    }

    /// Latin names → first letter; Chinese names → the last character (小明 → 明, the way kids are called).
    static func initial(of name: String) -> String {
        guard let first = name.first else { return "?" }
        let isCJK = first.unicodeScalars.first.map { (0x3400...0x9FFF).contains(Int($0.value)) } ?? false
        if isCJK, name.count >= 2, let last = name.last { return String(last) }
        return String(first).uppercased()
    }
}

/// Filter chip on the museum wall.
struct Chip: View {
    var title: String
    var systemImage: String?
    var selected: Bool
    var tint: Color = Palette.teal
    var showsMenuIndicator = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, systemImage: systemImage, selected: selected, tint: tint, showsMenuIndicator: showsMenuIndicator)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChipLabel: View {
    var title: String
    var systemImage: String?
    var selected: Bool
    var tint: Color = Palette.teal
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)) }
            Text(verbatim: title).lineLimit(1)
            if showsMenuIndicator { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
        }
        .font(.fm(14.5, bold: true))
        .padding(.horizontal, 13)
        .frame(height: 36)
        .foregroundStyle(selected ? Color.white : Palette.ink)
        .background(Capsule().fill(selected ? tint : Palette.surface))
        .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.line, lineWidth: 1.5))
        .shadow(color: selected ? Palette.shadow : .clear, radius: 3, y: 2)
    }
}

/// Small rounded value badge next to slider titles (60 / 0°).
struct ValueBadge: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.fm(15, bold: true))
            .monospacedDigit()
            .foregroundStyle(Palette.ink)
            .frame(minWidth: 44)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.surface2))
    }
}

/// Cream card panel with a tape glyph, title and 完成 (the web's bottom sheet, inline).
struct PanelCard<Content: View>: View {
    var title: String
    var onDone: () -> Void
    /// Optional small action next to 完成 (e.g. 重新自動找四角 in the crop panel).
    var accessoryIcon: String? = nil
    var accessoryLabel: String = ""
    var onAccessory: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("tape-mint").resizable().frame(width: 42, height: 14).rotationEffect(.degrees(-8))
                    .accessibilityHidden(true)
                Text(verbatim: title).font(.fmDisplay(21, relativeTo: .headline)).foregroundStyle(Palette.ink)
                Spacer()
                if let accessoryIcon, let onAccessory {
                    Button(action: onAccessory) {
                        Image(systemName: accessoryIcon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Palette.tealInk)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Palette.tealSoft))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: accessoryLabel))
                    .padding(.trailing, 6)
                }
                Button(action: onDone) {
                    Text("完成").font(.fm(17, bold: true)).foregroundStyle(Palette.tealInk)
                }
                .buttonStyle(.plain)
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.line, lineWidth: 1.5))
        .shadow(color: Palette.shadow, radius: 10, y: 4)
    }
}

/// Bibi as a tiny hint-giver next to a line of text.
struct BibiHint: View {
    var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("bibi-mini").resizable().scaledToFit().frame(width: 30, height: 37).accessibilityHidden(true)
            Text(verbatim: text)
                .font(.fm(14.5, relativeTo: .footnote))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Invisible marker the screenshot UI tests wait for (content rendered, animations settled).
struct ReadyMarker: View {
    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("fm.ready")
            .accessibilityLabel(Text(verbatim: "ready"))
    }
}

/// Thumbnail tile (session sheet, compact lists).
struct ArtworkThumb: View {
    let artwork: Artwork
    var processing: Bool = false

    var body: some View {
        let image = ThumbnailCache.shared.image(for: artwork)
        Rectangle()
            .fill(Palette.print)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if artwork.processingState == .failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.red)
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if artwork.isFavorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.yellow).padding(5).shadow(radius: 1)
                }
            }
            .accessibilityLabel(Text(verbatim: "\(artwork.placardTitle), \(artwork.kind.title)"))
    }
}
