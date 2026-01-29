import Foundation
import Combine
import AVFoundation
import WebRTC

@MainActor
class CallViewModel: ObservableObject {
    @Published var callState: CallState = .idle
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = true
    
    enum CallState { case idle, connecting, inCall, ended }
   

    
    func startCall() {
        // Request mic permission first
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {  // UI / ViewModel updates on main thread
                guard granted else {
                    print("❌ Mic permission denied")
                    return
                }
                
                guard let peerId = SignalingManager.shared.latestPeerId else {
                    print("❌ No peer available to call")
                    return
                }

                // Only create offer if we are initiating
                if !WebRTCManager.shared.hasLocalOffer {
                    self.callState = .connecting
                    WebRTCManager.shared.setupPeerConnection()
                    
                    Task {
                        await WebRTCManager.shared.createOffer(to: peerId)
                        self.callState = .inCall
                    }
                }
            }
        }
    }


    func endCall() {
        WebRTCManager.shared.cleanup()
        callState = .ended
    }
    
    func toggleMute() {
        isMuted.toggle()
        WebRTCManager.shared.localAudioTrack?.isEnabled = !isMuted
    }
    
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }
}
