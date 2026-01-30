import Foundation
@preconcurrency import WebRTC
import AVFoundation

final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {

    static let shared = WebRTCManager()
    private(set) var hasLocalOffer = false

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
                                    mode: .videoChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            print("AVAudioSession configured")
        } catch {
            print("AVAudioSession error:", error)
        }
    }

    func forceSpeaker() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
            print(" Audio routed to speaker")
        } catch {
            print(" Failed to force speaker:", error)
        }
    }


    @MainActor
    func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)

       
        let audioSource = factory.audioSource(with: nil)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        if let track = localAudioTrack {
            peerConnection?.add(track, streamIds: ["stream0"])
            print(" Local audio track added")
        }

        print(" PeerConnection created")
    }

  
    @MainActor
    func createOffer(to peerId: String) async {
        guard let pc = peerConnection else { return }
        remotePeerId = peerId
        do {
            let offer = try await pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await pc.setLocalDescription(offer)
            hasLocalOffer = true
            print(" Offer created & set locally for peer:", peerId)
            await SignalingManager.shared.sendSDP(offer, to: peerId)
        } catch {
            print("Failed creating offer:", error)
        }
    }
    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) async {
        guard let pc = peerConnection else { return }
        do {
            try await pc.setRemoteDescription(sdp)
            print(" Remote SDP set: \(sdp.type.rawValue)")
            flushQueuedICE()
        } catch {
            print(" Failed to set remote SDP:", error)
        }
    }

    @MainActor
    func handleRemoteOffer(_ sdp: RTCSessionDescription, from peerId: String) {
        remotePeerId = peerId

        if peerConnection == nil {
            setupPeerConnection()
        }
        guard let pc = peerConnection else { return }

     
        if pc.signalingState == .haveLocalOffer {
            cleanup()
            setupPeerConnection()
        }

        pc.setRemoteDescription(sdp) { error in
            if let error = error {
                print(" Failed to set remote SDP:", error)
                return
            }
            print(" Remote offer set")

            pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                if let error = error {
                    print(" Failed creating answer:", error)
                    return
                }
                guard let answer = answer else { return }

                pc.setLocalDescription(answer) { error in
                    if let error = error {
                        print(" Failed setting local answer:", error)
                        return
                    }
                    print(" Answer created & set locally")
                    Task { await SignalingManager.shared.sendSDP(answer, to: peerId) }
                }
            }
        }
    }

    @MainActor
    func addIceCandidate(_ candidate: RTCIceCandidate) async {
        guard let pc = peerConnection else { return }
        if pc.remoteDescription == nil {
            queuedCandidates.append(candidate)
            print(" ICE candidate queued")
        } else {
            try? await pc.add(candidate)
            print("ICE candidate added: \(candidate.sdp)")
        }
    }

    private func flushQueuedICE() {
        guard let remoteId = remotePeerId else { return }
        for candidate in queuedCandidates {
            Task { await SignalingManager.shared.sendCandidate(candidate, to: remoteId) }
        }
        queuedCandidates.removeAll()
        print(" Flushed queued ICE candidates")
    }


    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            remoteAudioTrack?.isEnabled = true
            forceSpeaker()
            print("🔊 Remote audio track received & speaker forced")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        remoteAudioTrack = nil
        print(" Remote stream removed")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print(" Signaling state changed:", stateChanged.rawValue)
        if stateChanged == .stable { flushQueuedICE() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print(" ICE state changed:", newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print(" ICE gathering state changed:", newState.rawValue)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print(" Should negotiate here.........")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print(" Removed ICE candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print(" Data channel opened:", dataChannel.label)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let remoteId = remotePeerId else { return }
        if peerConnection.remoteDescription == nil {
            queuedCandidates.append(candidate)
            print(" ICE candidate queued (remote SDP not ready)")
        } else {
            Task { await SignalingManager.shared.sendCandidate(candidate, to: remoteId) }
            print(" ICE candidate sent")
        }
    }

    func cleanup() {
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        remoteAudioTrack = nil
        queuedCandidates.removeAll()
        remotePeerId = nil
        hasLocalOffer = false
        print(" WebRTCManager cleaned up")
    }
}
