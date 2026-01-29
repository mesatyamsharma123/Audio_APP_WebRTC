import SwiftUI

struct ContentView: View {

    @StateObject private var viewModel = CallViewModel()

    var body: some View {
        VStack {
            Spacer()

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
        }
    }
}
