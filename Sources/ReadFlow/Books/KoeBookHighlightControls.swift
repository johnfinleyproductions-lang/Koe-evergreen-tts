import SwiftUI

@MainActor
struct KoeBookHighlightControls: View {
    @ObservedObject var highlights: KoeBookHighlights
    var onPage: (Int) -> Void
    @State private var showingMarks = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Picker("Color", selection: $highlights.color) {
                    ForEach(KoeHighlightColor.allCases) { color in Text(color.label).tag(color) }
                }.frame(width: 140).accessibilityLabel("Book highlight color")
                Button("Highlight text") { highlights.highlightSelection() }
                    .disabled(highlights.selection.isEmpty || highlights.areaMode)
                    .help("Select text on the page, then highlight it.")
                Toggle("Mark area", isOn: $highlights.areaMode).toggleStyle(.button)
                    .help("Drag over a passage or picture to highlight it, including scanned pages.")
                Spacer()
                Button("Highlights (\(highlights.marks.count))") { showingMarks.toggle() }
                    .popover(isPresented: $showingMarks) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Book highlights").font(.headline)
                            if highlights.marks.isEmpty {
                                Text("Select text and choose Highlight text, or use Mark area and drag over the page.").foregroundStyle(.secondary)
                            } else {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(highlights.marks.sorted { $0.page == $1.page ? $0.createdAt < $1.createdAt : $0.page < $1.page }) { mark in
                                            HStack(alignment: .top) {
                                                Circle().fill(Color(nsColor: mark.color.bookColor)).frame(width: 10, height: 10).padding(.top, 5)
                                                Button { onPage(mark.page); showingMarks = false } label: {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("Page \(mark.page)").font(.headline)
                                                        Text(mark.text.isEmpty ? "Highlighted area" : mark.text).lineLimit(4).foregroundStyle(.secondary)
                                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                                }.buttonStyle(.plain).help("Go to highlighted page")
                                                Button { highlights.remove(mark.id) } label: { Image(systemName: "trash") }
                                                    .help("Remove highlight").accessibilityLabel("Remove highlight on page \(mark.page)")
                                            }
                                            Divider()
                                        }
                                    }
                                }.frame(maxHeight: 360)
                            }
                        }.padding(18).frame(width: 340)
                    }
            }
            Text(highlights.areaMode ? "Drag over the page to highlight an area. Turn off Mark area to select text." : "Select text on the page, then choose Highlight text. Use Mark area for scanned pages.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = highlights.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 10).padding(.bottom, 8)
    }
}
