//
//  WhisperTranscriptionProvider.swift
//  leanring-buddy
//
//  Local, free speech-to-text using WhisperKit (OpenAI's Whisper model running
//  fully on-device via CoreML / the Apple Neural Engine). No API, no network
//  after the one-time model download, no cost.
//
//  Like the OpenAI provider, this buffers push-to-talk audio and transcribes
//  the whole utterance on release — but the transcription happens locally.
//

import AVFoundation
import Foundation
import WhisperKit

struct WhisperTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Loads and caches a single WhisperKit instance. The model is downloaded once
/// on first use (a few hundred MB) and then reused across all sessions, so we
/// don't pay the load cost on every push-to-talk.
actor WhisperModelLoader {
    /// Whisper model variant. "base.en" is a good balance of size/accuracy for
    /// short English commands; change to "small.en" for higher accuracy.
    private let modelVariant = "base.en"
    private var loadedWhisperKit: WhisperKit?

    func loadedModel() async throws -> WhisperKit {
        if let loadedWhisperKit {
            return loadedWhisperKit
        }
        let whisperKit = try await WhisperKit(WhisperKitConfig(model: modelVariant))
        loadedWhisperKit = whisperKit
        return whisperKit
    }
}

final class WhisperTranscriptionProvider: BuddyTranscriptionProvider {
    /// Shared loader so the model is only downloaded/loaded once per app run.
    private static let sharedModelLoader = WhisperModelLoader()

    let displayName = "Whisper (local)"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return WhisperTranscriptionSession(
            modelLoader: Self.sharedModelLoader,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Generous fallback because the very first transcription may also download
    // the model. Subsequent transcriptions are fast.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 30.0

    private static let targetSampleRate = 16_000

    private let modelLoader: WhisperModelLoader
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.bigbot.whisper.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        modelLoader: WhisperModelLoader,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.modelLoader = modelLoader
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let isEmptyOrCancelled = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }
        if isEmptyOrCancelled {
            deliverFinalTranscript("")
            return
        }

        // Write the captured audio to a temporary WAV file for WhisperKit.
        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )
        let temporaryWavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigbot-utterance-\(UUID().uuidString).wav")

        do {
            try wavAudioData.write(to: temporaryWavURL)
            defer { try? FileManager.default.removeItem(at: temporaryWavURL) }

            let whisperKit = try await modelLoader.loadedModel()
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            let transcriptionResults = try await whisperKit.transcribe(audioPath: temporaryWavURL.path)
            let transcriptText = transcriptionResults
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Whisper Transcription] ❌ Local transcription failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        // Only do deinit-safe work here. Calling cancel() would dispatch a
        // closure capturing self while the object is being deallocated, which
        // crashes the Swift runtime. Cancelling the task captures nothing.
        transcriptionTask?.cancel()
    }
}
