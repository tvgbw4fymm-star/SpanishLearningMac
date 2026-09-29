import Foundation
import AppKit

@MainActor
final class StudyStore: ObservableObject {
    @Published private(set) var data: StudyDatabase
    @Published var errorMessage: String?

    let supportDirectory: URL
    private let databaseURL: URL
    private let mediaDirectory: URL
    private var canWrite = true
    @Published private(set) var transferInProgress = false
    @Published private(set) var activeTranscriptions: Set<UUID> = []
    @Published private(set) var transcriptionStatus: [UUID: String] = [:]
    @Published private(set) var whisperDiagnostics: [UUID: String] = [:]
    @Published private(set) var whisperModelInstalled = false
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private let whisperTranscriptionService: WhisperKitTranscriptionService

    init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpanishLearningMac", isDirectory: true)
        supportDirectory = base
        let modelCache = base.appendingPathComponent("Models/WhisperKit", isDirectory: true)
        whisperTranscriptionService = WhisperKitTranscriptionService(cacheDirectory: modelCache)
        databaseURL = base.appendingPathComponent("study.json")
        mediaDirectory = base.appendingPathComponent("Media", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                let payload = try Data(contentsOf: databaseURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let loaded = try decoder.decode(StudyDatabase.self, from: payload)
                guard loaded.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
                data = loaded
            } else {
                data = StudyDatabase()
            }
        } catch {
            data = StudyDatabase()
            canWrite = false
            errorMessage = "无法读取本机学习资料：\(error.localizedDescription)。应用不会覆盖原文件。"
        }
        if canWrite {
            let previous = data.readingRecords
            let consolidated = Self.consolidatedReadingRecords(previous)
            if consolidated.count != previous.count {
                data.readingRecords = consolidated
                do { try save() }
                catch {
                    data.readingRecords = previous
                    errorMessage = "阅读历史合并未能保存：\(error.localizedDescription)"
                }
            }
            whisperModelInstalled = whisperTranscriptionService.modelIsInstalled
        }
    }

    func importAudio(from source: URL) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        let id = UUID()
        let fileName = id.uuidString + "." + source.pathExtension.lowercased()
        let destination = mediaDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        data.audioMaterials.append(AudioMaterial(id: id, title: source.deletingPathExtension().lastPathComponent,
                                                 fileName: fileName, importedAt: .now))
        do { try save() } catch {
            data.audioMaterials.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func importSubtitles(from source: URL, materialID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else {
            throw StoreError.missingMaterial
        }
        guard !activeTranscriptions.contains(materialID) else { throw BackupError.busy }
        let cues = try SubtitleImporter.parse(Data(contentsOf: source))
        let previous = data.audioMaterials[index].referenceSubtitleCues
        let previousReliability = data.audioMaterials[index].subtitleReferenceReliable
        let previousStatus = transcriptionStatus[materialID]
        data.audioMaterials[index].referenceSubtitleCues = cues
        data.audioMaterials[index].subtitleReferenceReliable = nil
        if data.audioMaterials[index].transcriptionComplete == true,
           !data.audioMaterials[index].sentences.isEmpty {
            transcriptionStatus[materialID] =
                "已导入 \(cues.count) 条字幕；点击“用字幕重新校准”将字幕设为练习句。"
        } else {
            transcriptionStatus.removeValue(forKey: materialID)
        }
        do { try save() } catch {
            data.audioMaterials[index].referenceSubtitleCues = previous
            data.audioMaterials[index].subtitleReferenceReliable = previousReliability
            transcriptionStatus[materialID] = previousStatus
            throw error
        }
    }

    func generateAudioTitle(materialID: UUID) async throws {
        guard let material = data.audioMaterials.first(where: { $0.id == materialID }) else {
            throw StoreError.missingMaterial
        }
        let transcript = material.sentences.prefix(35).map(\.transcript).joined(separator: " ")
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = try await TitleGenerationService.generate(from: transcript, kind: "听力素材")
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else { return }
        let previous = data.audioMaterials[index].title
        data.audioMaterials[index].title = title
        do { try save() } catch { data.audioMaterials[index].title = previous; throw error }
    }

    func audioURL(for material: AudioMaterial) -> URL {
        mediaDirectory.appendingPathComponent(material.fileName)
    }

    func startTranscription(materialID: UUID) throws {
        guard !activeTranscriptions.contains(materialID) else { throw BackupError.busy }
        guard let material = data.audioMaterials.first(where: { $0.id == materialID }) else { throw StoreError.missingMaterial }
        guard material.segmentationSource != .subtitle else { throw StoreError.transcriptionUsesSubtitles }
        try startWhisperTranscription(
            materialID: materialID,
            replacingExistingSentences: false
        )
    }

    func startWhisperSubtitleRecalibration(materialID: UUID) throws {
        guard canRecalibrateSubtitles(materialID: materialID),
              let material = data.audioMaterials.first(where: { $0.id == materialID }) else {
            throw StoreError.transcriptionLocked
        }
        guard material.referenceSubtitleCues?.isEmpty == false else {
            throw StoreError.subtitleReferenceRequiresSpeech
        }
        try startWhisperTranscription(
            materialID: materialID,
            replacingExistingSentences: true
        )
    }

    private func startWhisperTranscription(
        materialID: UUID,
        replacingExistingSentences: Bool
    ) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard !activeTranscriptions.contains(materialID) else { throw BackupError.busy }
        guard let material = data.audioMaterials.first(where: { $0.id == materialID }) else {
            throw StoreError.missingMaterial
        }
        if replacingExistingSentences {
            guard material.referenceSubtitleCues?.isEmpty == false,
                  material.segmentationSource == .speech,
                  !material.sentences.isEmpty,
                  !hasListeningHistory(materialID: materialID, sentences: material.sentences) else {
                throw StoreError.transcriptionLocked
            }
        } else {
            guard material.transcriptionComplete != true, material.sentences.isEmpty else {
                throw StoreError.transcriptionLocked
            }
            guard !hasListeningHistory(materialID: materialID, sentences: material.sentences) else {
                throw StoreError.transcriptionLocked
            }
        }
        let source = audioURL(for: material)
        activeTranscriptions.insert(materialID)
        transcriptionStatus[materialID] = whisperModelInstalled
            ? "正在准备本地转写模型…"
            : "准备本地转写模型"
        transcriptionTasks[materialID] = Task {
            do {
                let result = try await whisperTranscriptionService.transcribe(audioURL: source) { status in
                    self.transcriptionStatus[materialID] = status
                }
                guard !Task.isCancelled else { throw CancellationError() }
                whisperModelInstalled = whisperTranscriptionService.modelIsInstalled
                let cues = data.audioMaterials.first(where: { $0.id == materialID })?.referenceSubtitleCues ?? []
                let sentences: [ListeningSentence]
                var subtitleTimingStatus = ""
                if !cues.isEmpty {
                    transcriptionStatus[materialID] = "正在校准字幕时间…"
                    do {
                        let alignment = try WhisperListeningPipeline.alignSubtitles(
                            cues: cues,
                            words: result.timestampedWords,
                            audioDuration: result.audioDuration
                        )
                        sentences = alignment.sentences
                        whisperDiagnostics[materialID] =
                            "directWhisper=\(alignment.directCount); interpolated=\(alignment.interpolatedCount); originalSubtitle=\(alignment.originalCount); textConflicts=\(alignment.conflictCount); \(result.diagnostics.summary)"
                        subtitleTimingStatus = alignment.originalCount == 0 ? "已校准" : "部分校准"
                    } catch {
                        sentences = try originalSubtitleSentences(cues: cues, audioDuration: result.audioDuration)
                        subtitleTimingStatus = "部分校准"
                        whisperDiagnostics[materialID] =
                            "subtitleAlignmentFailed=true; \(result.diagnostics.summary)"
                    }
                } else {
                    sentences = try WhisperListeningPipeline.sentencesWithoutSubtitles(
                        segments: result.timestampedSegments,
                        words: result.timestampedWords
                    )
                }
                try commitWhisperTranscript(
                    materialID: materialID,
                    sentences: sentences,
                    audioDuration: result.audioDuration,
                    replacingExistingSentences: replacingExistingSentences,
                    hasSubtitles: !cues.isEmpty
                )
                var message = !cues.isEmpty
                    ? "\(sentences.count) 句 · 字幕时间\(subtitleTimingStatus)"
                    : "转写完成（\(sentences.count) 句）"
                if result.diagnostics.filteredCount > 0 {
                    message += "；已过滤异常时间戳 \(result.diagnostics.filteredCount) 项"
                    whisperDiagnostics[materialID] = result.diagnostics.summary
                }
                message += String(format: "；用时 %.1f 秒", result.elapsedSeconds)
                transcriptionStatus[materialID] = message
            } catch is CancellationError {
                transcriptionStatus[materialID] = "已暂停；尚未更改现有句子。"
            } catch {
                whisperModelInstalled = whisperTranscriptionService.modelIsInstalled
                transcriptionStatus[materialID] = error.localizedDescription
            }
            activeTranscriptions.remove(materialID)
            transcriptionTasks.removeValue(forKey: materialID)
        }
    }

    private func commitWhisperTranscript(
        materialID: UUID,
        sentences: [ListeningSentence],
        audioDuration: Double,
        replacingExistingSentences: Bool,
        hasSubtitles: Bool
    ) throws {
        guard canWrite, !transferInProgress,
              let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else {
            throw StoreError.missingMaterial
        }
        let existing = data.audioMaterials[index]
        if replacingExistingSentences {
            guard existing.segmentationSource == .speech,
                  !hasListeningHistory(materialID: materialID, sentences: existing.sentences) else {
                throw StoreError.transcriptionLocked
            }
        } else {
            guard existing.sentences.isEmpty,
                  !hasListeningHistory(materialID: materialID, sentences: existing.sentences) else {
                throw StoreError.transcriptionLocked
            }
        }
        guard !sentences.isEmpty,
              sentences.allSatisfy({
                  $0.startSeconds.isFinite && $0.endSeconds.isFinite &&
                      $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds &&
                      $0.endSeconds <= audioDuration + 0.05
              }) else {
            throw StoreError.invalidSentence
        }
        let previous = existing
        data.audioMaterials[index].sentences = sentences
        data.audioMaterials[index].segmentationSource = hasSubtitles ? .subtitleCalibrated : .speech
        data.audioMaterials[index].transcribedThroughSeconds = audioDuration
        data.audioMaterials[index].transcriptionComplete = true
        data.audioMaterials[index].speechTimingAnchors = nil
        do {
            try save()
        } catch {
            data.audioMaterials[index] = previous
            throw error
        }
    }

    private func originalSubtitleSentences(
        cues: [SubtitleCue],
        audioDuration: Double
    ) throws -> [ListeningSentence] {
        try cues.enumerated().map { index, cue in
            let start = max(0, cue.startSeconds)
            let end = min(audioDuration, cue.endSeconds)
            guard start.isFinite, end.isFinite, start < end else {
                throw WhisperPipelineError.invalidFinalTiming
            }
            return ListeningSentence(
                id: UUID(),
                ordinal: index + 1,
                startSeconds: start,
                endSeconds: end,
                transcript: cue.text,
                status: .generated,
                version: 1,
                referenceSubtitleText: cue.text,
                timingSource: .subtitleOriginal,
                timingConfidence: .low,
                whisperTimingMethod: .originalSubtitle
            )
        }
    }

    func canRecalibrateSubtitles(materialID: UUID) -> Bool {
        guard canWrite, !transferInProgress,
              let material = data.audioMaterials.first(where: { $0.id == materialID }),
              material.referenceSubtitleCues?.isEmpty == false,
              material.segmentationSource == .speech,
              !material.sentences.isEmpty,
              !activeTranscriptions.contains(materialID) else { return false }
        return !hasListeningHistory(materialID: materialID, sentences: material.sentences)
    }

    func startSubtitleCalibration(materialID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard !activeTranscriptions.contains(materialID) else { throw BackupError.busy }
        guard canRecalibrateSubtitles(materialID: materialID),
              let material = data.audioMaterials.first(where: { $0.id == materialID }) else {
            throw StoreError.transcriptionLocked
        }
        let source = audioURL(for: material)
        let previousAnchors = material.speechTimingAnchors
        let previousOffset = material.transcribedThroughSeconds
        let previousCompletion = material.transcriptionComplete
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else {
            throw StoreError.missingMaterial
        }
        data.audioMaterials[index].speechTimingAnchors = nil
        data.audioMaterials[index].transcribedThroughSeconds = nil
        data.audioMaterials[index].transcriptionComplete = false
        do { try save() } catch {
            data.audioMaterials[index].speechTimingAnchors = previousAnchors
            data.audioMaterials[index].transcribedThroughSeconds = previousOffset
            data.audioMaterials[index].transcriptionComplete = previousCompletion
            throw error
        }
        try beginTranscription(materialID: materialID, source: source, offset: 0,
                               hasTimedSubtitles: true, replacingSpeechSentences: true,
                               generateTitleAfterCompletion: false,
                               restoreOnFailure: (previousAnchors, previousOffset, previousCompletion))
    }

    private func beginTranscription(materialID: UUID, source: URL, offset: Double,
                                    hasTimedSubtitles: Bool, replacingSpeechSentences: Bool,
                                    generateTitleAfterCompletion: Bool,
                                    restoreOnFailure: (anchors: [SpeechTimingAnchor]?, offset: Double?,
                                                       completion: Bool?)? = nil) throws {
        activeTranscriptions.insert(materialID)
        transcriptionStatus[materialID] = hasTimedSubtitles
            ? "正在识别音频锚点并校准字幕…"
            : "正在转写并保存进度…"
        transcriptionTasks[materialID] = Task {
            await performTranscription(materialID: materialID, source: source, offset: offset,
                                       hasTimedSubtitles: hasTimedSubtitles,
                                       replacingSpeechSentences: replacingSpeechSentences,
                                       generateTitleAfterCompletion: generateTitleAfterCompletion,
                                       restoreOnFailure: restoreOnFailure)
        }
    }

    private func performTranscription(materialID: UUID, source: URL, offset: Double,
                                      hasTimedSubtitles: Bool, replacingSpeechSentences: Bool,
                                      generateTitleAfterCompletion: Bool,
                                      restoreOnFailure: (anchors: [SpeechTimingAnchor]?, offset: Double?,
                                                         completion: Bool?)?) async {
        do {
            let onChunk: @Sendable ([ListeningSentence], Double) async throws -> Void = { segments, through in
                try await MainActor.run {
                    if !hasTimedSubtitles {
                        try self.appendTranscriptChunk(materialID: materialID, segments: segments, through: through)
                    }
                    self.transcriptionStatus[materialID] =
                        "已转写到 \(Int(through) / 60):\(String(format: "%02d", Int(through) % 60))，进度已保存。"
                }
            }
            var rawHandler: (@Sendable ([NativeSpeechSegment], Double) async throws -> Void)?
            if hasTimedSubtitles {
                rawHandler = { segments, through in
                    let anchors = segments.map {
                        SpeechTimingAnchor(text: $0.substring, startSeconds: $0.timestamp,
                                           endSeconds: $0.end)
                    }
                    try await self.appendSpeechTimingAnchors(
                        materialID: materialID, segments: anchors, through: through
                    )
                }
            }
            let summary = try await TranscriptionService.transcribe(
                audioURL: source, startingAt: offset, onChunk: onChunk, onRawSegments: rawHandler
            )
            if hasTimedSubtitles {
                try applySubtitleTimingCalibration(
                    materialID: materialID,
                    audioDuration: summary.processedThroughSeconds,
                    replacingSpeechSentences: replacingSpeechSentences
                )
            }
            if !hasTimedSubtitles {
                try completeTranscription(materialID: materialID)
            }
            if hasTimedSubtitles {
                let calibrated = data.audioMaterials.first(where: { $0.id == materialID })?
                    .sentences.filter { $0.timingSource == .speechCalibrated }.count ?? 0
                let total = data.audioMaterials.first(where: { $0.id == materialID })?.sentences.count ?? 0
                transcriptionStatus[materialID] =
                    "字幕 + 本机音频校准完成（\(calibrated)/\(total) 句已校准；\(summary.noSpeechChunkCount) 个无语音块跳过）。"
            } else {
                transcriptionStatus[materialID] =
                    "本机转写完成（\(summary.successfulChunkCount)/\(summary.chunkCount) 个音频块成功，\(summary.noSpeechChunkCount) 个无语音块跳过）。"
                if generateTitleAfterCompletion {
                    do { try await generateAudioTitle(materialID: materialID) }
                    catch { transcriptionStatus[materialID] = "转写已保存，标题生成失败：\(error.localizedDescription)" }
                }
            }
        } catch is CancellationError {
            let restoreError = restoreSubtitleCalibrationState(materialID: materialID, state: restoreOnFailure)
            transcriptionStatus[materialID] = restoreError.map {
                "已暂停；恢复原转写状态失败：\($0)"
            } ?? "已暂停；下次可从已保存的位置继续。"
        } catch {
            let restoreError = restoreSubtitleCalibrationState(materialID: materialID, state: restoreOnFailure)
            let failure = replacingSpeechSentences
                ? "字幕校准失败，原有 Speech 句子已保留：\(error.localizedDescription)"
                : error.localizedDescription
            transcriptionStatus[materialID] = restoreError.map { "\(failure)；恢复状态失败：\($0)" } ?? failure
        }
        activeTranscriptions.remove(materialID)
        transcriptionTasks.removeValue(forKey: materialID)
    }

    func pauseTranscription(materialID: UUID) {
        transcriptionTasks[materialID]?.cancel()
    }

    func setTranscript(materialID: UUID, segments: [ListeningSentence],
                       segmentationSource: ListeningSegmentationSource? = nil) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else { throw StoreError.missingMaterial }
        guard !data.dictationAttempts.contains(where: { $0.materialID == materialID }),
              !data.cards.contains(where: { card in card.sources.contains { $0.materialID == materialID } })
        else { throw StoreError.transcriptionLocked }
        let previous = data.audioMaterials[index]
        data.audioMaterials[index].sentences = segments
        if let segmentationSource {
            data.audioMaterials[index].segmentationSource = segmentationSource
            data.audioMaterials[index].transcriptionComplete = true
            data.audioMaterials[index].transcribedThroughSeconds = segments.last?.endSeconds
        }
        do {
            try save()
            if segmentationSource == .subtitle {
                transcriptionStatus.removeValue(forKey: materialID)
            }
        } catch {
            data.audioMaterials[index] = previous
            throw error
        }
    }

    func applySubtitleTimingCalibration(materialID: UUID, audioDuration: Double,
                                        replacingSpeechSentences: Bool = false) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }),
              let cues = data.audioMaterials[index].referenceSubtitleCues,
              !cues.isEmpty,
              data.audioMaterials[index].segmentationSource != .subtitle else { return }
        let existingSentences = data.audioMaterials[index].sentences
        if replacingSpeechSentences {
            guard data.audioMaterials[index].segmentationSource == .speech,
                  !existingSentences.isEmpty,
                  !hasListeningHistory(materialID: materialID, sentences: existingSentences) else {
                throw StoreError.transcriptionLocked
            }
        } else {
            guard existingSentences.isEmpty else { throw StoreError.transcriptionLocked }
        }
        guard audioDuration.isFinite, audioDuration > 0 else { throw StoreError.invalidSentence }
        let originalMaterial = data.audioMaterials[index]
        let calibration = ListeningSubtitleAligner.SubtitleTimingCalibrator.calibrate(
            cues: cues, speech: originalMaterial.speechTimingAnchors ?? [],
            audioDuration: audioDuration
        )
        let previous = data.audioMaterials[index]
        data.audioMaterials[index].sentences = calibration.sentences
        data.audioMaterials[index].segmentationSource = .subtitleCalibrated
        data.audioMaterials[index].transcriptionComplete = true
        do { try save() } catch {
            data.audioMaterials[index] = previous
            throw error
        }
    }

    @discardableResult
    private func restoreSubtitleCalibrationState(
        materialID: UUID,
        state: (anchors: [SpeechTimingAnchor]?, offset: Double?, completion: Bool?)?
    ) -> String? {
        guard let state else { return nil }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else {
            return StoreError.missingMaterial.localizedDescription
        }
        let previous = data.audioMaterials[index]
        data.audioMaterials[index].speechTimingAnchors = state.anchors
        data.audioMaterials[index].transcribedThroughSeconds = state.offset
        data.audioMaterials[index].transcriptionComplete = state.completion
        do {
            try save()
            return nil
        } catch {
            data.audioMaterials[index] = previous
            return error.localizedDescription
        }
    }

    private func hasListeningHistory(materialID: UUID, sentences: [ListeningSentence]) -> Bool {
        data.dictationAttempts.contains { $0.materialID == materialID } ||
            data.cards.contains { card in card.sources.contains { $0.materialID == materialID } } ||
            data.writingExercises.contains { $0.sourceID == materialID } ||
            sentences.contains {
                $0.status != .generated || $0.draftText != nil || $0.answerRevealed == true ||
                    $0.analysis != nil || !($0.learningPoints ?? []).isEmpty
            }
    }

    func appendSpeechTimingAnchors(materialID: UUID, segments: [SpeechTimingAnchor],
                                   through seconds: Double) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else {
            throw StoreError.missingMaterial
        }
        guard data.audioMaterials[index].referenceSubtitleCues?.isEmpty == false,
              data.audioMaterials[index].segmentationSource != .subtitle else {
            throw StoreError.transcriptionUsesSubtitles
        }
        guard !hasListeningHistory(materialID: materialID,
                                   sentences: data.audioMaterials[index].sentences) else {
            throw StoreError.transcriptionLocked
        }
        let previous = data.audioMaterials[index]
        data.audioMaterials[index].speechTimingAnchors =
            (data.audioMaterials[index].speechTimingAnchors ?? []) + segments
        data.audioMaterials[index].transcribedThroughSeconds = seconds
        data.audioMaterials[index].transcriptionComplete = false
        do { try save() } catch { data.audioMaterials[index] = previous; throw error }
    }

    func appendTranscriptChunk(materialID: UUID, segments: [ListeningSentence], through seconds: Double) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else { throw StoreError.missingMaterial }
        guard data.audioMaterials[index].segmentationSource != .subtitle else {
            throw StoreError.transcriptionUsesSubtitles
        }
        guard !data.dictationAttempts.contains(where: { $0.materialID == materialID }) else { throw StoreError.transcriptionLocked }
        let previous = data.audioMaterials[index]
        let current = previous.sentences.count
        data.audioMaterials[index].sentences += segments.enumerated().map { offset, segment in
            var numbered = segment
            numbered.ordinal = current + offset + 1
            if numbered.rawSpeechText == nil { numbered.rawSpeechText = numbered.transcript }
            return numbered
        }
        data.audioMaterials[index].transcribedThroughSeconds = seconds
        data.audioMaterials[index].transcriptionComplete = false
        data.audioMaterials[index].segmentationSource = .speech
        do { try save() } catch { data.audioMaterials[index] = previous; throw error }
    }

    func completeTranscription(materialID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else { throw StoreError.missingMaterial }
        let previous = data.audioMaterials[index]
        if previous.sentences.isEmpty {
            data.audioMaterials[index].transcribedThroughSeconds = nil
            data.audioMaterials[index].transcriptionComplete = false
            try save()
            throw StoreError.noSpeech
        }
        data.audioMaterials[index].transcriptionComplete = true
        do { try save() } catch { data.audioMaterials[index] = previous; throw error }
    }

    func updateSentence(materialID: UUID, sentenceID: UUID, text: String, start: Double, end: Double) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        guard start >= 0, end > start, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidSentence }
        let previous = data.audioMaterials[m].sentences[s]
        data.audioMaterials[m].sentences[s].transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        data.audioMaterials[m].sentences[s].startSeconds = start
        data.audioMaterials[m].sentences[s].endSeconds = end
        data.audioMaterials[m].sentences[s].version += 1
        data.audioMaterials[m].sentences[s].status = .corrected
        do { try save() } catch { data.audioMaterials[m].sentences[s] = previous; throw error }
    }

    func splitSentence(materialID: UUID, sentenceID: UUID,
                       firstText: String, secondText: String, at splitSeconds: Double) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        guard !isReferencedSentence(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.sentenceReferenced }
        let first = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = secondText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = data.audioMaterials[m].sentences
        let old = previous[s]
        guard !first.isEmpty, !second.isEmpty,
              splitSeconds > old.startSeconds, splitSeconds < old.endSeconds else { throw StoreError.invalidSentence }
        data.audioMaterials[m].sentences[s].transcript = first
        data.audioMaterials[m].sentences[s].endSeconds = splitSeconds
        data.audioMaterials[m].sentences[s].status = .corrected
        data.audioMaterials[m].sentences[s].version += 1
        let added = ListeningSentence(id: UUID(), ordinal: old.ordinal + 1, startSeconds: splitSeconds,
                                      endSeconds: old.endSeconds, transcript: second, status: .corrected, version: 1)
        data.audioMaterials[m].sentences.insert(added, at: s + 1)
        for i in data.audioMaterials[m].sentences.indices { data.audioMaterials[m].sentences[i].ordinal = i + 1 }
        do { try save() } catch { data.audioMaterials[m].sentences = previous; throw error }
    }

    func mergeWithNext(materialID: UUID, sentenceID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID),
              s + 1 < data.audioMaterials[m].sentences.count else { throw StoreError.missingSentence }
        let next = data.audioMaterials[m].sentences[s + 1]
        guard !isReferencedSentence(materialID: materialID, sentenceID: sentenceID),
              !isReferencedSentence(materialID: materialID, sentenceID: next.id) else { throw StoreError.sentenceReferenced }
        let previous = data.audioMaterials[m].sentences
        data.audioMaterials[m].sentences[s].transcript += " " + next.transcript
        data.audioMaterials[m].sentences[s].endSeconds = next.endSeconds
        data.audioMaterials[m].sentences[s].version += 1
        data.audioMaterials[m].sentences[s].status = .corrected
        data.audioMaterials[m].sentences.remove(at: s + 1)
        for i in data.audioMaterials[m].sentences.indices { data.audioMaterials[m].sentences[i].ordinal = i + 1 }
        do { try save() } catch { data.audioMaterials[m].sentences = previous; throw error }
    }

    private func isReferencedSentence(materialID: UUID, sentenceID: UUID) -> Bool {
        data.dictationAttempts.contains { $0.materialID == materialID && $0.sentenceID == sentenceID } ||
        data.cards.contains { card in card.sources.contains { $0.materialID == materialID && $0.segmentID == sentenceID } }
    }

    func verifyTranscript(materialID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let index = data.audioMaterials.firstIndex(where: { $0.id == materialID }) else { throw StoreError.missingMaterial }
        let previous = data.audioMaterials[index].sentences
        guard !previous.isEmpty else { throw StoreError.missingSentence }
        guard data.audioMaterials[index].transcriptionComplete == true else { throw StoreError.transcriptionIncomplete }
        for i in data.audioMaterials[index].sentences.indices where data.audioMaterials[index].sentences[i].status == .generated {
            data.audioMaterials[index].sentences[i].status = .verified
        }
        do { try save() } catch { data.audioMaterials[index].sentences = previous; throw error }
    }

    func saveDictationDraft(materialID: UUID, sentenceID: UUID, text: String) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        let previous = data.audioMaterials[m].sentences[s].draftText
        data.audioMaterials[m].sentences[s].draftText = text
        do { try save() } catch { data.audioMaterials[m].sentences[s].draftText = previous; throw error }
    }

    func revealAnswer(materialID: UUID, sentenceID: UUID, text: String) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        let priorSentence = data.audioMaterials[m].sentences[s]
        let attempt = DictationAttempt(id: UUID(), materialID: materialID, sentenceID: sentenceID,
                                       submittedAt: .now, text: text, answerWasShown: true,
                                       answerTextSnapshot: priorSentence.transcript, answerVersion: priorSentence.version)
        data.audioMaterials[m].sentences[s].draftText = text
        data.audioMaterials[m].sentences[s].answerRevealed = true
        data.dictationAttempts.append(attempt)
        do { try save() } catch {
            data.audioMaterials[m].sentences[s] = priorSentence
            data.dictationAttempts.removeAll { $0.id == attempt.id }
            throw error
        }
    }

    func saveListeningAnalysis(materialID: UUID, sentenceID: UUID, attempt: String,
                                result: ListeningAnalysisResult) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        let previous = data.audioMaterials[m].sentences[s]
        data.audioMaterials[m].sentences[s].analysis = ListeningAnalysis(
            userAttemptSnapshot: attempt,
            explanation: result.explanation,
            items: result.items.map {
                ListeningAnalysisItem(id: UUID(), category: $0.category,
                                      title: $0.title, detail: $0.detail, evidence: $0.evidence)
            },
            generatedAt: .now
        )
        do { try save() } catch {
            data.audioMaterials[m].sentences[s] = previous
            throw error
        }
    }

    func saveListeningCards(materialID: UUID, sentenceID: UUID,
                            points: [LearningPointRequest], result: ListeningCardsResult) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        let byID = Dictionary(uniqueKeysWithValues: result.cards.compactMap { card in
            UUID(uuidString: card.requestID).map { ($0, card) }
        })
        guard byID.count == points.count, points.allSatisfy({ byID[$0.id] != nil }) else { throw AIStudyError.invalidResponse }
        let priorSentence = data.audioMaterials[m].sentences[s]
        let priorCards = data.cards

        // A regenerated sentence may have unconfirmed drafts from an earlier run.
        // Detach only this sentence's source; cards shared with other sources survive.
        let oldDraftIDs = Set((priorSentence.learningPoints ?? []).map(\.cardID))
        for index in data.cards.indices.reversed() where oldDraftIDs.contains(data.cards[index].id) &&
                data.cards[index].deletedAt == nil && data.cards[index].confirmedAt == nil {
            data.cards[index].sources.removeAll { $0.materialID == materialID && $0.segmentID == sentenceID }
            if data.cards[index].sources.isEmpty { data.cards.remove(at: index) }
        }

        var links: [ListeningLearningPoint] = []
        for point in points {
            guard let generated = byID[point.id] else { continue }
            let key = Self.normalizedMergeKey(generated.mergeKey)
            let source = SourceReference(materialID: materialID, segmentID: sentenceID,
                                         quote: priorSentence.transcript)
            let cardID: UUID
            if let existing = data.cards.firstIndex(where: {
                $0.deletedAt == nil && $0.category == generated.category &&
                Self.normalizedMergeKey($0.mergeKey ?? "") == key && !key.isEmpty
            }) {
                cardID = data.cards[existing].id
                let alreadyLinked = data.cards[existing].sources.contains {
                    $0.materialID == materialID && $0.segmentID == sentenceID
                }
                if !alreadyLinked { data.cards[existing].sources.append(source) }
                data.cards[existing].updatedAt = .now
            } else {
                cardID = UUID()
                let draft = CardContentNormalizer.normalize(CardDraft(
                    category: generated.category, mergeKey: key,
                    question: generated.question, answer: generated.answer))
                data.cards.append(StudyCard(id: cardID, category: generated.category,
                                            title: CardContentNormalizer.title(for: draft, auditedTitle: generated.title),
                                            question: draft.question, answer: draft.answer,
                                            sources: [source], confirmedAt: nil, dueAt: nil,
                                            fsrsState: nil, createdAt: .now, updatedAt: .now,
                                            revisionCount: 0, mergeKey: key))
            }
            links.append(ListeningLearningPoint(id: point.id, category: generated.category,
                                                prompt: point.prompt, cardID: cardID))
        }
        data.audioMaterials[m].sentences[s].learningPoints = links
        do { try save() } catch {
            data.audioMaterials[m].sentences[s] = priorSentence
            data.cards = priorCards
            throw error
        }
    }

    private static func readingCardQuestion(_ card: ReadingCardsResult.Card) -> String {
        let proposed = card.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard card.category == .vocabulary else { return proposed }
        let parts = card.mergeKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return proposed }
        let word = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”‘’¿?：:"))
        return word.isEmpty ? proposed : word
    }

    private static func normalizedMergeKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
    }

    func updateCardDraft(_ cardID: UUID, category: CardCategory, question: String, answer: String,
                         title: String? = nil) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.cards.firstIndex(where: { $0.id == cardID }) else { throw StoreError.missingCard }
        guard data.cards[index].confirmedAt == nil, data.cards[index].deletedAt == nil else { throw StoreError.cardConfirmed }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, !cleanAnswer.isEmpty else { throw StoreError.emptyCard }
        let previous = data.cards[index]
        data.cards[index].category = category
        data.cards[index].question = cleanQuestion
        data.cards[index].answer = cleanAnswer
        let draft = CardDraft(category: category, mergeKey: data.cards[index].mergeKey ?? "",
                              question: cleanQuestion, answer: cleanAnswer)
        data.cards[index].title = CardContentNormalizer.title(for: draft, auditedTitle: title)
        data.cards[index].updatedAt = .now
        data.cards[index].revisionCount = (data.cards[index].revisionCount ?? 0) + 1
        do { try save() } catch { data.cards[index] = previous; throw error }
    }

    func confirmCard(_ cardID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.cards.firstIndex(where: { $0.id == cardID }) else { throw StoreError.missingCard }
        let previous = data.cards[index]
        data.cards[index].confirmedAt = .now
        data.cards[index].dueAt = .now
        data.cards[index].updatedAt = .now
        do { try save() } catch { data.cards[index] = previous; throw error }
    }

    func updateCardContent(_ cardID: UUID, title: String, question: String, answer: String) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.cards.firstIndex(where: { $0.id == cardID }),
              data.cards[index].deletedAt == nil else { throw StoreError.missingCard }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = CardContentNormalizer.normalize(CardDraft(
            category: data.cards[index].category, mergeKey: data.cards[index].mergeKey ?? "",
            question: question, answer: answer))
        guard !cleanTitle.isEmpty, !draft.question.isEmpty, !draft.answer.isEmpty else { throw StoreError.emptyCard }
        let previous = data.cards[index]
        data.cards[index].title = cleanTitle
        data.cards[index].question = draft.question
        data.cards[index].answer = draft.answer
        data.cards[index].updatedAt = .now
        data.cards[index].revisionCount = (data.cards[index].revisionCount ?? 0) + 1
        do { try save() } catch { data.cards[index] = previous; throw error }
    }

    func moveCardToTrash(_ cardID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.cards.firstIndex(where: { $0.id == cardID }),
              data.cards[index].deletedAt == nil else { throw StoreError.missingCard }
        let previous = data.cards[index]
        data.cards[index].deletedAt = .now
        data.cards[index].updatedAt = .now
        do { try save() } catch { data.cards[index] = previous; throw error }
    }

    func restoreCard(_ cardID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard let index = data.cards.firstIndex(where: { $0.id == cardID }),
              data.cards[index].deletedAt != nil else { throw StoreError.missingCard }
        let previous = data.cards[index]
        data.cards[index].deletedAt = nil
        data.cards[index].updatedAt = .now
        do { try save() } catch { data.cards[index] = previous; throw error }
    }

    func reviewCard(_ cardID: UUID, grade: ReviewGrade, now: Date = .now) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let index = data.cards.firstIndex(where: { $0.id == cardID }) else { throw StoreError.missingCard }
        guard data.cards[index].confirmedAt != nil, data.cards[index].deletedAt == nil else { throw StoreError.unconfirmedCard }
        let priorCard = data.cards[index]
        let result = try LocalFSRSScheduler.schedule(card: priorCard, grade: grade, now: now)
        let event = ReviewEvent(id: UUID(), cardID: cardID, reviewedAt: now,
                                grade: grade.rawValue, nextDueAt: result.dueAt,
                                scheduledDays: result.scheduledDays, elapsedDays: result.elapsedDays)
        data.cards[index].fsrsState = result.state
        data.cards[index].dueAt = result.dueAt
        data.cards[index].updatedAt = now
        data.reviewEvents.append(event)
        do { try save() } catch {
            data.cards[index] = priorCard
            data.reviewEvents.removeAll { $0.id == event.id }
            throw error
        }
    }

    func startRetry(materialID: UUID, sentenceID: UUID) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let (m, s) = sentenceLocation(materialID: materialID, sentenceID: sentenceID) else { throw StoreError.missingSentence }
        let previous = data.audioMaterials[m].sentences[s]
        data.audioMaterials[m].sentences[s].draftText = nil
        data.audioMaterials[m].sentences[s].answerRevealed = false
        do { try save() } catch { data.audioMaterials[m].sentences[s] = previous; throw error }
    }

    private func sentenceLocation(materialID: UUID, sentenceID: UUID) -> (Int, Int)? {
        guard let m = data.audioMaterials.firstIndex(where: { $0.id == materialID }),
              let s = data.audioMaterials[m].sentences.firstIndex(where: { $0.id == sentenceID }) else { return nil }
        return (m, s)
    }

    struct WritingSaveResult {
        let exerciseID: UUID
        let versionID: UUID
        let cardID: UUID?
    }

    @discardableResult
    func saveWritingFeedback(exerciseID requestedID: UUID?, mode: WritingMode,
                             sourceID: UUID?, sourceSegmentID: UUID?, sourceQuote: String?,
                             chinesePrompt: String, referenceSpanish: String?, focus: String?,
                             learnerSpanish: String, result: WritingFeedbackResult,
                             submittedAt: Date = .now) throws -> WritingSaveResult {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        let prompt = chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let spanish = learnerSpanish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !spanish.isEmpty else { throw StoreError.emptyWriting }
        let priorExercises = data.writingExercises
        let priorCards = data.cards
        let exerciseID = requestedID ?? UUID()
        let exerciseIndex: Int
        if let requestedID {
            guard let index = data.writingExercises.firstIndex(where: { $0.id == requestedID }) else {
                throw StoreError.missingWritingExercise
            }
            exerciseIndex = index
        } else {
            data.writingExercises.append(WritingExercise(id: exerciseID, sourceID: sourceID,
                                                          chinesePrompt: prompt, versions: [],
                                                          sourceSegmentID: sourceSegmentID,
                                                          sourceQuote: sourceQuote,
                                                          referenceSpanish: referenceSpanish,
                                                          focus: focus, createdAt: submittedAt,
                                                          mode: mode))
            exerciseIndex = data.writingExercises.count - 1
        }

        let versionID = UUID()
        var correctionCardID: UUID?
        if result.card.create {
            let key = Self.normalizedMergeKey(result.card.mergeKey)
            let question = result.card.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = result.card.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !question.isEmpty, !answer.isEmpty {
                let source = SourceReference(materialID: exerciseID, segmentID: versionID, quote: spanish)
                if let existing = data.cards.firstIndex(where: {
                    $0.deletedAt == nil && $0.category == .correction &&
                    Self.normalizedMergeKey($0.mergeKey ?? "") == key
                }) {
                    correctionCardID = data.cards[existing].id
                    if !data.cards[existing].sources.contains(where: {
                        $0.materialID == exerciseID && $0.segmentID == versionID
                    }) {
                        data.cards[existing].sources.append(source)
                    }
                    data.cards[existing].updatedAt = submittedAt
                } else {
                    let id = UUID()
                    correctionCardID = id
                    let draft = CardContentNormalizer.normalize(CardDraft(
                        category: .correction, mergeKey: key, question: question, answer: answer))
                    data.cards.append(StudyCard(id: id, category: .correction,
                                                title: CardContentNormalizer.title(for: draft, auditedTitle: result.card.title),
                                                question: draft.question, answer: draft.answer,
                                                sources: [source], confirmedAt: nil,
                                                dueAt: nil, fsrsState: nil,
                                                createdAt: submittedAt, updatedAt: submittedAt,
                                                revisionCount: 0, mergeKey: key))
                }
            }
        }

        let errors = result.errors.map {
            WritingError(id: UUID(), original: $0.original,
                         correction: $0.correction, explanation: $0.explanation)
        }
        let version = WritingVersion(id: versionID, submittedAt: submittedAt,
                                     spanishText: spanish, feedback: result.feedback,
                                     meaningScore: result.scores.meaning,
                                     grammarScore: result.scores.grammar,
                                     wordingScore: result.scores.wording,
                                     naturalnessScore: result.scores.naturalness,
                                     correctedSpanish: result.correctedSpanish,
                                     errors: errors, cardID: correctionCardID)
        data.writingExercises[exerciseIndex].versions.append(version)
        do { try save() } catch {
            data.writingExercises = priorExercises
            data.cards = priorCards
            throw error
        }
        return WritingSaveResult(exerciseID: exerciseID, versionID: versionID, cardID: correctionCardID)
    }

    @discardableResult
    func saveReadingDiscussion(articleID: UUID, chunkID: UUID,
                               question: String, answer: String,
                               askedAt: Date = .now) throws -> UUID {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let articleIndex = data.articles.firstIndex(where: { $0.id == articleID }),
              let chunkIndex = data.articles[articleIndex].chunks.firstIndex(where: { $0.id == chunkID }) else {
            throw StoreError.missingReadingChunk
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, !cleanAnswer.isEmpty else { throw StoreError.emptyReadingQuestion }
        let item = ReadingDiscussionItem(id: UUID(), askedAt: askedAt,
                                         question: cleanQuestion, answer: cleanAnswer)
        let previous = data.articles[articleIndex].chunks[chunkIndex].discussion
        if data.articles[articleIndex].chunks[chunkIndex].discussion == nil {
            data.articles[articleIndex].chunks[chunkIndex].discussion = []
        }
        data.articles[articleIndex].chunks[chunkIndex].discussion?.append(item)
        do { try save() } catch {
            data.articles[articleIndex].chunks[chunkIndex].discussion = previous
            throw error
        }
        return item.id
    }

    func pendingReadingDiscussions(articleID: UUID, chunkID: UUID) -> [ReadingDiscussionItem] {
        guard let chunk = data.articles.first(where: { $0.id == articleID })?
            .chunks.first(where: { $0.id == chunkID }) else { return [] }
        let processed = Set(data.readingRecords
            .filter { $0.articleID == articleID && $0.chunkID == chunkID }
            .flatMap { $0.discussionIDs ?? [] })
        return (chunk.discussion ?? []).filter { !processed.contains($0.id) }
    }

    func completeReadingWithCards(articleID: UUID, chunkID: UUID,
                                  difficulty: ReadingDifficulty, note: String,
                                  result: ReadingCardsResult?, completedAt: Date = .now) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        guard let articleIndex = data.articles.firstIndex(where: { $0.id == articleID }),
              let chunkIndex = data.articles[articleIndex].chunks.firstIndex(where: { $0.id == chunkID }) else {
            throw StoreError.missingReadingChunk
        }
        let discussion = pendingReadingDiscussions(articleID: articleID, chunkID: chunkID)
        let priorRecords = data.readingRecords
        let priorCards = data.cards
        var cardIDs: [UUID] = []
        if let result {
            let generatedByID = Dictionary(uniqueKeysWithValues: result.cards.compactMap { card in
                UUID(uuidString: card.discussionID).map { ($0, card) }
            })
            guard generatedByID.count == discussion.count,
                  discussion.allSatisfy({ generatedByID[$0.id] != nil }) else { throw AIStudyError.invalidResponse }
            for item in discussion {
                guard let generated = generatedByID[item.id], generated.create else { continue }
                let key = Self.normalizedMergeKey(generated.mergeKey)
                let question = Self.readingCardQuestion(generated)
                let answer = generated.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !question.isEmpty, !answer.isEmpty else { throw AIStudyError.invalidResponse }
                let source = SourceReference(materialID: articleID, segmentID: chunkID,
                                             quote: data.articles[articleIndex].chunks[chunkIndex].text)
                let cardID: UUID
                if let existing = data.cards.firstIndex(where: {
                    $0.deletedAt == nil && $0.category == generated.category &&
                    Self.normalizedMergeKey($0.mergeKey ?? "") == key
                }) {
                    cardID = data.cards[existing].id
                    if !data.cards[existing].sources.contains(where: {
                        $0.materialID == articleID && $0.segmentID == chunkID
                    }) {
                        data.cards[existing].sources.append(source)
                    }
                    data.cards[existing].updatedAt = completedAt
                } else {
                    cardID = UUID()
                    let draft = CardContentNormalizer.normalize(CardDraft(
                        category: generated.category, mergeKey: key,
                        question: question, answer: answer))
                    data.cards.append(StudyCard(id: cardID, category: generated.category,
                                                title: CardContentNormalizer.title(for: draft, auditedTitle: generated.title),
                                                question: draft.question, answer: draft.answer,
                                                sources: [source], confirmedAt: nil,
                                                dueAt: nil, fsrsState: nil,
                                                createdAt: completedAt, updatedAt: completedAt,
                                                revisionCount: 0, mergeKey: key))
                }
                if !cardIDs.contains(cardID) { cardIDs.append(cardID) }
            }
        }
        let record = ReadingRecord(id: UUID(), articleID: articleID, chunkID: chunkID,
                                   completedAt: completedAt, difficulty: difficulty,
                                   questions: discussion.map(\.question), note: note,
                                   discussionIDs: discussion.map(\.id), cardIDs: cardIDs)
        upsertReadingRecord(record)
        do { try save() } catch {
            data.readingRecords = priorRecords
            data.cards = priorCards
            throw error
        }
    }

    func addArticle(title: String, source: String, text: String) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanText.isEmpty else { throw StoreError.emptyArticle }
        let chunks = ArticleSplitter.split(cleanText).enumerated().map { index, chunk in
            ReadingChunk(id: UUID(), ordinal: index + 1, text: chunk)
        }
        let article = ReadingArticle(id: UUID(), title: cleanTitle, source: source,
                                     originalText: cleanText, importedAt: .now, chunks: chunks)
        data.articles.append(article)
        do { try save() } catch { data.articles.removeAll { $0.id == article.id }; throw error }
    }

    func resegmentUnstudiedArticles() throws {
        guard canWrite, !transferInProgress else { return }
        let previousArticles = data.articles
        var changed = false
        for index in data.articles.indices {
            let article = data.articles[index]
            let hasReferences = data.readingRecords.contains { $0.articleID == article.id } ||
                data.cards.contains { card in card.sources.contains { $0.materialID == article.id } } ||
                data.writingExercises.contains { $0.sourceID == article.id } ||
                article.chunks.contains { !($0.discussion ?? []).isEmpty }
            guard !hasReferences else { continue }
            let pieces = ArticleSplitter.split(article.originalText)
            guard pieces != article.chunks.map(\.text) else { continue }
            data.articles[index].chunks = pieces.enumerated().map { position, text in
                ReadingChunk(id: UUID(), ordinal: position + 1, text: text)
            }
            changed = true
        }
        guard changed else { return }
        do { try save() } catch { data.articles = previousArticles; throw error }
    }

    func completeReading(articleID: UUID, chunkID: UUID, difficulty: ReadingDifficulty,
                         questions: [String], note: String) throws {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        let record = ReadingRecord(id: UUID(), articleID: articleID, chunkID: chunkID,
                                   completedAt: .now, difficulty: difficulty,
                                   questions: questions, note: note)
        let priorRecords = data.readingRecords
        upsertReadingRecord(record)
        do { try save() } catch { data.readingRecords = priorRecords; throw error }
    }

    private func upsertReadingRecord(_ record: ReadingRecord) {
        data.readingRecords = Self.consolidatedReadingRecords(data.readingRecords + [record])
    }

    private static func consolidatedReadingRecords(_ records: [ReadingRecord]) -> [ReadingRecord] {
        struct Key: Hashable { let articleID: UUID; let chunkID: UUID }
        var result: [ReadingRecord] = []
        var positions: [Key: Int] = [:]
        for record in records {
            let key = Key(articleID: record.articleID, chunkID: record.chunkID)
            if let index = positions[key] {
                var current = result[index]
                current.questions = unique(current.questions + record.questions)
                current.discussionIDs = unique((current.discussionIDs ?? []) + (record.discussionIDs ?? []))
                current.cardIDs = unique((current.cardIDs ?? []) + (record.cardIDs ?? []))
                if record.completedAt >= current.completedAt {
                    current.completedAt = record.completedAt
                    current.difficulty = record.difficulty
                }
                if !record.note.isEmpty && !current.note.components(separatedBy: "\n").contains(record.note) {
                    current.note += current.note.isEmpty ? record.note : "\n" + record.note
                }
                result[index] = current
            } else {
                positions[key] = result.count
                result.append(record)
            }
        }
        return result
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    @discardableResult
    func createAutomaticBackup(now: Date = .now) async throws -> URL? {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { return nil }
        let hasContent = !data.audioMaterials.isEmpty || !data.articles.isEmpty ||
            !data.readingRecords.isEmpty || !data.dictationAttempts.isEmpty ||
            !data.writingExercises.isEmpty || !data.cards.isEmpty
        guard hasContent else { return nil }
        transferInProgress = true
        defer { transferInProgress = false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let directory = supportDirectory.deletingLastPathComponent()
            .appendingPathComponent("SpanishLearningMac Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("自动备份-\(formatter.string(from: now)).zip")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(data)
        let media = mediaDirectory
        _ = try await Task.detached(priority: .utility) {
            try BackupManager.create(database: payload, mediaDirectory: media, destination: destination)
        }.value
        let automatic = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]))?.filter {
                $0.lastPathComponent.hasPrefix("自动备份-") && $0.pathExtension.lowercased() == "zip"
            }.sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            } ?? []
        for old in automatic.dropFirst(14) { try? FileManager.default.removeItem(at: old) }
        return destination
    }

    func createBackup(at destination: URL) async throws -> BackupSummary {
        guard canWrite else { throw StoreError.readOnly }
        guard !transferInProgress else { throw BackupError.busy }
        transferInProgress = true
        defer { transferInProgress = false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(data)
        let media = mediaDirectory
        return try await Task.detached(priority: .userInitiated) {
            try BackupManager.create(database: payload, mediaDirectory: media, destination: destination)
        }.value
    }

    func inspectBackup(at archive: URL) async throws -> BackupSummary {
        guard !transferInProgress else { throw BackupError.busy }
        transferInProgress = true
        defer { transferInProgress = false }
        return try await Task.detached(priority: .userInitiated) {
            try BackupManager.inspect(archive)
        }.value
    }

    func restoreBackup(at archive: URL) async throws -> URL? {
        guard !transferInProgress else { throw BackupError.busy }
        transferInProgress = true
        defer { transferInProgress = false }
        let directory = supportDirectory
        let safety = try await Task.detached(priority: .userInitiated) {
            try BackupManager.restore(archive, supportDirectory: directory)
        }.value
        let payload = try Data(contentsOf: databaseURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        data = try decoder.decode(StudyDatabase.self, from: payload)
        canWrite = true
        errorMessage = nil
        return safety
    }

    private func save() throws {
        guard canWrite else { throw StoreError.readOnly }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(data)
        try payload.write(to: databaseURL, options: .atomic)
        objectWillChange.send()
    }
}

enum StoreError: LocalizedError {
    case unsupportedVersion
    case emptyArticle
    case readOnly
    case missingMaterial
    case missingSentence
    case invalidSentence
    case transcriptionLocked
    case transcriptionIncomplete
    case transcriptionUsesSubtitles
    case subtitleReferenceRequiresSpeech
    case sentenceReferenced
    case noSpeech
    case missingCard
    case cardConfirmed
    case emptyCard
    case unconfirmedCard
    case invalidReviewGrade
    case emptyWriting
    case missingWritingExercise
    case missingReadingChunk
    case emptyReadingQuestion
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "资料格式比当前应用更新，请使用新版应用打开。"
        case .emptyArticle: "请输入文章标题和正文。"
        case .readOnly: "资料读取失败，当前会话只读。请先修复或备份原始资料文件。"
        case .missingMaterial: "找不到这段音频。"
        case .missingSentence: "找不到这句话。"
        case .invalidSentence: "请检查句子文本和起止时间。"
        case .transcriptionLocked: "已有听写记录，不能重新覆盖整份转写。你仍可逐句修正。"
        case .transcriptionIncomplete: "请等整段音频转写完成后再确认。"
        case .transcriptionUsesSubtitles: "此素材已使用字幕时间轴，不会再运行本机转写。"
        case .subtitleReferenceRequiresSpeech: "字幕只作为文字参考；请先运行本机语音识别生成音频时间轴。"
        case .sentenceReferenced: "这句话已有听写或卡片记录，不能改变切句。仍可修改文字和时间。"
        case .noSpeech: "这段音频没有识别出西语语音。请检查音频后重试。"
        case .missingCard: "找不到这张卡片。"
        case .cardConfirmed: "已确认的卡片不能再作为草稿修改。"
        case .emptyCard: "卡片问题和答案都不能为空。"
        case .unconfirmedCard: "请先确认卡片，再开始复习。"
        case .invalidReviewGrade: "无法识别这次复习评分。"
        case .emptyWriting: "请先准备中文题目并写下西语答案。"
        case .missingWritingExercise: "找不到这道写作练习。"
        case .missingReadingChunk: "找不到当前文章段落。"
        case .emptyReadingQuestion: "请先写下精读问题。"
        }
    }
}

enum ArticleSplitter {
    private struct Sentence {
        let text: String
        let wordCount: Int
        var endsParagraph: Bool
    }

    static func split(_ text: String, targetWords: Int = 100) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines)
            .reduce(into: [(text: String, endsParagraph: Bool)]()) { result, line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    if !result.isEmpty { result[result.count - 1].endsParagraph = true }
                    return
                }
                if let last = result.last, !last.endsParagraph {
                    result[result.count - 1].text += " " + value
                } else {
                    result.append((value, false))
                }
            }
        let sentences = paragraphs.flatMap { sentenceParts(in: $0.text, endsParagraph: $0.endsParagraph) }
        guard !sentences.isEmpty else { return [text] }

        var chunks: [[Sentence]] = []
        var current: [Sentence] = []
        var currentWords = 0
        for sentence in sentences {
            let combinedWords = currentWords + sentence.wordCount
            let shouldCutBefore = !current.isEmpty &&
                (current.last?.endsParagraph == true ||
                 abs(currentWords - targetWords) <= abs(combinedWords - targetWords))
            if shouldCutBefore {
                chunks.append(current)
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += sentence.wordCount
        }
        if !current.isEmpty { chunks.append(current) }

        return chunks.map { $0.map(\.text).joined(separator: " ") }
    }

    private static func sentenceParts(in paragraph: String, endsParagraph: Bool) -> [Sentence] {
        var result: [Sentence] = []
        var start = paragraph.startIndex
        var index = start
        while index < paragraph.endIndex {
            let character = paragraph[index]
            guard ".!?。！？".contains(character) else {
                index = paragraph.index(after: index)
                continue
            }
            var end = paragraph.index(after: index)
            while end < paragraph.endIndex && "!?。！？".contains(paragraph[end]) {
                end = paragraph.index(after: end)
            }
            if character == "." && !isSentencePeriod(paragraph, at: index) {
                index = end
                continue
            }
            let value = paragraph[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                result.append(Sentence(text: String(value),
                                       wordCount: value.split(whereSeparator: \.isWhitespace).count,
                                       endsParagraph: false))
            }
            start = end
            index = end
        }
        let tail = paragraph[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(Sentence(text: String(tail),
                                   wordCount: tail.split(whereSeparator: \.isWhitespace).count,
                                   endsParagraph: false))
        }
        if let last = result.indices.last { result[last].endsParagraph = endsParagraph }
        return result
    }

    private static func isSentencePeriod(_ text: String, at index: String.Index) -> Bool {
        let before = index > text.startIndex ? text[text.index(before: index)] : nil
        let afterIndex = text.index(after: index)
        let after = afterIndex < text.endIndex ? text[afterIndex] : nil
        if before?.isNumber == true && after?.isNumber == true { return false }
        let prefix = text[..<index].split(whereSeparator: { $0.isWhitespace || ",;:()[]¿¡".contains($0) }).last.map(String.init) ?? ""
        let abbreviations = ["Sr", "Sra", "Dr", "Dra", "etc", "p", "pág", "aprox"]
        if abbreviations.contains(prefix) { return false }
        return after == nil || after!.isWhitespace || "¿¡\"'".contains(after!)
    }
}
