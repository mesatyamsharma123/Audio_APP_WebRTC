import Foundation
import WebRTC
import AVFoundation

final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {
    static let shared = WebRTCManager()
    
    private(set) var peerConnection: RTCPeerConnection?
    private let factory: RTCPeerConnectionFactory
    
    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?
    
    private var remotePeerId: String?
    private var queuedCandidates: [RTCIceCandidate] = []
    
    override init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory()
        super.init()
        configureAudioSession()
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch { print(error) }
        
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.useManualAudio = false
        audioSession.isAudioEnabled = true
        audioSession.lockForConfiguration()
        audioSession.unlockForConfiguration()
    }
    
    @MainActor
    func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .planB
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        addLocalAudioTrack()
    }
    
    private func addLocalAudioTrack() {
        let audioSource = factory.audioSource(with: nil)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        if let track = localAudioTrack {
            peerConnection?.add(track, streamIds: ["stream0"])
        }
    }
    
    @MainActor
    func createOffer(to peerId: String) async {
        guard let pc = peerConnection else { return }
        self.remotePeerId = peerId
        do {
            let offer = try await pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(offer)
            await SignalingManager.shared.sendSDP(offer, to: peerId)
        } catch { print("❌ Failed creating offer:", error) }
    }
    
    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { return }
        
        if pc.remoteDescription != nil { return }
        try await pc.setRemoteDescription(sdp)
        
        // If remote SDP is an offer, create answer
        if sdp.type == .offer, let remoteId = remotePeerId {
            let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(answer)
            await SignalingManager.shared.sendSDP(answer, to: remoteId)
        }
        
        // Apply queued ICE candidates
        for candidate in queuedCandidates {
            try await pc.add(candidate)
            if let remoteId = remotePeerId {
                await SignalingManager.shared.sendCandidate(candidate, to: remoteId)
            }
        }
        queuedCandidates.removeAll()
    }
    
    @MainActor
    func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        if pc.remoteDescription == nil {
            queuedCandidates.append(candidate)
        } else {
            try await pc.add(candidate)
            if let remoteId = remotePeerId {
                await SignalingManager.shared.sendCandidate(candidate, to: remoteId)
            }
        }
    }
    
    // MARK: - Delegate
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            remoteAudioTrack?.isEnabled = true
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task {
            do {
                try await WebRTCManager.shared.addIceCandidate(candidate)
            } catch {
                print("❌ Failed adding ICE candidate:", error)
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) { remoteAudioTrack = nil }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    
    func cleanup() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        remoteAudioTrack = nil
        queuedCandidates.removeAll()
        remotePeerId = nil
    }
}
