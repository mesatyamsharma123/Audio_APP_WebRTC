import SwiftUI
import AVFoundation
import WebRTC

struct ContentView: View {

    @StateObject private var viewModel = CallViewModel()
    @ObservedObject private var signaling = SignalingManager.shared

    var body: some View {
        VStack(spacing: 16) {

            connectionStatusView

            switch viewModel.callState {
            case .idle:
                idleView
            case .connecting:
                connectingView
            case .inCall:
                inCallView
            case .ended:
                endedView
            }

            Spacer()
        }
        .padding()
        .onAppear {
            SignalingManager.shared.connect()
        }
    }

    // MARK: - Connection Status
    var connectionStatusView: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(signaling.isConnected ? .green : .red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(signaling.isConnected
                     ? "Connected to server"
                     : "Connecting…")

                Text("Peers online: \(signaling.connectedPeers)")
                    .font(.caption)
                    .foregroundColor(.blue)

                if signaling.isConnected && !signaling.remoteAvailable {
                    Text("Waiting for peer…")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - Idle View (Audio / Video choice)
    var idleView: some View {
        VStack(spacing: 24) {
            Text("📞 Call")
                .font(.largeTitle)
                .bold()

            Button("🎧 Audio Call") {
                viewModel.startCall(type: .audio)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!signaling.remoteAvailable)

            Button("📹 Video Call") {
                viewModel.startCall(type: .video)
            }
            .buttonStyle(.bordered)
            .disabled(!signaling.remoteAvailable)
        }
    }

    // MARK: - Connecting View
    var connectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Connecting…")
        }
    }

    // MARK: - In Call View (Audio / Video aware)
    var inCallView: some View {
        ZStack {

            // 🔹 VIDEO CALL UI
            if viewModel.callType == .video {

                RTCVideoView(track: WebRTCManager.shared.remoteVideoTrack)
                    .ignoresSafeArea()
                    .background(Color.black)

                VStack {
                    Spacer()

                    // Local PiP
                    HStack {
                        Spacer()
                        RTCVideoView(track: WebRTCManager.shared.localVideoTrack)
                            .frame(width: 120, height: 180)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white, lineWidth: 1)
                            )
                            .padding()
                    }

                    callControls
                        .padding(.bottom, 30)
                }

            } else {
                // 🔹 AUDIO CALL UI
                VStack(spacing: 30) {
                    Image(systemName: "person.wave.2.fill")
                        .resizable()
                        .frame(width: 100, height: 100)
                        .foregroundColor(.blue)

                    Text("Audio Call in Progress")
                        .font(.headline)

                    callControls
                }
            }
        }
    }

    // MARK: - Call Controls
    var callControls: some View {
        HStack(spacing: 32) {

            // Mic
            Button {
                viewModel.toggleMute()
            } label: {
                Image(systemName: viewModel.isMuted
                      ? "mic.slash.fill"
                      : "mic.fill")
            }

            // End Call
            Button {
                viewModel.endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .foregroundColor(.red)
            }

            // Speaker
            Button {
                viewModel.toggleSpeaker()
            } label: {
                Image(systemName: viewModel.isSpeakerOn
                      ? "speaker.wave.3.fill"
                      : "speaker.slash.fill")
            }

            // Video toggle (only for video call)
            if viewModel.callType == .video {
                Button {
                    viewModel.toggleVideo()
                } label: {
                    Image(systemName: viewModel.isVideoOn
                          ? "video.fill"
                          : "video.slash.fill")
                }
            }
        }
        .font(.title)
        .foregroundColor(viewModel.callType == .video ? .white : .primary)
    }

    // MARK: - Ended View
    var endedView: some View {
        VStack(spacing: 20) {
            Text("Call Ended")

            Button("Call Again") {
                viewModel.callState = .idle
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
