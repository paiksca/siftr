import Messages
import SwiftUI
import UIKit
import os

let log = Logger(subsystem: "com.samuelpaikheintz.voicetrim", category: "extension")

/// Tuning details. Logged as errors because lower levels from this process don't reach the device syslog.
func diag(_ message: String) {
    log.error("diag: \(message, privacy: .public)")
}

final class MessagesViewController: MSMessagesAppViewController {
    private let model = RecorderModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.insert = { [weak self] audio, text in self?.insert(audio: audio, text: text) }

        let host = UIHostingController(rootView: ContentView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        log.notice("willBecomeActive, style \(self.presentationStyle.rawValue)")
    }

    override func willResignActive(with conversation: MSConversation) {
        super.willResignActive(with: conversation)
        log.notice("willResignActive, phase \(String(describing: self.model.phase), privacy: .public)")
        model.stopAudio()
        model.interrupt()
    }

    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        log.notice("willTransition to style \(presentationStyle.rawValue)")
    }

    /// Stage the cleaned audio (and optionally its transcript) in the message field for the user to send.
    private func insert(audio: URL, text: String?) {
        guard let conversation = activeConversation else {
            log.error("insert: no active conversation")
            return
        }
        let name = audio.pathExtension == "caf" ? "Audio Message.caf" : "Audio Message.m4a"
        conversation.insertAttachment(audio, withAlternateFilename: name) { error in
            if let error { log.error("insertAttachment failed: \(error.localizedDescription, privacy: .public)") }
        }
        if let text, !text.isEmpty {
            conversation.insertText(text) { error in
                if let error { log.error("insertText failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        requestPresentationStyle(.compact)
    }
}
