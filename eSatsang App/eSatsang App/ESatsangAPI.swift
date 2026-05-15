import Foundation

struct ESatsangAPI {
    private let baseURL = URL(string: "https://api.esatsang.live/wapi/")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws -> Session {
        let uuid = Self.makeWebUUID()
        var request = URLRequest(url: baseURL.appendingPathComponent("loginUser"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(uuid, forHTTPHeaderField: "UUID")
        request.httpBody = try JSONEncoder().encode(LoginRequest(username: username, password: password, mode: "web"))

        let response: LoginResponse = try await send(request)
        guard !response.sessionToken.isEmpty else { throw ESatsangError.invalidLogin }
        return Session(username: username, uuid: uuid, sessionToken: response.sessionToken)
    }

    // MARK: - Entitlements

    func mediaEntitlement(session: Session) async throws -> MediaEntitlement {
        var request = authenticatedRequest(path: "v2/getUserEntitlements", session: session)
        request.httpMethod = "GET"

        let response: EntitlementsResponse = try await send(request)
        guard let entitlement = response.entitlements.first(where: { $0.mediaKind != nil }) ??
                response.entitlements.first(where: { $0.playbackURL != nil }) else {
            throw ESatsangError.noMediaEntitlement
        }
        guard let playbackURL = entitlement.playbackURL else {
            throw ESatsangError.noMediaEntitlement
        }

        return MediaEntitlement(name: entitlement.entitlementName, playbackURL: playbackURL, preferredKind: entitlement.mediaKind)
    }

    func checkEntitlement(name: String, session: Session) async throws -> EntitlementAccess {
        var components = URLComponents(url: baseURL.appendingPathComponent("entitlement"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "entitlement_name", value: name)]
        var request = authenticatedRequest(url: components.url!, session: session)
        request.httpMethod = "GET"
        return try await send(request)
    }

    // MARK: - Stream probe

    func probeMedia(url: URL, preferredKind: MediaKind?) async throws -> MediaProbe {
        let response = try await fetchMediaProbeResponse(url: url)
        let isLive = response.statusCode.map { (200...299).contains($0) } ?? false
        let kind = Self.kindFrom(preferredKind: preferredKind, url: url, contentType: response.contentType) ?? .audio
        return MediaProbe(isLive: isLive, kind: kind)
    }

    private func fetchMediaProbeResponse(url: URL) async throws -> MediaProbeResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return MediaProbeResponse(statusCode: nil, contentType: nil)
        }
        return MediaProbeResponse(
            statusCode: httpResponse.statusCode,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private static func kindFrom(preferredKind: MediaKind?, url: URL, contentType: String?) -> MediaKind? {
        let ct = contentType?.lowercased() ?? ""
        if ct.contains("video") { return .video }
        if ct.contains("audio") { return .audio }

        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm"].contains(ext) { return .video }
        if ["mp3", "aac", "m4a", "wav", "aiff", "flac", "ogg"].contains(ext) { return .audio }

        if let preferredKind { return preferredKind }
        return nil
    }

    // MARK: - Session events

    func recordAttendance(entitlementName: String, session: Session) async {
        var request = authenticatedRequest(path: "recordUserAttendance", session: session)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(EventRequest(eventID: Self.currentEventID(), entitlementName: entitlementName))
        let _: EmptyResponse? = try? await send(request)
    }

    func heartbeat(entitlementName: String, session: Session) async -> Bool {
        var request = authenticatedRequest(path: "heartbeat", session: session)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(EventRequest(eventID: Self.currentEventID(), entitlementName: entitlementName))

        do {
            let response: HeartbeatResponse = try await send(request)
            return response.code != 1000
        } catch {
            return true
        }
    }

    // MARK: - Helpers

    private func authenticatedRequest(path: String, session: Session) -> URLRequest {
        authenticatedRequest(url: baseURL.appendingPathComponent(path), session: session)
    }

    private func authenticatedRequest(url: URL, session: Session) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(session.sessionToken, forHTTPHeaderField: "SESSION_TOKEN")
        request.setValue(session.uuid, forHTTPHeaderField: "UUID")
        request.setValue(session.username, forHTTPHeaderField: "UID")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ESatsangError.invalidResponse
        }
        if httpResponse.statusCode == 401 { throw ESatsangError.notAuthenticated }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ESatsangError.requestFailed(httpResponse.statusCode)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func makeWebUUID() -> String {
        "\(UUID().uuidString.lowercased())rs\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    private static func currentEventID() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
