import CoreGraphics
import Foundation
import Testing
@testable import FridgeMuseum

/// 美術館 view modes (大圖 / 標準 / 小圖): columns, persistence and pinch steps (MuseumLayout.swift).
struct MuseumLayoutTests {
    @Test func columnsOnPhones() {
        for width: CGFloat in [375, 390, 393, 402] {
            #expect(MuseumViewMode.standard.columns(forWidth: width) == 2)
            #expect(MuseumViewMode.small.columns(forWidth: width) == 4)
            #expect(MuseumViewMode.large.columns(forWidth: width) == 1)
        }
        // Plus / Pro Max widths get a fifth 小圖 column; the other modes stay the same.
        for width: CGFloat in [428, 430, 440] {
            #expect(MuseumViewMode.small.columns(forWidth: width) == 5)
            #expect(MuseumViewMode.standard.columns(forWidth: width) == 2)
            #expect(MuseumViewMode.large.columns(forWidth: width) == 1)
        }
        // Before the width is measured (0) the phone layout is used.
        #expect(MuseumViewMode.small.columns(forWidth: 0) == 4)
        #expect(MuseumViewMode.standard.columns(forWidth: 0) == 2)
    }

    @Test func wideScreensGetMoreColumns() {
        #expect(MuseumViewMode.small.columns(forWidth: 700) == 6)
        #expect(MuseumViewMode.standard.columns(forWidth: 700) == 3)
        #expect(MuseumViewMode.large.columns(forWidth: 700) == 2)
    }

    @Test func smallerModesAreDenser() {
        for width: CGFloat in [375, 430, 700] {
            let small = MuseumViewMode.small.columns(forWidth: width)
            let standard = MuseumViewMode.standard.columns(forWidth: width)
            let large = MuseumViewMode.large.columns(forWidth: width)
            #expect(small > standard && standard > large)
            #expect(MuseumViewMode.small.tileWidth(containerWidth: width) < MuseumViewMode.standard.tileWidth(containerWidth: width))
            #expect(MuseumViewMode.standard.tileWidth(containerWidth: width) < MuseumViewMode.large.tileWidth(containerWidth: width))
        }
        #expect(MuseumViewMode.small.tileWidth(containerWidth: 0) == 0)
    }

    @Test func storedValueRoundTrips() {
        for mode in MuseumViewMode.allCases {
            #expect(MuseumViewMode(stored: mode.rawValue) == mode)
        }
        // Stored contract: renaming these would reset everyone's choice.
        #expect(MuseumViewMode.storageKey == "museumViewMode")
        #expect(MuseumViewMode.allCases.map(\.rawValue).sorted() == ["large", "small", "standard"])
    }

    @Test func unknownOrMissingValueFallsBackToStandard() {
        #expect(MuseumViewMode(stored: nil) == .standard)
        #expect(MuseumViewMode(stored: "") == .standard)
        #expect(MuseumViewMode(stored: "huge") == .standard)
    }

    @Test func persistsThroughUserDefaults() throws {
        let suite = "MuseumLayoutTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MuseumViewMode(stored: defaults.string(forKey: MuseumViewMode.storageKey)) == .standard)
        defaults.set(MuseumViewMode.small.rawValue, forKey: MuseumViewMode.storageKey)
        #expect(MuseumViewMode(stored: defaults.string(forKey: MuseumViewMode.storageKey)) == .small)
    }

    @Test func pinchStepsOneModeAtATime() {
        #expect(MuseumViewMode.standard.afterPinch(scale: 0.6) == .small)
        #expect(MuseumViewMode.standard.afterPinch(scale: 1.6) == .large)
        #expect(MuseumViewMode.large.afterPinch(scale: 0.5) == .standard)
        #expect(MuseumViewMode.small.afterPinch(scale: 2.0) == .standard)
        // Already at the end.
        #expect(MuseumViewMode.small.afterPinch(scale: 0.3) == .small)
        #expect(MuseumViewMode.large.afterPinch(scale: 3.0) == .large)
        // Small wobbles don't switch.
        #expect(MuseumViewMode.standard.afterPinch(scale: 0.9) == .standard)
        #expect(MuseumViewMode.standard.afterPinch(scale: 1.1) == .standard)
    }

    @Test func menuListsEveryModeOnce() {
        #expect(Set(MuseumViewMode.menuOrder) == Set(MuseumViewMode.allCases))
        #expect(MuseumViewMode.menuOrder.count == MuseumViewMode.allCases.count)
        #expect(MuseumViewMode.byDensity == [.small, .standard, .large])
    }

    @Test func largeDecodeSizeFitsTheScreenAndNeverExceedsTheRender() {
        // 1:2 portrait, 340 pt wide on a 3× phone: long edge = 340 / 0.5 × 3 = 2040 px.
        #expect(MuseumViewMode.largePixelSize(widthPoints: 340, aspect: 0.5, scale: 3) == 2040)
        // Landscape: the width is the long edge.
        #expect(MuseumViewMode.largePixelSize(widthPoints: 340, aspect: 1.5, scale: 3) == 1020)
        // Very tall works are capped at the 2400 px render.
        #expect(MuseumViewMode.largePixelSize(widthPoints: 400, aspect: 0.3, scale: 3) == 2400)
        // Unknown width → nothing to decode yet; unknown aspect → 3:4.
        #expect(MuseumViewMode.largePixelSize(widthPoints: 0, aspect: 0.75, scale: 3) == 0)
        #expect(MuseumViewMode.largePixelSize(widthPoints: 300, aspect: 0, scale: 2) == 800)
    }

    @Test func viewerDecodeSizeIsTheScreenLongEdge() {
        #expect(MuseumViewMode.viewerPixelSize(for: CGSize(width: 393, height: 852), scale: 3) == 2400)
        #expect(MuseumViewMode.viewerPixelSize(for: CGSize(width: 375, height: 667), scale: 2) == 1334)
        #expect(MuseumViewMode.viewerPixelSize(for: .zero, scale: 3) == 0)
    }
}
