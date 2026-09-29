import Foundation

@main
struct WhisperStoreIntegration {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            fputs("usage: WhisperStoreIntegration <audio.mp3> <captions.srt> <installed-model-cache>\n", stderr)
            exit(2)
        }
        let audioURL = URL(fileURLWithPath: arguments[0])
        let subtitleURL = URL(fileURLWithPath: arguments[1])
        let modelCache = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("SpanishWhisperStudyStoreE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try attachModelCache(modelCache, to: root.appendingPathComponent("A/Models/WhisperKit", isDirectory: true))
        let subtitleFirst = StudyStore(baseDirectory: root.appendingPathComponent("A", isDirectory: true))
        try subtitleFirst.importAudio(from: audioURL)
        let firstID = try materialID(in: subtitleFirst)
        try subtitleFirst.importSubtitles(from: subtitleURL, materialID: firstID)
        let cueCount = subtitleFirst.data.audioMaterials[0].referenceSubtitleCues?.count ?? 0
        try subtitleFirst.startTranscription(materialID: firstID)
        try await waitForCompletion(store: subtitleFirst, materialID: firstID)
        let first = try material(in: subtitleFirst, id: firstID)
        try assertSubtitleResult(first, cueCount: cueCount)
        report("A", material: first, beforeCalibrationCount: nil, status: subtitleFirst.transcriptionStatus[firstID])
        let restartedStore = StudyStore(baseDirectory: root.appendingPathComponent("A", isDirectory: true))
        guard restartedStore.whisperModelInstalled,
              try material(in: restartedStore, id: firstID).sentences.count == cueCount else {
            throw E2EError.assertion("The completed result or installed model was not restored after a StudyStore restart")
        }

        try attachModelCache(modelCache, to: root.appendingPathComponent("B/Models/WhisperKit", isDirectory: true))
        let speechFirst = StudyStore(baseDirectory: root.appendingPathComponent("B", isDirectory: true))
        try speechFirst.importAudio(from: audioURL)
        let secondID = try materialID(in: speechFirst)
        try speechFirst.startTranscription(materialID: secondID)
        try await waitForCompletion(store: speechFirst, materialID: secondID)
        let speechOnly = try material(in: speechFirst, id: secondID)
        guard speechOnly.segmentationSource == .speech, !speechOnly.sentences.isEmpty else {
            throw E2EError.assertion("MP3-only phase did not produce Speech-only sentences")
        }
        let speechSentenceCount = speechOnly.sentences.count
        let originalIDs = speechOnly.sentences.map(\.id)
        try speechFirst.importSubtitles(from: subtitleURL, materialID: secondID)
        guard try material(in: speechFirst, id: secondID).sentences.map(\.id) == originalIDs else {
            throw E2EError.assertion("Importing subtitles changed the Speech sentences before explicit recalibration")
        }
        try speechFirst.startWhisperSubtitleRecalibration(materialID: secondID)
        try await waitForCompletion(store: speechFirst, materialID: secondID)
        let recalibrated = try material(in: speechFirst, id: secondID)
        try assertSubtitleResult(recalibrated, cueCount: cueCount)
        report("B", material: recalibrated, beforeCalibrationCount: speechSentenceCount,
               status: speechFirst.transcriptionStatus[secondID])

        try attachModelCache(modelCache, to: root.appendingPathComponent("C/Models/WhisperKit", isDirectory: true))
        let audioOnly = StudyStore(baseDirectory: root.appendingPathComponent("C", isDirectory: true))
        try audioOnly.importAudio(from: audioURL)
        let thirdID = try materialID(in: audioOnly)
        try audioOnly.startTranscription(materialID: thirdID)
        try await waitForCompletion(store: audioOnly, materialID: thirdID)
        let speechResult = try material(in: audioOnly, id: thirdID)
        guard speechResult.segmentationSource == .speech,
              speechResult.referenceSubtitleCues == nil,
              !speechResult.sentences.isEmpty else {
            throw E2EError.assertion("MP3-only workflow did not stay on the local speech pipeline")
        }
        try assertValidTimings(speechResult)
        report("C", material: speechResult, beforeCalibrationCount: nil,
               status: audioOnly.transcriptionStatus[thirdID])

        print("studyStoreRoot=\(root.path)")
        print("modelCacheReusedAcrossStoreRestart=true")
        print("aiInvoked=false")
    }

    @MainActor
    private static func waitForCompletion(store: StudyStore, materialID: UUID) async throws {
        for _ in 0..<3600 {
            if !store.activeTranscriptions.contains(materialID) {
                let material = try Self.material(in: store, id: materialID)
                guard material.transcriptionComplete == true, !material.sentences.isEmpty else {
                    throw E2EError.transcription(store.transcriptionStatus[materialID] ?? "Missing completion status")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw E2EError.assertion("Timed out waiting for transcription")
    }

    @MainActor
    private static func materialID(in store: StudyStore) throws -> UUID {
        guard let id = store.data.audioMaterials.first?.id else { throw StoreError.missingMaterial }
        return id
    }

    @MainActor
    private static func material(in store: StudyStore, id: UUID) throws -> AudioMaterial {
        guard let material = store.data.audioMaterials.first(where: { $0.id == id }) else {
            throw StoreError.missingMaterial
        }
        return material
    }

    private static func attachModelCache(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    private static func assertSubtitleResult(_ material: AudioMaterial, cueCount: Int) throws {
        guard cueCount > 0,
              material.sentences.count == cueCount,
              material.segmentationSource == .subtitleCalibrated,
              material.sentences.allSatisfy({
                  $0.transcript == $0.referenceSubtitleText &&
                      $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds &&
                      $0.endSeconds <= (material.transcribedThroughSeconds ?? -1) + 0.05
              }) else {
            throw E2EError.assertion("Expected one legal SRT-text sentence per subtitle cue")
        }
        try assertValidTimings(material)
    }

    private static func assertValidTimings(_ material: AudioMaterial) throws {
        var priorStart = -Double.infinity
        for sentence in material.sentences {
            guard sentence.startSeconds.isFinite, sentence.endSeconds.isFinite,
                  sentence.startSeconds >= 0, sentence.endSeconds > sentence.startSeconds,
                  sentence.startSeconds >= priorStart else {
                throw E2EError.assertion("A final sentence has invalid or regressing timing")
            }
            priorStart = sentence.startSeconds
        }
    }

    private static func report(
        _ workflow: String,
        material: AudioMaterial,
        beforeCalibrationCount: Int?,
        status: String?
    ) {
        let methods = Dictionary(grouping: material.sentences) {
            $0.whisperTimingMethod?.rawValue ?? "none"
        }.mapValues(\.count)
        let first = material.sentences.first
        print([
            "workflow=\(workflow)",
            "speechOnlyBeforeCalibration=\(beforeCalibrationCount.map(String.init) ?? "n/a")",
            "subtitleCues=\(material.referenceSubtitleCues?.count ?? 0)",
            "finalSentences=\(material.sentences.count)",
            "methods=\(methods)",
            "firstSentence=\(first?.transcript ?? "n/a")",
            String(format: "firstTiming=%.3f–%.3f", first?.startSeconds ?? -1, first?.endSeconds ?? -1),
            "status=\(status ?? "n/a")"
        ].joined(separator: " | "))
    }
}

enum E2EError: LocalizedError {
    case assertion(String)
    case transcription(String)

    var errorDescription: String? {
        switch self {
        case .assertion(let message), .transcription(let message): message
        }
    }
}
