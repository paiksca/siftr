import AudioToolbox
import AVFoundation

/// Apple's on-device voice isolation, the model behind the Voice Isolation mic mode, run over a finished recording.
enum Isolation {
    /// Writes a voice-isolated copy of `url` with the same timing, or returns nil if the effect fails.
    static func run(_ url: URL) -> URL? {
        do {
            let input = try AVAudioFile(forReading: url)
            let format = input.processingFormat
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let isolation = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            engine.attach(player)
            engine.attach(isolation)
            engine.connect(player, to: isolation, format: format)
            engine.connect(isolation, to: engine.mainMixerNode, format: format)

            let chunk: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
            set(isolation.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
                AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice))
            set(isolation.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), 100)
            try engine.start()
            player.scheduleFile(input, at: nil)
            player.play()

            // The model looks ahead, so its output lags. Render that much extra and drop it from the start.
            let lag = AVAudioFramePosition(isolation.auAudioUnit.latency * format.sampleRate)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-\(UUID().uuidString).wav")
            let output = try AVAudioFile(forWriting: out, settings: input.fileFormat.settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)
            else { return nil }
            var toSkip = lag
            while engine.manualRenderingSampleTime < input.length + lag {
                let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunk),
                                                   input.length + lag - engine.manualRenderingSampleTime))
                guard try engine.renderOffline(frames, to: buffer) == .success else { break }
                let skip = min(toSkip, AVAudioFramePosition(buffer.frameLength))
                toSkip -= skip
                try output.write(from: skip == 0 ? buffer : buffer.dropping(Int(skip)))
            }
            player.stop()
            engine.stop()
            diag(String(format: "voice isolation done, lag %.0f ms", isolation.auAudioUnit.latency * 1000))
            return out
        } catch {
            diag("voice isolation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func set(_ unit: AudioUnit, _ parameter: AudioUnitParameterID, _ value: AudioUnitParameterValue) {
        let status = AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0)
        if status != noErr { diag("voice isolation parameter \(parameter) failed: \(status)") }
    }
}

private extension AVAudioPCMBuffer {
    /// A copy without the first `count` frames.
    func dropping(_ count: Int) -> AVAudioPCMBuffer {
        let remaining = Int(frameLength) - count
        let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(remaining, 1)))!
        copy.frameLength = AVAudioFrameCount(max(remaining, 0))
        if remaining > 0, let src = floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<Int(format.channelCount) { dst[c].update(from: src[c] + count, count: remaining) }
        }
        return copy
    }
}
