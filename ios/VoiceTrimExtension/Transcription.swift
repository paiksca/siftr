import AVFoundation
import Speech

/// On-device transcription of a whole recording, with each word's time span on one continuous timeline.
enum Transcription {
    /// Names the recognizer should expect, so "Sift" isn't heard as "SIFT" or "Sif".
    static let vocabulary = ["Sift", "iMessage", "WhatsApp", "iOS"]

    /// Returns nil if speech recognition is off or unavailable, in which case only pauses get trimmed.
    static func run(_ url: URL) async -> (words: [Word], text: String)? {
        guard await authorized() else {
            diag("speech recognition not authorized")
            return nil
        }
        return await transcribe(url)
    }

    /// Gives up after 1.5 times the recording's length (at least 8 s), returning nil. On some recordings,
    /// mostly silence, Apple's analyzer never finishes its results, which would leave Siftr stuck processing.
    static func transcribe(_ url: URL) async -> (words: [Word], text: String)? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            diag("recording is empty or unreadable")
            return nil
        }
        let limit = max(8, Double(file.length) / file.processingFormat.sampleRate * 1.5)
        let once = Once<(words: [Word], text: String)?>()
        return await withCheckedContinuation { continuation in
            let work = Task {
                let result = await transcribeUnbounded(url)
                once.resume(continuation, with: result)
            }
            Task {
                try? await Task.sleep(for: .seconds(limit))
                if once.resume(continuation, with: nil) {
                    diag(String(format: "transcription timed out after %.0f s", limit))
                    work.cancel()
                }
            }
        }
    }

    private static func transcribeUnbounded(_ url: URL) async -> (words: [Word], text: String)? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            diag("no on-device transcriber for \(Locale.current.identifier)")
            return nil
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                diag("downloading speech model for \(locale.identifier)")
                try await install.downloadAndInstall()
            }
            let file = try AVAudioFile(forReading: url)
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber],
                                                    analysisContext: context, finishAfterFile: true)
            var words: [Word] = []
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                pieces.append(String(result.text.characters))
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !word.isEmpty {
                        words.append(Word(text: word, start: range.start.seconds, end: range.end.seconds,
                                          confidence: run.transcriptionConfidence,
                                          heardStart: range.start.seconds, heardEnd: range.end.seconds))
                    }
                }
            }
            withExtendedLifetime(analyzer) {}
            let text = pieces.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (words, text)
        } catch {
            diag("transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func authorized() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .notDetermined { return status == .authorized }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}

/// Resumes a continuation exactly once, whichever of several racing tasks gets there first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    @discardableResult
    func resume(_ continuation: CheckedContinuation<T, Never>, with value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation.resume(returning: value)
        return true
    }
}
