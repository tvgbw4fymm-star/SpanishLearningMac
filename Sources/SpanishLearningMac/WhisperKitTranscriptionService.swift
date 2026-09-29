import AVFoundation
import Foundation
import WhisperKit

enum WhisperTranscriptionError: LocalizedError {
    case modelDownloadFailed
    case modelLoadingFailed
    case audioReadFailed
    case transcriptionFailed
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .modelDownloadFailed: "本地转写模型下载失败，请检查网络后重试。"
        case .modelLoadingFailed: "本地转写模型加载失败。"
        case .audioReadFailed: "无法读取音频文件。"
        case .transcriptionFailed: "本机转写失败，原有句子未修改。"
        case .noSpeech: "没有识别到可用的带时间戳语音，原有句子未修改。"
        }
    }
}

@MainActor
final class WhisperKitTranscriptionService {
    private let cacheDirectory: URL
    private var whisperKit: WhisperKit?

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    var modelIsInstalled: Bool {
        WhisperModelCache.installedFolder(cacheDirectory: cacheDirectory) != nil
    }

    func transcribe(
        audioURL: URL,
        onStatus: @escaping @MainActor (String) -> Void
    ) async throws -> WhisperTranscriptionResult {
        let duration: Double
        do {
            let asset = AVURLAsset(url: audioURL)
            duration = CMTimeGetSeconds(try await asset.load(.duration))
            guard duration.isFinite, duration > 0 else { throw WhisperTranscriptionError.audioReadFailed }
        } catch {
            throw WhisperTranscriptionError.audioReadFailed
        }

        if whisperKit == nil {
            let modelFolder = try await ensureModelInstalled(onStatus: onStatus)
            onStatus("正在准备本地转写模型…")
            do {
                let config = WhisperKitConfig(
                    model: WhisperModelCache.variant,
                    downloadBase: cacheDirectory,
                    modelFolder: modelFolder.path,
                    tokenizerFolder: cacheDirectory,
                    computeOptions: ModelComputeOptions(
                        melCompute: .cpuAndGPU,
                        audioEncoderCompute: .cpuAndNeuralEngine,
                        textDecoderCompute: .cpuAndNeuralEngine
                    ),
                    verbose: false,
                    logLevel: .none,
                    load: true,
                    download: false,
                    useBackgroundDownloadSession: false
                )
                whisperKit = try await WhisperKit(config)
                guard modelIsInstalled else { throw WhisperTranscriptionError.modelDownloadFailed }
            } catch let error as WhisperTranscriptionError {
                throw error
            } catch {
                if !modelIsInstalled {
                    throw WhisperTranscriptionError.modelDownloadFailed
                }
                throw WhisperTranscriptionError.modelLoadingFailed
            }
        }

        guard let whisperKit else { throw WhisperTranscriptionError.modelLoadingFailed }
        onStatus("正在本机转写…")
        let startedAt = Date()
        whisperKit.transcriptionStateCallback = { state in
            let message: String
            switch state {
            case .convertingAudio: message = "正在准备音频…"
            case .transcribing: message = "正在本机转写…"
            case .finished: return
            }
            Task { @MainActor in onStatus(message) }
        }
        defer { whisperKit.transcriptionStateCallback = nil }

        var options = DecodingOptions(
            task: .transcribe,
            language: "es",
            temperature: 0,
            wordTimestamps: true,
            concurrentWorkerCount: 1,
            chunkingStrategy: .vad
        )
        options.usePrefillPrompt = true
        options.detectLanguage = false
        let rawResults: [TranscriptionResult]
        do {
            rawResults = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                decodeOptions: options
            )
        } catch {
            throw WhisperTranscriptionError.transcriptionFailed
        }
        let rawSegments = rawResults.flatMap(\.segments).sorted { $0.start < $1.start }
        let rawWords = rawSegments.flatMap { $0.words ?? [] }.sorted { $0.start < $1.start }
        do {
            let qc = try WhisperListeningPipeline.validate(
                words: rawWords.map { WhisperTimedWord(start: Double($0.start), end: Double($0.end), text: $0.word) },
                segments: rawSegments.map {
                    WhisperTimedSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
                },
                audioDuration: duration
            )
            guard !qc.words.isEmpty || !qc.segments.isEmpty else {
                throw WhisperTranscriptionError.noSpeech
            }
            return WhisperTranscriptionResult(
                audioDuration: duration,
                timestampedWords: qc.words,
                timestampedSegments: qc.segments,
                diagnostics: qc.diagnostics,
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch let error as WhisperTranscriptionError {
            throw error
        } catch {
            throw WhisperTranscriptionError.transcriptionFailed
        }
    }

    private func ensureModelInstalled(
        onStatus: @escaping @MainActor (String) -> Void
    ) async throws -> URL {
        if let folder = WhisperModelCache.modelAssetsFolder(cacheDirectory: cacheDirectory) {
            if !modelIsInstalled {
                onStatus("正在下载本地转写模型…")
            }
            return folder
        }
        onStatus("正在下载本地转写模型…")
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let downloadedFolder = try await WhisperKit.download(
                variant: WhisperModelCache.variant,
                downloadBase: cacheDirectory,
                progressCallback: { progress in
                    guard !progress.isIndeterminate, progress.fractionCompleted.isFinite else {
                        Task { @MainActor in onStatus("正在下载本地转写模型…") }
                        return
                    }
                    let percent = Int((min(max(progress.fractionCompleted, 0), 1) * 100).rounded())
                    Task { @MainActor in onStatus("正在下载本地转写模型… \(percent)%") }
                }
            )
            guard WhisperModelCache.modelAssetsFolder(cacheDirectory: cacheDirectory) != nil else {
                throw WhisperTranscriptionError.modelDownloadFailed
            }
            return downloadedFolder
        } catch {
            throw WhisperTranscriptionError.modelDownloadFailed
        }
    }
}
