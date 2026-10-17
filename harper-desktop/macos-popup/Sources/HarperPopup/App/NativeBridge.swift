// Added in this fork (taehee-pd/harperSwift).
//
// The native windows (Settings, first-run setup, editor) run in the Tauri app process and ask
// Rust for data and changes (`src-tauri/src/native_ui/`). A request is JSON with an id; Rust
// answers later, on the main thread, with `{"ok": value}` or `{"error": message}`.

import AppKit
import Foundation

public typealias HarperNativeRequestHandler = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Void

@MainActor
enum NativeBridge {
    struct RemoteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Set by Rust at startup. `nil` in the highlighter process and in previews.
    static var requestHandler: HarperNativeRequestHandler?

    private static var nextID: UInt64 = 0
    private static var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Sends a request and decodes the value Rust answers with.
    static func request<Response: Decodable>(
        _ method: String,
        _ params: [String: Any] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await send(method, params)
        let envelope = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let object = envelope as? [String: Any] else {
            throw RemoteError(message: "Unexpected reply to \(method)")
        }
        if let message = object["error"] as? String {
            throw RemoteError(message: message)
        }
        let value = try JSONSerialization.data(
            withJSONObject: object["ok"] ?? NSNull(),
            options: [.fragmentsAllowed]
        )
        return try decoder.decode(Response.self, from: value)
    }

    /// Sends a request whose answer carries no value.
    static func perform(_ method: String, _ params: [String: Any] = [:]) async throws {
        _ = try await request(method, params, as: Ignored.self)
    }

    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private static func send(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let handler = requestHandler else {
            throw RemoteError(message: "Harper is not running.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        guard let json = String(data: body, encoding: .utf8) else {
            throw RemoteError(message: "Could not encode \(method)")
        }

        nextID &+= 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            json.withCString { handler(id, $0) }
        }
    }

    fileprivate static func respond(id: UInt64, json: String) {
        pending.removeValue(forKey: id)?.resume(returning: Data(json.utf8))
    }
}

@_cdecl("harper_native_set_request_handler")
public func harperNativeSetRequestHandler(_ handler: HarperNativeRequestHandler?) {
    MainActor.assumeIsolated { NativeBridge.requestHandler = handler }
}

@_cdecl("harper_native_respond")
public func harperNativeRespond(_ id: UInt64, _ json: UnsafePointer<CChar>?) {
    guard let json else { return }
    let text = String(cString: json)
    MainActor.assumeIsolated { NativeBridge.respond(id: id, json: text) }
}

@_cdecl("harper_native_show_settings")
public func harperNativeShowSettings() {
    MainActor.assumeIsolated { AppWindows.showSettingsOrSetup() }
}

@_cdecl("harper_native_show_editor")
public func harperNativeShowEditor() {
    MainActor.assumeIsolated { AppWindows.showEditor() }
}
