import Foundation

enum JSON {
    static func string(_ object: Any) -> String { String(decoding: data(object), as: UTF8.self) }
    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func object(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func iso(_ date: Date) -> String { date.formatted(.iso8601) }
}

/// TapKit's error shape: `{"detail":{"error","message","context"}}`.
struct APIError: Error {
    var status: Int
    var code: String
    var message: String
    var context: [String: String] = [:]

    var response: HTTPResponse {
        .json(["detail": ["error": code, "message": message, "context": context]], status: status)
    }

    static func invalid(_ field: String, _ message: String) -> APIError {
        APIError(
            status: 400, code: "INVALID_ARGUMENT", message: "\(field): \(message)",
            context: ["field": field])
    }

    static func phoneNotFound(_ id: String) -> APIError {
        APIError(status: 404, code: "PHONE_NOT_FOUND", message: "Phone not found", context: ["phone_id": id])
    }

    static func notFound(_ what: String = "Not found") -> APIError {
        APIError(status: 404, code: "NOT_FOUND", message: what)
    }

    static func from(_ error: Error, phoneID: String = "") -> APIError {
        if let failure = error as? JobFailure, let underlying = failure.underlying { return from(underlying, phoneID: phoneID) }
        guard let e = error as? PhoneServiceError else {
            return APIError(status: 500, code: "INTERNAL_ERROR", message: "The operation could not be completed")
        }
        switch e {
        case .phoneNotFound(let id): return .phoneNotFound(id.isEmpty ? phoneID : id)
        case .phoneNotReady(let r):
            return APIError(status: 409, code: "PHONE_NOT_READY", message: r, context: ["phone_id": phoneID])
        case .invalidArgument(let m): return APIError(status: 400, code: "INVALID_ARGUMENT", message: m)
        case .timeout: return APIError(status: 408, code: "TIMEOUT", message: "The phone did not respond in time")
        case .failed(let m): return APIError(status: 500, code: "FAILED", message: m)
        }
    }
}

/// Text stored in a failed job's `result.error`.
func jobErrorString(_ error: Error) -> String {
    if let failure = error as? InputFailure { return failure.message }
    if error is CancellationError { return "CANCELLED" }
    guard let e = error as? PhoneServiceError else { return "The operation could not be completed." }
    switch e {
    case .phoneNotFound(let id): return "PHONE_NOT_FOUND: \(id)"
    case .phoneNotReady(let r): return "PHONE_NOT_READY: \(r)"
    case .timeout: return "TIMEOUT"
    case .failed(let m): return m
    case .invalidArgument(let m): return "INVALID_ARGUMENT: \(m)"
    }
}

func phoneJSON(_ p: PhoneRecord) -> [String: Any] {
    [
        "id": p.id, "name": p.name, "display_name": p.displayName ?? NSNull(),
        "connection_status": p.connectionStatus.rawValue, "activation_state": "active",
        "connected_mac_id": macIdentifier, "width": p.width ?? NSNull(),
        "height": p.height ?? NSNull(), "created_at": JSON.iso(p.createdAt),
        "status_reason": p.statusReason ?? NSNull(), "model": p.model ?? NSNull(),
    ]
}

let macIdentifier: String = Host.current().localizedName ?? "this-mac"
