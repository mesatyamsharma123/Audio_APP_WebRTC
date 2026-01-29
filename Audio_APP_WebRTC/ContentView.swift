import SwiftUI

struct ContentView: View {

    @StateObject private var viewModel = CallViewModel()
    @ObservedObject private var signaling = SignalingManager.shared

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

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
        .animation(.easeInOut, value: viewModel.callState)
        .onAppear {
            SignalingManager.shared.connect()
        }
    }
}

// MARK: - Connection Status
private extension ContentView {

    var connectionStatusView: some View {
        HStack {
            Circle()
                .fill(signaling.isConnected ? .green : .red)
                .frame(width: 12, height: 12)
            Text(signaling.isConnected ? "Connected to server" : "Connecting...")
                .font(.subheadline)
            if signaling.isConnected && !signaling.remoteAvailable {
                Text("(Waiting for peer)")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Views
private extension ContentView {

    var idleView: some View {
        VStack(spacing: 20) {
            Text("🎧 Audio Chat")
                .font(.largeTitle)
                .bold()

            Button("Start Call") {
                viewModel.startCall()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!signaling.remoteAvailable)
        }
    }

    var connectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Connecting...")
        }
    }

    var inCallView: some View {
        VStack(spacing: 40) {
            Text("Connected")
                .foregroundColor(.green)

            HStack(spacing: 30) {
                Button {
                    viewModel.toggleMute()
                } label: {
                    Image(systemName:
                        viewModel.isMuted ? "mic.slash.fill" : "mic.fill"
                    )
                }

                Button {
                    viewModel.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .foregroundColor(.red)
                }

                Button {
                    viewModel.toggleSpeaker()
                } label: {
                    Image(systemName:
                        viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.slash.fill"
                    )
                }
            }
            .font(.title)
        }
        .alert("Microphone Required",
               isPresented: $viewModel.showPermissionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings.")
        }
    }

    var endedView: some View {
        VStack(spacing: 20) {
            Text("Call Ended")

            Button("Call Again") {
                viewModel.startCall()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!signaling.remoteAvailable)
        }
    }
}
