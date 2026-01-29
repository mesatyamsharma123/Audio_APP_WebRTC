import SwiftUI
import AVFoundation
import WebRTC

struct ContentView: View {
    @StateObject private var viewModel = CallViewModel()
    @ObservedObject private var signaling = SignalingManager.shared
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            connectionStatusView
            
            switch viewModel.callState {
            case .idle: idleView
            case .connecting: connectingView
            case .inCall: inCallView
            case .ended: endedView
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            SignalingManager.shared.connect()
            WebRTCManager.shared.setupPeerConnection()
        }
    }
    
    var connectionStatusView: some View {
        HStack {
            Circle().fill(signaling.isConnected ? .green : .red).frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text(signaling.isConnected ? "Connected to server" : "Connecting...")
                Text("Peers online: \(signaling.connectedPeers)").foregroundColor(.blue)
                if signaling.isConnected && !signaling.remoteAvailable {
                    Text("(Waiting for peer)").foregroundColor(.orange)
                }
            }
        }
    }
    
    var idleView: some View {
        VStack(spacing: 20) {
            Text("🎧 Audio Chat").font(.largeTitle).bold()
            Button("Start Call") { viewModel.startCall() }
                .buttonStyle(.borderedProminent)
                .disabled(!signaling.remoteAvailable)
        }
    }
    
    var connectingView: some View {
        VStack(spacing: 20) { ProgressView(); Text("Connecting...") }
    }
    
    var inCallView: some View {
        VStack(spacing: 40) {
            Text("Connected").foregroundColor(.green)
            HStack(spacing: 30) {
                Button { viewModel.toggleMute() } label: {
                    Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                }
                Button { viewModel.endCall() } label: {
                    Image(systemName: "phone.down.fill").foregroundColor(.red)
                }
                Button { viewModel.toggleSpeaker() } label: {
                    Image(systemName: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.slash.fill")
                }
            }.font(.title)
        }
    }
    
    var endedView: some View {
        VStack(spacing: 20) {
            Text("Call Ended")
            Button("Call Again") { viewModel.startCall() }
                .buttonStyle(.borderedProminent)
                .disabled(!signaling.remoteAvailable)
        }
    }
}
