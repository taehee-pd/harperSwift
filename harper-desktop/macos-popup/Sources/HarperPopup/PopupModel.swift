// Added in this fork (taehee-pd/harperSwift).

import CoreGraphics
import Foundation

/// Everything the popup shows for one lint. Sent by Rust as JSON (`native_popup/payload.rs`).
struct PopupData: Decodable, Equatable {
    struct Rect: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// Changes whenever Rust shows different content; echoed back with every action.
    let id: UInt64
    /// The flagged word in Accessibility coordinates (top-left origin, points).
    let anchor: Rect

    static func decode(_ json: UnsafePointer<CChar>?) -> PopupData? {
        guard let json else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(PopupData.self, from: Data(String(cString: json).utf8))
        } catch {
            FileHandle.standardError.write(Data("HarperPopup: invalid popup data: \(error)\n".utf8))
            return nil
        }
    }
}
