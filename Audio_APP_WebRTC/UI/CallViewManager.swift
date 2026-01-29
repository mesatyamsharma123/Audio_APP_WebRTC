import Foundation
import SwiftUI
import Combine
import WebRTC       // For RTCAudioTrack
import AVFoundation // For AVAudioSession

@MainActor
class CallViewModel: ObservableObject {

    enum CallState {
        case idle, connecting, inCall, ended
    }

    @Published var callState: CallState = .idle
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = false
    @Published var showPermissionAlert: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Observe connected peers
        SignalingManager.shared.$connectedPeers
            .sink { peers in
                print("Peers online: \(peers)")
            }
            .store(in: &cancellables)
    }

    func startCall() {
        guard let peerId = SignalingManager.shared.latestPeerId else {
            print("❌ No peer available to call")
            return
        }

        callState = .connecting
        Task {
            WebRTCManager.shared.setupPeerConnection()
            await WebRTCManager.shared.createOffer(to: peerId)
            DispatchQueue.main.async {
                self.callState = .inCall
            }
        }
    }

    func endCall() {
        WebRTCManager.shared.cleanup()
        callState = .ended
    }

    func toggleMute() {
        isMuted.toggle()
        // Ensure we safely enable/disable the local track
        if let track = WebRTCManager.shared.localAudioTrack {
            track.isEnabled = !isMuted
        }
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(
                isSpeakerOn ? .speaker : .none
            )
        } catch {
            print("❌ Failed to toggle speaker:", error)
        }
    }
}
