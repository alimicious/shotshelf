import SwiftUI

private let terracotta = Color(nsColor: ShelfIcon.terracotta)
private let miniSize = CGSize(width: 100, height: 64)

/// Every screenshot in the folder, searchable by name and by the text inside it, in its own panel
/// beside the shelf. Shots can be dragged from here onto the shelf's tiles to put them there, and
/// the arrow keys, Space and the other shelf keys work on the selected one.
struct AllShotsView: View {
    @ObservedObject var store: ShelfStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = store.searchResults
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text in screenshots", text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(miniSize.width), spacing: 8), count: 3), spacing: 10) {
                        ForEach(results) { MiniCell(shot: $0, results: results, store: store) }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, minHeight: 372, alignment: .top)
                    // Clicking empty space also takes the keys from the search field.
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { store.searchFocused = false } }
                }
                .onChange(of: store.searchSelection) { _, selected in
                    // Keep the keyboard selection in view.
                    if let selected { withAnimation(.snappy) { proxy.scrollTo(selected) } }
                }
            }
            .frame(height: 380)
            .overlay {
                if results.isEmpty {
                    Text(store.query.isEmpty ? "No screenshots yet" : "Nothing matches “\(store.query)”")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(status)
                Spacer()
                Text("↑↓←→ move · Space previews · Esc closes")
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(width: 352)
        // The store decides where typing goes (the keys move it between field and results);
        // this keeps the field's real focus in step both ways.
        .onAppear { searchFocused = store.searchFocused }
        .onChange(of: store.searchFocused) { _, focused in searchFocused = focused }
        .onChange(of: searchFocused) { _, focused in if store.searchFocused != focused { store.searchFocused = focused } }
    }

    private var status: String {
        if !store.selection.isEmpty { return "\(store.selection.count) selected · ⌘-click or ⇧-click to change" }
        let count = store.query.isEmpty ? "\(store.shots.count) screenshots" : "\(store.searchResults.count) of \(store.shots.count)"
        return store.indexing > 0 ? "\(count) · reading text in \(store.indexing) more…" : count
    }
}

private struct MiniCell: View {
    let shot: Shot
    /// What's showing in the grid, so Quick Look's arrow keys step through the search results.
    let results: [Shot]
    @ObservedObject var store: ShelfStore
    @AppStorage(Prefs.searchEyes) private var showEye = true

    /// Selected by the arrow keys or the pointer; the two share one selection.
    private var isHovered: Bool { store.searchSelection == shot.url }
    /// Picked with ⌘-click or ⇧-click, along with others (the shelf shares these).
    private var isSelected: Bool { store.selection.contains(shot.url) }

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
                    .fill(terracotta.opacity(isSelected ? 0.14 : 0))
                    .strokeBorder(isHovered || isSelected ? AnyShapeStyle(terracotta) : AnyShapeStyle(.white.opacity(0.12)),
                                  lineWidth: isSelected ? 2.5 : isHovered ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    if isSelected {
                        Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .glassEffect(.regular.tint(terracotta), in: .circle)
                    }
                    if store.isPinned(shot) {
                        Image(systemName: "pin.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .glassEffect(.regular.tint(terracotta), in: .circle)
                    }
                }
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                // Can be turned off in Settings; Space still previews.
                if showEye {
                    Button { store.quickLook(shot, among: results, follow: { store.searchSelection = $0 }) } label: {
                        Image(systemName: "eye").font(.system(size: 9, weight: .semibold))
                            .frame(width: 20, height: 20).contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .scaleEffect(isHovered ? 1.1 : 1)
                    .padding(4)
                    .help("View bigger (Quick Look)")
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
            if inside { store.searchSelection = shot.url }
        }
        .onTapGesture(count: 2) { store.open(shot) }
        // A click selects the shot and takes the keys from the search field, so the arrows and
        // Space work straight away. ⌘- and ⇧-clicks pick several.
        .simultaneousGesture(TapGesture().onEnded {
            store.searchSelection = shot.url
            store.searchFocused = false
            store.click(shot, in: results)
        })
        .onDrag {
            // Lets the panel's tiles take the drop and put this shot in their spot.
            store.dragging = shot.url
            return NSItemProvider(contentsOf: shot.url) ?? NSItemProvider()
        }
        .contextMenu { ShotMenu(shot: shot, store: store, results: results) }
        .help("\(shot.date.formatted(date: .abbreviated, time: .shortened)) · drag onto a tile to put it on the shelf, double-click to open")
    }
}
