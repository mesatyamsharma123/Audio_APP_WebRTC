import Foundation
import Combine
import AVFoundation
import WebRTC

@MainActor
class CallViewModel: ObservableObject {

    // MARK: - UI State
    @Published var callState: CallState = .idle
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = true
    @Published var isVideoOn: Bool = true

    @Published var callType: CallType = .video   // 🔥 IMPORTANT

    enum CallState {
        case idle
        case connecting
        case inCall
        case ended
    }

    // MARK: - Start Call (EXPLICIT Audio / Video)
    func startCall(type: CallType) {

        requestPermissionsIfNeeded(for: type) { granted in
            guard granted else {
                print("❌ Required permission denied")
                return
            }

            guard let peerId = SignalingManager.shared.latestPeerId else {
                print("❌ No peer available to call")
                return
            }

            if !WebRTCManager.shared.hasLocalOffer {

                self.callType = type
                self.callState = .connecting

                // 🔥 Setup based on call type
                WebRTCManager.shared.setupPeerConnection(callType: type)

                // Speaker always on for calls
                WebRTCManager.shared.forceSpeaker()

                // Enable audio
                WebRTCManager.shared.localAudioTrack?.isEnabled = true

                // Enable / disable video based on type
                if type == .video {
                    WebRTCManager.shared.localVideoTrack?.isEnabled = true
                    self.isVideoOn = true
                } else {
                    self.isVideoOn = false
                }

                Task {
                    await WebRTCManager.shared.createOffer(to: peerId)
                    self.callState = .inCall
                }
            }
        }
    }

    // MARK: - End Call
    func endCall() {
        WebRTCManager.shared.cleanup()
        callState = .ended
        isMuted = false
        isVideoOn = true
        callType = .video
    }

    // MARK: - Mute / Unmute Audio
    func toggleMute() {
        isMuted.toggle()
        WebRTCManager.shared.localAudioTrack?.isEnabled = !isMuted
    }

    // MARK: - Video On / Off (Only for Video Call)
    func toggleVideo() {
        guard callType == .video else { return }

        isVideoOn.toggle()
        WebRTCManager.shared.localVideoTrack?.isEnabled = isVideoOn
    }

    // MARK: - Speaker Toggle
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(
            isSpeakerOn ? .speaker : .none
        )
    }

    // MARK: - Permissions
    private func requestPermissionsIfNeeded(
        for type: CallType,
        completion: @escaping (Bool) -> Void
    ) {

        let audioSession = AVAudioSession.sharedInstance()

        // 🎤 Microphone (always required)
        audioSession.requestRecordPermission { micGranted in
            guard micGranted else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // 📹 Camera only for video call
            if type == .video {
                AVCaptureDevice.requestAccess(for: .video) { camGranted in
                    DispatchQueue.main.async {
                        completion(camGranted)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(true)
                }
            }
        }
    }
}
