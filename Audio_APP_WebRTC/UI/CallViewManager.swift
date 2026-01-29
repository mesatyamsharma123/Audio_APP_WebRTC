import Foundation
import SwiftUI
import Combine
import WebRTC      // ✅ Needed for localAudioTrack.isEnabled
import AVFoundation // ✅ Needed for AVAudioSession

@MainActor
class CallViewModel: ObservableObject {

    enum CallState { case idle, connecting, inCall, ended }

    @Published var callState: CallState = .idle
    @Published var isMuted = false
    @Published var isSpeakerOn = true
    @Published var showPermissionAlert = false

    func startCall() {
        guard let peerId = SignalingManager.shared.latestPeerId else {
            print("❌ No peer available to call")
            return
        }

        callState = .connecting
        Task {
            WebRTCManager.shared.setupPeerConnection()
            await WebRTCManager.shared.createOffer(to: peerId)
            callState = .inCall
        }
    }

    func endCall() {
        WebRTCManager.shared.cleanup()
        callState = .ended
    }

    func toggleMute() {
        isMuted.toggle()
        // ✅ This needs WebRTC import
        WebRTCManager.shared.localAudioTrack?.isEnabled = !isMuted
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
