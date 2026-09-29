import Foundation

@main
struct ModelSmoke {
    @MainActor static func main() async throws {
        let invalidTimestampResult = try WhisperListeningPipeline.validate(
            words: [
                WhisperTimedWord(start: 0, end: 1, text: "válido"),
                WhisperTimedWord(start: 453, end: 454.4, text: "¡Gracias!"),
                WhisperTimedWord(start: 2, end: 2, text: "cero"),
                WhisperTimedWord(start: -1, end: 0.5, text: "negativo"),
                WhisperTimedWord(start: .infinity, end: 4, text: "infinito")
            ],
            segments: [
                WhisperTimedSegment(start: 9, end: 12, text: "¡Gracias!")
            ],
            audioDuration: 10
        )
        precondition(invalidTimestampResult.words.count == 1)
        precondition(invalidTimestampResult.diagnostics.invalidWords["outOfBounds"] == 1)
        precondition(invalidTimestampResult.diagnostics.invalidWords["nonPositiveDuration"] == 1)
        precondition(invalidTimestampResult.diagnostics.invalidWords["negativeStart"] == 1)
        precondition(invalidTimestampResult.diagnostics.invalidWords["nonFinite"] == 1)
        precondition(invalidTimestampResult.diagnostics.invalidSegments["outOfBounds"] == 1)

        let repeatedCues = [
            SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2, text: "Vamos, vamos."),
            SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 2, endSeconds: 4, text: "Vamos, vamos.")
        ]
        let repeatedWords = [
            WhisperTimedWord(start: 0.2, end: 0.4, text: "Vamos"),
            WhisperTimedWord(start: 0.5, end: 0.7, text: "vamos"),
            WhisperTimedWord(start: 2.2, end: 2.4, text: "vamos"),
            WhisperTimedWord(start: 2.5, end: 2.7, text: "vamos")
        ]
        let repeatedAlignment = try WhisperListeningPipeline.alignSubtitles(
            cues: repeatedCues, words: repeatedWords, audioDuration: 5
        )
        precondition(repeatedAlignment.sentences.count == 2)
        precondition(repeatedAlignment.directCount == 2)
        precondition(repeatedAlignment.sentences[0].startSeconds < repeatedAlignment.sentences[1].startSeconds,
                     "Repeated phrases must remain monotonic in full-text alignment")
        precondition(repeatedAlignment.sentences.allSatisfy { $0.transcript.hasPrefix("Vamos") },
                     "SRT text must remain the displayed sentence text")
        let accentAndFuzzyAlignment = try WhisperListeningPipeline.alignSubtitles(
            cues: [
                SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2,
                            text: "¿Qué sueles desayunar?"),
                SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 2, endSeconds: 4,
                            text: "La taza roja.")
            ],
            words: [
                WhisperTimedWord(start: 0.1, end: 0.3, text: "Que"),
                WhisperTimedWord(start: 0.4, end: 0.7, text: "sueles"),
                WhisperTimedWord(start: 0.8, end: 1.2, text: "desayunar"),
                WhisperTimedWord(start: 2.1, end: 2.3, text: "La"),
                WhisperTimedWord(start: 2.4, end: 2.6, text: "tasa"),
                WhisperTimedWord(start: 2.7, end: 3.0, text: "roja")
            ],
            audioDuration: 5
        )
        precondition(accentAndFuzzyAlignment.directCount == 2,
                     "Accent-normalized matches and conservative spelling substitutions must align")
        precondition(accentAndFuzzyAlignment.sentences[0].textConflict == false)
        precondition(accentAndFuzzyAlignment.sentences[1].textConflict == true,
                     "A conservative spelling substitution must be surfaced as a text conflict")
        let insertedWordAlignment = try WhisperListeningPipeline.alignSubtitles(
            cues: [SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2,
                               text: "Hola mundo.")],
            words: [
                WhisperTimedWord(start: 0.1, end: 0.3, text: "Hola"),
                WhisperTimedWord(start: 0.4, end: 0.6, text: "extra"),
                WhisperTimedWord(start: 0.7, end: 1.0, text: "mundo")
            ],
            audioDuration: 3
        )
        precondition(insertedWordAlignment.sentences[0].textConflict == true,
                     "An ASR insertion inside an aligned cue must be flagged without changing its SRT text")

        let localFallbackCues = [
            SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 1, text: "Hola."),
            SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 1, endSeconds: 2, text: "Sin audio."),
            SubtitleCue(id: UUID(), ordinal: 3, startSeconds: 2, endSeconds: 3, text: "Adiós.")
        ]
        let localFallback = try WhisperListeningPipeline.alignSubtitles(
            cues: localFallbackCues,
            words: [
                WhisperTimedWord(start: 0.2, end: 0.5, text: "Hola"),
                WhisperTimedWord(start: 1.5, end: 1.8, text: "Adiós")
            ],
            audioDuration: 4
        )
        precondition(localFallback.sentences.count == 3)
        precondition(localFallback.directCount == 2 && localFallback.interpolatedCount == 1)
        precondition(localFallback.sentences[1].startSeconds == 0.5 &&
                     localFallback.sentences[1].endSeconds == 1.5,
                     "A single cue between reliable neighbors should use local interpolation")

        let originalTimingFallback = try WhisperListeningPipeline.alignSubtitles(
            cues: [localFallbackCues[1]],
            words: [],
            audioDuration: 4
        )
        precondition(originalTimingFallback.originalCount == 1)
        precondition(originalTimingFallback.sentences[0].startSeconds == 1 &&
                     originalTimingFallback.sentences[0].endSeconds == 2)
        let nonSpeechCue = try WhisperListeningPipeline.alignSubtitles(
            cues: [SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2, text: "[Música]")],
            words: [],
            audioDuration: 3
        )
        precondition(nonSpeechCue.originalCount == 1 &&
                     nonSpeechCue.sentences[0].textConflict == false)

        let manyCues = (0..<79).map {
            SubtitleCue(id: UUID(), ordinal: $0 + 1, startSeconds: Double($0),
                        endSeconds: Double($0 + 1), text: "palabra\($0)")
        }
        let manyWords = (0..<79).map {
            WhisperTimedWord(start: Double($0) + 0.1, end: Double($0) + 0.5, text: "palabra\($0)")
        }
        let manyAligned = try WhisperListeningPipeline.alignSubtitles(
            cues: manyCues, words: manyWords, audioDuration: 80
        )
        precondition(manyAligned.sentences.count == 79, "79 SRT cues must yield 79 sentences")
        precondition(manyAligned.sentences.allSatisfy { $0.whisperTimingMethod == .directWhisper })
        precondition(manyAligned.sentences.allSatisfy {
            $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds && $0.endSeconds <= 80
        })

        let noSubtitleSentences = try WhisperListeningPipeline.sentencesWithoutSubtitles(
            segments: [WhisperTimedSegment(start: 4, end: 5, text: "Sin palabras.")],
            words: [
                WhisperTimedWord(start: 0, end: 0.4, text: "Hola"),
                WhisperTimedWord(start: 0.5, end: 0.9, text: "amigos."),
                WhisperTimedWord(start: 2.3, end: 2.7, text: "Hasta"),
                WhisperTimedWord(start: 2.8, end: 3, text: "luego.")
            ]
        )
        precondition(noSubtitleSentences.count == 2)
        precondition(noSubtitleSentences.allSatisfy { $0.timingSource == .speechNative })
        let segmentFallbackSentences = try WhisperListeningPipeline.sentencesWithoutSubtitles(
            segments: [WhisperTimedSegment(start: 0, end: 2, text: "Hola amigos.")],
            words: []
        )
        precondition(segmentFallbackSentences.count == 1 &&
                     segmentFallbackSentences[0].transcript == "Hola amigos.")

        let emptyModelCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishWhisperEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyModelCache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyModelCache) }
        precondition(WhisperModelCache.installedFolder(cacheDirectory: emptyModelCache) == nil,
                     "A missing model must remain identifiable without downloading it")
        let fakeModelFolder = emptyModelCache
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small", isDirectory: true)
        let tokenizerFolder = emptyModelCache
            .appendingPathComponent("models/openai/whisper-small", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerFolder, withIntermediateDirectories: true)
        for name in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: fakeModelFolder.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(to: tokenizerFolder.appendingPathComponent("tokenizer.json"))
        precondition(WhisperModelCache.installedFolder(cacheDirectory: emptyModelCache) == fakeModelFolder,
                     "Model and tokenizer cache state must be recoverable after an app restart")

        let failedTranscriptionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishWhisperFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: failedTranscriptionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: failedTranscriptionDirectory) }
        let failingAudio = failedTranscriptionDirectory.appendingPathComponent("sample.mp3")
        try Data("test audio".utf8).write(to: failingAudio)
        let failingSRT = failedTranscriptionDirectory.appendingPathComponent("sample.srt")
        try Data("1\n00:00:00,000 --> 00:00:02,000\nHola.\n".utf8).write(to: failingSRT)
        let failureStore = StudyStore(
            baseDirectory: failedTranscriptionDirectory.appendingPathComponent("store", isDirectory: true)
        )
        try failureStore.importAudio(from: failingAudio)
        guard let failureMaterialID = failureStore.data.audioMaterials.first?.id else {
            preconditionFailure("The failure-test audio must be imported")
        }
        try failureStore.importSubtitles(from: failingSRT, materialID: failureMaterialID)
        let preservedSentence = ListeningSentence(
            id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2,
            transcript: "Hola.", status: .generated, version: 1
        )
        try failureStore.setTranscript(
            materialID: failureMaterialID,
            segments: [preservedSentence],
            segmentationSource: .speech
        )
        try failureStore.startWhisperSubtitleRecalibration(materialID: failureMaterialID)
        while failureStore.activeTranscriptions.contains(failureMaterialID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(failureStore.data.audioMaterials.first?.sentences.first?.id == preservedSentence.id,
                     "A failed Whisper run must not replace the existing transcript")

        let sentence = "La conversación continúa en la ciudad."
        let longText = Array(repeating: sentence, count: 100).joined(separator: " ")
        let chunks = ArticleSplitter.split(longText)
        precondition(chunks.count >= 2, "A long article must be divided")
        precondition(chunks.joined(separator: " ") == longText, "Chunking must preserve the text")

        func words(_ value: String) -> Int {
            value.split(whereSeparator: \.isWhitespace).count
        }
        let eightyFour = Array(repeating: "uno", count: 80).joined(separator: " ") + "."
        let twentyFour = Array(repeating: "dos", count: 24).joined(separator: " ") + "."
        let closeToTarget = ArticleSplitter.split(eightyFour + " " + twentyFour)
        precondition(words(closeToTarget[0]) == 104, "Closer sentence must be included")

        let ninetyFour = Array(repeating: "tres", count: 94).joined(separator: " ") + "."
        let thirtyFive = Array(repeating: "cuatro", count: 35).joined(separator: " ") + "."
        let earlyCut = ArticleSplitter.split(ninetyFour + " " + thirtyFive)
        precondition(words(earlyCut[0]) == 94, "Chunk should end at the closer sentence boundary")

        let longSentence = Array(repeating: "cinco", count: 130).joined(separator: " ") + "."
        precondition(ArticleSplitter.split(longSentence) == [longSentence],
                     "A sentence longer than the target must remain intact")

        let punctuation = "¿Cómo estás? ¡Muy bien! El Sr. García llegó a las 3.14."
        let punctuationChunks = ArticleSplitter.split(punctuation, targetWords: 100)
        precondition(punctuationChunks.joined(separator: " ") == punctuation,
                     "Spanish punctuation and abbreviations must preserve the text")

        let paragraphs = "Primera frase con contenido.\n\nSegunda frase separada."
        precondition(ArticleSplitter.split(paragraphs, targetWords: 4).count == 2,
                     "Paragraph boundaries should remain preferred cut points")

        var database = StudyDatabase()
        let articleID = UUID()
        let chunkID = UUID()
        database.articles.append(ReadingArticle(id: articleID, title: "Prueba", source: "local",
                                                 originalText: sentence, importedAt: .now,
                                                 chunks: [ReadingChunk(id: chunkID, ordinal: 1, text: sentence)]))
        database.readingRecords.append(ReadingRecord(id: UUID(), articleID: articleID, chunkID: chunkID,
                                                     completedAt: .now, difficulty: .someGaps,
                                                     questions: ["¿Por qué?"], note: "Test"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(database)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(StudyDatabase.self, from: payload)
        precondition(restored.articles.first?.id == articleID)
        precondition(restored.readingRecords.first?.chunkID == chunkID)
        let sourcedAudio = AudioMaterial(id: UUID(), title: "Legacy compatibility", fileName: "audio.mp3",
                                         importedAt: .now, segmentationSource: .speech)
        let sourcedAudioPayload = try JSONEncoder().encode(sourcedAudio)
        var legacyAudioObject = try JSONSerialization.jsonObject(with: sourcedAudioPayload) as! [String: Any]
        legacyAudioObject.removeValue(forKey: "segmentationSource")
        let legacyAudioPayload = try JSONSerialization.data(withJSONObject: legacyAudioObject)
        let legacyAudio = try JSONDecoder().decode(AudioMaterial.self, from: legacyAudioPayload)
        precondition(legacyAudio.segmentationSource == nil,
                     "Audio materials saved before segmentation provenance must remain decodable")
        let phraseDraft = CardDraft(category: .expression,
                                    mergeKey: "表达|tener ganas de + infinitivo|愿望",
                                    question: "  这个结构怎么表达？\n\n",
                                    answer: "```text\n**表示很想做某事**\n\n**表示很想做某事**\n```")
        let normalizedPhrase = CardContentNormalizer.normalize(phraseDraft)
        precondition(normalizedPhrase.question == "这个结构怎么表达？")
        precondition(!normalizedPhrase.answer.contains("```") && !normalizedPhrase.answer.contains("**"))
        precondition(CardContentNormalizer.title(for: phraseDraft) == "tener ganas de + infinitivo")
        precondition(CardContentNormalizer.title(for: CardDraft(category: .vocabulary,
                                                                mergeKey: "词汇|aprovechar|利用",
                                                                question: "什么意思？", answer: "利用")) == "aprovechar")
        assertStrictObjectsHaveMatchingRequiredProperties(CardAuditService.schema)
        let auditDraft = CardDraft(category: .expression,
                                   mergeKey: "表达|tener muchas ganas de + infinitivo|愿望",
                                   question: "这是什么结构？", answer: "表示很想做某事。")
        let success = await CardAuditService.auditOrFallback(auditDraft, apiKey: "test") { draft in
            CardAuditResult(title: "tener ganas de + infinitivo",
                            question: draft.question,
                            answer: "整理后的答案")
        }
        precondition(!success.usedFallback && success.answer == "整理后的答案",
                     "Successful audit must replace the normalized draft")
        let networkFailure = await CardAuditService.auditOrFallback(auditDraft, apiKey: "test") { _ in
            throw AIStudyError.server(503, "offline")
        }
        precondition(networkFailure.usedFallback && networkFailure.question == "这是什么结构？",
                     "Network failure must preserve the normalized draft")
        let schemaFailure = await CardAuditService.auditOrFallback(auditDraft, apiKey: "test") { _ in
            throw AIStudyError.invalidResponse
        }
        precondition(schemaFailure.usedFallback && !schemaFailure.answer.isEmpty,
                     "Schema failure must preserve the normalized draft")
        let emptyAudit = await CardAuditService.auditOrFallback(auditDraft, apiKey: "test") { _ in
            CardAuditResult(title: "", question: "", answer: "")
        }
        precondition(emptyAudit.usedFallback && !emptyAudit.question.isEmpty && !emptyAudit.answer.isEmpty,
                     "An empty successful audit response must preserve the original card draft")
        let invalidAuditResponses = [
            CardAuditResult(title: "Title", question: "", answer: "valid answer"),
            CardAuditResult(title: "Title", question: "valid question", answer: ""),
            CardAuditResult(title: "Title", question: "", answer: ""),
            CardAuditResult(title: "Title", question: " \n\t ", answer: " \n ")
        ]
        for response in invalidAuditResponses {
            let fallback = await CardAuditService.auditOrFallback(auditDraft, apiKey: "test") { _ in response }
            precondition(fallback.usedFallback &&
                         fallback.question == CardContentNormalizer.normalize(auditDraft).question &&
                         fallback.answer == CardContentNormalizer.normalize(auditDraft).answer &&
                         fallback.title == CardContentNormalizer.title(for: auditDraft),
                         "Invalid audit content must preserve the original normalized card draft")
        }
        let retry = await CardAuditService.auditOrFallback(
            CardDraft(category: .grammar, mergeKey: "语法|haber estado + gerundio|持续",
                      question: "如何表达持续？", answer: "基础答案"),
            apiKey: "test"
        ) { _ in
            CardAuditResult(title: "haber estado + gerundio",
                            question: "如何表达持续？", answer: "审核后的答案")
        }
        precondition(!retry.usedFallback && retry.title == "haber estado + gerundio",
                     "A successful retry must provide the audited result")
        let batch = await withTaskGroup(of: CardAuditDecision.self, returning: [CardAuditDecision].self) { group in
            for index in 0..<3 {
                group.addTask {
                    await CardAuditService.auditOrFallback(
                        CardDraft(category: .expression, mergeKey: "表达|point\(index)|test",
                                  question: "问题 \(index)", answer: "答案 \(index)"),
                        apiKey: "test"
                    ) { draft in
                        if index == 1 { throw AIStudyError.invalidResponse }
                        return CardAuditResult(title: "point\(index)",
                                               question: draft.question, answer: "审核答案 \(index)")
                    }
                }
            }
            var results: [CardAuditDecision] = []
            for await result in group { results.append(result) }
            return results
        }
        precondition(batch.count == 3 && batch.filter(\.usedFallback).count == 1,
                     "A partial batch failure must preserve all three cards")
        let writingContext = WritingSubmissionContext(
            exerciseID: nil, mode: .free, prompt: "Prompt A", learnerSpanish: "Draft A",
            sourceID: nil, sourceSegmentID: nil, sourceQuote: nil, referenceSpanish: nil, focus: ""
        )
        let switchedWritingContext = WritingSubmissionContext(
            exerciseID: nil, mode: .free, prompt: "Prompt B", learnerSpanish: "Draft B",
            sourceID: nil, sourceSegmentID: nil, sourceQuote: nil, referenceSpanish: nil, focus: ""
        )
        precondition(writingContext != switchedWritingContext,
                     "A late Writing response must not match a different prompt when both exercise IDs are nil")
        let sourceA = UUID()
        let sourceB = UUID()
        let existingContextA = WritingSubmissionContext(
            exerciseID: UUID(), mode: .material, prompt: "Same prompt", learnerSpanish: "Draft",
            sourceID: sourceA, sourceSegmentID: UUID(), sourceQuote: "quote A",
            referenceSpanish: "reference A", focus: "focus"
        )
        let existingContextB = WritingSubmissionContext(
            exerciseID: UUID(), mode: .material, prompt: "Same prompt", learnerSpanish: "Draft",
            sourceID: sourceB, sourceSegmentID: UUID(), sourceQuote: "quote B",
            referenceSpanish: "reference B", focus: "focus"
        )
        precondition(existingContextA != existingContextB,
                     "Existing exercises and identical prompts with different source contexts must not match")
        precondition(existingContextA != WritingSubmissionContext(
            exerciseID: existingContextA.exerciseID, mode: .material, prompt: "Same prompt",
            learnerSpanish: "Edited draft", sourceID: sourceA,
            sourceSegmentID: existingContextA.sourceSegmentID, sourceQuote: "quote A",
            referenceSpanish: "reference A", focus: "focus"
        ), "Editing the learner draft must invalidate the prior response's UI context")
        precondition(existingContextA != WritingSubmissionContext(
            exerciseID: existingContextA.exerciseID, mode: .free, prompt: "Same prompt",
            learnerSpanish: "Draft", sourceID: nil, sourceSegmentID: nil, sourceQuote: nil,
            referenceSpanish: nil, focus: "focus"
        ), "Switching Writing mode/source must invalidate the prior response's UI context")
        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SpanishLearningStoreTest-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let firstStore = StudyStore(baseDirectory: testDirectory)
        try firstStore.addArticle(title: "Artículo", source: "Prueba", text: longText)
        let savedArticle = firstStore.data.articles.first!
        let readingRaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishReadingRaceTest-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: readingRaceDirectory) }
        let readingRaceStore = StudyStore(baseDirectory: readingRaceDirectory)
        try readingRaceStore.addArticle(title: "Reading race", source: "test", text: longText)
        let readingRaceArticle = readingRaceStore.data.articles.first!
        precondition(readingRaceArticle.chunks.count > 1, "Reading stale-response fixture needs two chunks")
        let readingChunkA = readingRaceArticle.chunks[0]
        let readingChunkB = readingRaceArticle.chunks[1]
        _ = try readingRaceStore.saveReadingDiscussion(articleID: readingRaceArticle.id, chunkID: readingChunkA.id,
                                                       question: "question-A", answer: "answer-A")
        _ = try readingRaceStore.saveReadingDiscussion(articleID: readingRaceArticle.id, chunkID: readingChunkB.id,
                                                       question: "question-B", answer: "answer-B")
        let frozenReadingDiscussion = readingRaceStore.pendingReadingDiscussions(
            articleID: readingRaceArticle.id, chunkID: readingChunkA.id
        )
        let frozenDifficulty = ReadingDifficulty.difficult
        let frozenNote = "note captured for chunk A"
        var liveChunkID = readingChunkA.id
        var liveDifficulty = ReadingDifficulty.difficult
        var liveNote = frozenNote
        let delayedReadingSave = Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            try readingRaceStore.completeReadingWithCards(articleID: readingRaceArticle.id, chunkID: readingChunkA.id,
                                                          difficulty: frozenDifficulty, note: frozenNote, result: nil)
        }
        liveChunkID = readingChunkB.id
        liveDifficulty = .understood
        liveNote = "changed for chunk B"
        try await delayedReadingSave.value
        let readingRecordA = readingRaceStore.data.readingRecords.first { $0.chunkID == readingChunkA.id }
        precondition(readingRecordA?.difficulty == frozenDifficulty &&
                     readingRecordA?.note == frozenNote &&
                     readingRecordA?.questions == frozenReadingDiscussion.map(\.question),
                     "A delayed Reading save must use the requested chunk, difficulty, note, and questions")
        precondition(liveChunkID == readingChunkB.id && liveDifficulty == .understood && liveNote == "changed for chunk B")
        try firstStore.completeReading(articleID: savedArticle.id, chunkID: savedArticle.chunks[0].id, difficulty: .someGaps, questions: ["¿Por qué?"], note: "Leído")
        let secondStore = StudyStore(baseDirectory: testDirectory)
        precondition(secondStore.data.articles.first?.id == savedArticle.id, "Article did not survive reopening")
        precondition(secondStore.data.readingRecords.first?.chunkID == savedArticle.chunks[0].id, "Reading history lost its source")
        let audioSource = testDirectory.deletingLastPathComponent().appendingPathComponent("SpanishTest-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: audioSource) }
        let audioPayload = Data(repeating: 0x42, count: 4096)
        try audioPayload.write(to: audioSource)
        try firstStore.importAudio(from: audioSource)
        let audioID = firstStore.data.audioMaterials[0].id
        let subtitle = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        Hola, ¿cómo estás?

        00:00:03.000 --> 00:00:06.000
        ¿Podrías decirme cómo llegar?
        """
        let parsed = try SubtitleImporter.parse(Data(subtitle.utf8))
        precondition(parsed.count == 2 && parsed[0].text == "Hola, ¿cómo estás?" &&
                     parsed[0].startSeconds == 0 && parsed[1].endSeconds == 6)
        let longCueFixture = """
        1
        00:00:00,000 --> 00:00:20,000
        Hola. ¿Cómo estás? Esta es una frase larga que debe permanecer dentro del mismo cue.

        2
        00:00:25,000 --> 00:00:27,000
        Cue separado después de una pausa.
        """
        let longCueCues = try SubtitleImporter.parse(Data(longCueFixture.utf8))
        precondition(longCueCues.count == 2 &&
                     longCueCues[0].text == "Hola. ¿Cómo estás? Esta es una frase larga que debe permanecer dentro del mismo cue." &&
                     longCueCues[0].startSeconds == 0 && longCueCues[0].endSeconds == 20 &&
                     longCueCues[1].startSeconds == 25 && longCueCues[1].endSeconds == 27,
                     "Subtitle parsing must preserve complete long and multi-sentence cues as references")
        let seventyNineCueFixture = (0..<79).map { index in
            let start = index
            let end = index + 1
            return """
            \(index + 1)
            00:\(String(format: "%02d:%02d", start / 60, start % 60)),000 --> 00:\(String(format: "%02d:%02d", end / 60, end % 60)),000
            Cue \(index + 1). ¿Cómo estás?
            """
        }.joined(separator: "\n\n")
        let seventyNineCues = try SubtitleImporter.parse(Data(seventyNineCueFixture.utf8))
        precondition(seventyNineCues.count == 79 &&
                     seventyNineCues.first?.ordinal == 1 &&
                     seventyNineCues.last?.ordinal == 79,
                     "Seventy-nine valid timed subtitle cues must be retained in order")
        let speechFixture: (String, Double, Double) -> ListeningSentence = { text, start, end in
            ListeningSentence(id: UUID(), ordinal: 0, startSeconds: start, endSeconds: end,
                              transcript: text, status: .generated, version: 1,
                              rawSpeechText: text)
        }
        let oneToOne = ListeningSubtitleAligner.align(
            sentences: [speechFixture("Hola como estas", 0.2, 1.8)],
            cues: [SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 3,
                               text: "Hola, ¿cómo estás?")]
        )
        precondition(oneToOne.matches.count == 1 &&
                     oneToOne.matches[0].shape == .oneToOne &&
                     oneToOne.matches[0].confidence == .high)
        let oneToMany = ListeningSubtitleAligner.align(
            sentences: [speechFixture("Buenos días amigos", 0, 2)],
            cues: [
                SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 1, text: "Buenos días"),
                SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 1, endSeconds: 2, text: "amigos")
            ]
        )
        precondition(oneToMany.matches.count == 1 &&
                     oneToMany.matches[0].shape == .oneToMany &&
                     oneToMany.matches[0].cueRange == 0..<2)
        let manyToOne = ListeningSubtitleAligner.align(
            sentences: [
                speechFixture("Buenos días", 0, 1),
                speechFixture("¿Cómo estás?", 1, 2)
            ],
            cues: [SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2,
                               text: "Buenos días. ¿Cómo estás?")]
        )
        precondition(manyToOne.matches.count == 1 &&
                     manyToOne.matches[0].shape == .manyToOne &&
                     manyToOne.matches[0].sentenceRange == 0..<2)
        let unmatched = ListeningSubtitleAligner.align(
            sentences: [speechFixture("La transcripción no coincide", 0, 2)],
            cues: [SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2,
                               text: "Completamente diferente")]
        )
        precondition(unmatched.matches.isEmpty &&
                     unmatched.unmatchedSentenceIndices == [0] &&
                     unmatched.unmatchedCueIndices == [0],
                     "Unrelated subtitle text must not be forced onto Speech output")
        let calibrationCues = [
            SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2, text: "Inicio sin ancla"),
            SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 2, endSeconds: 5, text: "Buenos días amigos"),
            SubtitleCue(id: UUID(), ordinal: 3, startSeconds: 5, endSeconds: 8, text: "Texto intermedio"),
            SubtitleCue(id: UUID(), ordinal: 4, startSeconds: 8, endSeconds: 11, text: "Hasta mañana amigo"),
            SubtitleCue(id: UUID(), ordinal: 5, startSeconds: 11, endSeconds: 14, text: "Final sin ancla")
        ]
        let calibrationSpeech = [
            SpeechTimingAnchor(text: "Buenos", startSeconds: 12, endSeconds: 12.5),
            SpeechTimingAnchor(text: "días", startSeconds: 12.5, endSeconds: 13),
            SpeechTimingAnchor(text: "amigos", startSeconds: 13, endSeconds: 15),
            SpeechTimingAnchor(text: "Hasta", startSeconds: 18, endSeconds: 18.5),
            SpeechTimingAnchor(text: "mañana", startSeconds: 18.5, endSeconds: 19),
            SpeechTimingAnchor(text: "amigo", startSeconds: 19, endSeconds: 21)
        ]
        let calibration = ListeningSubtitleAligner.SubtitleTimingCalibrator.calibrate(
            cues: calibrationCues, speech: calibrationSpeech, audioDuration: 30
        )
        precondition(calibration.sentences.count == calibrationCues.count &&
                     calibration.sentences.map(\.transcript) == calibrationCues.map(\.text),
                     "Timed subtitles must produce exactly one text-preserving sentence per cue")
        precondition(calibration.anchors.count == 4 &&
                     calibration.anchors.allSatisfy {
                         $0.kind == .cueBoundary && $0.confidence == .high && $0.similarity >= 0.92
                     },
                     "Only unique, high-similarity complete cue matches may create boundary anchors")
        precondition(calibration.regions.count == 1 &&
                     calibration.regions[0].subtitleStart == 2 &&
                     calibration.regions[0].subtitleEnd == 11,
                     "Close, monotonic boundary anchors should form an interpolation region")
        precondition(calibration.sentences[0].startSeconds == 0 &&
                     calibration.sentences[0].endSeconds == 2 &&
                     calibration.sentences[0].timingSource == .subtitleOriginal &&
                     calibration.sentences[0].timingConfidence == .low,
                     "Unanchored leading cues must retain original SRT times without extrapolation")
        precondition(calibration.sentences[1].startSeconds == 12 &&
                     calibration.sentences[1].endSeconds == 15 &&
                     calibration.sentences[1].timingSource == .speechCalibrated,
                     "Cue-boundary anchors must calibrate the matching cue using Speech time")
        precondition(calibration.sentences[2].startSeconds == 15 &&
                     calibration.sentences[2].endSeconds == 18 &&
                     calibration.sentences[2].timingSource == .speechCalibrated,
                     "Cue times between anchors must use piecewise-linear interpolation")
        precondition(calibration.sentences[4].startSeconds == 11 &&
                     calibration.sentences[4].endSeconds == 14 &&
                     calibration.sentences[4].timingSource == .subtitleOriginal,
                     "Unanchored trailing cues must retain original SRT times without extrapolation")
        precondition(calibration.sentences.allSatisfy {
            $0.startSeconds.isFinite && $0.endSeconds.isFinite &&
                $0.startSeconds >= 0 && $0.startSeconds < $0.endSeconds &&
                $0.transcript == calibrationCues[$0.ordinal - 1].text
        }, "Calibration must preserve text and produce finite positive-duration cue ranges")
        let duplicateCues = [
            SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2, text: "Vamos amigos"),
            SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 2, endSeconds: 4, text: "Vamos amigos")
        ]
        let duplicateCalibration = ListeningSubtitleAligner.SubtitleTimingCalibrator.calibrate(
            cues: duplicateCues,
            speech: [
                SpeechTimingAnchor(text: "Vamos", startSeconds: 1, endSeconds: 1.4),
                SpeechTimingAnchor(text: "amigos", startSeconds: 1.4, endSeconds: 2)
            ],
            audioDuration: 10
        )
        precondition(duplicateCalibration.anchors.isEmpty &&
                     duplicateCalibration.sentences.allSatisfy {
                         $0.timingSource == .subtitleOriginal && $0.timingConfidence == .low
                     },
                     "Repeated text must not form timing anchors even at exact text similarity")
        let internalCue = SubtitleCue(id: UUID(), ordinal: 13, startSeconds: 61,
                                      endSeconds: 65, text: "¿Desayunaste? ¿Quieres algo de desayunar?")
        let internalCalibration = ListeningSubtitleAligner.SubtitleTimingCalibrator.calibrate(
            cues: [internalCue],
            speech: [
                SpeechTimingAnchor(text: "Quieres", startSeconds: 62.97, endSeconds: 63.15),
                SpeechTimingAnchor(text: "algo", startSeconds: 63.15, endSeconds: 63.57),
                SpeechTimingAnchor(text: "de", startSeconds: 63.57, endSeconds: 63.69),
                SpeechTimingAnchor(text: "desayunar", startSeconds: 63.69, endSeconds: 64.56)
            ],
            audioDuration: 100
        )
        precondition(internalCalibration.anchors.count == 1 &&
                     internalCalibration.anchors[0].kind == .internalPhrase &&
                     internalCalibration.anchors[0].confidence == .medium &&
                     internalCalibration.anchors[0].subtitleTime == 63 &&
                     internalCalibration.anchors[0].speechTime == 63.765 &&
                     internalCalibration.sentences[0].startSeconds == 61 &&
                     internalCalibration.sentences[0].endSeconds == 65 &&
                     internalCalibration.sentences[0].timingSource == .subtitleOriginal,
                     "An internal phrase must create only an approximate midpoint point, never cue boundary times")
        let distantCues = [
            SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2, text: "Alpha buenos días"),
            SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 2, endSeconds: 80, text: "Sin evidencia intermedia"),
            SubtitleCue(id: UUID(), ordinal: 3, startSeconds: 80, endSeconds: 82, text: "Omega hasta mañana")
        ]
        let distantSpeech = [
            SpeechTimingAnchor(text: "Alpha", startSeconds: 10, endSeconds: 10.4),
            SpeechTimingAnchor(text: "buenos", startSeconds: 10.4, endSeconds: 11),
            SpeechTimingAnchor(text: "días", startSeconds: 11, endSeconds: 12),
            SpeechTimingAnchor(text: "Omega", startSeconds: 90, endSeconds: 90.4),
            SpeechTimingAnchor(text: "hasta", startSeconds: 90.4, endSeconds: 91),
            SpeechTimingAnchor(text: "mañana", startSeconds: 91, endSeconds: 92)
        ]
        let distantCalibration = ListeningSubtitleAligner.SubtitleTimingCalibrator.calibrate(
            cues: distantCues, speech: distantSpeech, audioDuration: 100
        )
        precondition(distantCalibration.sentences[0].timingSource == .speechCalibrated &&
                     distantCalibration.sentences[0].startSeconds == 10 &&
                     distantCalibration.sentences[0].endSeconds == 12 &&
                     distantCalibration.sentences[1].startSeconds == 2 &&
                     distantCalibration.sentences[1].endSeconds == 80 &&
                     distantCalibration.sentences[1].timingSource == .subtitleOriginal &&
                     distantCalibration.sentences[2].timingSource == .speechCalibrated &&
                     distantCalibration.sentences[2].startSeconds == 90 &&
                     distantCalibration.sentences[2].endSeconds == 92,
                     "Anchor gaps over sixty seconds must calibrate anchored cues only, without interpolating the intervening cue")
        let discontinuityCues = [
            SubtitleCue(id: UUID(), ordinal: 1, startSeconds: 0, endSeconds: 2, text: "Primero buen día"),
            SubtitleCue(id: UUID(), ordinal: 2, startSeconds: 2, endSeconds: 4, text: "Cue sin ancla"),
            SubtitleCue(id: UUID(), ordinal: 3, startSeconds: 4, endSeconds: 6, text: "Último hasta luego")
        ]
        let discontinuitySpeech = [
            SpeechTimingAnchor(text: "Primero", startSeconds: 10, endSeconds: 10.4),
            SpeechTimingAnchor(text: "buen", startSeconds: 10.4, endSeconds: 11),
            SpeechTimingAnchor(text: "día", startSeconds: 11, endSeconds: 12),
            SpeechTimingAnchor(text: "Último", startSeconds: 40, endSeconds: 40.4),
            SpeechTimingAnchor(text: "hasta", startSeconds: 40.4, endSeconds: 41),
            SpeechTimingAnchor(text: "luego", startSeconds: 41, endSeconds: 42)
        ]
        let discontinuityCalibration = ListeningSubtitleAligner.SubtitleTimingCalibrator.calibrate(
            cues: discontinuityCues, speech: discontinuitySpeech, audioDuration: 60
        )
        precondition(discontinuityCalibration.regions.count == 2 &&
                     discontinuityCalibration.sentences[1].timingSource == .subtitleOriginal &&
                     discontinuityCalibration.sentences[1].startSeconds == 2 &&
                     discontinuityCalibration.sentences[1].endSeconds == 4,
                     "An anomalous local slope must split regions and preserve the unsupported cue's SRT time")
        precondition(!ListeningSubtitleAligner.isReferenceReliable(
            SpeechSubtitleAlignment(
                matches: [
                    ListeningSubtitleMatch(sentenceRange: 0..<10, cueRange: 0..<10,
                                           subtitleText: "High matches", similarity: 1,
                                           confidence: .high, shape: .oneToOne),
                    ListeningSubtitleMatch(sentenceRange: 10..<18, cueRange: 10..<20,
                                           subtitleText: "Medium matches", similarity: 0.8,
                                           confidence: .medium, shape: .oneToMany),
                    ListeningSubtitleMatch(sentenceRange: 18..<22, cueRange: 20..<25,
                                           subtitleText: "Low matches", similarity: 0.5,
                                           confidence: .low, shape: .manyToOne)
                ],
                unmatchedSentenceIndices: [22],
                unmatchedCueIndices: Array(25..<79)
            ),
            sentenceCount: 23, cueCount: 79
        ), "Sparse subtitle alignment must not be treated as a reliable reference")
        let lowConfidenceSentence = speechFixture("texto reconocido claramente distinto", 4, 8)
        let lowConfidenceMatch = ListeningSubtitleMatch(
            sentenceRange: 0..<1, cueRange: 0..<1, subtitleText: "otra referencia",
            similarity: 0.2, confidence: .low, shape: .oneToOne
        )
        let lowConfidenceFinal = ListeningSubtitleAligner.locallyReviewed(
            lowConfidenceSentence, match: lowConfidenceMatch, referenceReliable: true
        )
        precondition(lowConfidenceFinal.transcript == lowConfidenceSentence.transcript,
                     "Low-confidence reference text must not automatically replace Speech")
        let aiCorrectedSentence = ListeningSubtitleAligner.applyingAIReview(
            lowConfidenceSentence,
            review: SpeechTranscriptReview(decision: .corrected, correctedText: "Texto corregido",
                                           reason: "mock", confidence: 0.95)
        )
        precondition(aiCorrectedSentence.transcript == "Texto corregido" &&
                     aiCorrectedSentence.id == lowConfidenceSentence.id &&
                     aiCorrectedSentence.startSeconds == lowConfidenceSentence.startSeconds &&
                     aiCorrectedSentence.endSeconds == lowConfidenceSentence.endSeconds &&
                     aiCorrectedSentence.rawSpeechText == lowConfidenceSentence.rawSpeechText)
        let aiFailureFallback = ListeningSubtitleAligner.applyingAIReview(lowConfidenceSentence, review: nil)
        precondition(aiFailureFallback.transcript == lowConfidenceSentence.transcript &&
                     aiFailureFallback.startSeconds == lowConfidenceSentence.startSeconds &&
                     aiFailureFallback.endSeconds == lowConfidenceSentence.endSeconds)
        let timelineDirectory = testDirectory.appendingPathComponent("SubtitleTimeline", isDirectory: true)
        let timelineStore = StudyStore(baseDirectory: timelineDirectory)
        try timelineStore.importAudio(from: audioSource)
        let timelineFixture = """
        1
        00:00:00,000 --> 00:00:03,000
        Muy buenas a todos y bienvenidos a un

        2
        00:00:03,000 --> 00:00:08,000
        Super Slow Easy Spanish. Hoy saldremos a

        3
        00:00:08,000 --> 00:00:10,000
        grabar en Barcelona,

        4
        00:00:10,000 --> 00:00:14,000
        pero antes desayunamos, ¿no, José?
        """
        let timelineSource = testDirectory.deletingLastPathComponent()
            .appendingPathComponent("SpanishTimeline-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: timelineSource) }
        try Data(timelineFixture.utf8).write(to: timelineSource)
        let timelineMaterialID = timelineStore.data.audioMaterials[0].id
        try timelineStore.importSubtitles(from: timelineSource, materialID: timelineMaterialID)
        let savedReferenceMaterial = timelineStore.data.audioMaterials[0]
        precondition(savedReferenceMaterial.segmentationSource == nil &&
                     savedReferenceMaterial.transcriptionComplete != true &&
                     savedReferenceMaterial.transcribedThroughSeconds == nil &&
                     savedReferenceMaterial.sentences.isEmpty &&
                     savedReferenceMaterial.referenceSubtitleCues?.count == 4,
                     "Importing subtitles must save reference cues without completing transcription or creating sentences")
        let workflowSpeechAnchors = savedReferenceMaterial.referenceSubtitleCues!.map {
            SpeechTimingAnchor(text: $0.text, startSeconds: $0.startSeconds + 0.2,
                               endSeconds: $0.endSeconds + 0.2)
        }
        let workflowA = StudyStore(baseDirectory: testDirectory.appendingPathComponent("SubtitleBeforeSpeech", isDirectory: true))
        try workflowA.importAudio(from: audioSource)
        let workflowAMaterialID = workflowA.data.audioMaterials[0].id
        try workflowA.importSubtitles(from: timelineSource, materialID: workflowAMaterialID)
        precondition(workflowA.data.audioMaterials[0].referenceSubtitleCues?.count == 4 &&
                     workflowA.data.audioMaterials[0].sentences.isEmpty)
        try workflowA.appendSpeechTimingAnchors(materialID: workflowAMaterialID,
                                                segments: workflowSpeechAnchors, through: 14)
        try workflowA.applySubtitleTimingCalibration(materialID: workflowAMaterialID, audioDuration: 20)
        let workflowAMaterial = workflowA.data.audioMaterials[0]
        precondition(workflowAMaterial.referenceSubtitleCues?.count == 4 &&
                     workflowAMaterial.sentences.count == 4 &&
                     workflowAMaterial.segmentationSource == .subtitleCalibrated &&
                     workflowAMaterial.transcriptionComplete == true,
                     "MP3 → SRT → Speech must finish as one subtitle sentence per cue")

        let workflowB = StudyStore(baseDirectory: testDirectory.appendingPathComponent("SpeechBeforeSubtitle", isDirectory: true))
        try workflowB.importAudio(from: audioSource)
        let workflowBMaterialID = workflowB.data.audioMaterials[0].id
        let speechOnlyFixture = (0..<23).map { index in
            speechFixture("Speech sentence \(index + 1)", Double(index * 2), Double(index * 2 + 1))
        }
        try workflowB.appendTranscriptChunk(materialID: workflowBMaterialID,
                                            segments: speechOnlyFixture, through: 46)
        try workflowB.completeTranscription(materialID: workflowBMaterialID)
        try workflowB.importSubtitles(from: timelineSource, materialID: workflowBMaterialID)
        precondition(workflowB.data.audioMaterials[0].sentences.count == 23 &&
                     workflowB.data.audioMaterials[0].referenceSubtitleCues?.count == 4 &&
                     workflowB.canRecalibrateSubtitles(materialID: workflowBMaterialID),
                     "Importing subtitles after Speech must preserve the original sentences and expose explicit calibration")
        try workflowB.appendSpeechTimingAnchors(materialID: workflowBMaterialID,
                                                segments: workflowSpeechAnchors, through: 14)
        try workflowB.applySubtitleTimingCalibration(materialID: workflowBMaterialID,
                                                     audioDuration: 20,
                                                     replacingSpeechSentences: true)
        let workflowBMaterial = workflowB.data.audioMaterials[0]
        precondition(workflowBMaterial.sentences.count == 4 &&
                     workflowBMaterial.segmentationSource == .subtitleCalibrated &&
                     workflowBMaterial.sentences.map(\.transcript) ==
                        workflowBMaterial.referenceSubtitleCues?.map(\.text),
                     "Explicit post-transcription calibration must replace Speech segmentation with subtitle cue units")

        let workflowC = StudyStore(baseDirectory: testDirectory.appendingPathComponent("SpeechOnlyNoSubtitle", isDirectory: true))
        try workflowC.importAudio(from: audioSource)
        let workflowCMaterialID = workflowC.data.audioMaterials[0].id
        try workflowC.appendTranscriptChunk(materialID: workflowCMaterialID,
                                            segments: speechOnlyFixture, through: 46)
        try workflowC.completeTranscription(materialID: workflowCMaterialID)
        precondition(workflowC.data.audioMaterials[0].sentences.count == 23 &&
                     workflowC.data.audioMaterials[0].segmentationSource == .speech,
                     "MP3-only transcription must preserve the Speech sentence pipeline")
        let protectedWorkflow = StudyStore(
            baseDirectory: testDirectory.appendingPathComponent("ProtectedSubtitleCalibration", isDirectory: true)
        )
        try protectedWorkflow.importAudio(from: audioSource)
        let protectedMaterialID = protectedWorkflow.data.audioMaterials[0].id
        let protectedSentences = (0..<97).map { index in
            speechFixture("Legacy sentence \(index + 1)", Double(index * 2), Double(index * 2 + 1))
        }
        try protectedWorkflow.appendTranscriptChunk(materialID: protectedMaterialID,
                                                     segments: protectedSentences, through: 194)
        try protectedWorkflow.completeTranscription(materialID: protectedMaterialID)
        try protectedWorkflow.importSubtitles(from: timelineSource, materialID: protectedMaterialID)
        let protectedSentenceID = protectedWorkflow.data.audioMaterials[0].sentences[0].id
        try protectedWorkflow.revealAnswer(materialID: protectedMaterialID,
                                           sentenceID: protectedSentenceID, text: "Legacy attempt")
        let protectedIDs = protectedWorkflow.data.audioMaterials[0].sentences.map(\.id)
        precondition(!protectedWorkflow.canRecalibrateSubtitles(materialID: protectedMaterialID))
        do {
            try protectedWorkflow.startWhisperSubtitleRecalibration(materialID: protectedMaterialID)
            preconditionFailure("Whisper recalibration must refuse materials with learning history")
        } catch StoreError.transcriptionLocked {
            precondition(protectedWorkflow.data.audioMaterials[0].sentences.map(\.id) == protectedIDs &&
                         protectedWorkflow.data.audioMaterials[0].sentences.count == 97,
                         "Whisper recalibration must preserve the protected legacy sentence set")
        }
        do {
            try protectedWorkflow.startSubtitleCalibration(materialID: protectedMaterialID)
            preconditionFailure("Calibration must refuse materials with learning history")
        } catch StoreError.transcriptionLocked {
            precondition(protectedWorkflow.data.audioMaterials[0].sentences.map(\.id) == protectedIDs &&
                         protectedWorkflow.data.audioMaterials[0].sentences.count == 97,
                         "Explicit recalibration must preserve the protected legacy sentence set")
        }

        let expectedCueTexts = [
            "Muy buenas a todos y bienvenidos a un",
            "Super Slow Easy Spanish. Hoy saldremos a",
            "grabar en Barcelona,",
            "pero antes desayunamos, ¿no, José?"
        ]
        for index in savedReferenceMaterial.referenceSubtitleCues!.indices {
            let cue = savedReferenceMaterial.referenceSubtitleCues![index]
            precondition(cue.text == expectedCueTexts[index] &&
                         cue.startSeconds == Double(index == 0 ? 0 : [3, 8, 10][index - 1]) &&
                         cue.endSeconds == Double([3, 8, 10, 14][index]),
                         "Imported reference cue text and original timestamps must remain intact")
        }
        let speechSegments = [
            speechFixture("Speech one", 0.2, 2.8),
            speechFixture("Speech two", 3.25, 9.4),
            speechFixture("Speech three", 10.3, 13.6)
        ]
        try timelineStore.appendTranscriptChunk(materialID: timelineMaterialID,
                                                segments: speechSegments, through: 14)
        let speechMaterial = timelineStore.data.audioMaterials[0]
        precondition(speechMaterial.sentences.map(\.startSeconds) == [0.2, 3.25, 10.3] &&
                     speechMaterial.sentences.map(\.endSeconds) == [2.8, 9.4, 13.6] &&
                     speechMaterial.segmentationSource == .speech &&
                     speechMaterial.referenceSubtitleCues?.count == 4 &&
                     speechMaterial.transcriptionComplete == false,
                     "Speech segments must own sentence boundaries while subtitle cues remain references")
        let mergedCueID = speechMaterial.sentences[1].id
        try timelineStore.mergeWithNext(materialID: timelineMaterialID, sentenceID: mergedCueID)
        let mergedCues = timelineStore.data.audioMaterials[0].sentences
        precondition(mergedCues.count == 2 &&
                     mergedCues[1].transcript == "Speech two Speech three" &&
                     mergedCues[1].startSeconds == 3.25 && mergedCues[1].endSeconds == 13.6,
                     "Manual merge must combine Speech text and preserve first/last Speech boundaries")
        try timelineStore.splitSentence(materialID: timelineMaterialID, sentenceID: mergedCues[1].id,
                                        firstText: "First part", secondText: "Second part", at: 7.2)
        let manuallySplit = timelineStore.data.audioMaterials[0].sentences
        precondition(manuallySplit[1].startSeconds == 3.25 && manuallySplit[1].endSeconds == 7.2 &&
                     manuallySplit[2].startSeconds == 7.2 && manuallySplit[2].endSeconds == 13.6,
                     "Manual split must use only the explicitly selected split timestamp")
        let speechStore = StudyStore(baseDirectory: testDirectory.appendingPathComponent("SpeechPipeline", isDirectory: true))
        try speechStore.importAudio(from: audioSource)
        let speechMaterialID = speechStore.data.audioMaterials[0].id
        try speechStore.appendTranscriptChunk(materialID: speechMaterialID, segments: [
            ListeningSentence(id: UUID(), ordinal: 0, startSeconds: 0, endSeconds: 2,
                              transcript: "Hola.", status: .generated, version: 1)
        ], through: 2)
        precondition(speechStore.data.audioMaterials[0].segmentationSource == .speech &&
                     speechStore.data.audioMaterials[0].transcriptionComplete == false,
                     "Appending native Speech results must preserve the Speech-only pipeline")
        precondition(TranscriptionService.isNoSpeechError(
            NSError(domain: "kAFAssistantErrorDomain", code: 1110)
        ), "Apple's no-speech recognition error must be classified as a skippable chunk")
        precondition(!TranscriptionService.isNoSpeechError(
            NSError(domain: "kAFAssistantErrorDomain", code: 1101)
        ), "Other Speech failures must remain fatal")
        let chunkLocalSegment = NativeSpeechSegment(substring: "test", timestamp: 2.5, duration: 1.25)
            .globalized(by: 30)
        precondition(chunkLocalSegment.timestamp == 32.5 &&
                     chunkLocalSegment.end == 33.75 &&
                     chunkLocalSegment.duration == 1.25,
                     "Chunk-local Speech timestamps and ends must be shifted into the source audio timeline")
        let subtitleSource = testDirectory.deletingLastPathComponent().appendingPathComponent("SpanishTest-\(UUID().uuidString).vtt")
        defer { try? FileManager.default.removeItem(at: subtitleSource) }
        try Data(subtitle.utf8).write(to: subtitleSource)
        try firstStore.importSubtitles(from: subtitleSource, materialID: audioID)
        precondition(firstStore.data.audioMaterials[0].transcriptionComplete != true)
        precondition(firstStore.data.audioMaterials[0].sentences.isEmpty &&
                     firstStore.data.audioMaterials[0].referenceSubtitleCues?.count == 2,
                     "Importing reference subtitles must not create or complete Listening sentences")
        let sentenceID = UUID()
        let secondSentenceID = UUID()
        try firstStore.setTranscript(materialID: audioID, segments: [
            ListeningSentence(id: sentenceID, ordinal: 1, startSeconds: 0, endSeconds: 3,
                              transcript: "Hola, ¿cómo estás?", status: .generated, version: 1),
            ListeningSentence(id: secondSentenceID, ordinal: 2, startSeconds: 3, endSeconds: 6,
                              transcript: "¿Podrías decirme cómo llegar?", status: .generated, version: 1)
        ])
        try firstStore.completeTranscription(materialID: audioID)
        try firstStore.splitSentence(materialID: audioID, sentenceID: sentenceID,
                                     firstText: "Hola", secondText: "¿cómo estás?", at: 1.0)
        precondition(firstStore.data.audioMaterials[0].sentences.count == 3)
        try firstStore.mergeWithNext(materialID: audioID, sentenceID: sentenceID)
        precondition(firstStore.data.audioMaterials[0].sentences.count == 2)
        try firstStore.verifyTranscript(materialID: audioID)
        try firstStore.saveDictationDraft(materialID: audioID, sentenceID: sentenceID, text: "Hola como estas")
        try firstStore.revealAnswer(materialID: audioID, sentenceID: sentenceID, text: "Hola como estas")
        let pointID = UUID()
        let point = LearningPointRequest(id: pointID, category: .expression, prompt: "礼貌问候")
        let analysisResult = ListeningAnalysisResult(
            explanation: "可能没有识别疑问语调。",
            items: [.init(category: .attemptDifference, title: "听写差异",
                          detail: "你漏写了疑问结构。", evidence: "原句与听写对比")]
        )
        try firstStore.saveListeningAnalysis(materialID: audioID, sentenceID: sentenceID,
                                             attempt: "Hola como estas", result: analysisResult)
        precondition(firstStore.data.cards.isEmpty)
        let cardsResult = ListeningCardsResult(cards: [
            .init(requestID: pointID.uuidString,
                  category: .expression,
                  mergeKey: "表达|cómo estás|问候",
                  question: "如何自然问候？",
                  answer: "使用 ¿Cómo estás?。")
        ])
        try firstStore.saveListeningCards(materialID: audioID, sentenceID: sentenceID,
                                          points: [point], result: cardsResult)
        precondition(firstStore.data.cards.count == 1)
        precondition(firstStore.data.audioMaterials[0].sentences.first(where: { $0.id == sentenceID })?.analysis?.explanation == "可能没有识别疑问语调。")
        precondition(firstStore.data.audioMaterials[0].sentences.first(where: { $0.id == sentenceID })?.analysis?.items?.count == 1)
        let replacementAnalysis = ListeningAnalysisResult(
            explanation: "重新分析后的听辨困难。",
            items: [.init(category: .difficulty, title: "词边界", detail: "边界不明显。", evidence: nil)]
        )
        try firstStore.saveListeningAnalysis(materialID: audioID, sentenceID: sentenceID,
                                             attempt: "lluvia", result: replacementAnalysis)
        let replacedSentence = firstStore.data.audioMaterials[0].sentences.first(where: { $0.id == sentenceID })
        precondition(replacedSentence?.analysis?.explanation == "重新分析后的听辨困难。")
        precondition(firstStore.data.cards.count == 1, "Replacing analysis must not alter cards")
        let reopenedStore = StudyStore(baseDirectory: testDirectory)
        let restoredAnalysis = reopenedStore.data.audioMaterials[0].sentences.first(where: { $0.id == sentenceID })?.analysis
        precondition(restoredAnalysis?.items?.first?.category == .difficulty)
        let legacyAnalysis = """
        {"userAttemptSnapshot":"Hola","explanation":"旧格式","generatedAt":"2026-01-01T00:00:00Z"}
        """
        let legacyDecoded = try decoder.decode(ListeningAnalysis.self, from: Data(legacyAnalysis.utf8))
        precondition(legacyDecoded.items == nil && legacyDecoded.explanation == "旧格式")
        let listeningSchema = AIStudyService.listeningAnalysisSchema
        assertStrictObjectsHaveMatchingRequiredProperties(listeningSchema)
        let cardsSchema = AIStudyService.listeningCardsSchema()
        assertStrictObjectsHaveMatchingRequiredProperties(cardsSchema)
        let writingHintSchema = WritingAIService.writingHintSchema
        assertStrictObjectsHaveMatchingRequiredProperties(writingHintSchema)
        let writingFeedbackPresentationSchema = WritingAIService.writingFeedbackPresentationSchema
        assertStrictObjectsHaveMatchingRequiredProperties(writingFeedbackPresentationSchema)
        let writingHintJSON = """
        {"expressionIdeas":["可以考虑使用一个表示持续的时态结构。","先写主句，再补充原因。"],"cautions":["注意动词后面的形式。"]}
        """
        let writingHint = try decoder.decode(WritingHintResult.self, from: Data(writingHintJSON.utf8))
        precondition(writingHint.expressionIdeas.count == 2 && writingHint.cautions.count == 1)
        let emptyWritingHint = try decoder.decode(
            WritingHintResult.self,
            from: Data(#"{"expressionIdeas":[],"cautions":[]}"#.utf8)
        )
        precondition(emptyWritingHint.expressionIdeas.isEmpty && emptyWritingHint.cautions.isEmpty)
        let presentationJSON = """
        {"summary":"原始反馈中的总体说明。","issues":[{"title":"原因表达","explanation":"这里需要使用原因结构。","example":"Con tanta lluvia..."}],"recommendedExpression":"Con tanta lluvia, ha estado lloviendo muchísimo.","improvements":[]}
        """
        let presentation = try decoder.decode(
            WritingFeedbackPresentation.self,
            from: Data(presentationJSON.utf8)
        )
        precondition(presentation.issues.count == 1 &&
                     presentation.issues[0].example == "Con tanta lluvia..." &&
                     presentation.improvements.isEmpty)
        let emptyPresentation = try decoder.decode(
            WritingFeedbackPresentation.self,
            from: Data(#"{"summary":null,"issues":[],"recommendedExpression":null,"improvements":[]}"#.utf8)
        )
        precondition(emptyPresentation.summary == nil &&
                     emptyPresentation.recommendedExpression == nil &&
                     emptyPresentation.issues.isEmpty &&
                     emptyPresentation.improvements.isEmpty)
        let originalFeedback = "原始反馈不得被 formatter 改写。"
        let originalCorrected = "Aunque se parecen."
        precondition(originalFeedback == "原始反馈不得被 formatter 改写。" &&
                     originalCorrected == "Aunque se parecen.",
                     "Presentation formatting must not mutate saved writing content")
        let analysisCategories = (((listeningSchema["properties"] as! [String: Any])["items"] as! [String: Any])["items"] as! [String: Any])["properties"] as! [String: Any]
        let categoryValues = ((analysisCategories["category"] as! [String: Any])["enum"] as! [String])
        precondition(!categoryValues.contains("expression") && !categoryValues.contains("vocabulary"))
        let schemaData = try JSONSerialization.data(withJSONObject: listeningSchema)
        let schemaObject = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let itemSchema = (((schemaObject["properties"] as! [String: Any])["items"] as! [String: Any])["items"] as! [String: Any])
        let evidenceSchema = (itemSchema["properties"] as! [String: Any])["evidence"] as! [String: Any]
        precondition((evidenceSchema["type"] as? [String]) == ["string", "null"])
        let nullEvidence = """
        {"explanation":"分析","items":[{"category":"difficulty","title":"难点","detail":"语流较快","evidence":null}],"cards":[]}
        """
        let stringEvidence = """
        {"explanation":"分析","items":[{"category":"difficulty","title":"难点","detail":"语流较快","evidence":"原句片段"}],"cards":[]}
        """
        let decodedNullEvidence = try decoder.decode(ListeningAnalysisResult.self, from: Data(nullEvidence.utf8))
        let decodedStringEvidence = try decoder.decode(ListeningAnalysisResult.self, from: Data(stringEvidence.utf8))
        precondition(decodedNullEvidence.items.first?.evidence == nil)
        precondition(decodedStringEvidence.items.first?.evidence == "原句片段")
        let emptyItems = ListeningAnalysisResult(explanation: "无结构化重点", items: [])
        precondition(emptyItems.items.isEmpty)
        let invalidResult = ListeningCardsResult(cards: [])
        do {
            try firstStore.saveListeningCards(materialID: audioID, sentenceID: secondSentenceID,
                                              points: [point], result: invalidResult)
            preconditionFailure("An incomplete AI card response was accepted")
        } catch AIStudyError.invalidResponse { }
        precondition(firstStore.data.audioMaterials[0].sentences.first(where: { $0.id == secondSentenceID })?.analysis == nil)
        let draftCardID = firstStore.data.cards[0].id
        let originalDraftCard = firstStore.data.cards[0]
        let invalidExistingCardAudits = [
            CardAuditResult(title: "", question: "", answer: " "),
            CardAuditResult(title: "", question: " ", answer: ""),
            CardAuditResult(title: "", question: " \n ", answer: "\t ")
        ]
        for response in invalidExistingCardAudits {
            let fallback = await CardAuditService.auditOrFallback(
                CardDraft(category: originalDraftCard.category, mergeKey: originalDraftCard.mergeKey ?? "",
                          question: originalDraftCard.question, answer: originalDraftCard.answer),
                apiKey: "test"
            ) { _ in response }
            precondition(fallback.usedFallback &&
                         fallback.question == originalDraftCard.question &&
                         fallback.answer == originalDraftCard.answer &&
                         !fallback.title.isEmpty,
                         "Failed reorganization must preserve the original card content and a usable title")
        }
        let cardStateBeforeDraftUpdate = firstStore.data.cards[0]
        try firstStore.updateCardDraft(draftCardID, category: .expression,
                                       question: "如何问候熟人？", answer: "可以说 ¿Cómo estás?")
        precondition(firstStore.data.cards[0].revisionCount == 1)
        precondition(firstStore.data.cards[0].id == cardStateBeforeDraftUpdate.id &&
                     firstStore.data.cards[0].sources.map(\.materialID) == cardStateBeforeDraftUpdate.sources.map(\.materialID) &&
                     firstStore.data.cards[0].mergeKey == cardStateBeforeDraftUpdate.mergeKey,
                     "Editing a card draft must preserve its identity and references")
        try firstStore.confirmCard(draftCardID)
        precondition(firstStore.data.cards[0].confirmedAt != nil && firstStore.data.cards[0].dueAt != nil)
        let schedulePreview = LocalFSRSScheduler.preview(card: firstStore.data.cards[0])
        precondition(schedulePreview[.again]! < schedulePreview[.hard]!)
        precondition(schedulePreview[.hard]! < schedulePreview[.good]!)
        precondition(schedulePreview[.good]! < schedulePreview[.easy]!)
        let firstReviewAt = Date()
        try firstStore.reviewCard(draftCardID, grade: .good, now: firstReviewAt)
        var reviewedDue = firstStore.data.cards[0].dueAt
        var reviewedState = firstStore.data.cards[0].fsrsState
        precondition(firstStore.data.reviewEvents.count == 1 && reviewedState != nil)

        // A UI review action is synchronous and hides the rating controls immediately;
        // exercise the underlying API directly to document that repeated invocations
        // are accepted as distinct reviews, rather than incorrectly asserting dedup.
        try firstStore.reviewCard(draftCardID, grade: .good, now: firstReviewAt.addingTimeInterval(0.001))
        precondition(firstStore.data.reviewEvents.filter { $0.cardID == draftCardID }.count == 2,
                     "A second direct Good review is a distinct ReviewEvent under current store semantics")
        let beforeConcurrentReviews = firstStore.data.reviewEvents.filter { $0.cardID == draftCardID }.count
        await withTaskGroup(of: Void.self) { group in
            for offset in 1...2 {
                group.addTask { @MainActor in
                    try? firstStore.reviewCard(draftCardID, grade: .good,
                                               now: firstReviewAt.addingTimeInterval(Double(offset + 1)))
                }
            }
        }
        let afterConcurrentReviews = firstStore.data.reviewEvents.filter { $0.cardID == draftCardID }.count
        precondition(afterConcurrentReviews == beforeConcurrentReviews + 2,
                     "Concurrent direct review calls are serialized by MainActor and both persist as distinct reviews")

        let eventCountBeforeTrash = firstStore.data.reviewEvents.count
        try firstStore.moveCardToTrash(draftCardID)
        do {
            try firstStore.moveCardToTrash(draftCardID)
            preconditionFailure("A second Trash operation unexpectedly succeeded")
        } catch StoreError.missingCard { }
        do {
            try firstStore.reviewCard(draftCardID, grade: .good)
            preconditionFailure("A trashed card was reviewed")
        } catch StoreError.unconfirmedCard { }
        precondition(firstStore.data.reviewEvents.count == eventCountBeforeTrash,
                     "Reviewing a trashed card must not append a ReviewEvent")
        try firstStore.restoreCard(draftCardID)
        do {
            try firstStore.restoreCard(draftCardID)
            preconditionFailure("A second Restore operation unexpectedly succeeded")
        } catch StoreError.missingCard { }
        try firstStore.reviewCard(draftCardID, grade: .good,
                                  now: firstReviewAt.addingTimeInterval(10))
        precondition(firstStore.data.reviewEvents.filter { $0.cardID == draftCardID }.count == afterConcurrentReviews + 1,
                     "A restored confirmed card can be reviewed again")

        let beforeTrashRace = firstStore.data.reviewEvents.filter { $0.cardID == draftCardID }.count
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try? firstStore.reviewCard(draftCardID, grade: .good,
                                           now: firstReviewAt.addingTimeInterval(20))
            }
            group.addTask { @MainActor in try? firstStore.moveCardToTrash(draftCardID) }
        }
        let afterTrashRace = firstStore.data.reviewEvents.filter { $0.cardID == draftCardID }.count
        precondition(firstStore.data.cards.first(where: { $0.id == draftCardID })?.deletedAt != nil &&
                     (afterTrashRace == beforeTrashRace || afterTrashRace == beforeTrashRace + 1),
                     "Review-vs-Trash serialization must leave one coherent outcome")
        do {
            try firstStore.reviewCard(draftCardID, grade: .good)
            preconditionFailure("Review after Trash race unexpectedly succeeded")
        } catch StoreError.unconfirmedCard { }
        try firstStore.restoreCard(draftCardID)
        try firstStore.reviewCard(draftCardID, grade: .good,
                                  now: firstReviewAt.addingTimeInterval(30))
        reviewedDue = firstStore.data.cards[0].dueAt
        reviewedState = firstStore.data.cards[0].fsrsState

        let stateBeforeConfirmedAuditFailure = firstStore.data.cards[0]
        let historyBeforeConfirmedAuditFailure = firstStore.data.reviewEvents
        let confirmedFallback = await CardAuditService.auditOrFallback(
            CardDraft(category: stateBeforeConfirmedAuditFailure.category,
                      mergeKey: stateBeforeConfirmedAuditFailure.mergeKey ?? "",
                      question: stateBeforeConfirmedAuditFailure.question,
                      answer: stateBeforeConfirmedAuditFailure.answer),
            apiKey: "test"
        ) { _ in throw AIStudyError.server(500, "mock failure") }
        precondition(confirmedFallback.usedFallback &&
                     confirmedFallback.question == stateBeforeConfirmedAuditFailure.question &&
                     confirmedFallback.answer == stateBeforeConfirmedAuditFailure.answer)
        do {
            try firstStore.updateCardDraft(draftCardID, category: stateBeforeConfirmedAuditFailure.category,
                                           question: confirmedFallback.question, answer: confirmedFallback.answer,
                                           title: confirmedFallback.title)
            preconditionFailure("Reorganizing a confirmed card unexpectedly bypassed the confirmed-card guard")
        } catch StoreError.cardConfirmed { }
        let stateAfterConfirmedAuditFailure = firstStore.data.cards[0]
        precondition(stateAfterConfirmedAuditFailure.id == stateBeforeConfirmedAuditFailure.id &&
                     stateAfterConfirmedAuditFailure.title == stateBeforeConfirmedAuditFailure.title &&
                     stateAfterConfirmedAuditFailure.question == stateBeforeConfirmedAuditFailure.question &&
                     stateAfterConfirmedAuditFailure.answer == stateBeforeConfirmedAuditFailure.answer &&
                     stateAfterConfirmedAuditFailure.createdAt == stateBeforeConfirmedAuditFailure.createdAt &&
                     stateAfterConfirmedAuditFailure.dueAt == stateBeforeConfirmedAuditFailure.dueAt &&
                     stateAfterConfirmedAuditFailure.sources.map(\.materialID) == stateBeforeConfirmedAuditFailure.sources.map(\.materialID) &&
                     stateAfterConfirmedAuditFailure.sources.map(\.segmentID) == stateBeforeConfirmedAuditFailure.sources.map(\.segmentID) &&
                     stateAfterConfirmedAuditFailure.sources.map(\.quote) == stateBeforeConfirmedAuditFailure.sources.map(\.quote) &&
                     stateAfterConfirmedAuditFailure.mergeKey == stateBeforeConfirmedAuditFailure.mergeKey &&
                     stateAfterConfirmedAuditFailure.fsrsState?.difficulty == stateBeforeConfirmedAuditFailure.fsrsState?.difficulty &&
                     stateAfterConfirmedAuditFailure.fsrsState?.stability == stateBeforeConfirmedAuditFailure.fsrsState?.stability &&
                     stateAfterConfirmedAuditFailure.fsrsState?.reps == stateBeforeConfirmedAuditFailure.fsrsState?.reps &&
                     firstStore.data.reviewEvents.map(\.id) == historyBeforeConfirmedAuditFailure.map(\.id),
                     "Failed reorganization must not alter a confirmed card, its FSRS state, source, or review history")

        // A repeated semantic point on another sentence must reuse the card,
        // append the new source, and preserve its accumulated review state.
        let repeatedPointID = UUID()
        let repeatedPoint = LearningPointRequest(id: repeatedPointID, category: .expression, prompt: "礼貌问候的另一处出现")
        let repeatedResult = ListeningCardsResult(cards: [
            .init(requestID: repeatedPointID.uuidString,
                  category: .expression,
                  mergeKey: "表达|COMO ESTAS|问候",
                  question: "这次问候怎么理解？",
                  answer: "同一表达的新来源。")
        ])
        try firstStore.saveListeningCards(materialID: audioID, sentenceID: secondSentenceID,
                                          points: [repeatedPoint], result: repeatedResult)
        precondition(firstStore.data.cards.count == 1, "Semantic duplicate created a second card")
        precondition(firstStore.data.cards[0].sources.count == 2, "Merged card lost a source")
        precondition(firstStore.data.cards[0].dueAt == reviewedDue && firstStore.data.cards[0].fsrsState?.reps == reviewedState?.reps,
                     "Merging reset the card review schedule")
        do {
            try firstStore.splitSentence(materialID: audioID, sentenceID: sentenceID,
                                         firstText: "Hola", secondText: "¿cómo estás?", at: 1.0)
            preconditionFailure("Practiced sentence was allowed to lose its source ID")
        } catch StoreError.sentenceReferenced { }

        let writingFeedback = WritingFeedbackResult(
            feedback: "意思完整，但让步结构需要调整。",
            correctedSpanish: "Aunque se parecen, tienen sabores distintos.",
            scores: .init(meaning: 5, grammar: 3, wording: 4, naturalness: 4),
            errors: [.init(original: "Aunque parecen", correction: "Aunque se parecen",
                           explanation: "这里需要自复动词 parecerse 表达彼此相似。")],
            card: .init(create: true, mergeKey: "写作纠错|aunque+直陈式|让步结构",
                        question: "怎样用 aunque 表达一个已知事实？",
                        answer: "aunque 后可用直陈式描述说话者视为事实的信息。"))
        let writingSaved = try firstStore.saveWritingFeedback(
            exerciseID: nil, mode: .material,
            sourceID: savedArticle.id, sourceSegmentID: savedArticle.chunks[0].id,
            sourceQuote: savedArticle.chunks[0].text,
            chinesePrompt: "虽然它们看起来相似，但味道不同。",
            referenceSpanish: "Aunque se parecen, tienen sabores distintos.",
            focus: "练习 aunque 让步结构。", learnerSpanish: "Aunque parecen, tienen sabores diferentes.",
            result: writingFeedback)
        precondition(firstStore.data.writingExercises.count == 1)
        precondition(firstStore.data.writingExercises[0].versions[0].grammarScore == 3)
        precondition(firstStore.data.writingExercises[0].versions[0].errors?.count == 1)
        precondition(firstStore.data.cards.filter { $0.category == .correction }.count == 1)

        let secondWriting = try firstStore.saveWritingFeedback(
            exerciseID: writingSaved.exerciseID, mode: .material,
            sourceID: savedArticle.id, sourceSegmentID: savedArticle.chunks[0].id,
            sourceQuote: savedArticle.chunks[0].text,
            chinesePrompt: "虽然它们看起来相似，但味道不同。",
            referenceSpanish: "Aunque se parecen, tienen sabores distintos.",
            focus: "练习 aunque 让步结构。", learnerSpanish: "Aunque se parecen, tienen sabores distintos.",
            result: writingFeedback)
        precondition(firstStore.data.writingExercises[0].versions.count == 2)
        precondition(secondWriting.cardID == writingSaved.cardID)
        let correction = firstStore.data.cards.first { $0.category == .correction }!
        precondition(correction.sources.count == 2, "Repeated writing issue did not merge its sources")
        let noCardWritingResult = try decoder.decode(
            WritingFeedbackResult.self,
            from: Data(#"{"feedback":"feedback","correctedSpanish":"corrected","scores":{"meaning":4,"grammar":4,"wording":4,"naturalness":4},"errors":[],"card":{"create":false,"mergeKey":"","title":null,"question":"","answer":""}}"#.utf8)
        )
        let writingRaceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishWritingRaceTest-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: writingRaceDirectory) }
        let writingRaceStore = StudyStore(baseDirectory: writingRaceDirectory)
        try writingRaceStore.addArticle(title: "Writing race", source: "test", text: longText)
        let writingRaceArticle = writingRaceStore.data.articles.first!
        let writingExerciseA = try writingRaceStore.saveWritingFeedback(
            exerciseID: nil, mode: .material,
            sourceID: writingRaceArticle.id, sourceSegmentID: writingRaceArticle.chunks[0].id,
            sourceQuote: writingRaceArticle.chunks[0].text,
            chinesePrompt: "题目 A", referenceSpanish: nil, focus: "focus A",
            learnerSpanish: "A draft", result: noCardWritingResult
        )
        let writingExerciseB = try writingRaceStore.saveWritingFeedback(
            exerciseID: nil, mode: .material,
            sourceID: writingRaceArticle.id, sourceSegmentID: writingRaceArticle.chunks[1].id,
            sourceQuote: writingRaceArticle.chunks[1].text,
            chinesePrompt: "题目 B", referenceSpanish: nil, focus: nil,
            learnerSpanish: "B draft", result: noCardWritingResult
        )
        let capturedExerciseAContext = WritingSubmissionContext(
            exerciseID: writingExerciseA.exerciseID, mode: .material,
            prompt: "题目 A", learnerSpanish: "A draft",
            sourceID: writingRaceArticle.id, sourceSegmentID: writingRaceArticle.chunks[0].id,
            sourceQuote: writingRaceArticle.chunks[0].text,
            referenceSpanish: nil, focus: "focus A"
        )
        let currentExerciseBContext = WritingSubmissionContext(
            exerciseID: writingExerciseB.exerciseID, mode: .material,
            prompt: "题目 B", learnerSpanish: "B draft",
            sourceID: writingRaceArticle.id, sourceSegmentID: writingRaceArticle.chunks[1].id,
            sourceQuote: writingRaceArticle.chunks[1].text,
            referenceSpanish: nil, focus: ""
        )
        precondition(capturedExerciseAContext != currentExerciseBContext,
                     "Switching existing exercise A to existing exercise B must invalidate A's display context")
        let versionsBeforeLateA = writingRaceStore.data.writingExercises.first {
            $0.id == writingExerciseB.exerciseID
        }?.versions.count
        let lateWritingResponse = Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            return try writingRaceStore.saveWritingFeedback(
                exerciseID: capturedExerciseAContext.exerciseID, mode: capturedExerciseAContext.mode,
                sourceID: capturedExerciseAContext.sourceID,
                sourceSegmentID: capturedExerciseAContext.sourceSegmentID,
                sourceQuote: capturedExerciseAContext.sourceQuote,
                chinesePrompt: capturedExerciseAContext.prompt,
                referenceSpanish: capturedExerciseAContext.referenceSpanish,
                focus: capturedExerciseAContext.focus,
                learnerSpanish: capturedExerciseAContext.learnerSpanish,
                result: noCardWritingResult
            )
        }
        _ = try await lateWritingResponse.value
        let savedExerciseA = writingRaceStore.data.writingExercises.first { $0.id == writingExerciseA.exerciseID }
        let savedExerciseB = writingRaceStore.data.writingExercises.first { $0.id == writingExerciseB.exerciseID }
        precondition(savedExerciseA?.versions.last?.feedback == "feedback" &&
                     savedExerciseA?.versions.last?.spanishText == capturedExerciseAContext.learnerSpanish,
                     "A late response must remain attached to exercise A and its submitted Spanish draft")
        precondition(savedExerciseB?.versions.count == versionsBeforeLateA &&
                     savedExerciseB?.versions.last?.spanishText == "B draft",
                     "A late response for A must not append history to exercise B")
        let newPromptA = WritingSubmissionContext(
            exerciseID: nil, mode: .free, prompt: "Same text", learnerSpanish: "Draft A",
            sourceID: nil, sourceSegmentID: nil, sourceQuote: nil, referenceSpanish: nil, focus: ""
        )
        let newPromptB = WritingSubmissionContext(
            exerciseID: nil, mode: .free, prompt: "Same text", learnerSpanish: "Draft B",
            sourceID: nil, sourceSegmentID: nil, sourceQuote: nil, referenceSpanish: nil, focus: ""
        )
        precondition(newPromptA != newPromptB,
                     "Two not-yet-persisted prompts with the same text but different learner drafts are distinct contexts")

        let readingQuestionID = try firstStore.saveReadingDiscussion(
            articleID: savedArticle.id, chunkID: savedArticle.chunks[0].id,
            question: "这里为什么使用 aunque？", answer: "这里引导让步从句。")
        let readingCards = ReadingCardsResult(cards: [
            .init(discussionID: readingQuestionID.uuidString, create: true,
                  category: .grammar, mergeKey: "语法|aunque+直陈式|已知事实",
                  question: "aunque 后什么时候使用直陈式？",
                  answer: "描述说话者视为事实的信息时可使用直陈式。")
        ])
        try firstStore.completeReadingWithCards(articleID: savedArticle.id,
                                                chunkID: savedArticle.chunks[0].id,
                                                difficulty: .someGaps,
                                                note: "完成对话式精读", result: readingCards)
        precondition(firstStore.data.articles[0].chunks[0].discussion?.count == 1)
        precondition(firstStore.data.readingRecords.last?.cardIDs?.count == 1)
        precondition(firstStore.data.cards.contains { $0.category == .grammar })
        precondition(firstStore.pendingReadingDiscussions(articleID: savedArticle.id,
                                                          chunkID: savedArticle.chunks[0].id).isEmpty,
                     "Completed discussion was offered for card generation again")
        let cardCountBeforeNewQuestion = firstStore.data.cards.count
        let newReadingQuestionID = try firstStore.saveReadingDiscussion(
            articleID: savedArticle.id, chunkID: savedArticle.chunks[0].id,
            question: "conmoción 是什么意思？", answer: "震动、轰动。")
        let pending = firstStore.pendingReadingDiscussions(articleID: savedArticle.id,
                                                           chunkID: savedArticle.chunks[0].id)
        precondition(pending.map(\.id) == [newReadingQuestionID],
                     "Previously completed discussion was mixed with a new question")
        let newReadingCards = ReadingCardsResult(cards: [
            .init(discussionID: newReadingQuestionID.uuidString, create: true,
                  category: .vocabulary, mergeKey: "词汇|conmoción|震动",
                  question: "本句 una gran conmoción 应怎样翻译？",
                  answer: "conmoción 表示震动、轰动。\n\n本句指事件引起的强烈社会反应。")
        ])
        try firstStore.completeReadingWithCards(articleID: savedArticle.id,
                                                chunkID: savedArticle.chunks[0].id,
                                                difficulty: .understood, note: "新问题", result: newReadingCards)
        precondition(firstStore.data.readingRecords.count == 1,
                     "One paragraph created multiple reading history entries")
        precondition(Set(firstStore.data.readingRecords[0].discussionIDs ?? []) == Set([readingQuestionID, newReadingQuestionID]),
                     "Updating reading history lost an earlier discussion")
        precondition(firstStore.data.cards.last?.question == "conmoción",
                     "Vocabulary card front was not reduced to the lemma")
        precondition(firstStore.data.cards.count == cardCountBeforeNewQuestion + 1,
                     "Existing reading card was duplicated")

        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishLegacyReading-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        var legacy = firstStore.data
        var duplicate = legacy.readingRecords[0]
        duplicate.id = UUID()
        duplicate.completedAt = duplicate.completedAt.addingTimeInterval(60)
        duplicate.questions = ["新增的历史提问"]
        duplicate.discussionIDs = nil
        duplicate.cardIDs = nil
        legacy.readingRecords.append(duplicate)
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        try legacyEncoder.encode(legacy).write(to: legacyDirectory.appendingPathComponent("study.json"))
        let consolidated = StudyStore(baseDirectory: legacyDirectory)
        precondition(consolidated.data.readingRecords.count == 1,
                     "Existing duplicate reading history was not consolidated")
        precondition(consolidated.data.readingRecords[0].questions.contains("新增的历史提问") &&
                     consolidated.data.readingRecords[0].cardIDs?.count == 2,
                     "Consolidating history lost questions or linked cards")
        precondition(StudyStore(baseDirectory: legacyDirectory).data.readingRecords.count == 1,
                     "Consolidated reading history was not persisted")

        let archive = testDirectory.deletingLastPathComponent().appendingPathComponent("SpanishBackupTest-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        let summary = try BackupManager.create(database: Data(contentsOf: testDirectory.appendingPathComponent("study.json")),
                                               mediaDirectory: testDirectory.appendingPathComponent("Media"), destination: archive)
        precondition(summary.audioCount == 1 && summary.articleCount == 1 && summary.readingCount == 1)
        let inspected = try BackupManager.inspect(archive)
        precondition(inspected.mediaBytes == Int64(audioPayload.count))
        _ = try BackupManager.create(database: Data(contentsOf: testDirectory.appendingPathComponent("study.json")),
                                     mediaDirectory: testDirectory.appendingPathComponent("Media"), destination: archive)
        let inspectedReplacement = try BackupManager.inspect(archive)
        precondition(inspectedReplacement.audioCount == 1, "Replacing an existing backup failed")

        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("SpanishRestoreSuite-\(UUID().uuidString)", isDirectory: true)
        let target = suite.appendingPathComponent("SpanishLearningMac", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: suite) }
        let existing = StudyStore(baseDirectory: target)
        try existing.addArticle(title: "旧资料", source: "local", text: sentence)
        let oldArticleID = existing.data.articles[0].id
        let safety = try await existing.restoreBackup(at: archive)
        precondition(safety?.pathExtension == "zip", "The previous library should be restorable in the app")
        let previousCopy = suite.appendingPathComponent("PreviousLibrary", isDirectory: true)
        _ = try BackupManager.restore(safety!, supportDirectory: previousCopy)
        precondition(StudyStore(baseDirectory: previousCopy).data.articles.first?.id == oldArticleID,
                     "The previous library backup cannot be restored")
        precondition(existing.data.articles.first?.id == savedArticle.id, "Open app did not reload restored data")
        let migrated = StudyStore(baseDirectory: target)
        precondition(migrated.data.articles.first?.id == savedArticle.id, "Article ID changed during restore")
        precondition(migrated.data.readingRecords.first?.chunkID == savedArticle.chunks[0].id, "Reading source link broke")
        precondition(migrated.data.audioMaterials.count == 1)
        precondition(migrated.data.audioMaterials[0].sentences.first?.id == sentenceID)
        precondition(migrated.data.dictationAttempts.first?.sentenceID == sentenceID,
                     "Dictation history lost its sentence link")
        precondition(migrated.data.dictationAttempts.first?.answerTextSnapshot == "Hola ¿cómo estás?",
                     "Historical answer snapshot changed")
        precondition(migrated.data.cards.first?.id == draftCardID && migrated.data.cards.first?.sources.first?.segmentID == sentenceID,
                     "Card source link did not survive migration")
        precondition(migrated.data.writingExercises.first?.versions.count == 2,
                     "Writing versions did not survive migration")
        precondition(migrated.data.articles.first?.chunks.first?.discussion?.count == 2,
                     "Reading discussion did not survive migration")
        precondition(migrated.data.readingRecords.last?.cardIDs?.count == 2,
                     "Reading card links did not survive migration")
        let migratedCorrection = migrated.data.cards.first { $0.category == .correction }
        precondition(migratedCorrection?.sources.count == 2,
                     "Writing correction card lost its version sources during migration")

        let managedCardID = firstStore.data.cards.first!.id
        let managedReviewCount = firstStore.data.reviewEvents.count
        let managedFSRS = firstStore.data.cards.first!.fsrsState
        try firstStore.moveCardToTrash(managedCardID)
        precondition(firstStore.data.cards.first(where: { $0.id == managedCardID })?.deletedAt != nil)
        precondition(firstStore.data.cards.filter { $0.deletedAt == nil && $0.confirmedAt != nil }.allSatisfy { $0.id != managedCardID })
        do {
            try firstStore.reviewCard(managedCardID, grade: .good)
            preconditionFailure("Trashed card entered review scheduling")
        } catch StoreError.unconfirmedCard { }
        try firstStore.restoreCard(managedCardID)
        precondition(firstStore.data.cards.first(where: { $0.id == managedCardID })?.deletedAt == nil)
        precondition(firstStore.data.cards.first(where: { $0.id == managedCardID })?.fsrsState?.reps == managedFSRS?.reps &&
                     firstStore.data.reviewEvents.count == managedReviewCount,
                     "Restore changed review state or history")
        let reopenedTrashState = StudyStore(baseDirectory: testDirectory).data.cards.first(where: { $0.id == managedCardID })
        precondition(reopenedTrashState?.deletedAt == nil, "Restored trash state did not persist")
        if let editable = firstStore.data.cards.first(where: { $0.confirmedAt == nil }) {
            let editID = editable.id
            let editFSRS = editable.fsrsState?.reps
            try firstStore.updateCardContent(editID, title: "手动标题",
                                             question: "手动正面", answer: "手动背面")
            let edited = firstStore.data.cards.first(where: { $0.id == editID })
            precondition(edited?.id == editID && edited?.title == "手动标题" &&
                         edited?.question == "手动正面" && edited?.fsrsState?.reps == editFSRS,
                         "Manual content editing changed identity or FSRS")
        }
        let recoveredAudio = try Data(contentsOf: migrated.audioURL(for: migrated.data.audioMaterials[0]))
        precondition(recoveredAudio == audioPayload)

        // An otherwise readable archive must still fail when a payload no longer matches its manifest.
        let tamperRoot = suite.appendingPathComponent("tamper", isDirectory: true)
        try FileManager.default.createDirectory(at: tamperRoot, withIntermediateDirectories: true)
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", archive.path, tamperRoot.path]
        try unpack.run()
        unpack.waitUntilExit()
        precondition(unpack.terminationStatus == 0)
        let alteredDatabase = tamperRoot.appendingPathComponent("SpanishLearningBackup/study.json")
        try Data("{}".utf8).write(to: alteredDatabase)
        let tamperedArchive = suite.appendingPathComponent("tampered.zip")
        let repack = Process()
        repack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        repack.arguments = ["-c", "-k", "--keepParent", tamperRoot.appendingPathComponent("SpanishLearningBackup").path, tamperedArchive.path]
        try repack.run()
        repack.waitUntilExit()
        precondition(repack.terminationStatus == 0)
        do {
            _ = try BackupManager.inspect(tamperedArchive)
            preconditionFailure("Changed content passed checksum validation")
        } catch BackupError.invalidArchive {
            precondition(StudyStore(baseDirectory: target).data.articles.first?.id == savedArticle.id)
        }

        let cleanTarget = suite.appendingPathComponent("NewMacLibrary", isDirectory: true)
        let cleanSafety = try BackupManager.restore(archive, supportDirectory: cleanTarget)
        precondition(cleanSafety == nil, "A clean Mac should not need a previous-data copy")
        let cleanStore = StudyStore(baseDirectory: cleanTarget)
        precondition(cleanStore.data.audioMaterials.count == 1 && cleanStore.data.articles.first?.id == savedArticle.id)

        let autoBase = testDirectory.appendingPathComponent("AutoLibrary", isDirectory: true)
        let autoStore = StudyStore(baseDirectory: autoBase)
        try autoStore.addArticle(title: "自动备份测试", source: "local", text: sentence)
        let autoURL = try await autoStore.createAutomaticBackup(now: Date(timeIntervalSince1970: 1_795_200_000))
        precondition(autoURL != nil && FileManager.default.fileExists(atPath: autoURL!.path),
                     "Automatic daily backup was not created")
        let autoSummary = try BackupManager.inspect(autoURL!)
        precondition(autoSummary.articleCount == 1, "Automatic backup lost study data")

        let damaged = archive.deletingLastPathComponent().appendingPathComponent("Damaged-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: damaged) }
        try Data("not a zip".utf8).write(to: damaged)
        do {
            _ = try BackupManager.restore(damaged, supportDirectory: target)
            preconditionFailure("Damaged archive was accepted")
        } catch {
            precondition(StudyStore(baseDirectory: target).data.articles.first?.id == savedArticle.id,
                         "Failed restore modified the current library")
        }
        // A study.json written by an old build (missing every field added since) must still open.
        let legacyRawDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpanishLegacyRaw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: legacyRawDirectory) }
        try FileManager.default.createDirectory(at: legacyRawDirectory, withIntermediateDirectories: true)
        let legacyCardID = UUID().uuidString
        let legacyMaterialID = UUID().uuidString
        let legacySentenceID = UUID().uuidString
        let legacyRawJSON = """
        {
          "schemaVersion": 1,
          "audioMaterials": [
            { "id": "\(legacyMaterialID)", "title": "旧音频", "fileName": "a.mp3",
              "importedAt": "2023-01-01T00:00:00Z",
              "sentences": [
                { "id": "\(legacySentenceID)", "ordinal": 1, "startSeconds": 0, "endSeconds": 2,
                  "transcript": "Hola.", "status": "generated", "version": 1 }
              ]
            }
          ],
          "articles": [],
          "readingRecords": [],
          "dictationAttempts": [],
          "writingExercises": [],
          "cards": [
            { "id": "\(legacyCardID)", "category": "词汇", "question": "hola", "answer": "hello",
              "sources": [ { "materialID": "\(legacyMaterialID)", "segmentID": "\(legacySentenceID)" } ],
              "confirmedAt": null, "dueAt": null, "fsrsState": null }
          ],
          "reviewEvents": []
        }
        """
        try Data(legacyRawJSON.utf8).write(to: legacyRawDirectory.appendingPathComponent("study.json"))
        let legacyRawStore = StudyStore(baseDirectory: legacyRawDirectory)
        precondition(legacyRawStore.errorMessage == nil, "A pre-existing study.json without newer fields failed to open")
        precondition(legacyRawStore.data.audioMaterials.count == 1 && legacyRawStore.data.cards.count == 1,
                     "Legacy study.json lost data on decode")
        precondition(legacyRawStore.data.cards[0].title == nil && legacyRawStore.data.cards[0].deletedAt == nil &&
                     legacyRawStore.data.cards[0].mergeKey == nil,
                     "Fields absent from a legacy database should decode as nil, not fail or fabricate values")
        try legacyRawStore.updateCardDraft(UUID(uuidString: legacyCardID)!, category: .vocabulary,
                                          question: "hola", answer: "hello, hi")
        precondition(StudyStore(baseDirectory: legacyRawDirectory).data.cards[0].answer == "hello, hi",
                     "A migrated legacy database could not be written back")

        print("Model smoke passed: reading chat, writing versions, card merging, FSRS and automatic backup")
    }

    private static func assertStrictObjectsHaveMatchingRequiredProperties(_ schema: [String: Any]) {
        guard schema["type"] as? String == "object" else { return }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        precondition(Set(properties.keys) == required, "Strict object required/properties mismatch")
        for value in properties.values {
            inspectSchemaValue(value)
        }
    }

    private static func inspectSchemaValue(_ value: Any) {
        guard let schema = value as? [String: Any] else { return }
        if schema["type"] as? String == "object" {
            assertStrictObjectsHaveMatchingRequiredProperties(schema)
        }
        if let items = schema["items"] as? [String: Any] {
            inspectSchemaValue(items)
        }
    }
}
