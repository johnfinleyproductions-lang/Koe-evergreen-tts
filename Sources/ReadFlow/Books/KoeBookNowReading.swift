import SwiftUI

@MainActor
struct KoeBookNowReading: View {
    @ObservedObject private var store = KoeBookStore.shared
    @ObservedObject private var player = KoeBookStore.shared.player
    let palette: KoePalette
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("NOW READING").font(KoeFont.gothic(9.5, .medium)).tracking(2).foregroundStyle(palette.mute)
            Text(store.selectedBook?.title ?? "Choose a book").font(KoeFont.mincho(13)).foregroundStyle(palette.ink).lineLimit(2)
            Text(store.selectedBook == nil ? "Original pages and narration" : player.chapter?.title ?? "Choose a chapter").font(KoeFont.gothic(11)).foregroundStyle(palette.mute).lineLimit(2)
            if store.selectedBook != nil {
                Text(player.preparing ? "Preparing Kokoro…" : player.isPlaying ? "Playing \(player.voiceDetail)" : "Your place is saved").font(KoeFont.mono(10)).foregroundStyle(palette.shu)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.s1))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.line, lineWidth: 1))
    }
}
