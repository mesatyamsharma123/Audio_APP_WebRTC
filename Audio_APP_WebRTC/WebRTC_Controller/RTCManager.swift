import Foundation
import WebRTC
import AVFoundation

final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {

    static let shared = WebRTCManager()

    private(set) var peerConnection: RTCPeerConnection?
    private let factory: RTCPeerConnectionFactory

    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?

    override init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
        super.init()
        configureAudioSession()
    }

    // MARK: - Audio Session
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            print("✅ AVAudioSession configured")
        } catch {
            print("❌ AVAudioSession error:", error)
        }

        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.useManualAudio = false
        audioSession.isAudioEnabled = true
        audioSession.lockForConfiguration()
        audioSession.unlockForConfiguration()
        print("✅ RTCAudioSession enabled")
    }

    // MARK: - Peer Connection
    @MainActor
    func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .planB // For old delegate support
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        addLocalAudioTrack()
        print("✅ PeerConnection created")
    }

    private func addLocalAudioTrack() {
        let audioSource = factory.audioSource(with: nil)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        if let track = localAudioTrack {
            peerConnection?.add(track, streamIds: ["stream0"])
            print("✅ Local audio track added")
        }
    }

    // MARK: - SDP Methods
    @MainActor
    func createOffer() async throws {
        guard let pc = peerConnection else { return }
        let offer = try await pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await pc.setLocalDescription(offer)
        print("✅ Offer created & set locally")
        try await SignalingManager.shared.sendSDP(offer)
    }

    @MainActor
    func createAnswer() async throws {
        guard let pc = peerConnection else { return }
        let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        try await pc.setLocalDescription(answer)
        print("✅ Answer created & set locally")
        try await SignalingManager.shared.sendSDP(answer)
    }

    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { return }
        try await pc.setRemoteDescription(sdp)
        print("✅ Remote SDP set: \(sdp.type.rawValue)")
    }

    @MainActor
    func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await pc.add(candidate)
        print("✅ ICE candidate added: \(candidate.sdp)")
    }

    // MARK: - RTCPeerConnectionDelegate (Plan B)
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            remoteAudioTrack?.isEnabled = true
            print("🔊 Remote audio track received")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        remoteAudioTrack = nil
        print("🗑 Remote stream removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        SignalingManager.shared.sendCandidate(candidate)
        print("📡 ICE candidate generated")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ℹ️ ICE state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ℹ️ ICE gathering state: \(newState.rawValue)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("🔄 Should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("ℹ️ Signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("🗑 Removed ICE candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("📨 Data channel opened: \(dataChannel.label)")
    }
}
extension WebRTCManager {
    func cleanup() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        remoteAudioTrack = nil
        print("🔹 WebRTCManager cleaned up")
    }
}
