import Foundation
import WebRTC
import Combine

final class SignalingManager: ObservableObject {

    static let shared = SignalingManager()

    @Published var isConnected: Bool = false
    @Published var remoteAvailable: Bool = false
    @Published var connectedPeers: Int = 0
    @Published var latestPeerId: String? // Peer to call

    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    private var peerList: [String] = []
    private let myId = UUID().uuidString // Unique ID for this device

    // MARK: - Connect
    func connect() {
        guard let url = URL(string: "wss:/53cf93551a5a.ngrok-free.app") else { return }
        socket = URLSession.shared.webSocketTask(with: url)
        socket?.resume()
        isConnected = true
        listen()
        startPing()
        print("🔗 WebSocket connecting with ID:", myId)
    }

    func disconnect() {
        socket?.cancel()
        isConnected = false
        remoteAvailable = false
        stopPing()
        print("❌ WebSocket disconnected")
    }

    // MARK: - Ping
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

    // MARK: - Listen
    private func listen() {
        socket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self?.handle(text)
                }
            case .failure(let error):
                print("WebSocket receive error:", error)
                self?.disconnect()
            }
            self?.listen()
        }
    }

    // MARK: - Handle messages
    private func handle(_ text: String) {
        if text == "ping" || text == "pong" { return }

        // Server sends peers as comma-separated list
        if text.starts(with: "peers:") {
            let peersString = text.replacingOccurrences(of: "peers:", with: "")
            let peers = peersString.split(separator: ",").map { String($0) }
            DispatchQueue.main.async {
                self.peerList = peers
                self.connectedPeers = peers.count
                self.latestPeerId = peers.first(where: { $0 != self.myId })
                self.remoteAvailable = self.connectedPeers > 1
            }
            return
        }

        // SDP & ICE candidate messages
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "offer":
            if let sdpString = json["sdp"] as? String,
               let fromId = json["from"] as? String {
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
                Task {
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                    try? await WebRTCManager.shared.createAnswer(to: fromId)
                }
            }
        case "answer":
            if let sdpString = json["sdp"] as? String {
                let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
                Task { try? await WebRTCManager.shared.setRemoteDescription(sdp) }
            }
        case "candidate":
            if let candidate = json["candidate"] as? String,
               let index = json["sdpMLineIndex"] as? Int,
               let mid = json["sdpMid"] as? String?,
               let fromId = json["from"] as? String {
                let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(index), sdpMid: mid)
                Task { try? await WebRTCManager.shared.addIceCandidate(iceCandidate) }
            }
        default:
            break
        }
    }

    // MARK: - Send
    func sendSDP(_ sdp: RTCSessionDescription, to peerId: String) async {
        let msg: [String: Any] = [
            "type": sdp.type == .offer ? "offer" : "answer",
            "sdp": sdp.sdp,
            "to": peerId,
            "from": myId
        ]
        await send(msg)
    }

    func sendCandidate(_ c: RTCIceCandidate, to peerId: String) async {
        let msg: [String: Any] = [
            "type": "candidate",
            "candidate": c.sdp,
            "sdpMLineIndex": c.sdpMLineIndex,
            "sdpMid": c.sdpMid ?? "",
            "to": peerId,
            "from": myId
        ]
        await send(msg)
    }

    private func send(_ msg: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { [weak socket] in
            do { try await socket?.send(.string(text)) }
            catch { print("WebSocket send error:", error) }
        }
    }
}
