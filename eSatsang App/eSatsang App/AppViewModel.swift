import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

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
    private var playbackObservers = Set<AnyCancellable>()
    private var interruptionObserver: NSObjectProtocol?

    var savedUsername: String? { credentials.username }

    var playbackHint: String {
        if isPlaying {
            return mediaKind == .video ? "Pauses the video stream." : "Pauses the audio stream."
        }
        return "Checks whether the stream is live, then starts playback."
    }

    init() {
        isLoggedIn = CredentialStore().hasSession
        configureRemoteCommands()
        configureInterruptionHandling()
    }

    // MARK: - Login

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

    // MARK: - Playback control

    func togglePlayback() async {
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
        // Use stored session, or try a silent re-login if the token has expired.
        let session: Session
        if let stored = credentials.session {
            session = stored
        } else if await silentRelogin(), let refreshed = credentials.session {
            session = refreshed
        } else {
            expireSession()
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let entitlement = try await api.mediaEntitlement(session: session)

            let access = try await api.checkEntitlement(name: entitlement.name, session: session)
            guard access.enabled else {
                presentAlert(title: "Cannot Play", message: access.errorText ?? "Access denied.")
                return
            }

            try configureAudioSession()

            let playerItem = AVPlayerItem(url: entitlement.playbackURL)
            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            mediaKind = entitlement.preferredKind ?? .audio
            updateNowPlayingInfo(isPlaying: true)
            player.play()
            isPlaying = true
            observePlayback(player: player)

            await api.recordAttendance(entitlementName: entitlement.name, session: session)
            startHeartbeat(entitlementName: entitlement.name, session: session)
        } catch ESatsangError.notAuthenticated {
            expireSession()
            presentAlert(title: "Session Expired", message: "Please login again.")
        } catch ESatsangError.noMediaEntitlement {
            presentAlert(title: "Cannot Play", message: "No stream is available for this login.")
        } catch {
            presentAlert(title: "Cannot Play", message: error.localizedDescription)
        }
    }

    func logout() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackObservers.removeAll()
        player?.pause()
        player = nil
        mediaKind = nil
        isPlaying = false
        isBuffering = false
        clearNowPlayingInfo()
        credentials.clear()
        isLoggedIn = false
    }

    /// Session expired — stop playback and go to login screen, but keep the
    /// username and Keychain password so re-login is pre-filled / one tap.
    private func expireSession() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackObservers.removeAll()
        player?.pause()
        player = nil
        mediaKind = nil
        isPlaying = false
        isBuffering = false
        clearNowPlayingInfo()
        credentials.clearSession()
        isLoggedIn = false
    }

    /// Attempts a silent re-login using stored Keychain credentials.
    /// Returns true if the session was successfully refreshed.
    @discardableResult
    private func silentRelogin() async -> Bool {
        guard let username = credentials.username,
              let password = credentials.readPassword() else { return false }
        do {
            let session = try await api.login(username: username, password: password)
            try credentials.save(username: username, password: password, session: session)
            return true
        } catch {
            return false
        }
    }

    private func resumePlayback() {
        // If player item failed (e.g. expired CDN token), fetch fresh entitlements.
        if player == nil || player?.currentItem?.status == .failed {
            playbackObservers.removeAll()
            player?.pause()
            player = nil
            Task { await play() }
            return
        }
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

    // MARK: - Playback observation

    private func observePlayback(player: AVPlayer) {
        playbackObservers.removeAll()

        // Track buffering state for UI feedback.
        player.publisher(for: \.timeControlStatus)
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
                    stallRecoveryTask?.cancel()
                    stallRecoveryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run { [weak self] in
                            guard let self, isPlaying else { return }
                            playbackObservers.removeAll()
                            self.player?.pause()
                            self.player = nil
                        }
                        await self?.play()
                    }
                case .paused:
                    isBuffering = false
                @unknown default:
                    break
                }
            }
            .store(in: &playbackObservers)

        // If the item fails to load, the stream isn't reachable right now.
        player.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 == .failed }
            .first()
            .sink { [weak self] _ in
                guard let self, isPlaying else { return }
                playbackObservers.removeAll()
                self.player?.pause()
                self.player = nil
                isPlaying = false
                isBuffering = false
                updateNowPlayingInfo(isPlaying: false)
                presentAlert(title: "Stream Not Live", message: "The stream isn't available right now. Try again later.")
            }
            .store(in: &playbackObservers)
    }

    // MARK: - Heartbeat

    private func startHeartbeat(entitlementName: String, session: Session) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [api] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                let stillAllowed = await api.heartbeat(entitlementName: entitlementName, session: session)
                if !stillAllowed {
                    await MainActor.run {
                        self.expireSession()
                        self.presentAlert(title: "Session Ended", message: "Please login again.")
                    }
                    return
                }
            }
        }
    }

    // MARK: - Audio session

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
                self.isPlaying = false
                self.updateNowPlayingInfo(isPlaying: false)
            case .ended:
                let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                guard options.contains(.shouldResume) else { return }
                self.resumePlayback()
            @unknown default:
                break
            }
        }
    }

    // MARK: - Remote commands

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumePlayback() }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlayback() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.togglePlayback() }
            return .success
        }

        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlayback() }
            return .success
        }
    }

    // MARK: - Now Playing

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

    // MARK: - Alerts

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
