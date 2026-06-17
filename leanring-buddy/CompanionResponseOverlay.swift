//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  A small floating bubble that shows Big Bot's reply as text (used when
//  spoken replies are turned off). It appears near the cursor, sizes itself
//  to the text once, then fades out.
//
//  IMPORTANT: this uses fixed widths and sizes itself exactly once per reply.
//  An earlier version used `.fixedSize` plus a per-frame resize timer, which
//  fed a SwiftUI layout-recursion loop that wedged the main thread. Keep the
//  layout unambiguous (fixed widths, no `.fixedSize`, no continuous resizing).
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isShowingResponse: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionResponseOverlayManager {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var hostingView: NSHostingView<CompanionResponseOverlayView>?
    private var autoHideWorkItem: DispatchWorkItem?

    /// Fixed panel/content width. The bubble never changes width — only its
    /// height adapts to the text — so layout can't oscillate.
    private let panelWidth: CGFloat = 320
    private let cursorOffsetX: CGFloat = 22
    private let cursorOffsetY: CGFloat = 6

    func showOverlayAndBeginStreaming() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil

        overlayViewModel.streamingResponseText = ""
        overlayViewModel.isShowingResponse = true
        createPanelIfNeeded()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
    }

    func updateStreamingText(_ accumulatedText: String) {
        overlayViewModel.streamingResponseText = accumulatedText
        sizeAndPositionOnce()
    }

    func finishStreaming() {
        // Keep the reply visible briefly so it can be read, then fade out.
        let hideWork = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        autoHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: hideWork)
    }

    func hideOverlay() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        overlayViewModel.isShowingResponse = false
        overlayViewModel.streamingResponseText = ""
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func createPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: 60)
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let host = NSHostingView(rootView: CompanionResponseOverlayView(viewModel: overlayViewModel))
        host.autoresizingMask = []
        host.frame = initialFrame
        panel.contentView = host

        self.hostingView = host
        self.overlayPanel = panel
    }

    /// Measures the text height at the fixed width, sizes the panel to it, and
    /// positions it near the cursor. Called once per reply — never on a timer —
    /// so there is no resize feedback loop.
    private func sizeAndPositionOnce() {
        guard let overlayPanel, let hostingView else { return }

        // Height the content wants at the fixed width.
        let fittingHeight = hostingView.fittingSize.height
        let panelHeight = max(40, fittingHeight)

        let mouseLocation = NSEvent.mouseLocation
        var originX = mouseLocation.x + cursorOffsetX
        var originY = mouseLocation.y - cursorOffsetY - panelHeight

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            let visibleFrame = screen.visibleFrame
            if originX + panelWidth > visibleFrame.maxX {
                originX = mouseLocation.x - cursorOffsetX - panelWidth
            }
            if originY < visibleFrame.minY {
                originY = mouseLocation.y + cursorOffsetY
            }
            originX = max(visibleFrame.minX, min(originX, visibleFrame.maxX - panelWidth))
            originY = max(visibleFrame.minY, min(originY, visibleFrame.maxY - panelHeight))
        }

        overlayPanel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            display: true
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
    }

    private func fadeOutAndHide() {
        guard let overlayPanel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            overlayPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.hideOverlay()
            }
        })
    }
}

// MARK: - SwiftUI View

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel

    var body: some View {
        if viewModel.isShowingResponse {
            Text(viewModel.streamingResponseText.isEmpty ? "…" : viewModel.streamingResponseText)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                // Fixed text width (no `.fixedSize`) so the layout can't oscillate.
                .frame(width: 292, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
                        )
                )
                .frame(width: 320, alignment: .leading)
        }
    }
}
