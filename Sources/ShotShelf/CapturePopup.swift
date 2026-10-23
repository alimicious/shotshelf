import SwiftUI

private let terracotta = Color(nsColor: ShelfIcon.terracotta)

/// The pop-up under the menu bar icon after a capture, while the shelf is closed: the shot, big
/// enough to check, and what you most often do next. It leaves after about six seconds, but not
/// while the pointer is over it. Drag the shot straight into any app, or click it for the shelf.
struct CapturePopupView: View {
    @ObservedObject var store: ShelfStore

    static let previewSize = CGSize(width: 276, height: 156)

    var body: some View {
        VStack(spacing: 10) {
            if let shot = store.popup {
                preview(shot)
                actions(shot)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onHover { store.popupHovered = $0 }
        .overlay(alignment: .top) {
            if let toast = store.toast { ToastCapsule(toast: toast, store: store).padding(.top, 4) }
        }
        .animation(.spring(duration: 0.28, bounce: 0.25), value: store.toast)
    }

    private func preview(_ shot: Shot) -> some View {
        let size = Self.previewSize
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.quinary)
            if let image = store.popupImage {
                // The whole shot over a blurred copy of itself, like the shelf's big tile.
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).blur(radius: 20).opacity(0.6).clipped()
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)) }
        .overlay(alignment: .topLeading) {
            if shot.isVideo { RecordingBadge(duration: store.durations[shot.url]).padding(8) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            store.dismissPopup()
            store.togglePanel?()
        }
        .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
        .help("Drag into any app, or click to open the shelf")
    }

    private func actions(_ shot: Shot) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                PopupButton(systemName: "doc.on.doc", help: "Copy") { store.copy(shot) }
                if shot.isVideo {
                    PopupButton(systemName: "photo.stack", help: "Trim or make a GIF") { store.editRecording(shot) }
                } else {
                    PopupButton(systemName: "text.viewfinder", help: "Copy text") { store.copyText(shot) }
                    PopupButton(systemName: "pencil.tip.crop.circle", help: "Mark up") { store.markup(shot) }
                    PopupButton(systemName: "pip.enter", help: "Float on screen") { store.float(shot) }
                }
                PopupButton(systemName: "trash", help: "Move to the Trash") { store.trash(shot) }
            }
        }
    }
}

private struct PopupButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 13, weight: .medium)).frame(width: 18, height: 18)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle)
        .help(help)
    }
}

/// A toast: what just happened, with Undo after a Trash. On its own glass capsule inside the shelf
/// and the pop-up; without one in the notice window, which is glass itself.
struct ToastCapsule: View {
    let toast: Toast
    @ObservedObject var store: ShelfStore
    var glass = true

    var body: some View {
        HStack(spacing: 10) {
            Label(toast.text, systemImage: toast.symbol).lineLimit(1)
            if toast.undo {
                Button("Undo") { store.undoTrash() }
                    .buttonStyle(.borderless).foregroundStyle(terracotta)
                    .help("Put it back (⌘Z)")
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .modifier(CapsuleGlass(on: glass, interactive: toast.undo))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct CapsuleGlass: ViewModifier {
    let on: Bool
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if on {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            content
        }
    }
}
