import SwiftUI

private let terracotta = Color(nsColor: ShelfIcon.terracotta)
private let miniSize = CGSize(width: 100, height: 64)

/// Every screenshot in the folder, searchable by name and by the text inside it.
struct AllShotsView: View {
    @ObservedObject var store: ShelfStore

    var body: some View {
        let results = store.searchResults
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text in screenshots", text: $store.query)
                    .textFieldStyle(.plain)
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(miniSize.width), spacing: 8), count: 3), spacing: 10) {
                    ForEach(results) { MiniCell(shot: $0, store: store) }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 380)
            .overlay {
                if results.isEmpty {
                    Text(store.query.isEmpty ? "No screenshots yet" : "Nothing matches “\(store.query)”")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Text(status).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 352)
    }

    private var status: String {
        let count = store.query.isEmpty ? "\(store.shots.count) screenshots" : "\(store.searchResults.count) of \(store.shots.count)"
        return store.indexing > 0 ? "\(count) · reading text in \(store.indexing) more…" : count
    }
}

private struct MiniCell: View {
    let shot: Shot
    @ObservedObject var store: ShelfStore

    private var isHovered: Bool { store.hovered == shot.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quinary)
                if let image = store.minis[shot.url] {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: miniSize.width, height: miniSize.height).clipped()
                }
            }
            .frame(width: miniSize.width, height: miniSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovered ? AnyShapeStyle(terracotta) : AnyShapeStyle(.white.opacity(0.12)), lineWidth: isHovered ? 1.5 : 1)
            }
            .overlay(alignment: .topLeading) {
                if store.isPinned(shot) {
                    Image(systemName: "pin.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .glassEffect(.regular.tint(terracotta), in: .circle)
                        .padding(4)
                }
            }
            .shadow(color: .black.opacity(isHovered ? 0.25 : 0.08), radius: isHovered ? 6 : 2, y: isHovered ? 3 : 1)

            Text(shot.url.deletingPathExtension().lastPathComponent)
                .font(.caption2).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: miniSize.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onAppear { store.requestMini(shot.url) }
        .onHover { inside in
            if inside { store.hovered = shot.url } else if isHovered { store.hovered = nil }
        }
        .onTapGesture(count: 2) { store.open(shot) }
        .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
        .contextMenu { ShotMenu(shot: shot, store: store) }
        .help("\(shot.date.formatted(date: .abbreviated, time: .shortened)) · double-click to open, right-click for more")
    }
}
