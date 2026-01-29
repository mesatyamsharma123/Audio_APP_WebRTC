import Foundation
import WebRTC
import AVFoundation

final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {

    static let shared = WebRTCManager()
    private(set) var hasLocalOffer = false

    private(set) var peerConnection: RTCPeerConnection?
    private let factory: RTCPeerConnectionFactory

    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?

    private var remotePeerId: String?              // Track remote peer
    private var queuedCandidates: [RTCIceCandidate] = []  // Queue ICE before remote SDP

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

        // WebRTC audio session setup
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.useManualAudio = true
        audioSession.isAudioEnabled = true
        audioSession.lockForConfiguration()
        audioSession.unlockForConfiguration()
        print("✅ RTCAudioSession enabled")
    }

    private func forceSpeaker() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
            print("🔊 Audio routed to speaker")
        } catch {
            print("❌ Failed to force speaker:", error)
        }
    }

    // MARK: - Peer Connection
    @MainActor
    func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
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
            hasLocalOffer = true
            print("✅ Offer created & set locally for peer:", peerId)
            await SignalingManager.shared.sendSDP(offer, to: peerId)
        } catch {
            print("❌ Failed creating offer:", error)
        }
    }

    @MainActor
    func handleRemoteOffer(_ sdp: RTCSessionDescription, from peerId: String) {
        remotePeerId = peerId

        if peerConnection == nil {
            setupPeerConnection()
        }

        guard let pc = peerConnection else { return }

        print("ℹ️ Handling remote offer, signalingState:", pc.signalingState.rawValue)

        // Glare fix: recreate PeerConnection if local offer exists
        if pc.signalingState == .haveLocalOffer {
            print("⚠️ Glare detected → recreating PeerConnection")
            cleanup()
            setupPeerConnection()
        }

        applyRemoteOfferAndAnswer(sdp)
    }

    @MainActor
    private func applyRemoteOfferAndAnswer(_ sdp: RTCSessionDescription) {
        guard let pc = peerConnection, let remoteId = remotePeerId else { return }

        pc.setRemoteDescription(sdp) { error in
            if let error = error {
                print("❌ Failed to set remote SDP:", error)
                return
            }

            print("✅ Remote offer set")

            pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                if let error = error {
                    print("❌ Failed creating answer:", error)
                    return
                }

                guard let answer = answer else { return }

                pc.setLocalDescription(answer) { error in
                    if let error = error {
                        print("❌ Failed setting local answer:", error)
                        return
                    }

                    print("✅ Answer created & set locally")
                    Task {
                        await SignalingManager.shared.sendSDP(answer, to: remoteId)
                    }
                }
            }
        }
    }

    @MainActor
    func createAnswer(to peerId: String) {
        guard let pc = peerConnection else { return }
        remotePeerId = peerId

        pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
            if let error = error {
                print("❌ Failed creating answer:", error)
                return
            }

            guard let answer = answer else { return }

            pc.setLocalDescription(answer) { error in
                if let error = error {
                    print("❌ Failed setting local answer:", error)
                    return
                }

                print("✅ Answer created & set locally")
                Task {
                    await SignalingManager.shared.sendSDP(answer, to: peerId)
                }
            }
        }
    }

    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) {
        peerConnection?.setRemoteDescription(sdp) { error in
            if let error = error {
                print("❌ Failed to set remote SDP:", error)
            } else {
                print("✅ Remote SDP set:", sdp.type.rawValue)
            }
        }
    }

    @MainActor
    func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await pc.add(candidate)
        print("✅ ICE candidate added: \(candidate.sdp)")
    }

    @MainActor
    private func flushQueuedICE() {
        guard let remoteId = remotePeerId else { return }
        print("🚀 Flushing \(queuedCandidates.count) queued ICE candidates")
        for candidate in queuedCandidates {
            Task {
                await SignalingManager.shared.sendCandidate(candidate, to: remoteId)
            }
        }
        queuedCandidates.removeAll()
    }

    // MARK: - RTCPeerConnectionDelegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            remoteAudioTrack?.isEnabled = true
            forceSpeaker()
            print("🔊 Remote audio track received & speaker forced")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let remoteId = remotePeerId else { return }

        if peerConnection.remoteDescription == nil {
            queuedCandidates.append(candidate)
            print("⏳ ICE candidate queued (remote SDP not ready)")
        } else {
            Task {
                await SignalingManager.shared.sendCandidate(candidate, to: remoteId)
            }
            print("📡 ICE candidate sent")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        remoteAudioTrack = nil
        print("🗑 Remote stream removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ℹ️ ICE state changed:", newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ℹ️ ICE gathering state changed:", newState.rawValue)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("🔄 Should negotiate")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("ℹ️ Signaling state changed:", stateChanged.rawValue)
        if stateChanged == .stable {
            flushQueuedICE()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("🗑 Removed ICE candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("📨 Data channel opened:", dataChannel.label)
    }

    // MARK: - Cleanup
    func cleanup() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        remoteAudioTrack = nil
        queuedCandidates.removeAll()
        remotePeerId = nil
        hasLocalOffer = false
        print("🔹 WebRTCManager cleaned up")
    }
}
