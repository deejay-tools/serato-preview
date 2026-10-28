import AppKit
import Combine
import SwiftUI

/// Pannello flottante che non prende mai il focus: la tastiera resta a Serato.
@MainActor
final class MiniPlayerPanel {
    private let panel: NSPanel
    private var cancellable: AnyCancellable?

    init(controller: PreviewController) {
        let size = NSSize(width: MiniPlayerView.width, height: MiniPlayerView.height)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstMouseHostingView(rootView: MiniPlayerView(controller: controller))

        // Posizione ricordata tra un avvio e l'altro; la prima volta in alto a destra.
        if !panel.setFrameUsingName("MiniPlayer"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
        }
        panel.setFrameAutosaveName("MiniPlayer")

        cancellable = controller.$status.sink { [weak self] status in
            self?.update(status)
        }
    }

    private func update(_ status: PreviewController.Status) {
        if status == .idle {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }
}

/// I pulsanti rispondono al primo clic anche se il pannello non è la finestra attiva.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MiniPlayerView: View {
    static let width: CGFloat = 340
    static let height: CGFloat = 104

    @ObservedObject var controller: PreviewController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isPlaying {
                    Button {
                        controller.stopPreview()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Ferma (Esc)")
                }
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if isPlaying {
                ProgressView(value: min(controller.position, controller.duration), total: max(controller.duration, 0.1))
                    .progressViewStyle(.linear)
                HStack {
                    Text(Self.format(controller.position))
                    Spacer()
                    Text("\(controller.settings.modifier.symbol)+rotella sposta · Esc ferma")
                    Spacer()
                    Text("-" + Self.format(controller.duration - controller.position))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if controller.status == .identifying {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var isPlaying: Bool {
        if case .playing = controller.status { return true }
        return false
    }

    private var title: String {
        switch controller.status {
        case .idle: return ""
        case .identifying: return "Riconosco la traccia…"
        case .playing(let title, _), .message(let title, _, _): return title
        }
    }

    private var subtitle: String {
        switch controller.status {
        case .idle, .identifying: return ""
        case .playing(_, let subtitle), .message(_, let subtitle, _): return subtitle
        }
    }

    private var symbol: String {
        switch controller.status {
        case .idle, .identifying: return "text.viewfinder"
        case .playing: return "headphones"
        case .message(_, _, let symbol): return symbol
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
