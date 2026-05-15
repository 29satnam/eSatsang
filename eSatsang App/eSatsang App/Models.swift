import Foundation

struct Session: Codable {
    let username: String
    let uuid: String
    let sessionToken: String
}

enum MediaKind: Equatable {
    case audio
    case video
}

struct MediaEntitlement {
    let name: String
    let playbackURL: URL
    let preferredKind: MediaKind?
}

struct MediaProbe {
    let isLive: Bool
    let kind: MediaKind
}

struct MediaProbeResponse {
    let statusCode: Int?
    let contentType: String?
}

// MARK: - API request / response shapes

struct LoginRequest: Encodable {
    let username: String
    let password: String
    let mode: String
}

struct LoginResponse: Decodable {
    let sessionToken: String
}

struct EntitlementsResponse: Decodable {
    let entitlements: [Entitlement]
}

struct Entitlement: Decodable {
    let type: String?
    let entitlementText: String?
    let entitlementName: String
    let entitlementURL: String?

    var playbackURL: URL? {
        entitlementURL.flatMap(URL.init(string:))
    }

    var mediaKind: MediaKind? {
        let values = [type, entitlementText, entitlementName, entitlementURL]
            .compactMap { $0?.lowercased() }

        guard playbackURL != nil else { return nil }

        if values.contains(where: { $0.contains("video") }) { return .video }
        if values.contains(where: { $0.contains("audio") || $0 == "mult" }) { return .audio }
        return nil
    }
}

struct EntitlementAccess: Decodable {
    let enabled: Bool
    let errorText: String?
}

struct EventRequest: Encodable {
    let eventID: String
    let entitlementName: String
}

struct HeartbeatResponse: Decodable {
    let code: Int?
}

struct EmptyResponse: Decodable {}

// MARK: - Errors

enum ESatsangError: LocalizedError {
    case invalidLogin
    case notAuthenticated
    case invalidResponse
    case requestFailed(Int)
    case noMediaEntitlement
    case streamNotLive
    case keychainFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidLogin:       return "Incorrect username or password."
        case .notAuthenticated:   return "Please login again."
        case .invalidResponse:    return "The server response could not be read."
        case .requestFailed(let code): return "The server returned status \(code)."
        case .noMediaEntitlement: return "No stream is available for this login."
        case .streamNotLive:      return "Stream isnt live right now"
        case .keychainFailed:     return "The login could not be saved securely."
        }
    }
}
