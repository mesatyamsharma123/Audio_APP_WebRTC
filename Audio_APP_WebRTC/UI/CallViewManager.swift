import Foundation
import Combine
import AVFoundation
import WebRTC
import SwiftUI

@MainActor
class CallViewModel: ObservableObject {

    // MARK: - UI State
    @Published var callState: CallState = .idle
    @Published var isMuted: Bool = false
    @Published var isSpeakerOn: Bool = true
    @Published var isVideoOn: Bool = true
    @Published var callType: CallType = .video

    enum CallState {
        case idle
        case connecting
        case inCall
        case ended
    }

    // MARK: - Start Call
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

                // 1. Force the Audio Session to "Active" mode
                // This is what triggers the Yellow Dot on iOS
                self.configureAudioSessionForCall()

                // 2. Setup PeerConnection
                WebRTCManager.shared.setupPeerConnection(callType: type)

                // 3. Explicitly enable local tracks
                WebRTCManager.shared.localAudioTrack?.isEnabled = true
                
                if type == .video {
                    WebRTCManager.shared.localVideoTrack?.isEnabled = true
                    self.isVideoOn = true
                } else {
                    self.isVideoOn = false
                    // Ensure video track is nil or disabled for audio-only to prevent "swapping"
                    WebRTCManager.shared.localVideoTrack?.isEnabled = false
                }

                Task {
                    await WebRTCManager.shared.createOffer(to: peerId)
                    
                    withAnimation {
                        self.callState = .inCall
                    }
                }
            }
        }
    }

    // MARK: - Audio Session Management
    private func configureAudioSessionForCall() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Using .voiceChat mode specifically helps iOS prioritize the mic and speaker for calls
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session activated for call")
        } catch {
            print("❌ Failed to activate audio session: \(error)")
        }
    }

    // MARK: - End Call
    func endCall() {
        WebRTCManager.shared.cleanup()
        
        // Deactivate audio session to remove the orange dot immediately
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        callState = .ended
        isMuted = false
        isVideoOn = true
        callType = .video
    }

    // MARK: - Mute / Unmute
    func toggleMute() {
        isMuted.toggle()
        WebRTCManager.shared.localAudioTrack?.isEnabled = !isMuted
        
        // Re-nudging the session helps maintain the system status indicators
        if !isMuted {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    // MARK: - Video On / Off
    func toggleVideo() {
        guard callType == .video else { return }
        isVideoOn.toggle()
        WebRTCManager.shared.localVideoTrack?.isEnabled = isVideoOn
    }

    // MARK: - Speaker Toggle
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        let session = AVAudioSession.sharedInstance()
        // Ensure the session is in a call-compatible mode when overriding ports
        try? session.setMode(.voiceChat)
        try? session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }

    // MARK: - Permissions
    private func requestPermissionsIfNeeded(for type: CallType, completion: @escaping (Bool) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()

        audioSession.requestRecordPermission { micGranted in
            guard micGranted else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            if type == .video {
                AVCaptureDevice.requestAccess(for: .video) { camGranted in
                    DispatchQueue.main.async { completion(camGranted) }
                }
            } else {
                DispatchQueue.main.async { completion(true) }
            }
        }
    }
}

