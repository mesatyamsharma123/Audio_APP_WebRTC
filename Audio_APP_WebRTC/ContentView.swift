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
                .fill(signaling.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(signaling.isConnected ? "Connected to server" : "Connecting…")
                    .fontWeight(.medium)

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Idle View
    var idleView: some View {
        VStack(spacing: 24) {
            Text("📞 WebRTC Call")
                .font(.largeTitle)
                .bold()
                .padding(.top, 40)

            Button(action: { viewModel.startCall(type: .audio) }) {
                Label("Audio Call", systemImage: "headphones")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!signaling.remoteAvailable)

            Button(action: { viewModel.startCall(type: .video) }) {
                Label("Video Call", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!signaling.remoteAvailable)
        }
    }

    // MARK: - Connecting View
    var connectingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Establishing Connection...")
                .font(.headline)
            Spacer()
        }
    }

    // MARK: - In Call View
    var inCallView: some View {
        ZStack {
            if viewModel.callType == .video {
                // --- REMOTE VIDEO (Background) ---
                Group {
                    if let remoteTrack = WebRTCManager.shared.remoteVideoTrack {
                        RTCVideoView(track: remoteTrack)
                            .id("remote-\(remoteTrack.trackId)") // Forces unique view
                            .ignoresSafeArea()
                            .background(Color.black)
                    } else {
                        ZStack {
                            Color.black.ignoresSafeArea()
                            VStack {
                                ProgressView().tint(.white)
                                Text("Waiting for video...").foregroundColor(.white)
                            }
                        }
                    }
                }

                // --- LOCAL VIDEO (Picture-in-Picture) ---
                VStack {
                    HStack {
                        Spacer()
                        if viewModel.isVideoOn, let localTrack = WebRTCManager.shared.localVideoTrack {
                            RTCVideoView(track: localTrack)
                                .id("local-\(localTrack.trackId)") // Forces unique view
                                .frame(width: 120, height: 180)
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 1))
                                .shadow(radius: 5)
                                .padding()
                        }
                    }
                    Spacer()
                    
                    callControls
                        .padding(.bottom, 20)
                        .background(
                            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        )
                }
            } else {
                // --- AUDIO CALL UI ---
                VStack(spacing: 40) {
                    Spacer()
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 150, height: 150)
                        .foregroundColor(.gray)
                    
                    Text("Ongoing Audio Call")
                        .font(.title2)
                    
                    Spacer()
                    callControls
                        .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: - Call Controls
    var callControls: some View {
        HStack(spacing: 35) {
            // Mute Toggle
            controlButton(
                icon: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                color: viewModel.isMuted ? .red : .white
            ) {
                viewModel.toggleMute()
            }

            // End Call
            Button(action: { viewModel.endCall() }) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 30))
                    .padding(20)
                    .background(Color.red)
                    .clipShape(Circle())
                    .foregroundColor(.white)
            }

            // Speaker Toggle
            controlButton(
                icon: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.1.fill",
                color: .white
            ) {
                viewModel.toggleSpeaker()
            }

            // Video Toggle (Conditional)
            if viewModel.callType == .video {
                controlButton(
                    icon: viewModel.isVideoOn ? "video.fill" : "video.slash.fill",
                    color: viewModel.isVideoOn ? .white : .red
                ) {
                    viewModel.toggleVideo()
                }
            }
        }
    }

    // Helper for buttons
    private func controlButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
                .frame(width: 50, height: 50)
                .background(Color.white.opacity(0.2))
                .clipShape(Circle())
        }
    }

    // MARK: - Ended View
    var endedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "phone.arrow.down.left.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)
            Text("Call Ended")
                .font(.title)

            Button("Return to Home") {
                viewModel.callState = .idle
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}
