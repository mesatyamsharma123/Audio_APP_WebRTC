import Foundation
@preconcurrency import WebRTC
import AVFoundation

enum CallType {
    case audio
    case video
}


final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {
    

    static let shared = WebRTCManager()

    private(set) var hasLocalOffer = false
    private(set) var peerConnection: RTCPeerConnection?

    private let factory: RTCPeerConnectionFactory

    // MARK: - Tracks
    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?

    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?

    private var videoCapturer: RTCCameraVideoCapturer?

    // MARK: - Signaling helpers
    private var remotePeerId: String?
    private var queuedCandidates: [RTCIceCandidate] = []
    
    private(set) var callType: CallType = .video

    // MARK: - Init
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
            try session.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            print("✅ AVAudioSession configured")
        } catch {
            print("❌ AVAudioSession error:", error)
        }
    }

    func forceSpeaker() {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true)
    }

    // MARK: - PeerConnection Setup
    @MainActor
        func setupPeerConnection(callType: CallType) {

            self.callType = callType

            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.iceServers = [
                RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
            ]

            peerConnection = factory.peerConnection(
                with: config,
                constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                delegate: self
            )

            addLocalAudio()

            if callType == .video {
                addLocalVideo()
            }

            print(" PeerConnection setup for:", callType)
        }

        private func addLocalAudio() {
            let source = factory.audioSource(with: nil)
            localAudioTrack = factory.audioTrack(with: source, trackId: "audio0")
            peerConnection?.add(localAudioTrack!, streamIds: ["stream0"])
        }

        private func addLocalVideo() {
            let videoSource = factory.videoSource()
            videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
            localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
            peerConnection?.add(localVideoTrack!, streamIds: ["stream0"])
            startCamera()
        }

        private func startCamera() {
            guard
                let capturer = videoCapturer,
                let device = RTCCameraVideoCapturer.captureDevices()
                    .first(where: { $0.position == .front }),
                let format = RTCCameraVideoCapturer.supportedFormats(for: device).first,
                let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate
            else { return }

            capturer.startCapture(with: device, format: format, fps: Int(fps))
        }
    // MARK: - Offer / Answer
    @MainActor
    func createOffer(to peerId: String) async {
        guard let pc = peerConnection else { return }
        remotePeerId = peerId

        do {
            let offer = try await pc.offer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            )
            try await pc.setLocalDescription(offer)
            hasLocalOffer = true

            await SignalingManager.shared.sendSDP(offer, to: peerId)
            print("📤 Offer sent")
        } catch {
            print("❌ Offer failed:", error)
        }
    }

    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) async {
        guard let pc = peerConnection else { return }
        try? await pc.setRemoteDescription(sdp)
        flushQueuedICE()
    }
    
    
    private func detectCallType(from sdp: RTCSessionDescription) -> CallType {
        if sdp.sdp.contains("m=video") {
            return .video
        } else {
            return .audio
        }
    }


    @MainActor
    func handleRemoteOffer(_ sdp: RTCSessionDescription, from peerId: String) {

        remotePeerId = peerId

        // 🔥 1. Detect call type from SDP
        let incomingCallType = detectCallType(from: sdp)

        // 🔥 2. Setup PeerConnection accordingly
        if peerConnection == nil {
            setupPeerConnection(callType: incomingCallType)
        }

        guard let pc = peerConnection else { return }

        // 🔥 3. Collision handling
        if pc.signalingState == .haveLocalOffer {
            cleanup()
            setupPeerConnection(callType: incomingCallType)
        }

        // 🔥 4. Normal Answer Flow
        pc.setRemoteDescription(sdp) { error in
            if let error = error {
                print("❌ Failed to set remote offer:", error)
                return
            }

            pc.answer(
                for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            ) { answer, error in

                if let error = error {
                    print("❌ Failed to create answer:", error)
                    return
                }

                guard let answer = answer else { return }

                pc.setLocalDescription(answer) { error in
                    if let error = error {
                        print("❌ Failed to set local answer:", error)
                        return
                    }

                    Task {
                        await SignalingManager.shared.sendSDP(answer, to: peerId)
                    }
                }
            }
        }
    }


    // MARK: - ICE
    @MainActor
    func addIceCandidate(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else { return }

        if pc.remoteDescription == nil {
            queuedCandidates.append(candidate)
        } else {
            pc.add(candidate)
        }
    }

    private func flushQueuedICE() {
        guard let remoteId = remotePeerId else { return }
        for candidate in queuedCandidates {
            let candidateToSend = candidate
            Task { await SignalingManager.shared.sendCandidate(candidateToSend, to: remoteId) }
        }
        queuedCandidates.removeAll()
    }

    // MARK: - Delegate (Unified Plan)
//    func peerConnection(_ peerConnection: RTCPeerConnection,
//                        didAdd rtpReceiver: RTCRtpReceiver,
//                        streams: [RTCMediaStream]) {
//
//        if let video = rtpReceiver.track as? RTCVideoTrack {
//            remoteVideoTrack = video
//            print("📺 Remote video received")
//        }
//
//        if let audio = rtpReceiver.track as? RTCAudioTrack {
//            remoteAudioTrack = audio
//            forceSpeaker()
//            print("🔊 Remote audio received")
//        }
//    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        guard let remoteId = remotePeerId else { return }

        if peerConnection.remoteDescription == nil {
            queuedCandidates.append(candidate)
        } else {
            Task {
                await SignalingManager.shared.sendCandidate(candidate, to: remoteId)
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {

        // 🔊 Remote Audio
        if let audioTrack = stream.audioTracks.first {
            remoteAudioTrack = audioTrack
            remoteAudioTrack?.isEnabled = true
            forceSpeaker()
            print("🔊 Remote audio track received")
        }

        // 📺 Remote Video
        if let videoTrack = stream.videoTracks.first {
            remoteVideoTrack = videoTrack
            remoteVideoTrack?.isEnabled = true
            print("📺 Remote video track received")
        }
    }

    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        
    }
    

    // MARK: - Cleanup
    func cleanup() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        
        localAudioTrack = nil
        remoteAudioTrack = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        
        hasLocalOffer = false
        queuedCandidates.removeAll()
        remotePeerId = nil
    }
}

