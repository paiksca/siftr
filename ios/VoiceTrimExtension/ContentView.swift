import SwiftUI
import UIKit

/// Warm sand behind everything, with ember and apricot orange for what you touch.
private enum Palette {
    static let sand = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.12, green: 0.10, blue: 0.08, alpha: 1)
        : UIColor(red: 0.96, green: 0.92, blue: 0.86, alpha: 1) })
    static let ember = Color(red: 0.85, green: 0.35, blue: 0.12)  // dark orange
    static let apricot = Color(red: 1.00, green: 0.70, blue: 0.40)  // light orange
}

struct ContentView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        ZStack {
            Palette.sand.ignoresSafeArea()
            Glow(level: model.level)

            VStack(spacing: 20) {
                switch model.phase {
                case .ready:
                    if let result = model.result { ResultView(model: model, result: result) }
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try again") { model.reset() }.buttonStyle(.plain).foregroundStyle(Palette.ember)
                default:
                    MicButton(model: model)
                    RecordingClock(start: model.phase == .recording ? model.started : nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
        }
        .overlay(alignment: .topLeading) {
            if model.phase == .ready {
                // Out of the way of the playback controls, so it reads as "start over", not "replay".
                Button { model.reset() } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Discard and record again")
            }
        }
        .tint(Palette.ember)
        .animation(.smooth(duration: 0.35), value: model.phase)
    }
}

/// Elapsed time under the record button while recording. It keeps its space when hidden, so nothing jumps.
private struct RecordingClock: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: start ?? .now, by: 0.5)) { context in
            Text(start.map { clock(context.date.timeIntervalSince($0)) } ?? "0:00")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(start == nil ? 0 : 1)
        }
        .accessibilityHidden(start == nil)
    }

    private func clock(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// A soft apricot light behind the controls, for the glass to refract. It swells with your voice.
private struct Glow: View {
    let level: Double

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Palette.apricot.opacity(0.55), Palette.ember.opacity(0.2), .clear],
                                 center: .center, startRadius: 0, endRadius: 130))
            .frame(width: 260, height: 260)
            .scaleEffect(1 + level * 0.5)
            .blur(radius: 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: level)
            .allowsHitTesting(false)
    }
}

private struct MicButton: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        Button(action: model.toggleRecording) {
            ZStack {
                if model.phase == .processing {
                    Image(systemName: "waveform")  // sifting
                        .font(.system(size: 30, weight: .medium))
                        .symbolEffect(.variableColor.iterative.reversing)
                } else {
                    Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 84, height: 84)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(model.phase == .processing)
        .background {
            Circle()
                .stroke(Palette.apricot, lineWidth: 1.5)
                .scaleEffect(1.08 + model.level * 0.35)
                .opacity(model.phase == .recording ? 0.9 : 0)
                .animation(.easeOut(duration: 0.12), value: model.level)
        }
        .accessibilityLabel(model.phase == .recording ? "Stop recording" : "Record")
    }
}

private struct ResultView: View {
    @ObservedObject var model: RecorderModel
    let result: TrimResult

    var body: some View {
        VStack(spacing: 22) {
            Text(String(format: "−%.1f s", max(0, result.before - result.after)))
                .font(.system(size: 40, weight: .light, design: .rounded))
                .accessibilityLabel(String(format: "%.1f seconds shorter", result.before - result.after))

            ChoiceSlider(choice: model.choice) { clip in
                withAnimation(.smooth(duration: 0.3)) { model.select(clip) }
            }

            HStack(spacing: 20) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.playing == nil ? "play.fill" : "stop.fill")
                        .font(.title3)
                        .foregroundStyle(Palette.ember)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.playing == nil ? "Play" : "Stop")
                Button { model.send() } label: {
                    Label("Send", systemImage: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 112, height: 44)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }
}

/// Sifted or Original. Sifted is chosen to start with. Tap a side or slide the ember thumb across.
private struct ChoiceSlider: View {
    let choice: RecorderModel.Clip
    let select: (RecorderModel.Clip) -> Void
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            segment("Sifted", .cleaned)
            segment("Original", .original)
        }
        .gesture(DragGesture(minimumDistance: 8).onEnded { drag in
            if abs(drag.translation.width) > 20 { select(drag.translation.width > 0 ? .original : .cleaned) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Version")
        .accessibilityValue(choice == .cleaned ? "Sifted" : "Original")
        .accessibilityAdjustableAction { _ in select(choice == .cleaned ? .original : .cleaned) }
    }

    private func segment(_ title: String, _ clip: RecorderModel.Clip) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(choice == clip ? Color.white : Color.secondary)
            .frame(width: 104, height: 36)
            .background {
                if choice == clip {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.apricot, Palette.ember],
                                             startPoint: .top, endPoint: .bottom))
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Capsule())
            .onTapGesture { select(clip) }
    }
}
