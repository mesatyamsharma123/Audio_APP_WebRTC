import Foundation
import WebRTC
import AVFoundation

final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {

    static let shared = WebRTCManager()

    private(set) var peerConnection: RTCPeerConnection?
    private let factory: RTCPeerConnectionFactory

    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?

    private var remotePeerId: String? // Track remote peer
    private var queuedCandidates: [RTCIceCandidate] = [] // Queue ICE before remote SDP

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
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
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
        config.sdpSemantics = .planB
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
    func createOffer(to peerId: String) async {
        guard let pc = peerConnection else { return }
        self.remotePeerId = peerId
        do {
            let offer = try await pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(offer)
            print("✅ Offer created & set locally for peer:", peerId)
            await SignalingManager.shared.sendSDP(offer, to: peerId)
        } catch {
            print("❌ Failed creating offer:", error)
        }
    }

    @MainActor
    func createAnswer(to peerId: String) async {
        guard let pc = peerConnection else { return }
        self.remotePeerId = peerId
        do {
            let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(answer)
            print("✅ Answer created & set locally for peer:", peerId)
            await SignalingManager.shared.sendSDP(answer, to: peerId)
        } catch {
            print("❌ Failed creating answer:", error)
        }
    }

    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { return }
        try await pc.setRemoteDescription(sdp)
        print("✅ Remote SDP set: \(sdp.type.rawValue)")

        // Send queued ICE candidates
        for candidate in queuedCandidates {
            if let remoteId = remotePeerId {
                await SignalingManager.shared.sendCandidate(candidate, to: remoteId)
            }
        }
        queuedCandidates.removeAll()
    }

    @MainActor
    func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await pc.add(candidate)
        print("✅ ICE candidate added: \(candidate.sdp)")
    }

    // MARK: - RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            remoteAudioTrack?.isEnabled = true
            print("🔊 Remote audio track received")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let remoteId = remotePeerId else { return }

        // Queue if remote SDP not yet set
        if peerConnection.remoteDescription == nil {
            queuedCandidates.append(candidate)
            print("⏳ Candidate queued")
        } else {
            Task { await SignalingManager.shared.sendCandidate(candidate, to: remoteId) }
            print("📡 ICE candidate sent")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        remoteAudioTrack = nil
        print("🗑 Remote stream removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ℹ️ ICE state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ℹ️ ICE gathering state: \(newState.rawValue)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }

    // MARK: - Cleanup
    func cleanup() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        remoteAudioTrack = nil
        queuedCandidates.removeAll()
        remotePeerId = nil
        print("🔹 WebRTCManager cleaned up")
    }
}
