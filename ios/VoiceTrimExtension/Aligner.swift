import AVFoundation
import CoreML
import Foundation

/// Re-times Apple's transcript with wav2vec2 CTC forced alignment, the approach WhisperX uses.
/// Apple's word ranges can be off by half a second, which leaves parts of ums behind and clips real words.
enum Aligner {
    static var modelURL = Bundle.main.url(forResource: "Aligner", withExtension: "mlmodelc")
    static var vocabURL = Bundle.main.url(forResource: "aligner_vocab", withExtension: "json")

    private static let rate = 16000.0
    private static let chunk = 160_000  // the model takes exactly 10 s
    private static let frameSeconds = 0.02  // one CTC frame per 320 samples
    private static let digits = ["ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"]

    /// Words with new times, or nil if the model is missing or alignment fails.
    static func retime(_ words: [Word], audio url: URL) -> [Word]? {
        guard !words.isEmpty, let modelURL, let vocabURL,
              let vocabData = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int].self, from: vocabData),
              let blank = vocab["<pad>"], let separator = vocab["|"] else {
            diag("aligner unavailable")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndGPU  // the Neural Engine compiler can hang for minutes on this model
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            let samples = try read16k(url)
            let emissions = try emit(model, samples)

            var tokens: [Int] = [], owner: [Int?] = []
            for (i, word) in words.enumerated() {
                for part in spoken(word.text) {
                    if !tokens.isEmpty { tokens.append(separator); owner.append(nil) }
                    for ch in part { tokens.append(vocab[String(ch)] ?? vocab["<unk>"] ?? blank); owner.append(i) }
                }
            }
            guard let spans = forcedAlign(emissions, tokens, blank: blank) else {
                diag("alignment failed")
                return nil
            }
            var frames: [Int: (Int, Int)] = [:]
            for (k, span) in spans {
                guard let i = owner[k] else { continue }
                let old = frames[i] ?? span
                frames[i] = (min(old.0, span.0), max(old.1, span.1))
            }
            // CTC marks the moment a letter is heard, which runs late for a word's start, so pad the start more.
            return words.enumerated().map { i, w in
                guard let (a, b) = frames[i] else { return w }
                return Word(text: w.text, start: max(0, Double(a) * frameSeconds - 0.08),
                            end: Double(b + 1) * frameSeconds + 0.04, confidence: w.confidence,
                            heardStart: w.heardStart ?? w.start, heardEnd: w.heardEnd ?? w.end)
            }
        } catch {
            diag("aligner error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Uppercase letters the model knows, with digits read out one at a time ("12" as "ONE TWO").
    static func spoken(_ text: String) -> [String] {
        var out = ""
        for ch in text.uppercased() {
            if let d = ch.wholeNumberValue, ch.isNumber {
                out += " \(digits[d]) "
            } else if ("A"..."Z").contains(String(ch)) || ch == "'" {
                out.append(ch)
            } else {
                out += " "
            }
        }
        return out.split(separator: " ").map(String.init)
    }

    /// Log-probabilities per 20 ms frame, running the model over 10 s windows to keep memory low.
    private static func emit(_ model: MLModel, _ samples: [Float]) throws -> [[Float]] {
        var x = samples
        let mean = x.reduce(0, +) / Float(max(x.count, 1))
        let variance = x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(x.count, 1))
        let scale = 1 / (variance + 1e-7).squareRoot()
        for i in x.indices { x[i] = (x[i] - mean) * scale }

        var emissions: [[Float]] = []
        for start in stride(from: 0, to: x.count, by: chunk) {
            let n = min(chunk, x.count - start)
            let input = try MLMultiArray(shape: [1, NSNumber(value: chunk)], dataType: .float32)
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: chunk)
            for i in 0..<chunk { ptr[i] = i < n ? x[start + i] : 0 }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
            guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { throw CocoaError(.coderInvalidValue) }
            let frames = logits.shape[1].intValue, classes = logits.shape[2].intValue
            let valid = min(frames, Int((Double(n) / rate / frameSeconds).rounded(.up)))
            for t in 0..<valid {
                var row = (0..<classes).map { logits[[0, t, $0] as [NSNumber]].floatValue }
                let top = row.max() ?? 0
                let logSum = Foundation.log(row.reduce(0) { $0 + exp($1 - top) }) + top  // the extension also defines a logger named log
                for c in row.indices { row[c] -= logSum }
                emissions.append(row)
            }
        }
        return emissions
    }

    /// Viterbi CTC forced alignment. Returns the first and last frame of each token that got frames.
    static func forcedAlign(_ emis: [[Float]], _ tokens: [Int], blank: Int) -> [Int: (Int, Int)]? {
        let T = emis.count, S = 2 * tokens.count + 1
        guard !tokens.isEmpty, T >= tokens.count else { return nil }
        var ext = [Int](repeating: blank, count: S)
        for (k, token) in tokens.enumerated() { ext[2 * k + 1] = token }
        var skip = [Bool](repeating: false, count: S)
        for s in stride(from: 3, to: S, by: 2) { skip[s] = ext[s] != ext[s - 2] }
        let neg: Float = -1e30
        var score = [Float](repeating: neg, count: S), next = score
        score[0] = emis[0][ext[0]]
        score[1] = emis[0][ext[1]]
        var back = [UInt8](repeating: 0, count: T * S)
        for t in 1..<T {
            let row = emis[t]
            for s in 0..<S {
                var best = score[s], move: UInt8 = 0
                if s >= 1, score[s - 1] > best { best = score[s - 1]; move = 1 }
                if s >= 2, skip[s], score[s - 2] > best { best = score[s - 2]; move = 2 }
                next[s] = best + row[ext[s]]
                back[t * S + s] = move
            }
            swap(&score, &next)
        }
        guard max(score[S - 1], score[S - 2]) > neg / 2 else { return nil }
        var s = score[S - 2] > score[S - 1] ? S - 2 : S - 1
        var spans: [Int: (Int, Int)] = [:]
        for t in stride(from: T - 1, through: 0, by: -1) {
            if s % 2 == 1 { spans[s / 2] = (t, spans[s / 2]?.1 ?? t) }
            s -= Int(back[t * S + s])
        }
        return spans
    }

    private static func read16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
