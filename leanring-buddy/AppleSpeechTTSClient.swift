//
//  AppleSpeechTTSClient.swift
//  leanring-buddy
//
//  Free, fully on-device text-to-speech using Apple's built-in AVSpeechSynthesizer.
//  This is a drop-in replacement for ElevenLabsTTSClient — same method surface
//  (speakText / isPlaying / stopPlayback) — so the rest of the app doesn't need
//  to know which voice engine is behind it. No API key, no network, no cost.
//
//  Speaking aloud is optional and user-toggleable: the caller decides whether to
//  call speakText at all. When spoken replies are off, the app just shows text.
//

import AVFoundation
import Foundation

@MainActor
final class AppleSpeechTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    /// Resolved once: prefer a higher-quality "enhanced/premium" English voice
    /// if the user has downloaded one (System Settings ▸ Accessibility ▸
    /// Spoken Content ▸ System Voice ▸ Manage Voices), otherwise fall back to
    /// the default system voice. Picking it once keeps the voice consistent.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = Self.resolvePreferredEnglishVoice()

    /// Continuation used to await the end of the current utterance, so callers
    /// can `await speakText(...)` and know when speech has finished.
    private var activeSpeechContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` aloud and returns once playback finishes (or is stopped).
    /// Safe to call repeatedly — any in-progress speech is cancelled first.
    func speakText(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Cancel anything already speaking so replies don't overlap.
        stopPlayback()

        let utterance = AVSpeechUtterance(string: trimmedText)
        if let preferredVoice {
            utterance.voice = preferredVoice
        }
        // A touch faster than the default robotic pace, still clearly intelligible.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.prefersAssistiveTechnologySettings = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.activeSpeechContinuation = continuation
            self.synthesizer.speak(utterance)
        }
    }

    /// Whether speech is currently being spoken.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Immediately stops any in-progress speech and resolves a pending await.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        resumeActiveSpeechContinuation()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeActiveSpeechContinuation() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeActiveSpeechContinuation() }
    }

    // MARK: - Private

    /// Resolves the pending speech continuation exactly once.
    private func resumeActiveSpeechContinuation() {
        guard let continuation = activeSpeechContinuation else { return }
        activeSpeechContinuation = nil
        continuation.resume()
    }

    /// Picks the best available English voice: an enhanced/premium one if the
    /// user has downloaded any, otherwise the system default for the locale.
    private static func resolvePreferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = allVoices.filter { $0.language.hasPrefix("en") }

        // Prefer the highest available quality tier (premium > enhanced > default).
        if let premiumVoice = englishVoices.first(where: { $0.quality == .premium }) {
            return premiumVoice
        }
        if let enhancedVoice = englishVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }
        // Fall back to the user's current system voice for their locale.
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }
}
