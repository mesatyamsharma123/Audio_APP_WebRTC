import Foundation
import WebRTC
import Combine

final class SignalingManager: ObservableObject {

    static let shared = SignalingManager()

    @Published var isConnected: Bool = false
    @Published var remoteAvailable: Bool = false // true when another peer connects

    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    // MARK: - Connect
    func connect() {
        let url = URL(string: "wss://3305980e7d9d.ngrok-free.app")!
        socket = URLSession.shared.webSocketTask(with: url)
        socket?.resume()
        isConnected = true
        listen()
        startPing()
        print("🔗 WebSocket connecting...")
    }

    private func disconnect() {
        socket?.cancel()
        isConnected = false
        remoteAvailable = false
        stopPing()
        print("❌ WebSocket disconnected")
    }

    // MARK: - Keep-alive Ping
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

    // MARK: - Send
    func sendSDP(_ sdp: RTCSessionDescription) {
        guard remoteAvailable else {
            print("❌ Cannot send SDP, no remote peer available yet")
            return
        }
        let msg: [String: Any] = [
            "type": sdp.type == .offer ? "offer" : "answer",
            "sdp": sdp.sdp
        ]
        send(msg)
    }

    func sendCandidate(_ c: RTCIceCandidate) {
        guard remoteAvailable else { return }
        let msg: [String: Any] = [
            "type": "candidate",
            "candidate": c.sdp,
            "sdpMLineIndex": c.sdpMLineIndex,
            "sdpMid": c.sdpMid ?? ""
        ]
        send(msg)
    }

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { [weak socket] in
            do {
                try await socket?.send(.string(text))
            } catch {
                print("WebSocket send error: \(error)")
            }
        }
    }

    // MARK: - Handle Incoming Messages
    private func handle(_ text: String) {
        if text == "ping" || text == "pong" {
            return
        }

        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        // Whenever we receive a message from another peer, mark remote as available
        remoteAvailable = true

        switch type {
        case "offer":
            if let sdpString = json["sdp"] as? String {
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
                Task {
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                    try? await WebRTCManager.shared.createAnswer()
                }
            }
        case "answer":
            if let sdpString = json["sdp"] as? String {
                let sdp = RTCSessionDescription(type: .answer, sdp: sdpString)
                Task {
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                }
            }
        case "candidate":
            if let candidate = json["candidate"] as? String,
               let index = json["sdpMLineIndex"] as? Int,
               let mid = json["sdpMid"] as? String? {
                let c = RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(index), sdpMid: mid)
                Task { try? await WebRTCManager.shared.addIceCandidate(c) }
            }
        default:
            break
        }
    }
}
