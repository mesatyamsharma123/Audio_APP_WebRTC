//
//  RTCVideoView.swift
//  Audio_APP_WebRTC
//
//  Created by Sumit Raj Chingari on 02/02/26.
//

import SwiftUI
import WebRTC

struct RTCVideoView: UIViewRepresentable {

    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        track?.add(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

