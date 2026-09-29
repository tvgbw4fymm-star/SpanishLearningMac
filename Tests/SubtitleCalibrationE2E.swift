import Foundation

@main
@MainActor
struct SubtitleCalibrationE2E {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: SubtitleCalibrationE2E <audio> <srt>\n", stderr)
            exit(2)
        }
        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let subtitleURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishSubtitleWorkflowE2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let subtitleFirst = try makeStore(
            name: "subtitle-first", baseDirectory: root, audioURL: audioURL,
            subtitleURL: subtitleURL, importSubtitle: true
        )
        guard let subtitleFirstID = subtitleFirst.data.audioMaterials.first?.id else {
            throw StoreError.missingMaterial
        }
        let subtitleFirstCueCount = subtitleFirst.data.audioMaterials[0].referenceSubtitleCues?.count ?? 0
        try subtitleFirst.startTranscription(materialID: subtitleFirstID)
        try await waitForCompletion(subtitleFirst, materialID: subtitleFirstID)
        let subtitleFirstMaterial = try material(in: subtitleFirst, id: subtitleFirstID)
        precondition(subtitleFirstCueCount == 79 && subtitleFirstMaterial.sentences.count == 79,
                     "MP3 → SRT → Speech must produce one final sentence for every subtitle cue")
        precondition(subtitleFirstMaterial.segmentationSource == .subtitleCalibrated,
                     "Subtitle-first workflow must select calibrated subtitle sentences")
        validateSubtitleMaterial(subtitleFirstMaterial)
        print("WORKFLOW_A_MP3_SRT_SPEECH")
        print("subtitleCueCount=\(subtitleFirstCueCount)")
        print("rawSpeechSegments=\(subtitleFirstMaterial.speechTimingAnchors?.count ?? 0)")
        print("finalSentenceCount=\(subtitleFirstMaterial.sentences.count)")
        print("status=\(subtitleFirst.transcriptionStatus[subtitleFirstID] ?? "completed")")
        printCueOne(subtitleFirstMaterial)

        let speechFirst = try makeStore(
            name: "speech-first", baseDirectory: root, audioURL: audioURL,
            subtitleURL: subtitleURL, importSubtitle: false
        )
        guard let speechFirstID = speechFirst.data.audioMaterials.first?.id else {
            throw StoreError.missingMaterial
        }
        try speechFirst.startTranscription(materialID: speechFirstID)
        try await waitForCompletion(speechFirst, materialID: speechFirstID)
        let speechFirstSentenceCount = speechFirst.data.audioMaterials[0].sentences.count
        precondition(speechFirstSentenceCount > 0, "Speech-first workflow must retain its initial native transcript")
        try speechFirst.importSubtitles(from: subtitleURL, materialID: speechFirstID)
        let afterSubtitleImport = try material(in: speechFirst, id: speechFirstID)
        precondition(afterSubtitleImport.sentences.count == speechFirstSentenceCount &&
                     afterSubtitleImport.referenceSubtitleCues?.count == 79 &&
                     speechFirst.canRecalibrateSubtitles(materialID: speechFirstID),
                     "Importing subtitles after Speech must preserve the Speech transcript and offer explicit recalibration")
        try speechFirst.startSubtitleCalibration(materialID: speechFirstID)
        try await waitForCompletion(speechFirst, materialID: speechFirstID)
        let speechFirstMaterial = try material(in: speechFirst, id: speechFirstID)
        precondition(speechFirstMaterial.sentences.count == 79 &&
                     speechFirstMaterial.segmentationSource == .subtitleCalibrated,
                     "Explicit post-transcription calibration must replace native sentence segmentation with 79 cues")
        validateSubtitleMaterial(speechFirstMaterial)
        print("WORKFLOW_B_MP3_SPEECH_SRT_EXPLICIT_CALIBRATION")
        print("initialSpeechSentenceCount=\(speechFirstSentenceCount)")
        print("subtitleCueCount=\(speechFirstMaterial.referenceSubtitleCues?.count ?? 0)")
        print("rawSpeechSegments=\(speechFirstMaterial.speechTimingAnchors?.count ?? 0)")
        print("finalSentenceCount=\(speechFirstMaterial.sentences.count)")
        print("status=\(speechFirst.transcriptionStatus[speechFirstID] ?? "completed")")
        printCueOne(speechFirstMaterial)

        let speechOnly = try makeStore(
            name: "speech-only", baseDirectory: root, audioURL: audioURL,
            subtitleURL: subtitleURL, importSubtitle: false
        )
        guard let speechOnlyID = speechOnly.data.audioMaterials.first?.id else {
            throw StoreError.missingMaterial
        }
        try speechOnly.startTranscription(materialID: speechOnlyID)
        try await waitForCompletion(speechOnly, materialID: speechOnlyID)
        let speechOnlyMaterial = try material(in: speechOnly, id: speechOnlyID)
        precondition(speechOnlyMaterial.referenceSubtitleCues == nil &&
                     speechOnlyMaterial.segmentationSource == .speech &&
                     !speechOnlyMaterial.sentences.isEmpty,
                     "MP3-only workflow must retain native Speech segmentation")
        print("WORKFLOW_C_MP3_ONLY")
        print("subtitleCueCount=0")
        print("rawSpeechSegments=\(speechOnlyMaterial.speechTimingAnchors?.count ?? 0)")
        print("finalSpeechSentenceCount=\(speechOnlyMaterial.sentences.count)")
        print("status=\(speechOnly.transcriptionStatus[speechOnlyID] ?? "completed")")

        print("AI=disabled")
        print("temporaryStudyStores=\(root.path)")
    }

    private static func makeStore(name: String, baseDirectory: URL, audioURL: URL, subtitleURL: URL,
                                 importSubtitle: Bool) throws -> StudyStore {
        let root = baseDirectory.appendingPathComponent(name, isDirectory: true)
        let store = StudyStore(baseDirectory: root)
        try store.importAudio(from: audioURL)
        guard let materialID = store.data.audioMaterials.first?.id else {
            throw StoreError.missingMaterial
        }
        if importSubtitle {
            try store.importSubtitles(from: subtitleURL, materialID: materialID)
            guard store.data.audioMaterials[0].referenceSubtitleCues?.count == 79 else {
                throw NSError(domain: "SubtitleCalibrationE2E", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Expected 79 imported subtitle cues"])
            }
        }
        return store
    }

    private static func waitForCompletion(_ store: StudyStore, materialID: UUID) async throws {
        let deadline = Date().addingTimeInterval(600)
        while store.activeTranscriptions.contains(materialID), Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !store.activeTranscriptions.contains(materialID),
              let material = store.data.audioMaterials.first(where: { $0.id == materialID }),
              material.transcriptionComplete == true else {
            throw NSError(domain: "SubtitleCalibrationE2E", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            store.transcriptionStatus[materialID] ?? "Transcription timed out or did not complete"])
        }
    }

    private static func material(in store: StudyStore, id: UUID) throws -> AudioMaterial {
        guard let material = store.data.audioMaterials.first(where: { $0.id == id }) else {
            throw StoreError.missingMaterial
        }
        return material
    }

    private static func printCueOne(_ material: AudioMaterial) {
        guard let cue = material.sentences.first else { return }
        print("sentencePickerFirst=\(cue.ordinal)\t\(String(format: "%.3f", cue.startSeconds))–\(String(format: "%.3f", cue.endSeconds))\t\(cue.transcript)")
        precondition(cue.ordinal == 1 && cue.transcript == material.referenceSubtitleCues?.first?.text,
                     "Sentence picker must begin with subtitle cue 1, not a Speech-only segment")
    }

    private static func validateSubtitleMaterial(_ material: AudioMaterial) {
        let cues = material.referenceSubtitleCues ?? []
        precondition(material.sentences.count == cues.count, "Timed subtitle cue count changed")
        precondition(material.sentences.map(\.transcript) == cues.map(\.text),
                     "Final subtitle cue text does not match imported SRT")
        precondition(material.sentences.allSatisfy {
            $0.startSeconds.isFinite && $0.endSeconds.isFinite &&
                $0.startSeconds >= 0 && $0.startSeconds < $0.endSeconds &&
                $0.timingSource != nil && $0.timingConfidence != nil
        }, "Final calibrated cue timeline contains invalid time or missing provenance")
        precondition(zip(material.sentences, material.sentences.dropFirst()).allSatisfy {
            $0.0.startSeconds <= $0.1.startSeconds && $0.0.endSeconds <= $0.1.endSeconds
        }, "Final calibrated timeline regressed")
    }
}
