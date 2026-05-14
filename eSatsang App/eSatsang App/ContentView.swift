//
//  ContentView.swift
//  eSatsang App
//
//  Created by Satnam on 13/05/26.
//

import AVFoundation
import AVKit
import Combine
import MediaPlayer
import Security
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoggedIn {
                    PlayView(viewModel: viewModel)
                } else {
                    LoginView(viewModel: viewModel)
                }
            }
            .navigationTitle("eSatsang")
        }
        .navigationViewStyle(.stack)
        .alert(viewModel.alertTitle, isPresented: $viewModel.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.alertMessage)
        }
    }
}

struct LoginView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    enum Field {
        case username
        case password
    }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                    .accessibilityLabel("Username")

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { login() }
                    .accessibilityLabel("Password")
            }

            Section {
                Button {
                    login()
                } label: {
                    if viewModel.isBusy {
                        ProgressView()
                    } else {
                        Text("Login")
                    }
                }
                .disabled(!canLogin || viewModel.isBusy)
                .accessibilityHint("Validates your eSatsang login and remembers it on this device.")
            }
        }
        .navigationTitle("Login")
        .onAppear {
            username = viewModel.savedUsername ?? ""
            focusedField = username.isEmpty ? .username : .password
        }
    }

    private var canLogin: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    private func login() {
        Task {
            await viewModel.login(username: username, password: password)
        }
    }
}

struct PlayView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        await viewModel.togglePlayback()
                    }
                } label: {
                    if viewModel.isBusy {
                        ProgressView()
                    } else {
                        Text(viewModel.isPlaying ? "Pause" : "Play")
                    }
                }
                .disabled(viewModel.isBusy)
                .accessibilityHint(viewModel.playbackHint)

                if viewModel.mediaKind == .video, let player = viewModel.player {
                    VideoPlayer(player: player)
                        .frame(minHeight: 260)
                        .accessibilityLabel("Video player")
                        .accessibilityHint("Native video player controls for the live stream.")
                } else if viewModel.isBuffering {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Buffering…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Buffering, please wait")
                } else if viewModel.isPlaying {
                    Text("Audio is playing. You can pause it from the lock screen, Control Center, or headphone controls.")
                        .accessibilityLabel("Audio is playing")
                }
            }

            Section {
                Button("Logout", role: .destructive) {
                    viewModel.logout()
                }
                .accessibilityHint("Clears the saved login and returns to the login screen.")
            }
        }
        .navigationTitle("Listen")
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var mediaKind: MediaKind?
    @Published private(set) var player: AVPlayer?
    @Published var showAlert = false
    @Published private(set) var alertTitle = ""
    @Published private(set) var alertMessage = ""

    private let api = ESatsangAPI()
    private let credentials = CredentialStore()
    private var heartbeatTask: Task<Void, Never>?
    private var stallRecoveryTask: Task<Void, Never>?
    private var timeControlObserver: AnyCancellable?
    private var interruptionObserver: NSObjectProtocol?

    var savedUsername: String? {
        credentials.username
    }

    var playbackHint: String {
        if isPlaying {
            return mediaKind == .video ? "Pauses the video stream." : "Pauses the audio stream."
        }

        return "Checks whether the stream is live, then opens the native player."
    }

    init() {
        isLoggedIn = CredentialStore().hasSession
        configureRemoteCommands()
        configureInterruptionHandling()
    }

    func login(username: String, password: String) async {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            presentAlert(title: "Login Required", message: "Enter your username and password.")
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let session = try await api.login(username: cleanUsername, password: password)
            try credentials.save(username: cleanUsername, password: password, session: session)
            isLoggedIn = true
        } catch ESatsangError.invalidLogin {
            presentAlert(title: "Login Failed", message: "Incorrect username or password.")
        } catch {
            presentAlert(title: "Login Failed", message: error.localizedDescription)
        }
    }

    func togglePlayback() async {
        // Guard here (not just on the button) so rapid VoiceOver double-taps
        // can't create two concurrent play() calls before isBusy is set.
        guard !isBusy else { return }
        if isPlaying {
            pausePlayback()
        } else if player != nil {
            resumePlayback()
        } else {
            await play()
        }
    }

    private func play() async {
        guard let session = credentials.session else {
            logout()
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let entitlement = try await api.mediaEntitlement(session: session)

            // Entitlement access check and liveness probe are independent — run together.
            async let access = api.checkEntitlement(name: entitlement.name, session: session)
            async let mediaProbe = api.probeMedia(url: entitlement.playbackURL, preferredKind: entitlement.preferredKind)
            let (resolvedAccess, resolvedProbe) = try await (access, mediaProbe)

            guard resolvedAccess.enabled else {
                presentAlert(title: "Cannot Play", message: resolvedAccess.errorText ?? "Access denied.")
                return
            }
            guard resolvedProbe.isLive else {
                presentAlert(title: "Stream Not Live", message: "Stream isnt live right now")
                return
            }

            try configureAudioSession()
            let playerItem = AVPlayerItem(url: entitlement.playbackURL)
            // One segment (≈12 s) of buffer — starts audio as soon as the first segment
            // arrives instead of waiting for the system-default 3 segments (≈36 s).
            playerItem.preferredForwardBufferDuration = 12

            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            mediaKind = resolvedProbe.kind
            updateNowPlayingInfo(isPlaying: true)
            player.play()
            isPlaying = true
            observePlayback(player: player)

            await api.recordAttendance(entitlementName: entitlement.name, session: session)
            startHeartbeat(entitlementName: entitlement.name, session: session)
        } catch ESatsangError.notAuthenticated {
            logout()
            presentAlert(title: "Login Required", message: "Please login again.")
        } catch ESatsangError.noMediaEntitlement {
            presentAlert(title: "Cannot Play", message: "No stream is available for this login.")
        } catch ESatsangError.streamNotLive {
            presentAlert(title: "Stream Not Live", message: "Stream isnt live right now")
        } catch {
            presentAlert(title: "Cannot Play", message: error.localizedDescription)
        }
    }

    func logout() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        timeControlObserver = nil
        player?.pause()
        player = nil
        mediaKind = nil
        isPlaying = false
        isBuffering = false
        clearNowPlayingInfo()
        credentials.clear()
        isLoggedIn = false
    }

    private func resumePlayback() {
        do {
            try configureAudioSession()
            player?.play()
            isPlaying = true
            updateNowPlayingInfo(isPlaying: true)
        } catch {
            presentAlert(title: "Cannot Play", message: error.localizedDescription)
        }
    }

    private func pausePlayback() {
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        player?.pause()
        isPlaying = false
        isBuffering = false
        updateNowPlayingInfo(isPlaying: false)
    }

    private func observePlayback(player: AVPlayer) {
        timeControlObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .playing:
                    isBuffering = false
                    stallRecoveryTask?.cancel()
                    stallRecoveryTask = nil
                case .waitingToPlayAtSpecifiedRate:
                    isBuffering = true
                    // If still stalled after 20 s, jump to the live edge and retry.
                    stallRecoveryTask?.cancel()
                    stallRecoveryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { [weak self] in
                            guard let self, isPlaying else { return }
                            self.player?.seek(to: .positiveInfinity)
                        }
                    }
                case .paused:
                    isBuffering = false
                @unknown default:
                    break
                }
            }
    }

    private func startHeartbeat(entitlementName: String, session: Session) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [api] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                let stillAllowed = await api.heartbeat(entitlementName: entitlementName, session: session)
                if !stillAllowed {
                    await MainActor.run {
                        self.logout()
                        self.presentAlert(title: "Session Ended", message: "Please login again.")
                    }
                    return
                }
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func configureInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                // Call / Siri / alarm started — player already paused by system,
                // just sync the UI so the button shows "Play".
                self.isPlaying = false
                self.updateNowPlayingInfo(isPlaying: false)

            case .ended:
                // Resume only if the system says it's safe to do so.
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                guard options.contains(.shouldResume) else { return }
                self.resumePlayback()

            @unknown default:
                break
            }
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.resumePlayback()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pausePlayback()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.togglePlayback()
            }
            return .success
        }

        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pausePlayback()
            }
            return .success
        }
    }

    private func updateNowPlayingInfo(isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: mediaKind == .video ? "eSatsang Live Video" : "eSatsang Live Audio",
            MPMediaItemPropertyArtist: "Ra Dha Sva Aa Mi Satsang Sabha",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let currentTime = player?.currentTime().seconds, currentTime.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

struct ESatsangAPI {
    private let baseURL = URL(string: "https://api.esatsang.live/wapi/")!
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func login(username: String, password: String) async throws -> Session {
        let uuid = Self.makeWebUUID()
        var request = URLRequest(url: baseURL.appendingPathComponent("loginUser"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(uuid, forHTTPHeaderField: "UUID")
        request.httpBody = try JSONEncoder().encode(LoginRequest(username: username, password: password, mode: "web"))

        let response: LoginResponse = try await send(request)
        guard !response.sessionToken.isEmpty else {
            throw ESatsangError.invalidLogin
        }

        return Session(username: username, uuid: uuid, sessionToken: response.sessionToken)
    }

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
        let contentType = contentType?.lowercased() ?? ""
        if contentType.contains("video") { return .video }
        if contentType.contains("audio") { return .audio }

        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm"].contains(ext) { return .video }
        if ["mp3", "aac", "m4a", "wav", "aiff", "flac", "ogg"].contains(ext) { return .audio }

        // Trust the entitlement metadata for both audio and video —
        // avoids a slow AVURLAsset track-load on every play tap.
        if let preferredKind { return preferredKind }

        return nil
    }


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

        if httpResponse.statusCode == 401 {
            throw ESatsangError.notAuthenticated
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ESatsangError.requestFailed(httpResponse.statusCode)
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

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

struct CredentialStore {
    private let service = "com.silverseahog.esatsang.credentials"
    private let passwordAccount = "password"
    private let defaults = UserDefaults.standard

    var username: String? {
        defaults.string(forKey: "username")
    }

    var session: Session? {
        guard let username,
              let uuid = defaults.string(forKey: "uuid"),
              let token = defaults.string(forKey: "sessionToken"),
              !username.isEmpty,
              !uuid.isEmpty,
              !token.isEmpty else {
            return nil
        }

        return Session(username: username, uuid: uuid, sessionToken: token)
    }

    var hasSession: Bool {
        session != nil
    }

    func save(username: String, password: String, session: Session) throws {
        defaults.set(username, forKey: "username")
        defaults.set(session.uuid, forKey: "uuid")
        defaults.set(session.sessionToken, forKey: "sessionToken")
        try savePassword(password)
    }

    func clear() {
        defaults.removeObject(forKey: "username")
        defaults.removeObject(forKey: "uuid")
        defaults.removeObject(forKey: "sessionToken")
        deletePassword()
    }

    private func savePassword(_ password: String) throws {
        let data = Data(password.utf8)
        deletePassword()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ESatsangError.keychainFailed(status)
        }
    }

    private func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

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

        guard playbackURL != nil else {
            return nil
        }

        if values.contains(where: { $0.contains("video") }) {
            return .video
        }

        if values.contains(where: { $0.contains("audio") || $0 == "mult" }) {
            return .audio
        }

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

struct EmptyResponse: Decodable { }

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
        case .invalidLogin:
            return "Incorrect username or password."
        case .notAuthenticated:
            return "Please login again."
        case .invalidResponse:
            return "The server response could not be read."
        case .requestFailed(let statusCode):
            return "The server returned status \(statusCode)."
        case .noMediaEntitlement:
            return "No stream is available for this login."
        case .streamNotLive:
            return "Stream isnt live right now"
        case .keychainFailed:
            return "The login could not be saved securely."
        }
    }
}
