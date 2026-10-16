// Added in this fork (taehee-pd/harperSwift).
//
// Small pieces shared by the native windows.

import AppKit
import SwiftUI

/// The system search field, with its magnifier, clear button, and Escape to clear.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// An installed app's icon, or a generic app icon when the app is not found.
struct AppIcon: View {
    let bundleId: String
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: Self.icon(for: bundleId))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleId: String) -> NSImage {
        if let cached = cache[bundleId] {
            return cached
        }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        cache[bundleId] = icon
        return icon
    }
}

/// A white symbol on a colored rounded square, like the icons in the System Settings sidebar.
struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(color.gradient)
            )
            .accessibilityHidden(true)
    }
}

/// A title in the window's toolbar band, where System Settings shows the page name.
struct ToolbarTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Sets the title of the window that shows this view; the unified toolbar displays it over the
/// detail column, where System Settings shows the page name.
struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if view.window?.title != title {
                view.window?.title = title
            }
        }
    }
}

/// The frosted, see-through material of the system sidebars, for a whole window background. It
/// blurs what is behind the window, dims while the window is inactive, and turns solid when the
/// user asks for reduced transparency, all like the system's own.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// The "…" button at the end of a row, like the rows in System Settings' Wi-Fi list, with actions
/// for that row.
struct RowMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A row title with a smaller explanation under it, the way grouped forms show them.
struct RowLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
