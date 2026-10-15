// Added in this fork (taehee-pd/harperSwift).

import AppKit
import SwiftUI

/// Borderless panel that never activates Harper and never becomes the key window, so the app the
/// user is typing in keeps keyboard focus, its caret, and its active title bar.
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // Harper is never the active app, so the default (hide on deactivate) would hide us at once.
        hidesOnDeactivate = false
        // Above the always-on-top underline overlay windows.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets SwiftUI buttons react to the first click even though the panel is never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the single popup panel. Rust decides what is shown; this type only displays it and places
/// it next to the flagged word.
@MainActor
final class PopupController {
    static let shared = PopupController()

    /// Set once by Rust at startup.
    static var actionHandler: HarperPopupActionHandler?

    private let panel = PopupPanel()
    private let background = NSVisualEffectView()
    private let hostingView = FirstClickHostingView(rootView: PopupView(data: nil, onAction: { _ in }))
    private var data: PopupData?
    /// Where the last placement put the popup relative to the word, for the entrance animation.
    private var edge = PopupEdge.below
    private var wordCenterX: CGFloat = 0
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    private init() {
        background.material = .popover
        background.blendingMode = .behindWindow
        // Harper is never active; without this the material would render in its inactive style.
        background.state = .active
        background.maskImage = .roundedMask(radius: 12)
        background.wantsLayer = true

        hostingView.autoresizingMask = [.width, .height]
        background.addSubview(hostingView)
        panel.contentView = background
    }

    func show(_ data: PopupData) {
        render(data)
        startObserving()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animateIn()
        announce(data)
    }

    func update(_ data: PopupData) {
        guard panel.isVisible else {
            show(data)
            return
        }

        let isNewContent = data.id != self.data?.id
        render(data)

        if isNewContent {
            announce(data)
        }
    }

    func hide() {
        stopObserving()
        panel.orderOut(nil)
        data = nil
    }

    /// Whether a point in Accessibility coordinates (top-left origin) falls on the visible popup.
    func contains(topLeftPoint point: CGPoint) -> Bool {
        guard panel.isVisible else { return false }

        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return panel.frame.contains(PopupGeometry.appKitPoint(fromTopLeft: point, primaryScreenHeight: primaryHeight))
    }

    private func render(_ data: PopupData) {
        self.data = data
        hostingView.rootView = PopupView(data: data) { [weak self] action in
            self?.send(action)
        }
        reposition()
    }

    /// Reports an action to Rust. Rust decides what happens next, including hiding the popup.
    private func send(_ action: PopupAction) {
        guard let data, let handler = Self.actionHandler else { return }

        let raw = action.raw
        handler(data.id, raw.kind, raw.index)
    }

    /// Measures the SwiftUI content and places the panel on the screen that shows the word.
    private func reposition() {
        guard let data else { return }

        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.maxY ?? 0
        let anchor = PopupGeometry.appKitRect(fromTopLeft: data.anchor.cgRect, primaryScreenHeight: primaryHeight)

        guard let index = PopupGeometry.screenIndex(for: anchor, screenFrames: screens.map(\.frame)) else {
            return
        }

        let placement = PopupGeometry.place(
            anchor: anchor,
            popupSize: hostingView.fittingSize,
            visibleFrame: screens[index].visibleFrame
        )

        panel.setFrame(placement.frame, display: true)
        hostingView.frame = background.bounds
        panel.invalidateShadow()
        edge = placement.edge
        wordCenterX = anchor.midX - placement.frame.minX
    }

    /// Fades in over 120 ms while growing slightly out of the word. With Reduce Motion on, only
    /// the fade runs.
    private func animateIn() {
        let duration = 0.12
        let timing = CAMediaTimingFunction(name: .easeOut)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            panel.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated { PopupController.shared.panel.invalidateShadow() }
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = background.layer
        else { return }

        let bounds = layer.bounds
        let pivot = CGPoint(
            x: min(max(wordCenterX, 0), bounds.width),
            y: edge == .below ? bounds.maxY : bounds.minY
        )
        // Transforms apply around the layer's anchor point, so express the pivot relative to it.
        let offset = CGPoint(
            x: pivot.x - bounds.width * layer.anchorPoint.x,
            y: pivot.y - bounds.height * layer.anchorPoint.y
        )
        let scale: CGFloat = 0.95
        let from = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-offset.x, -offset.y, 0),
                CATransform3DMakeScale(scale, scale, 1)
            ),
            CATransform3DMakeTranslation(offset.x, offset.y, 0)
        )

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "harper-popup-scale-in")
    }

    /// Lets VoiceOver read the popup even though it never takes keyboard focus.
    private func announce(_ data: PopupData) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: PopupText.announcement(for: data),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func startObserving() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PopupController.shared.reposition() }
        }

        // Another app became active (Command-Tab, Dock, clicking another window): close.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { PopupController.shared.send(.close) }
        }
    }

    private func stopObserving() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        screenObserver = nil
        activationObserver = nil
    }
}

extension NSImage {
    /// Stretchable rounded-rect mask; the window shadow follows its shape.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
