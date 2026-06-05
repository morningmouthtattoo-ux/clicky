//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Claude client that talks to api.anthropic.com directly using the key
    /// stored in the macOS Keychain. Nil until the user has entered a key.
    private var claudeAPI: ClaudeAPI?

    /// Free, on-device text-to-speech (Apple voices). Replaces ElevenLabs.
    private let appleSpeechTTSClient = AppleSpeechTTSClient()

    /// Direct bridge to the running Blender's MCP socket (localhost:9876).
    private let blenderBridge = BlenderBridge()

    /// Cursor-following bubble used to always show Clicky's reply as text,
    /// regardless of whether spoken replies are turned on.
    private let responseOverlayManager = CompanionResponseOverlayManager()

    /// Whether replies are also spoken aloud (text is always shown either way).
    /// User-toggleable; persisted across launches. Defaults to on.
    @Published var speakRepliesAloud: Bool = UserDefaults.standard.object(forKey: "speakRepliesAloud") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "speakRepliesAloud")

    func setSpeakRepliesAloud(_ enabled: Bool) {
        speakRepliesAloud = enabled
        UserDefaults.standard.set(enabled, forKey: "speakRepliesAloud")
    }

    /// Whether an Anthropic API key is currently stored in the Keychain.
    @Published private(set) var hasAnthropicAPIKey: Bool = KeychainStore.hasAnthropicAPIKey

    /// When Claude proposes a destructive Blender change (delete / clear /
    /// overwrite), we hold the exact Python here and ask the user to confirm
    /// out loud before running it on their next push-to-talk.
    private var pendingDestructiveBlenderCode: String?

    /// Rebuilds the Claude client from the currently stored key (or clears it).
    private func rebuildClaudeAPIFromStoredKey() {
        if let storedKey = KeychainStore.anthropicAPIKey,
           !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            claudeAPI = ClaudeAPI(apiKey: storedKey, model: selectedModel)
        } else {
            claudeAPI = nil
        }
        hasAnthropicAPIKey = KeychainStore.hasAnthropicAPIKey
    }

    /// Saves a new Anthropic key to the Keychain and rebuilds the Claude client.
    func saveAnthropicAPIKey(_ key: String) {
        KeychainStore.saveAnthropicAPIKey(key)
        rebuildClaudeAPIFromStoredKey()
    }

    /// Shows a simple dialog where the user can paste their Anthropic API key.
    /// Used on first launch (when no key is stored) and from the menu later.
    func promptForAnthropicAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Paste your Claude (Anthropic) API key"
        alert.informativeText = "Clicky stores it securely in your Mac's Keychain and talks to Claude directly. You can get a key at console.anthropic.com."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let keyInputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        keyInputField.placeholderString = "sk-ant-..."
        if let existingKey = KeychainStore.anthropicAPIKey {
            keyInputField.stringValue = existingKey
        }
        alert.accessoryView = keyInputField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let enteredKey = keyInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !enteredKey.isEmpty {
                saveAnthropicAPIKey(enteredKey)
            }
        }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI?.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        // This is a personal build — skip the original author's onboarding flow
        // and mailing-list email capture so Clicky is usable immediately.
        hasCompletedOnboarding = true
        if !hasSubmittedEmail {
            hasSubmittedEmail = true
            UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
        }

        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Build the Claude client from the stored key (and warm its TLS).
        rebuildClaudeAPIFromStoredKey()

        // First launch with no key: ask the user to paste one so Clicky can
        // actually talk to Claude. Deferred so it doesn't block startup.
        if !hasAnthropicAPIKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.promptForAnthropicAPIKey()
            }
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            appleSpeechTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're big bot, a minimal, functional studio partner that helps the user work in blender. the user just spoke to you via push-to-talk, and you can see screenshots of their screen including the blender viewport. your reply may be spoken aloud, so write the way you'd actually talk. this is an ongoing conversation — you remember what was said before.

    your personality:
    - minimal and functional. do the thing, say little. default to one short sentence.
    - you are NOT chatty. don't fill space, don't over-explain, don't ask follow-up questions, don't end with "want me to..." prompts.
    - quiet executor by default: when the user asks for an action, just do it and confirm briefly ("done. raised it two meters.").
    - creative nudge only when asked: ONLY when the user signals they're stuck or asks for ideas (for example "i'm stuck", "any ideas", "what would you do", "this looks off"), offer one concrete suggestion or workaround. keep it brief. the rest of the time, stay out of the way.
    - all lowercase, warm but spare. no emojis. write for the ear: no lists, no markdown, spell out small numbers.

    driving blender:
    - you control the user's running blender through two tools: get_blender_scene (read what's in the scene) and run_blender_python (run bpy code to inspect or change things).
    - LOOK BEFORE YOU LEAP. when a request depends on what's in the scene (object names, selection, materials), call get_blender_scene first, then act on what's actually there. don't guess object names.
    - run_blender_python runs real python with bpy. your code MUST assign a json-serializable dict to a variable named result, for example: result = {"moved": "Cube", "to_z": 2.0}. read that result to confirm what happened, then tell the user in plain words.
    - chain tool calls as needed: inspect, then act, then verify. when you're done, give one short spoken confirmation.
    - for visual questions ("does this look right", "what's off here"), actually look at the viewport screenshot and respond to what you see, then act if they want a change.

    safety — destructive actions:
    - deleting objects, clearing the scene, or overwriting work is destructive. if you call run_blender_python with destructive code, the app will BLOCK it and return a message asking for confirmation.
    - when that happens, do NOT retry the code. instead, tell the user in one short sentence exactly what will be removed and ask them to say "yes" to confirm. the app runs it on their next reply if they confirm.
    - non-destructive changes (move, rotate, scale, color, add, material tweaks) just run — no need to ask.

    if a request has nothing to do with blender, you can still answer normally and briefly. if you can't reach blender, say so plainly (the user may need to open blender).
    """

    // MARK: - AI Response Pipeline

    /// Entry point for a spoken request. Handles three cases:
    ///  1. A pending destructive-action confirmation (user says yes/no).
    ///  2. No Claude key yet (prompt the user to add one).
    ///  3. A normal request — runs the agentic Claude + Blender loop.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        appleSpeechTTSClient.stopPlayback()

        // Case 1: we're waiting on a yes/no for a destructive Blender change.
        if let pendingCode = pendingDestructiveBlenderCode {
            pendingDestructiveBlenderCode = nil
            if Self.isAffirmativeConfirmation(transcript) {
                currentResponseTask = Task {
                    voiceState = .processing
                    do {
                        let runResult = try await blenderBridge.runPython(pendingCode)
                        await presentResponse(runResult.didSucceed ? "done." : "that didn't work. \(runResult.summaryForModel)")
                    } catch {
                        await presentResponse("i couldn't reach blender.")
                    }
                    if !Task.isCancelled { voiceState = .idle; scheduleTransientHideIfNeeded() }
                }
                return
            } else if Self.isNegativeConfirmation(transcript) {
                currentResponseTask = Task {
                    await presentResponse("okay, leaving it.")
                    if !Task.isCancelled { voiceState = .idle; scheduleTransientHideIfNeeded() }
                }
                return
            }
            // Anything else: treat as a brand-new request (fall through).
        }

        // Case 2: no key stored yet.
        guard let claudeAPI = claudeAPI else {
            currentResponseTask = Task {
                await presentResponse("i don't have your claude key yet. opening the box so you can paste it.")
                promptForAnthropicAPIKey()
                if !Task.isCancelled { voiceState = .idle; scheduleTransientHideIfNeeded() }
            }
            return
        }

        // Case 3: the normal agentic loop.
        currentResponseTask = Task {
            voiceState = .processing
            do {
                // Capture all screens so Claude can SEE the viewport. If screen
                // recording isn't granted yet, continue WITHOUT images so Blender
                // control still works — viewport vision is a bonus, not required.
                let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
                guard !Task.isCancelled else { return }

                // First user message: every screenshot + the spoken request.
                var currentUserContent: [[String: Any]] = []
                for capture in screenCaptures {
                    let isPNG = capture.imageData.starts(with: [0x89, 0x50, 0x4E, 0x47] as [UInt8])
                    currentUserContent.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": isPNG ? "image/png" : "image/jpeg",
                            "data": capture.imageData.base64EncodedString(),
                        ],
                    ])
                    currentUserContent.append([
                        "type": "text",
                        "text": "\(capture.label) (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)",
                    ])
                }
                currentUserContent.append(["type": "text", "text": transcript])

                // Replay prior exchanges as simple text so Claude has context.
                var messages: [[String: Any]] = []
                for entry in conversationHistory {
                    messages.append(["role": "user", "content": entry.userTranscript])
                    messages.append(["role": "assistant", "content": entry.assistantResponse])
                }
                messages.append(["role": "user", "content": currentUserContent])

                let tools = Self.blenderToolDefinitions()

                // Look-then-act loop: keep running tools until Claude is done.
                var finalText = ""
                var loopGuard = 0
                while true {
                    loopGuard += 1
                    if loopGuard > 8 {
                        if finalText.isEmpty { finalText = "i went back and forth on that one a bit too long — try asking again." }
                        break
                    }

                    let turn = try await claudeAPI.sendConversationTurn(
                        systemPrompt: Self.companionVoiceResponseSystemPrompt,
                        tools: tools,
                        messages: messages
                    )
                    guard !Task.isCancelled else { return }

                    if turn.toolUseRequests.isEmpty {
                        finalText = turn.assistantText
                        break
                    }

                    // Append Claude's tool_use turn verbatim, then run each tool.
                    messages.append(["role": "assistant", "content": turn.assistantContentBlocks])

                    var toolResultBlocks: [[String: Any]] = []
                    for toolUse in turn.toolUseRequests {
                        let toolResultText = await executeBlenderTool(toolUse)
                        toolResultBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolUse.id,
                            "content": toolResultText,
                        ])
                    }
                    messages.append(["role": "user", "content": toolResultBlocks])
                }

                guard !Task.isCancelled else { return }

                // Strip any leftover [POINT:...] tag from the original behavior.
                let spokenText = Self.parsePointingCoordinates(from: finalText).spokenText

                conversationHistory.append((userTranscript: transcript, assistantResponse: spokenText))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)
                await presentResponse(spokenText)
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                await presentResponse("something went wrong reaching claude. \(error.localizedDescription)")
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Shows Clicky's reply as text near the cursor and, if the user has spoken
    /// replies turned on, also reads it aloud with the Apple voice.
    private func presentResponse(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        responseOverlayManager.showOverlayAndBeginStreaming()
        responseOverlayManager.updateStreamingText(trimmedText)
        responseOverlayManager.finishStreaming()

        if speakRepliesAloud {
            voiceState = .responding
            await appleSpeechTTSClient.speakText(trimmedText)
        }
    }

    // MARK: - Blender tools + safety

    /// The tools Claude can call to inspect and drive Blender.
    private static func blenderToolDefinitions() -> [ClaudeAPI.ToolDefinition] {
        [
            ClaudeAPI.ToolDefinition(
                name: "get_blender_scene",
                description: "Return a summary of every object in the current Blender scene (names, types, locations, selection), plus the active object and current mode. Call this first when you need to know what's in the scene before acting.",
                inputSchema: [
                    "type": "object",
                    "properties": [String: Any](),
                ]
            ),
            ClaudeAPI.ToolDefinition(
                name: "run_blender_python",
                description: "Run Python (bpy) inside the user's running Blender to inspect or modify the scene. The code MUST assign a JSON-serializable dict to a variable named `result`, for example: result = {\"moved\": \"Cube\"}. Use it to move/rotate/scale objects, change materials, add geometry, or read details. Destructive code (delete/clear/overwrite) will be blocked pending the user's spoken confirmation.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "description": "Python using bpy. Must assign a JSON-serializable dict to `result`.",
                        ],
                    ],
                    "required": ["code"],
                ]
            ),
        ]
    }

    /// Runs a tool Claude requested and returns a string result for Claude.
    private func executeBlenderTool(_ toolUse: ClaudeAPI.ToolUseRequest) async -> String {
        switch toolUse.name {
        case "get_blender_scene":
            do {
                return try await blenderBridge.describeSceneObjects().summaryForModel
            } catch {
                return "Could not reach Blender: \(error.localizedDescription)"
            }

        case "run_blender_python":
            guard let code = toolUse.input["code"] as? String, !code.isEmpty else {
                return "No code was provided."
            }
            // Block destructive code the first time we see it, and stash it so
            // the user can confirm out loud on their next push-to-talk.
            if Self.isLikelyDestructiveBlenderCode(code) && pendingDestructiveBlenderCode == nil {
                pendingDestructiveBlenderCode = code
                return "BLOCKED_PENDING_CONFIRMATION: this looks destructive (it could delete or overwrite the user's work). Do NOT retry the code. Tell the user in one short sentence exactly what will be removed and ask them to say yes to confirm."
            }
            do {
                let runResult = try await blenderBridge.runPython(code)
                pendingDestructiveBlenderCode = nil
                var combined = runResult.summaryForModel
                if let output = runResult.standardOutput, !output.isEmpty {
                    combined += "\nstdout: \(output)"
                }
                return combined
            } catch {
                return "Could not reach Blender: \(error.localizedDescription)"
            }

        default:
            return "Unknown tool: \(toolUse.name)"
        }
    }

    /// Heuristic: does this bpy code look like it deletes/clears/overwrites work?
    /// Erring slightly toward caution here is intentional — the user asked for a
    /// seatbelt on destructive actions only.
    static func isLikelyDestructiveBlenderCode(_ code: String) -> Bool {
        let lowercased = code.lowercased()
        let destructiveSignals = [
            "delete", ".remove(", ".unlink(", "read_homefile",
            "ops.object.delete", "batch_remove", "ops.wm.read", "ops.wm.open",
        ]
        return destructiveSignals.contains { lowercased.contains($0) }
    }

    /// Does the transcript read like "yes, do it"?
    static func isAffirmativeConfirmation(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let yesSignals = ["yes", "yeah", "yep", "yup", "confirm", "do it", "go ahead", "sure", "delete it", "go for it", "please do", "sounds good", "okay do", "ok do"]
        return yesSignals.contains { lowercased.contains($0) }
    }

    /// Does the transcript read like "no, don't"?
    static func isNegativeConfirmation(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let noSignals = ["no", "nope", "don't", "do not", "cancel", "stop", "wait", "nevermind", "never mind", "leave it", "forget it"]
        return noSignals.contains { lowercased.contains($0) }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while appleSpeechTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        // Skip the onboarding pointing demo if there's no Claude key yet.
        guard let claudeAPI = claudeAPI else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
