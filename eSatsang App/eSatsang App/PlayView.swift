import AVKit
import SwiftUI

struct PlayView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await viewModel.togglePlayback() }
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
        }
        .navigationTitle("Listen")
    }
}
