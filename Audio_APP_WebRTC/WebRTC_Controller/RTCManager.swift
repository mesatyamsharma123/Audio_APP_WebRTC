import Foundation
@preconcurrency import WebRTC
import AVFoundation

enum CallType {
    case audio
    case video
}

final class WebRTCManager: NSObject, RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        
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
    

    static let shared = WebRTCManager()

    private let factory = RTCPeerConnectionFactory()
    private(set) var peerConnection: RTCPeerConnection?
    private(set) var hasLocalOffer = false

    // MARK: - Tracks
    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteAudioTrack: RTCAudioTrack?

    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?

    private var videoCapturer: RTCCameraVideoCapturer?

    // MARK: - Signaling
    private var remotePeerId: String?
    private var queuedCandidates: [RTCIceCandidate] = []

    private(set) var callType: CallType = .video

    // MARK: - Init
    override init() {
        RTCInitializeSSL()
        super.init()
        configureAudioSession()
    }

    // MARK: - Audio Session
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            print("✅ AVAudioSession configured")
        } catch {
            print("❌ AVAudioSession error:", error)
        }
    }
    
    @MainActor
    func setRemoteDescription(_ sdp: RTCSessionDescription) async {
        guard let pc = peerConnection else { return }
        try? await pc.setRemoteDescription(sdp)
        flushQueuedICE()   // 🔥 IMPORTANT
    }


    func forceSpeaker() {
        let session = AVAudioSession.sharedInstance()
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setActive(true)
    }

    // MARK: - PeerConnection (PLAN-B ONLY)
    @MainActor
    func setupPeerConnection(callType: CallType) {
        
        if peerConnection != nil {
               print("⚠️ PeerConnection already exists, skipping setup")
               return
           }

        self.callType = callType

        let config = RTCConfiguration()
        config.sdpSemantics = .planB   // 🔥 IMPORTANT
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

        print("✅ PeerConnection setup (PLAN-B):", callType)
    }

    // MARK: - Local Audio
    private func addLocalAudio() {
        let audioSource = factory.audioSource(with: nil)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")

        if let track = localAudioTrack {
            peerConnection?.add(track, streamIds: ["stream0"])
            print("🎤 Local audio added")
        }
    }

    // MARK: - Local Video
    private func addLocalVideo() {
        let videoSource = factory.videoSource()
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)

        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")

        if let track = localVideoTrack {
            peerConnection?.add(track, streamIds: ["stream0"])
            startCamera()
            print("📹 Local video added")
        }
    }

    private func startCamera() {
        guard
            let capturer = videoCapturer,
            let device = RTCCameraVideoCapturer.captureDevices()
                .first(where: { $0.position == .front }),
            let format = RTCCameraVideoCapturer.supportedFormats(for: device).first,
            let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate
        else {
            print("❌ Camera start failed")
            return
        }

        capturer.startCapture(
            with: device,
            format: format,
            fps: Int(fps)
        )

        print("📸 Camera started")
    }

    // MARK: - Offer
    @MainActor
    func createOffer(to peerId: String) async {
        guard let pc = peerConnection else { return }
        remotePeerId = peerId

        let offer = try? await pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        guard let offer else { return }

        try? await pc.setLocalDescription(offer)
        hasLocalOffer = true

        await SignalingManager.shared.sendSDP(offer, to: peerId)
        print("📤 Offer sent")
    }

    // MARK: - Remote Offer
    @MainActor
    func handleRemoteOffer(_ sdp: RTCSessionDescription, from peerId: String) {

        remotePeerId = peerId
        let incomingType: CallType = sdp.sdp.contains("m=video") ? .video : .audio

        if peerConnection == nil {
            setupPeerConnection(callType: incomingType)
        }

        guard let pc = peerConnection else { return }

        pc.setRemoteDescription(sdp) { _ in
            pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, _ in
                guard let answer else { return }

                pc.setLocalDescription(answer) { _ in
                    Task {
                        await SignalingManager.shared.sendSDP(answer, to: peerId)
                    }
                }
            }
        }
    }

    // MARK: - ICE
    func addIceCandidate(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else { return }

        if pc.remoteDescription == nil {
            queuedCandidates.append(candidate)
        } else {
            pc.add(candidate)
        }
    }

    private func flushQueuedICE() {
        guard let peerId = remotePeerId else { return }
        queuedCandidates.forEach { candidate in
            Task { await SignalingManager.shared.sendCandidate(candidate, to: peerId) }
        }
        queuedCandidates.removeAll()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {

        guard let peerId = remotePeerId else { return }

        if peerConnection.remoteDescription == nil {
            queuedCandidates.append(candidate)
        } else {
            Task {
                await SignalingManager.shared.sendCandidate(candidate, to: peerId)
            }
        }
    }

    // MARK: - PLAN-B REMOTE STREAM (🔥 MOST IMPORTANT)
    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {

        if let audio = stream.audioTracks.first {
            remoteAudioTrack = audio
            remoteAudioTrack?.isEnabled = true
            forceSpeaker()
            print("🔊 Remote audio received")
        }

        if let video = stream.videoTracks.first {
            remoteVideoTrack = video
            remoteVideoTrack?.isEnabled = true
            print("📺 Remote video received")
        }
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

        queuedCandidates.removeAll()
        remotePeerId = nil
        hasLocalOffer = false

        print("🧹 WebRTC cleaned up")
    }
}

