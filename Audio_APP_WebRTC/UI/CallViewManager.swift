import Foundation
import AVFoundation
import Combine
import WebRTC

enum CallState {
    case idle
    case connecting
    case inCall
    case ended
}

final class CallViewModel: ObservableObject {

    @Published var callState: CallState = .idle
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var showPermissionAlert = false

    private let audioSession = AVAudioSession.sharedInstance()

    func startCall() {
        requestMicrophonePermission { granted in
            guard granted else {
                DispatchQueue.main.async {
                    self.showPermissionAlert = true
                }
                return
            }

            DispatchQueue.main.async {
                self.callState = .connecting
                self.setupAudioSession()
                Task {
                    await self.setupWebRTC()
                }
            }
        }
    }

    func endCall() {
        DispatchQueue.main.async {
            self.callState = .ended
            self.isMuted = false
            self.isSpeakerOn = false
            WebRTCManager.shared.cleanup()
            try? self.audioSession.setActive(false)
        }
    }

    func toggleMute() {
        isMuted.toggle()
        WebRTCManager.shared.localAudioTrack?.isEnabled = !isMuted
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        try? audioSession.overrideOutputAudioPort(
            isSpeakerOn ? .speaker : .none
        )
    }

    private func setupAudioSession() {
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? audioSession.setActive(true)
    }

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        switch audioSession.recordPermission {
        case .granted: completion(true)
        case .denied: completion(false)
        case .undetermined:
            audioSession.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default: completion(false)
        }
    }

    // MARK: - WebRTC Setup
    private func setupWebRTC() async {
        await WebRTCManager.shared.setupPeerConnection()
        do {
            try await WebRTCManager.shared.createOffer()
            DispatchQueue.main.async { self.callState = .inCall }
        } catch {
            print("WebRTC setup failed:", error)
            DispatchQueue.main.async { self.callState = .ended }
        }
    }
}
