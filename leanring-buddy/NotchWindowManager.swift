//
//  NotchWindowManager.swift
//  leanring-buddy
//
//  Makes Big Bot "live" in the MacBook's camera notch. Creates a borderless
//  panel pinned over the notch region of the built-in display, showing Big
//  Bot's smiley. The face subtly reacts to voice state (breathes with your
//  voice while listening), and clicking it opens Big Bot's menu panel.
//
//  Only shown on displays that actually have a notch (safe-area inset at top).
//  On Macs/displays without a notch, this does nothing and the menu bar icon
//  remains the home.
//

import AppKit
import SwiftUI

@MainActor
final class NotchWindowManager {
    private var notchPanel: NSPanel?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Shows Big Bot in the notch if the built-in display has one.
    func showInNotchIfAvailable() {
        guard let notchScreen = Self.screenWithNotch() else {
            print("🟦 Notch: no notched display found — staying in the menu bar only")
            return
        }
        let notchFrame = Self.notchFrame(for: notchScreen)
        createNotchPanel(frame: notchFrame)
        print("🙂 Big Bot is living in the notch at \(notchFrame)")
    }

    func hide() {
        notchPanel?.orderOut(nil)
        notchPanel = nil
    }

    // MARK: - Notch geometry

    /// The first screen that has a camera notch (non-zero top safe-area inset).
    private static func screenWithNotch() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// The rectangle (in global AppKit coordinates) covering the notch itself —
    /// the black gap at top-center between the two menu bar halves.
    private static func notchFrame(for screen: NSScreen) -> NSRect {
        let fullFrame = screen.frame
        let notchHeight = screen.safeAreaInsets.top

        // Width of the notch = the gap between the usable menu bar areas on
        // either side. Fall back to a sensible default if unavailable.
        var notchWidth: CGFloat = 220
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let gap = rightArea.minX - leftArea.maxX
            if gap > 40 { notchWidth = gap }
        }

        let originX = fullFrame.midX - (notchWidth / 2)
        // AppKit y grows upward; the notch sits at the very top of the screen.
        let originY = fullFrame.maxY - notchHeight

        return NSRect(x: originX, y: originY, width: notchWidth, height: notchHeight)
    }

    // MARK: - Panel

    private func createNotchPanel(frame: NSRect) {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = false
        // Sit just above the menu bar so the face shows inside the black notch.
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        panel.level = NSWindow.Level(rawValue: mainMenuLevel + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostingView = NSHostingView(
            rootView: NotchBigBotView(companionManager: companionManager)
        )
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        notchPanel = panel
    }
}

// MARK: - SwiftUI content

/// Big Bot's face as shown in the notch. Reacts to voice state and (while
/// listening) gently breathes with the user's voice. Click opens the menu.
private struct NotchBigBotView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        ZStack {
            // The notch is already black; this transparent layer just makes the
            // whole notch area clickable.
            Color.white.opacity(0.001)

            BigBotSmileyView(faceColor: faceColor)
                .frame(width: 20, height: 20)
                .scaleEffect(breathingScale)
                .animation(.easeOut(duration: 0.12), value: companionManager.currentAudioPowerLevel)
                .animation(.easeInOut(duration: 0.25), value: companionManager.voiceState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            NotificationCenter.default.post(name: .clickyTogglePanel, object: nil)
        }
    }

    /// Face color reflects what Big Bot is doing.
    private var faceColor: Color {
        switch companionManager.voiceState {
        case .idle, .responding:
            return .white
        case .listening, .processing:
            return DS.Colors.accent
        }
    }

    /// While listening, the face gently grows with the user's voice level.
    private var breathingScale: CGFloat {
        guard companionManager.voiceState == .listening else { return 1.0 }
        return 1.0 + min(max(companionManager.currentAudioPowerLevel, 0), 1) * 0.22
    }
}
