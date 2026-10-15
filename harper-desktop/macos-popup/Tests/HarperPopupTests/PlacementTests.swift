// Added in this fork (taehee-pd/harperSwift).

import CoreGraphics
import Testing

@testable import HarperPopup

/// A 1512 x 982 pt main display with a 37 pt menu bar and a 70 pt Dock at the bottom.
private let mainScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let mainVisible = CGRect(x: 0, y: 70, width: 1512, height: 875)
private let popupSize = CGSize(width: 320, height: 160)
private let margin = PopupGeometry.margin
private let gap = PopupGeometry.gap

/// Builds an anchor in AppKit coordinates from its top-left corner, the way a word looks on screen.
private func word(x: CGFloat, top: CGFloat, width: CGFloat = 60, height: CGFloat = 18) -> CGRect {
    CGRect(x: x, y: top - height, width: width, height: height)
}

struct PlacementTests {
    @Test func placesBelowAndAlignsLeadingEdges() {
        let anchor = word(x: 400, top: 600)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: mainVisible)

        #expect(placement.edge == .below)
        #expect(!placement.flipped)
        #expect(placement.frame.maxY == anchor.minY - gap)
        #expect(placement.frame.minX == anchor.minX)
        #expect(placement.frame.size == popupSize)
    }

    @Test func flipsAboveWhenWordIsNearBottomEdge() {
        let anchor = word(x: 400, top: 200)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: mainVisible)

        #expect(placement.flipped)
        #expect(placement.frame.minY == anchor.maxY + gap)
        #expect(placement.frame.minX == anchor.minX)
    }

    @Test func shiftsLeftWhenWordIsNearRightEdge() {
        let anchor = word(x: 1400, top: 600)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: mainVisible)

        #expect(placement.edge == .below)
        #expect(placement.frame.maxX == mainVisible.maxX - margin)
    }

    @Test func flipsAndShiftsInBottomRightCorner() {
        let anchor = word(x: 1450, top: 120)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: mainVisible)

        #expect(placement.flipped)
        #expect(placement.frame.minY == anchor.maxY + gap)
        #expect(placement.frame.maxX == mainVisible.maxX - margin)
    }

    @Test func placesOnSecondaryMonitorAboveMain() {
        // A 1920 x 1080 monitor sitting directly above the main display, with its own menu bar.
        let upperScreen = CGRect(x: -200, y: 982, width: 1920, height: 1080)
        let upperVisible = CGRect(x: -200, y: 982, width: 1920, height: 1055)

        // Accessibility reports a word on that monitor with a negative y (above the main display).
        let axWord = CGRect(x: -100, y: -900, width: 80, height: 20)
        let anchor = PopupGeometry.appKitRect(fromTopLeft: axWord, primaryScreenHeight: mainScreen.height)
        #expect(anchor == CGRect(x: -100, y: 1862, width: 80, height: 20))

        let index = PopupGeometry.screenIndex(for: anchor, screenFrames: [mainScreen, upperScreen])
        #expect(index == 1)

        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: upperVisible)
        #expect(placement.edge == .below)
        #expect(placement.frame.maxY == anchor.minY - gap)
        #expect(placement.frame.minX == anchor.minX)
        #expect(upperVisible.contains(placement.frame))
    }

    @Test func clampsOnRoomierSideWhenScreenIsTooSmallForEitherSide() {
        let smallVisible = CGRect(x: 0, y: 0, width: 800, height: 300)
        let tallPopup = CGSize(width: 320, height: 200)

        // More room below (176 pt) than above (76 pt), but neither side fits 200 pt.
        let anchor = word(x: 100, top: 210, height: 20)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: tallPopup, visibleFrame: smallVisible)

        #expect(placement.edge == .below)
        #expect(placement.frame.minY == smallVisible.minY + margin)
        #expect(placement.frame.maxY <= smallVisible.maxY - margin)
    }

    @Test func keepsTopVisibleWhenPopupIsTallerThanScreen() {
        let smallVisible = CGRect(x: 0, y: 0, width: 800, height: 150)
        let anchor = word(x: 100, top: 100, height: 20)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: smallVisible)

        #expect(placement.frame.maxY == smallVisible.maxY - margin)
    }

    @Test func neverShiftsPastLeadingEdgeOfVisibleFrame() {
        let narrowVisible = CGRect(x: -1000, y: 0, width: 300, height: 900)
        let anchor = word(x: -900, top: 600)
        let placement = PopupGeometry.place(anchor: anchor, popupSize: popupSize, visibleFrame: narrowVisible)

        #expect(placement.frame.minX == narrowVisible.minX)
    }

    @Test func convertsMonitorLeftOfMain() {
        let axWord = CGRect(x: -1500, y: 300, width: 50, height: 16)
        let anchor = PopupGeometry.appKitRect(fromTopLeft: axWord, primaryScreenHeight: 982)

        #expect(anchor == CGRect(x: -1500, y: 666, width: 50, height: 16))

        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(PopupGeometry.screenIndex(for: anchor, screenFrames: [mainScreen, leftScreen]) == 1)
    }

    @Test func convertsPoints() {
        let point = PopupGeometry.appKitPoint(fromTopLeft: CGPoint(x: 10, y: 100), primaryScreenHeight: 982)
        #expect(point == CGPoint(x: 10, y: 882))
    }

    @Test func picksOverlappingOrNearestScreenWhenCenterIsOffScreen() {
        let rightScreen = CGRect(x: 1512, y: 0, width: 1000, height: 800)

        // Center is in the gap above the right screen, but the rect overlaps it.
        let straddling = CGRect(x: 1600, y: 790, width: 40, height: 30)
        #expect(PopupGeometry.screenIndex(for: straddling, screenFrames: [mainScreen, rightScreen]) == 1)

        // Fully off-screen: nearest screen wins.
        let offScreen = CGRect(x: 3000, y: 100, width: 10, height: 10)
        #expect(PopupGeometry.screenIndex(for: offScreen, screenFrames: [mainScreen, rightScreen]) == 1)
        #expect(PopupGeometry.screenIndex(for: offScreen, screenFrames: []) == nil)
    }
}
