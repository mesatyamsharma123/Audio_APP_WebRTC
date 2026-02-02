import Foundation
import WebRTC
import Combine

final class SignalingManager: ObservableObject {

    static let shared = SignalingManager()

    @Published var isConnected = false
    @Published var remoteAvailable = false
    @Published var connectedPeers = 0
    @Published var latestPeerId: String?

    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    func connect() {
        guard let url = URL(string: "wss://f726e817afaf.ngrok-free.app") else { return }
        socket = URLSession.shared.webSocketTask(with: url)
        socket?.resume()
        isConnected = true
        listen()
        startPing()
        print("🔗 WebSocket connected")
    }

    func disconnect() {
        socket?.cancel()
        isConnected = false
        remoteAvailable = false
        latestPeerId = nil
        stopPing()
    }

    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task {
                try? await self?.socket?.send(.string("ping"))
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func listen() {
        socket?.receive { [weak self] result in
            guard let self else { return }

            if case .success(let message) = result,
               case .string(let text) = message {
                self.handle(text)
            }

            self.listen()
        }
    }

    private func handle(_ text: String) {
        if text == "ping" || text == "pong" { return }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {

        case "peers":
            if let peers = json["peers"] as? [String],
               let myId = json["myId"] as? String {
                DispatchQueue.main.async {
                    self.connectedPeers = peers.count
                    self.remoteAvailable = peers.contains { $0 != myId }
                    self.latestPeerId = peers.first { $0 != myId }
                }
            }

        case "offer":
            if let sdpString = json["sdp"] as? String,
               let fromPeer = json["from"] as? String {

                let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
                WebRTCManager.shared.handleRemoteOffer(sdp, from: fromPeer)
            }

        case "answer":
            if let sdpString = json["sdp"] as? String {
                let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
                Task { await WebRTCManager.shared.setRemoteDescription(sdp) }
            }

        case "candidate":
            if let c = json["candidate"] as? String,
               let index = json["sdpMLineIndex"] as? Int,
               let mid = json["sdpMid"] as? String {
                let candidate = RTCIceCandidate(
                    sdp: c,
                    sdpMLineIndex: Int32(index),
                    sdpMid: mid
                )
                Task { await WebRTCManager.shared.addIceCandidate(candidate) }
            }

        default: break
            
        }
    }

    func sendSDP(_ sdp: RTCSessionDescription, to peerId: String) async {
        let msg: [String: Any] = [
            "type": sdp.type.rawValue,
            "sdp": sdp.sdp,
            "to": peerId
        ]
        await send(msg)
    }

    func sendCandidate(_ c: RTCIceCandidate, to peerId: String) async {
        let msg: [String: Any] = [
            "type": "candidate",
            "candidate": c.sdp,
            "sdpMLineIndex": c.sdpMLineIndex,
            "sdpMid": c.sdpMid ?? "",
            "to": peerId
        ]
        await send(msg)
    }

    private func send(_ msg: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }

        try? await socket?.send(.string(text))
    }
}
