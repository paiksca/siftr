import AVFoundation
import Foundation

@MainActor
final class RecorderModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle, recording, processing, ready
        case failed(String)
    }

    enum Clip { case original, cleaned }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Double = 0  // 0...1, live input loudness
    @Published private(set) var result: TrimResult?
    @Published private(set) var playing: Clip?
    @Published private(set) var choice: Clip = .cleaned  // what Send sends; sifted unless the user slides over

    /// Set by the view controller.
    var insert: ((URL, String?) -> Void)?

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var player: AVAudioPlayer?
    private var recording: URL?
    @Published private(set) var started: Date?

    func toggleRecording() {
        if phase == .recording {
            finishRecording()
        } else {
            Task { await startRecording() }
        }
    }

    func play(_ clip: Clip) {
        if playing == clip {
            stopAudio()
            return
        }
        guard let url = clip == .original ? recording : result?.audio else { return }
        stopAudio()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            playing = clip
        } catch {
            fail("Could not play audio: \(error.localizedDescription)")
        }
    }

    func select(_ clip: Clip) {
        guard clip != choice else { return }
        stopAudio()
        choice = clip
    }

    func togglePlay() { play(choice) }

    func send() {
        guard let result else { return }
        stopAudio()
        let source = choice == .cleaned ? result.audio : recording
        let text = choice == .cleaned ? result.transcript : result.originalTranscript
        guard let source else { return }
        Task {
            // Send in Messages' own audio-message format when possible, falling back to .m4a.
            let audio = await Task.detached(priority: .userInitiated) {
                (try? Trimmer.exportVoiceMessage(source)) ?? (try? Trimmer.encode(source))
            }.value
            insert?(audio ?? source, text)
            reset()
        }
    }

    func reset() {
        stopAudio()
        phase = .idle
        result = nil
        choice = .cleaned
        level = 0
    }

    func stopAudio() {
        player?.stop()
        player = nil
        playing = nil
    }

    /// The extension is going inactive. Keep whatever was recorded rather than lose it.
    func interrupt() {
        if phase == .recording { finishRecording() }
    }

    private func startRecording() async {
        if AVAudioApplication.shared.recordPermission != .granted {
            guard await AVAudioApplication.requestRecordPermission() else {
                fail("Microphone access is off. Turn it on in Settings, Privacy & Security, Microphone.")
                return
            }
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            // Record the raw mic. Voice isolation afterward removes noise far better than live voice processing.
            try beginCapture()
        } catch {
            tearDownCapture()
            fail("Could not record: \(error.localizedDescription)")
            return
        }
        result = nil
        started = Date()
        phase = .recording
    }

    private func beginCapture() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(file: file, model: self))
        engine.prepare()
        try engine.start()
        diag("recording at \(format.sampleRate) Hz, \(format.channelCount) ch")
        self.file = file
        recording = url
    }

    private func tearDownCapture() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
    }

    private func finishRecording() {
        tearDownCapture()  // also closes the file
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let recording else { return }
        diag(String(format: "recording stopped after %.1f s", Date().timeIntervalSince(started ?? Date())))
        phase = .processing
        Task {
            // Isolate the voice first, so transcription and trimming both work on clean audio.
            let isolated = await Task.detached(priority: .userInitiated) { Isolation.run(recording) }.value ?? recording
            let transcription = await Transcription.run(isolated)
            let apple = transcription?.words ?? [], text = transcription?.text ?? ""
            // Apple finds the ums, but its timings drift. Re-time every word before cutting.
            let words = await Task.detached(priority: .userInitiated) {
                Aligner.retime(apple, audio: isolated) ?? apple
            }.value
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Trimmer.trim(recording: isolated, words: words, transcript: text)
                }.value
                self.result = result
                phase = .ready
                diag(String(format: "trimmed %.1f s -> %.1f s", result.before, result.after))
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        log.error("failed: \(message, privacy: .public)")
        phase = .failed(message)
    }

    /// The audio tap calls back off the main thread, so it is built outside the actor.
    nonisolated private static func tap(file: AVAudioFile, model: RecorderModel) -> AVAudioNodeTapBlock {
        { [weak model] buffer, _ in
            do { try file.write(from: buffer) } catch { log.error("write failed: \(error.localizedDescription)") }
            let level = rms(buffer)
            Task { @MainActor in
                guard let model else { return }
                model.level = model.level * 0.5 + level * 0.5
            }
        }
    }

    /// Loudness of a buffer mapped to 0...1, from about -50 dB to 0 dB.
    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let db = 10 * log10(Double(sum) / Double(buffer.frameLength) + 1e-12)
        return max(0, min(1, (db + 50) / 50))
    }
}

extension RecorderModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}
