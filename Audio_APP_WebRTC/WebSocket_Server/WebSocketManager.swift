import Foundation
import WebRTC
import Combine

@MainActor
final class SignalingManager: ObservableObject {
    static let shared = SignalingManager()
    
    @Published var isConnected: Bool = false
    @Published var connectedPeers: Int = 0
    @Published var remoteAvailable: Bool = false
    @Published var latestPeerId: String? = nil
    
    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    
    func connect() {
        guard let url = URL(string: "wss://c86e9d583a80.ngrok-free.app") else { return }
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
        connectedPeers = 0
        remoteAvailable = false
        latestPeerId = nil
        stopPing()
        print("❌ WebSocket disconnected")
    }
    
    private func startPing() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { try? await self?.socket?.send(.string("ping")) }
        }
    }
    
    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
    
    private func listen() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
            case .failure(let error):
                print("WebSocket receive error:", error)
                self.disconnect()
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
            if let peers = json["peersList"] as? [String],
               let myId = json["myId"] as? String {
                DispatchQueue.main.async {
                    self.connectedPeers = peers.count
                    self.remoteAvailable = peers.contains { $0 != myId }
                    self.latestPeerId = peers.first { $0 != myId }
                    print("🔹 Peers updated: \(peers), latestPeerId: \(self.latestPeerId ?? "nil")")
                }
            }
            
        case "offer":
            if let sdpString = json["sdp"] as? String,
               let fromPeer = json["from"] as? String {
                let sdp = RTCSessionDescription(type: .offer, sdp: sdpString)
                Task {
                    try? await WebRTCManager.shared.setRemoteDescription(sdp)
                    // Answer is created inside setRemoteDescription
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
            
        default: break
        }
    }
    
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
        Task { [weak socket] in
            do { try await socket?.send(.string(text)) }
            catch { print("WebSocket send error:", error) }
        }
    }
}
