import SwiftUI

/// Reads one saved passage: a Board item, a notebook page or a canvas card.
struct SnippetReaderView: View {
    let title: String
    let text: String
    var source: String = ""
    @StateObject private var speaker = TextSpeaker()

    var body: some View {
        VStack(spacing: 0) {
            HighlightTextView(text: text, ranges: speaker.ranges, currentIndex: speaker.wordIndex, readingPen: false,
                              onTapWord: { speaker.seek(toWord: $0) })
                .background(Koe.paper)
                .overlay(alignment: .top) {
                    if speaker.preparing {
                        HStack(spacing: 8) { ProgressView().tint(Koe.shu); Text("Preparing…").font(.footnote) }
                            .padding(.horizontal, 14).padding(.vertical, 8).background(Koe.paper2, in: Capsule()).padding(.top, 10)
                    } else if let error = speaker.error {
                        Text(error).font(.footnote).foregroundStyle(Koe.shu).padding(10).background(Koe.paper2, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                    }
                }
            VStack(spacing: 6) {
                if !source.isEmpty {
                    Text(source).font(.footnote).foregroundStyle(Koe.faint).lineLimit(1)
                }
                HStack(spacing: 18) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                            Button { speaker.rate = Float(r) } label: {
                                if abs(Double(speaker.rate) - r) < 0.01 { Label(String(format: "%g×", r), systemImage: "checkmark") } else { Text(String(format: "%g×", r)) }
                            }
                        }
                    } label: {
                        Text(String(format: "%g×", speaker.rate)).font(.system(.subheadline, design: .monospaced).weight(.medium))
                            .frame(width: 54, height: 34).background(Koe.paper2, in: Capsule())
                    }
                    .tint(Koe.ink)
                    Menu {
                        Button { speaker.useKokoro = true; if speaker.isPlaying { speaker.play(from: speaker.wordIndex) } } label: {
                            if speaker.useKokoro { Label("Kokoro · \(KokoroSettings.voiceName(KokoroSettings.voice))", systemImage: "checkmark") } else { Text("Kokoro · \(KokoroSettings.voiceName(KokoroSettings.voice))") }
                        }
                        Button { speaker.useKokoro = false; if speaker.isPlaying { speaker.play(from: speaker.wordIndex) } } label: {
                            if !speaker.useKokoro { Label("System voice", systemImage: "checkmark") } else { Text("System voice") }
                        }
                    } label: {
                        Label(speaker.useKokoro ? "Kokoro" : "System", systemImage: "waveform")
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 34).background(Koe.paper2, in: Capsule())
                    }
                    .tint(Koe.ink)
                    Spacer()
                    Button { speaker.seek(toWord: speaker.wordIndex - 20) } label: { Image(systemName: "arrow.uturn.backward").font(.title2) }
                    Button { speaker.toggle() } label: {
                        Image(systemName: speaker.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 54))
                    }
                    Button { speaker.seek(toWord: speaker.wordIndex + 20) } label: { Image(systemName: "arrow.uturn.forward").font(.title2) }
                    Spacer()
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Koe.paper2)
            .overlay(alignment: .top) { Rectangle().fill(Koe.line).frame(height: 1) }
        }
        .background(Koe.readerBg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(PencilGestures { speaker.toggle() })
        .onAppear { speaker.load(text) }
        .onDisappear { speaker.stop() }
    }
}
