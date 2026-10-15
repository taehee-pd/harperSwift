// Added in this fork (taehee-pd/harperSwift).

import CoreGraphics
import Foundation

/// Everything the popup shows for one lint. Sent by Rust as JSON (`native_popup/payload.rs`);
/// `Tests/HarperPopupTests/Fixtures/popup.json` pins the format for both sides.
struct PopupData: Decodable, Equatable {
    struct Rect: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct RGB: Decodable, Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    struct Suggestion: Decodable, Equatable {
        enum Kind: String, Decodable {
            case replace
            /// Insert `label` after the flagged text.
            case insert
            case remove
        }

        let kind: Kind
        /// The replacement or inserted text; "Remove" for removals.
        let label: String
        /// Tooltip and VoiceOver label, such as "Replace “Ths” with “This”".
        let description: String
    }

    /// Changes whenever Rust shows different content; echoed back with every action.
    let id: UInt64
    let kindName: String
    /// The underline color for this kind of lint.
    let kindColor: RGB
    let ruleName: String
    /// Markdown.
    let message: String
    let suggestions: [Suggestion]
    let flaggedText: String
    let canAddToDictionary: Bool
    /// The flagged word in Accessibility coordinates (top-left origin, points).
    let anchor: Rect

    static func decode(_ json: Data) throws -> PopupData {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PopupData.self, from: json)
    }

    static func decode(_ json: UnsafePointer<CChar>?) -> PopupData? {
        guard let json else { return nil }

        do {
            return try decode(Data(String(cString: json).utf8))
        } catch {
            FileHandle.standardError.write(Data("HarperPopup: invalid popup data: \(error)\n".utf8))
            return nil
        }
    }
}

/// One user action, reported to Rust through `harper_popup_set_action_handler`.
enum PopupAction: Equatable {
    case close
    case applySuggestion(Int)
    case ignoreLint
    case addToDictionary
    case disableRule

    /// Wire format shared with `NativeAction::from_raw` in `native_popup/action.rs`:
    /// an action kind and a suggestion index (-1 when unused).
    var raw: (kind: UInt32, index: Int64) {
        switch self {
        case .close: (0, -1)
        case .applySuggestion(let index): (1, Int64(index))
        case .ignoreLint: (2, -1)
        case .addToDictionary: (3, -1)
        case .disableRule: (4, -1)
        }
    }
}
