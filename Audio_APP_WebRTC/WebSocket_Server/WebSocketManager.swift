import Foundation
import WebRTC
import Combine

final class SignalingManager: ObservableObject {

    static let shared = SignalingManager()

    // MARK: - Published properties
    @Published var isConnected: Bool = false
    @Published var remoteAvailable: Bool = false
    @Published var connectedPeers: Int = 0
    @Published var latestPeerId: String? = nil // Track the remote peer ID

    // MARK: - Private properties
    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    // MARK: - Connect / Disconnect
    func connect() {
        let url = URL(string: "wss://0202ef02f8f3.ngrok-free.app")! // Replace with your ngrok URL
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
        latestPeerId = nil
        stopPing()
        print("❌ WebSocket disconnected")
    }

    // MARK: - Keep-alive ping
    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { try? await self?.socket?.send(.string("ping")) }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: - Listen for incoming messages
    private func listen() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text)
                }
            case .failure(let error):
                print("WebSocket receive error:", error)
                self.disconnect()
            }
            // Keep listening recursively
            self.listen()
        }
    }

    // MARK: - Handle incoming messages
    private func handle(_ text: String) {
        if text == "ping" || text == "pong" { return }

        // Update peers online
        if text.starts(with: "peers:") {
            if let count = Int(text.replacingOccurrences(of: "peers:", with: "")) {
                DispatchQueue.main.async {
                    self.connectedPeers = count
                    self.remoteAvailable = count > 1

                    // Pick the latest peer ID if more than 1 peer is online
                    self.latestPeerId = self.remoteAvailable ? "peer_\(count)" : nil
                }
            }
            return
        }

        // Parse SDP / ICE candidate
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "offer":
            if let sdpString = json["sdp"] as? String,
               let fromPeer = json["from"] as? String {
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
                Task {
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                    try? await WebRTCManager.shared.createAnswer(to: fromPeer)
                    DispatchQueue.main.async {
                        self.latestPeerId = fromPeer
                    }
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
               let mid = json["sdpMid"] as? String? {
                let iceCandidate = RTCIceCandidate(sdp: candidate,
                                                  sdpMLineIndex: Int32(index),
                                                  sdpMid: mid)
                Task { try? await WebRTCManager.shared.addIceCandidate(iceCandidate) }
            }
        default:
            break
        }
    }

    // MARK: - Send SDP / ICE candidate
    func sendSDP(_ sdp: RTCSessionDescription, to peerId: String) async {
        let msg: [String: Any] = [
            "type": sdp.type == .offer ? "offer" : "answer",
            "sdp": sdp.sdp,
            "to": peerId
        ]
        await send(msg)
    }

    func sendCandidate(_ candidate: RTCIceCandidate, to peerId: String) async {
        let msg: [String: Any] = [
            "type": "candidate",
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? "",
            "to": peerId
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
