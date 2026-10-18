// Runs Sift's isolation, transcription and trimming on a Mac, to check them without a phone.
// Build: see scripts/harness.sh. Usage: harness <input audio> <output dir>
import Foundation

let env = ProcessInfo.processInfo.environment

func diag(_ message: String) { print("diag:", message) }

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let isolated = Isolation.run(input) ?? input
try? FileManager.default.removeItem(at: outDir.appendingPathComponent("isolated.wav"))
try FileManager.default.copyItem(at: isolated, to: outDir.appendingPathComponent("isolated.wav"))

let transcription = await Transcription.transcribe(isolated)
if let models = env["SIFT_MODELS"] {
    Aligner.modelURL = URL(fileURLWithPath: models).appendingPathComponent("Aligner.mlmodelc")
    Aligner.vocabURL = URL(fileURLWithPath: models).appendingPathComponent("aligner_vocab.json")
}
let words = env["SIFT_MODELS"] == nil ? transcription?.words ?? []
    : Aligner.retime(transcription?.words ?? [], audio: isolated) ?? transcription?.words ?? []
print("transcript:", transcription?.text ?? "(none)")
print("confidence:", (transcription?.words ?? []).map { "\($0.text) \($0.confidence.map { String(format: "%.2f", $0) } ?? "-")" }.joined(separator: ", "))
let wordRows = (transcription?.words ?? []).map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
try JSONSerialization.data(withJSONObject: ["text": transcription?.text ?? "", "words": wordRows])
    .write(to: outDir.appendingPathComponent("words.json"))
let alignedRows = words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
try JSONSerialization.data(withJSONObject: alignedRows).write(to: outDir.appendingPathComponent("aligned.json"))
let result = try Trimmer.trim(recording: isolated, words: words, transcript: transcription?.text ?? "")
let sifted = outDir.appendingPathComponent("sifted.m4a")
try? FileManager.default.removeItem(at: sifted)
try FileManager.default.copyItem(at: result.audio, to: sifted)
print(String(format: "%.1f s -> %.1f s, removed %@, %d pauses", result.before, result.after,
             result.removed.description, result.pausesShortened))
print("sifted transcript:", result.transcript)
if let caf = try Trimmer.exportVoiceMessage(result.audio) {
    let size = (try FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int) ?? 0
    print("voice message: \(caf.lastPathComponent.prefix(13))... \(size / 1024) KB")
} else {
    print("voice message: sample rate not supported by Opus, would send .m4a")
}
