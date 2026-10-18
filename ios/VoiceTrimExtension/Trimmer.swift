import Accelerate
import AVFoundation
import Foundation

/// One recognized word with its time span in seconds.
struct Word {
    let text: String
    let start: Double
    let end: Double
    var confidence: Double? = nil  // the recognizer's, from 0 to 1, when it reports one
    var heardStart: Double? = nil  // the recognizer's own time range, kept when the word is re-timed
    var heardEnd: Double? = nil
}

struct TrimResult {
    let audio: URL
    let transcript: String  // cleaned, to send with the sifted audio
    let originalTranscript: String  // as spoken, to send with the original
    let before: Double
    let after: Double
    let removed: [String: Int]  // reason -> count: "filler", "repeat", "false start"
    let pausesShortened: Int
}

enum TrimError: LocalizedError {
    case unreadable, unwritable
    var errorDescription: String? {
        self == .unreadable ? "Couldn't read the recording." : "Couldn't save the trimmed audio."
    }
}

/// Removes fillers, repeats and long pauses from a recording, on device. Only deletes, never adds.
enum Trimmer {
    static let fillers: Set<String> = ["um", "uh", "uhm", "erm", "er", "ah", "eh", "hm", "m", "mhm"]  // after collapsing repeated letters
    // Words that are filler only when set off by commas, as in "um, like, um" but not "I like it".
    static let commaFillers: Set<String> = ["like", "basically", "actually", "literally", "so", "well", "anyway"]
    static let commaFillerPhrases: [[String]] = [["you", "know"], ["i", "mean"]]
    // Words people repeat on purpose, as in "had had" or "very very".
    static let intentionalRepeats: Set<String> = ["had", "that", "very", "really", "no", "so", "bye", "ha", "yeah"]

    struct Settings {
        var maxPause = 0.3  // silent pauses longer than this are shortened to it
        var unwrittenFiller = 0.4  // seconds of untranscribed sound between two words that count as a filler
        var longGap = 0.6  // a gap between words longer than this is shortened to maxPause even if not silent
        var cutPause = 0.12  // pause left where a filler or repeat was removed
        var lead = 0.1  // silence kept before the first word
        var tail = 0.2  // silence kept after the last word
        var guardTime = 0.04  // margin kept around each word, for timestamp error
        var edgeGuard = 0.1  // margin kept before the first word and after the last, so no syllable is clipped
        var maxUnplannedLoss = 0.15  // share of speech lost outside removed words that means the timings are off
        var crossfade = 0.02
    }

    static func trim(recording: URL, words: [Word], transcript: String,
                     settings: Settings = Settings()) throws -> TrimResult {
        let (samples, rate) = try readMono(recording)
        let duration = Double(samples.count) / rate
        let energy = Energy(samples: samples, rate: rate)
        // Apple's word ranges run end to end and absorb pauses, so shrink each to the sound inside it.
        let usable = words.filter { $0.end > $0.start && $0.start >= 0 && $0.end <= duration + 0.5 }
            .map { energy.tighten($0) }
        diag("\(words.count) words, \(usable.count) usable, \(String(format: "%.1f", duration)) s: "
             + usable.map { String(format: "%@ %.2f-%.2f", $0.text, $0.start, $0.end) }.joined(separator: ", "))

        if usable.count * 2 >= words.count && !usable.isEmpty {
            let plan = makePlan(usable, energy: energy, duration: duration, settings: settings)
            // Speech inside removed words is meant to go. Any other speech lost means the timings are wrong.
            let total = max(energy.voicedSeconds(in: [(0, duration)]), 0.01)
            let intended = energy.voicedSeconds(in: plan.removedSpans)
            let lost = 1 - (energy.voicedSeconds(in: plan.spans) + intended) / total
            diag(String(format: "word plan: %d spans, removes %.0f%% of speech on purpose, %.0f%% unplanned",
                        plan.spans.count, intended / total * 100, lost * 100))
            if lost <= settings.maxUnplannedLoss {
                return try finish(samples, rate: rate, plan: plan, transcript: transcript, settings: settings)
            }
        }
        // Without trustworthy word timings, stretches of sound stand in for words and only pauses get trimmed.
        let plan = makePlan(energy.voicedRuns(), energy: energy, duration: duration, settings: settings)
        diag("falling back to pause-only trimming, \(plan.spans.count) spans")
        return try finish(samples, rate: rate, plan: plan, transcript: transcript, settings: settings)
    }

    struct Plan {
        var spans: [(Double, Double)] = []
        var removedSpans: [(Double, Double)] = []  // everything cut on purpose: fillers, repeats, edges
        var removed: [String: Int] = [:]
        var pauses = 0
        var transcript: String?  // the kept words, nil when there were no words to keep
    }

    private static func finish(_ samples: [Float], rate: Double, plan: Plan, transcript: String,
                               settings: Settings) throws -> TrimResult {
        let output = render(samples, rate: rate, spans: plan.spans, crossfade: settings.crossfade)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetrim-\(UUID().uuidString).m4a")
        try writeAAC(output, rate: rate, to: url)
        return TrimResult(audio: url, transcript: plan.transcript ?? cleanTranscript(transcript), originalTranscript: transcript,
                          before: Double(samples.count) / rate,
                          after: Double(output.count) / rate, removed: plan.removed, pausesShortened: plan.pauses)
    }

    static func makePlan(_ words: [Word], energy: Energy, duration: Double, settings: Settings) -> Plan {
        var reasons = words.map(classify)
        markCommaFillers(words, &reasons)
        markRepeats(words, &reasons)
        let loudness = relativeLoudness(words, energy: energy)
        diag("loudness: " + zip(words, loudness).map { "\($0.text) \(Int($1.rounded()))" }.joined(separator: ", "))
        markBackground(loudness, &reasons)
        markUnclear(words, loudness, &reasons)
        var removed: [String: Int] = [:]
        for case let reason? in reasons { removed[reason, default: 0] += 1 }
        let kept = reasons.indices.filter { reasons[$0] == nil }

        var spans: [(Double, Double)] = []
        var cuts: [(Double, Double)] = []  // everything taken out on purpose
        var gapPauses = 0
        var unwritten = 0  // fillers found by sound alone
        if let firstIndex = kept.first, let lastIndex = kept.last {
            let first = words[firstIndex], last = words[lastIndex]
            // Before the first word, keep only quiet lead-in. Sound right up against it (a filler Apple
            // missed, or the end of a removed one) goes, cut at the quietest point.
            var start: Double
            if firstIndex > 0, first.start - words[firstIndex - 1].end < settings.guardTime {
                start = min(first.start, energy.quietest(around: min(first.start, words[firstIndex - 1].end),
                                                         max(first.start, words[firstIndex - 1].end)))
            } else {
                let room = energy.quietRun(from: first.start, forward: false)
                start = max(0, first.start - min(settings.lead, max(settings.edgeGuard, room)))
            }
            cuts.append((0, start))
            for (ka, kb) in zip(kept, kept.dropFirst()) {
                let a = words[ka], b = words[kb]
                let gap = max(0, b.start - a.end)
                if kb - ka == 1 {
                    if gap > settings.longGap {
                        // No word was transcribed in a long gap, so whatever it holds is a breath, mumbling or
                        // room noise, not speech. Shorten it to a normal pause even if it isn't silent.
                        let half = settings.maxPause / 2
                        spans.append((start, a.end + half))
                        cuts.append((a.end + half, b.start - half))
                        start = b.start - half
                        gapPauses += 1
                        diag(String(format: "long gap cut %.2f-%.2f between '%@' and '%@'", a.end + half, b.start - half, a.text, b.text))
                    } else if energy.longestSound(from: a.end, to: b.start) >= settings.unwrittenFiller {
                        // A held sound no word covers is a filler Apple didn't write down.
                        let half = settings.cutPause / 2
                        let cutStart = a.end + min(half, energy.quietRun(from: a.end, forward: true))
                        let cutEnd = b.start - min(half, energy.quietRun(from: b.start, forward: false))
                        if cutEnd > cutStart {
                            spans.append((start, cutStart))
                            cuts.append((cutStart, cutEnd))
                            start = cutEnd
                            unwritten += 1
                            diag(String(format: "unwritten filler cut %.2f-%.2f between '%@' and '%@'", cutStart, cutEnd, a.text, b.text))
                        }
                    }
                    continue
                }
                // A filler or repeat sits between these two words. Cut everything between them, so no
                // leftover piece of the um survives. Where a kept word runs straight into the removed sound,
                // cut at the quietest point between them, but never into the kept word. Where there is silence,
                // keep a little of it.
                let r1 = words[ka + 1], rk = words[kb - 1]
                let want = settings.cutPause
                let tailRoom = max(0, min(r1.start - a.end, energy.quietRun(from: a.end, forward: true)))
                let headRoom = max(0, min(b.start - rk.end, energy.quietRun(from: b.start, forward: false)))
                var tail = min(tailRoom, want / 2)
                let head = min(headRoom, want - tail)
                tail = min(tailRoom, want - head)
                let cutStart = r1.start - a.end < settings.guardTime
                    ? max(a.end, energy.quietest(around: min(a.end, r1.start), max(a.end, r1.start)))
                    : a.end + max(tail, settings.guardTime)
                let cutEnd = b.start - rk.end < settings.guardTime
                    ? min(b.start, energy.quietest(around: min(rk.end, b.start), max(rk.end, b.start)))
                    : b.start - max(head, settings.guardTime)
                guard cutEnd > cutStart else { continue }
                spans.append((start, cutStart))
                cuts.append((cutStart, cutEnd))
                start = cutEnd
            }
            // After the last word, keep only quiet tail-out, so a trailing filler Apple missed goes too.
            var end: Double
            if lastIndex + 1 < words.count, words[lastIndex + 1].start - last.end < settings.guardTime {
                end = max(last.end, energy.quietest(around: min(last.end, words[lastIndex + 1].start),
                                                    max(last.end, words[lastIndex + 1].start)))
            } else {
                let room = energy.quietRun(from: last.end, forward: true)
                end = min(duration, last.end + min(settings.tail, max(settings.edgeGuard, room)))
            }
            spans.append((start, end))
            cuts.append((end, duration))
        } else {
            spans = [(0, duration)]
        }
        // Pauses are shortened by sound level alone. Gaps between words can hold speech the timings missed.
        let (shortened, silences) = shortenSilences(in: spans, energy: energy, maxPause: settings.maxPause)
        let pauses = silences + gapPauses
        diag("spans: " + shortened.map { String(format: "%.2f-%.2f", $0.0, $0.1) }.joined(separator: " "))
        let hasText = words.contains { !$0.text.isEmpty }
        if unwritten > 0 { removed["filler", default: 0] += unwritten }
        return Plan(spans: shortened, removedSpans: cuts, removed: removed, pauses: pauses,
                    transcript: hasText ? keptTranscript(words, reasons) : nil)
    }

    /// Word ranges can hide a pause inside one word. Shorten any silence longer than `maxPause` within the kept audio.
    static func shortenSilences(in spans: [(Double, Double)], energy: Energy,
                                maxPause: Double) -> ([(Double, Double)], Int) {
        var out: [(Double, Double)] = []
        var count = 0
        for (start, end) in spans {
            var segStart = start
            for (qs, qe) in energy.quietRuns(from: start, to: end, below: energy.pauseThreshold)
            where qe - qs > maxPause {
                out.append((segStart, qs + maxPause / 2))
                segStart = qe - maxPause / 2
                count += 1
            }
            out.append((segStart, end))
        }
        return (out, count)
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" })
    }

    static func classify(_ word: Word) -> String? {
        let norm = normalize(word.text)
        // Collapse drawn-out letters, so "ummm" and "hmmm" match "um" and "hm".
        let squeezed = String(norm.reduce(into: [Character]()) { if $0.last != $1 { $0.append($1) } })
        if fillers.contains(squeezed) { return "filler" }
        if norm.count > 1 && norm.hasSuffix("-") { return "false start" }
        return nil
    }

    /// Mark the first copy of a word or phrase said twice in a row.
    static func markRepeats(_ words: [Word], _ reasons: inout [String?]) {
        let idx = reasons.indices.filter { reasons[$0] == nil }
        let norms = idx.map { normalize(words[$0].text) }
        var i = 0
        while i < idx.count {
            var matched = false
            for n in [3, 2, 1] where i + 2 * n <= idx.count {
                let a = norms[i..<i + n], b = norms[i + n..<i + 2 * n]
                // Stand-in words from the pause-only fallback have no text and never repeat.
                if !a.contains("") && Array(a) == Array(b) && !(n == 1 && intentionalRepeats.contains(a.first!)) {
                    for j in idx[i..<i + n] { reasons[j] = "repeat" }
                    i += n
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
    }

    // Words Apple capitalizes when it guesses a new sentence after a filler, which read wrong once the filler is gone.
    static let lowercaseMidSentence: Set<String> = [
        "and", "but", "so", "or", "it", "it's", "its", "that", "that's", "this", "what", "what's", "when", "where",
        "why", "how", "the", "a", "an", "we", "we're", "you", "your", "they", "then", "there", "there's", "he", "she",
        "my", "our", "is", "are", "was", "if", "because", "just", "also", "any", "every", "to", "of", "in", "on",
        "for", "with", "as", "at", "not", "which", "who",
    ]

    // Canonical spellings, keyed by lowercase letters. Apple hears the app's name as "SIFT" or "Sif".
    static let spellings = ["sift": "Sift", "sif": "Sift", "imessage": "iMessage", "whatsapp": "WhatsApp", "ios": "iOS"]

    /// The words Sift kept, so the text matches the audio, with spelling, capitals and punctuation repaired
    /// where fillers came out.
    static func keptTranscript(_ words: [Word], _ reasons: [String?]) -> String {
        var out: [String] = []
        var sentenceStart = true
        for i in words.indices where !words[i].text.isEmpty {
            if reasons[i] != nil {
                // Before a removed "like" or "you know", the comma was only there to set the filler apart.
                // Before an um it can separate list items, as in "one, um, two", so it stays.
                let fillerWord = reasons[i] == "filler" && classify(words[i]) == nil
                if fillerWord, let last = out.last, last.hasSuffix(",") { out[out.count - 1] = String(last.dropLast()) }
                continue
            }
            var t = words[i].text
            let core = normalize(t), tail = t.drop { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
            if let fixed = spellings[core] { t = fixed + tail }
            let capitalized = t.first?.isUppercase == true && !t.dropFirst().contains { $0.isUppercase }
            let pronounI = core == "i" || core.hasPrefix("i'")
            let afterRemoval = i > 0 && reasons[i - 1] != nil
            if sentenceStart {
                t = t.prefix(1).uppercased() + t.dropFirst()
            } else if capitalized && !pronounI && spellings[core] == nil
                        && (lowercaseMidSentence.contains(core) || afterRemoval) {
                t = t.prefix(1).lowercased() + t.dropFirst()  // Apple guessed a new sentence at the filler
            }
            out.append(t)
            sentenceStart = t.last.map { ".?!".contains($0) } ?? false
        }
        var text = out.joined(separator: " ")
        text = text.replacingOccurrences(of: #",\s*([,.?!])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #",$"#, with: "", options: .regularExpression)
        if let last = text.last, !".?!".contains(last) { text += "." }
        return text
    }

    /// Each word's loudness in dB relative to the message's typical word, smoothed over its neighbors.
    /// The speaker holding the phone is loud. Background talk and mumbling are well below.
    static func relativeLoudness(_ words: [Word], energy: Energy) -> [Double] {
        // Measured over the recognizer's own ranges: forced alignment places even misheard words onto
        // nearby loud speech, which would hide that they were quiet.
        let levels = words.map { energy.peakLevel(from: $0.heardStart ?? $0.start, to: $0.heardEnd ?? $0.end) }
        guard !levels.isEmpty else { return [] }
        let typical = levels.sorted()[levels.count / 2]
        let rel: [Double] = levels.map { $0 - typical }
        var smoothed: [Double] = []
        for i in rel.indices {
            let window: [Double] = Array(rel[max(0, i - 1)...min(rel.count - 1, i + 1)])
            let sum: Double = window.reduce(0, +)
            smoothed.append(window.count == 3 ? window.sorted()[1] : sum / Double(window.count))
        }
        return smoothed
    }

    /// Mark three or more words in a row at least 10 dB quieter than the speaker: someone else talking nearby.
    static func markBackground(_ loudness: [Double], _ reasons: inout [String?]) {
        var i = 0
        while i < loudness.count {
            var j = i
            while j < loudness.count, loudness[j] <= -10 { j += 1 }
            if j - i >= 3 { for k in i..<j where reasons[k] == nil { reasons[k] = "background" } }
            i = max(j, i + 1)
        }
        // A quieter word left alone at the very start or end, next to background talk, is part of it.
        if loudness.count > 1, loudness[0] <= -5, reasons[0] == nil, reasons[1] == "background" { reasons[0] = "background" }
        let last = loudness.count - 1
        if last > 0, loudness[last] <= -5, reasons[last] == nil, reasons[last - 1] == "background" {
            reasons[last] = "background"
        }
    }

    /// Mark speech the recognizer was mostly guessing at, such as mumbling it turned into words.
    static func markUnclear(_ words: [Word], _ loudness: [Double], _ reasons: inout [String?]) {
        guard words.contains(where: { $0.confidence != nil }) else { return }
        var unclear = [Bool](repeating: false, count: words.count)
        // Three or more words in a row, each below 0.5. Cut them if Apple was lost (averaging below 0.15),
        // or if it was guessing (below 0.3) at quiet speech. Loud speech it was unsure of is usually real,
        // as in someone counting "three, four, five".
        // Runs are counted over the words still kept, so cut repeats and fillers don't split them.
        let open: [Int] = words.indices.filter { reasons[$0] == nil }
        var i = 0
        while i < open.count {
            var j = i, sum = 0.0
            while j < open.count, let c = words[open[j]].confidence, c < 0.5 { sum += c; j += 1 }
            if j - i >= 3 {
                let mean: Double = sum / Double(j - i)
                let run: [Double] = open[i..<j].map { loudness[$0] }.sorted()
                let quiet: Bool = run[run.count / 2] <= -6
                if mean < 0.15 || (mean < 0.3 && quiet) { for k in open[i..<j] { unclear[k] = true } }
            }
            i = max(j, i + 1)
        }
        // A phrase Apple marks as trailing off, as in "It's a hell of a...", that it wasn't sure of.
        var start = 0
        for k in words.indices {
            let t = words[k].text
            if (t.hasSuffix("...") || t.hasSuffix("…")) && k + 1 < words.count {
                let scores = words[start...k].compactMap(\.confidence)
                if !scores.isEmpty && scores.reduce(0, +) / Double(scores.count) < 0.6 {
                    for m in start...k { unclear[m] = true }
                }
            }
            if let last = t.last, ".?!…".contains(last) { start = k + 1 }
        }
        // If most of the message is unclear, the recognizer misheard it all, and cutting would remove real speech.
        guard unclear.filter({ $0 }).count * 2 <= words.count else { return }
        for k in words.indices where unclear[k] && reasons[k] == nil { reasons[k] = "unclear" }
    }

    /// Mark "like", "you know" and similar when commas set them apart from the sentence.
    static func markCommaFillers(_ words: [Word], _ reasons: inout [String?]) {
        func endsClause(_ i: Int) -> Bool {
            i < 0 || reasons[i] == "filler" || words[i].text.last.map { ",.?!".contains($0) } == true
        }
        let norms = words.map { normalize($0.text) }
        for i in words.indices where reasons[i] == nil && words[i].text.hasSuffix(",") {
            if commaFillers.contains(norms[i]) && endsClause(i - 1) {
                reasons[i] = "filler"
            } else if i >= 1, reasons[i - 1] == nil, commaFillerPhrases.contains([norms[i - 1], norms[i]]),
                      endsClause(i - 2) {
                reasons[i - 1] = "filler"
                reasons[i] = "filler"
            }
        }
    }

    static func cleanTranscript(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\b(?:u+m+|u+h+|u+h+m+|e+r+m+|h+m+|m+h+m+)\b[,.]?\s*"#, with: "",
                                          options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(
            of: #"(^|[,.?!]\s+)(?:like|basically|actually|literally|so|well|anyway|you know|i mean),\s*"#,
            with: "$1", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\b(\w+)(?:,?\s+\1\b)+"#, with: "$1",
                                   options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        return t
    }

    static func render(_ s: [Float], rate: Double, spans: [(Double, Double)], crossfade: Double) -> [Float] {
        let n = Int(crossfade * rate)
        var out: [Float] = []
        out.reserveCapacity(s.count)
        for (a, b) in spans {
            let lo = max(0, Int(a * rate)), hi = min(s.count, Int(b * rate))
            guard hi > lo else { continue }
            let piece = s[lo..<hi]
            let k = min(n, out.count, piece.count)
            for i in 0..<k {  // equal-power crossfade into the next piece
                let t = Float(i) / Float(k)
                let j = out.count - k + i
                out[j] = out[j] * cos(t * .pi / 2) + piece[lo + i] * sin(t * .pi / 2)
            }
            out.append(contentsOf: piece.dropFirst(k))
        }
        return out
    }

    static func readMono(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw TrimError.unreadable }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw TrimError.unreadable }
        let n = Int(buffer.frameLength), channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            vDSP.add(mono, UnsafeBufferPointer(start: data[c], count: n), result: &mono)
        }
        if channels > 1 { vDSP.divide(mono, Float(channels), result: &mono) }
        return (mono, format.sampleRate)
    }

    /// Opus in a .caf file, the format of Messages' own audio messages, so a sent message looks and plays like one.
    /// Returns nil if the audio's sample rate can't be encoded as Opus.
    static func exportVoiceMessage(_ url: URL) throws -> URL? {
        let (samples, rate) = try readMono(url)
        guard [8000.0, 12000, 16000, 24000, 48000].contains(rate), !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Audio Message \(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return out
    }

    /// The whole recording as .m4a, for sending the original.
    static func encode(_ url: URL) throws -> URL {
        let (samples, rate) = try readMono(url)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("original-\(UUID().uuidString).m4a")
        try writeAAC(samples, rate: rate, to: out)
        return out
    }

    static func writeAAC(_ samples: [Float], rate: Double, to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw TrimError.unwritable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,  // a fixed bitrate fails at low sample rates
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// Loudness of a recording in 10 ms frames, with a threshold between room noise and speech.
struct Energy {
    let db: [Double]
    let hop: Double  // seconds per frame
    let threshold: Double

    init(samples: [Float], rate: Double, frame: Double = 0.01) {
        let n = max(1, Int(frame * rate))
        hop = Double(n) / rate
        db = stride(from: 0, to: samples.count - n + 1, by: n).map {
            10 * log10(Double(vDSP.meanSquare(samples[$0..<$0 + n])) + 1e-12)
        }
        let sorted = db.sorted()
        let noise = sorted.isEmpty ? -90 : sorted[sorted.count / 10]
        threshold = max(noise + 12, (sorted.last ?? 0) - 45)
        let speech = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        pauseThreshold = speech - 35
    }

    /// Quieter than this counts as a pause: breaths and room noise, well below any spoken syllable.
    let pauseThreshold: Double

    private func frame(_ t: Double) -> Int { max(0, min(db.count, Int(t / hop))) }

    func voicedSeconds(from a: Double, to b: Double) -> Double {
        let lo = frame(a), hi = frame(b)
        guard hi > lo else { return 0 }
        return Double(db[lo..<hi].filter { $0 >= threshold }.count) * hop
    }

    /// A word's loudness: the 90th percentile of its frames, in dB.
    func peakLevel(from a: Double, to b: Double) -> Double {
        let lo = frame(a), hi = max(frame(b), lo + 1)
        guard lo < db.count else { return -120 }
        let seg = db[lo..<min(hi, db.count)].sorted()
        return seg[min(seg.count - 1, Int(Double(seg.count) * 0.9))]
    }

    func voicedSeconds(in spans: [(Double, Double)]) -> Double {
        spans.reduce(0) { $0 + voicedSeconds(from: $1.0, to: $1.1) }
    }

    /// Stretches of quiet frames between `a` and `b` seconds, as (start, end) times.
    func quietRuns(from a: Double, to b: Double, below level: Double? = nil) -> [(Double, Double)] {
        var runs: [(Double, Double)] = []
        var start: Int?
        let lo = frame(a), hi = frame(b)
        let limit = level ?? threshold
        for i in lo..<max(lo, hi) {
            if db[i] < limit {
                if start == nil { start = i }
            } else if let s = start {
                runs.append((Double(s) * hop, Double(i) * hop))
                start = nil
            }
        }
        if let s = start { runs.append((Double(s) * hop, Double(hi) * hop)) }
        return runs
    }

    /// The quietest moment within 30 ms of the span between `a` and `b`: the natural seam between two sounds.
    func quietest(around a: Double, _ b: Double) -> Double {
        let lo = frame(a - 0.03), hi = min(db.count, max(frame(b + 0.03), lo + 1))
        guard lo < hi else { return (a + b) / 2 }
        var best = lo
        for i in lo..<hi where db[i] < db[best] { best = i }
        return (Double(best) + 0.5) * hop
    }

    /// The longest unbroken stretch of sound between `a` and `b`, in seconds.
    func longestSound(from a: Double, to b: Double) -> Double {
        var best = 0, run = 0
        for i in frame(a)..<max(frame(a), frame(b)) {
            run = db[i] >= threshold ? run + 1 : 0
            best = max(best, run)
        }
        return Double(best) * hop
    }

    /// Shrink a word's range to the sound inside it, keeping `margin` seconds for soft edges.
    func tighten(_ w: Word, margin: Double = 0.03) -> Word {
        let lo = frame(w.start), hi = frame(w.end)
        guard hi > lo, let first = (lo..<hi).first(where: { db[$0] >= threshold }),
              let last = (lo..<hi).last(where: { db[$0] >= threshold }) else { return w }
        return Word(text: w.text, start: max(w.start, Double(first) * hop - margin),
                    end: min(w.end, Double(last + 1) * hop + margin), confidence: w.confidence,
                    heardStart: w.heardStart, heardEnd: w.heardEnd)
    }

    /// Length of the quiet stretch that starts at `t`, looking forward or backward.
    func quietRun(from t: Double, forward: Bool) -> Double {
        var i = forward ? frame(t) : frame(t) - 1
        var count = 0
        while i >= 0 && i < db.count && db[i] < threshold {
            count += 1
            i += forward ? 1 : -1
        }
        return Double(count) * hop
    }

    /// Stretches of sound, merged across gaps shorter than `mergeGap` seconds.
    func voicedRuns(mergeGap: Double = 0.15) -> [Word] {
        var runs: [Word] = []
        var start: Int?
        for (i, value) in db.enumerated() {
            if value >= threshold, start == nil { start = i }
            if value < threshold || i == db.count - 1, let s = start {
                let run = Word(text: "", start: Double(s) * hop, end: Double(i) * hop)
                if let last = runs.last, run.start - last.end < mergeGap {
                    runs[runs.count - 1] = Word(text: "", start: last.start, end: run.end)
                } else {
                    runs.append(run)
                }
                start = nil
            }
        }
        return runs
    }
}
