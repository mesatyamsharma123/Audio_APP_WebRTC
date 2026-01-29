import Foundation
import WebRTC
import Combine

final class SignalingManager: ObservableObject {

    static let shared = SignalingManager()

    @Published var isConnected: Bool = false
    @Published var remoteAvailable: Bool = false
    @Published var connectedPeers: Int = 0
    @Published var latestPeerId: String?

    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    // MARK: - Connect
    func connect() {
        let url = URL(string: "wss://53cf93551a5a.ngrok-free.app")! // Replace with your ngrok URL
        socket = URLSession.shared.webSocketTask(with: url)
        socket?.resume()
        isConnected = true
        listen()
        startPing()
        print("🔗 WebSocket connecting...")
    }

    func disconnect() {
        socket?.cancel()
        isConnected = false
        remoteAvailable = false
        stopPing()
        print("❌ WebSocket disconnected")
    }

    // MARK: - Keep-alive ping
    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let socket = self?.socket else { return }
            Task {
                try? await socket.send(.string("ping"))
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

    // MARK: - Handle incoming messages
    private func handle(_ text: String) {
        if text == "ping" || text == "pong" { return }

        // Server sends number of peers
        if text.starts(with: "peers:") {
            if let count = Int(text.replacingOccurrences(of: "peers:", with: "")) {
                DispatchQueue.main.async {
                    self.connectedPeers = count
                    self.remoteAvailable = count > 1
                }
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
               let fromPeer = json["from"] as? String {
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
                Task {
                    self.latestPeerId = fromPeer
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                    try? await WebRTCManager.shared.createAnswer(to: fromPeer)
                }
            }

        case "answer":
            if let sdpString = json["sdp"] as? String,
               let fromPeer = json["from"] as? String {
                let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
                Task {
                    self.latestPeerId = fromPeer
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                }
            }

        case "candidate":
            if let candidate = json["candidate"] as? String,
               let index = json["sdpMLineIndex"] as? Int,
               let mid = json["sdpMid"] as? String? {
                let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(index), sdpMid: mid)
                Task { try? await WebRTCManager.shared.addIceCandidate(iceCandidate) }
            }
        default:
            break
        }
    }

    // MARK: - Send messages
    func sendSDP(_ sdp: RTCSessionDescription, to peerId: String) async {
        let msg: [String: Any] = [
            "type": sdp.type == .offer ? "offer" : "answer",
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
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard let socket = socket else { return }
        do {
            try await socket.send(.string(text))
        } catch {
            print("WebSocket send error:", error)
        }
    }
}
