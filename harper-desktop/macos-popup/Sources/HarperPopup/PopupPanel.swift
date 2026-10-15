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

/// The panel background, matched to the system popovers of each release: Liquid Glass on macOS 26
/// and later, the popover material before.
enum PopupChrome {
    case glass
    case material

    static var current: PopupChrome {
        // Older Xcode versions do not know the glass API.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return .glass
        }
        #endif
        return .material
    }

    var cornerRadius: CGFloat {
        switch self {
        case .glass: 16
        case .material: 12
        }
    }

    /// Glass draws its own edge. The flat material needs a hairline to stand apart from similar
    /// colors behind it.
    var drawsBorder: Bool { self == .material }

    /// Wraps `content` in the background view.
    @MainActor
    func makeBackground(around content: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *), self == .glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            glass.wantsLayer = true
            return glass
        }
        #endif

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        // Harper is never active; without this the material would render in its inactive style.
        material.state = .active
        material.maskImage = .roundedMask(radius: cornerRadius)
        material.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        material.addSubview(content)
        return material
    }
}

/// Timing for showing and hiding the popup. It grows out of the word and shrinks back into it
/// along the same path; the exit is a little faster, like system popovers.
private enum Motion {
    static let enterDuration: TimeInterval = 0.12
    static let exitDuration: TimeInterval = 0.1
    /// Scale of the popup when it is hidden, before it grows to full size.
    static let hiddenScale: CGFloat = 0.95
    static let scaleKey = "harper-popup-scale"
}

/// Owns the single popup panel. Rust decides what is shown; this type only displays it and places
/// it next to the flagged word.
@MainActor
final class PopupController {
    static let shared = PopupController()

    /// Set once by Rust at startup.
    static var actionHandler: HarperPopupActionHandler?

    private enum Phase {
        case hidden
        case shown
        /// Fading out: still on screen, but ignoring the mouse.
        case hiding
    }

    private let panel = PopupPanel()
    private let chrome = PopupChrome.current
    private let background: NSView
    private let hostingView: FirstClickHostingView<PopupView>
    private var data: PopupData?
    private var phase = Phase.hidden
    /// Bumped by every `show`, so a fade-out that `show` interrupted does not order the panel out.
    private var generation: UInt64 = 0
    /// Where the last placement put the popup relative to the word, for the scale animation.
    private var edge = PopupEdge.below
    private var wordCenterX: CGFloat = 0
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    private init() {
        hostingView = FirstClickHostingView(rootView: PopupView(data: nil, chrome: chrome, onAction: { _ in }))
        background = chrome.makeBackground(around: hostingView)
        panel.contentView = background
    }

    func show(_ data: PopupData) {
        let previous = phase
        let sameWord = data.anchor == self.data?.anchor
        generation &+= 1
        phase = .shown
        panel.ignoresMouseEvents = false
        render(data)
        startObserving()

        switch previous {
        case .hidden:
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animateIn(fromScale: Motion.hiddenScale)
        case .hiding:
            // Same word: reverse the exit from wherever it got to. Another word: the panel moved,
            // so the old scale pivot no longer applies; grow out of the new word instead.
            animateIn(fromScale: sameWord ? nil : Motion.hiddenScale)
        case .shown:
            // Another word was clicked while the popup was open: swap the content in place, the
            // way menus switch when the pointer moves between them.
            break
        }

        announce(data)
    }

    func update(_ data: PopupData) {
        guard phase == .shown else {
            show(data)
            return
        }

        let isNewContent = data.id != self.data?.id
        render(data)

        if isNewContent {
            announce(data)
        }
    }

    /// Fades out and shrinks back toward the word. The content stays until the panel is ordered
    /// out, so the popup does not go blank while it fades.
    func hide() {
        guard phase == .shown else { return }

        phase = .hiding
        stopObserving()
        panel.ignoresMouseEvents = true

        let generation = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.exitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { PopupController.shared.finishHiding(generation) }
        }
        animateScale(from: nil, to: Motion.hiddenScale, duration: Motion.exitDuration, timing: .easeIn)
    }

    /// Whether a point in Accessibility coordinates (top-left origin) falls on the visible popup.
    /// A popup that is fading out no longer counts.
    func contains(topLeftPoint point: CGPoint) -> Bool {
        guard phase == .shown else { return false }

        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return panel.frame.contains(PopupGeometry.appKitPoint(fromTopLeft: point, primaryScreenHeight: primaryHeight))
    }

    private func finishHiding(_ generation: UInt64) {
        // `show` took the panel back during the fade.
        guard generation == self.generation, phase == .hiding else { return }

        phase = .hidden
        panel.orderOut(nil)
        background.layer?.removeAnimation(forKey: Motion.scaleKey)
        data = nil
    }

    private func render(_ data: PopupData) {
        self.data = data
        hostingView.rootView = PopupView(data: data, chrome: chrome) { [weak self] action in
            self?.send(action)
        }
        reposition()
    }

    /// Reports an action to Rust. Rust decides what happens next, including hiding the popup.
    private func send(_ action: PopupAction) {
        guard phase == .shown, let data, let handler = Self.actionHandler else { return }

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

    /// Fades in while growing out of the word. `fromScale` nil continues from what is on screen,
    /// which reverses an interrupted exit without a jump.
    private func animateIn(fromScale scale: CGFloat?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.enterDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated { PopupController.shared.panel.invalidateShadow() }
        }
        animateScale(from: scale, to: 1, duration: Motion.enterDuration, timing: .easeOut)
    }

    /// Scales the background around the point nearest the word. With Reduce Motion on, only the
    /// fades run.
    private func animateScale(
        from start: CGFloat?,
        to end: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard let layer = background.layer else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: Motion.scaleKey)
            return
        }

        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: start.map { scaleTransform($0, of: layer) } ?? current)
        animation.toValue = NSValue(caTransform3D: scaleTransform(end, of: layer))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        // The layer's own transform stays identity, so an exit holds its end scale until
        // `finishHiding` removes it.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = end == 1
        layer.add(animation, forKey: Motion.scaleKey)
    }

    /// A scale around the point where the popup meets the word.
    private func scaleTransform(_ scale: CGFloat, of layer: CALayer) -> CATransform3D {
        guard scale != 1 else { return CATransform3DIdentity }

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
        return CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-offset.x, -offset.y, 0),
                CATransform3DMakeScale(scale, scale, 1)
            ),
            CATransform3DMakeTranslation(offset.x, offset.y, 0)
        )
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
