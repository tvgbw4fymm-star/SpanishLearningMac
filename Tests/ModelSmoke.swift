import Foundation

@main
struct ModelSmoke {
    @MainActor static func main() async throws {
        let sentence = "La conversación continúa en la ciudad."
        let longText = Array(repeating: sentence, count: 100).joined(separator: " ")
        let chunks = ArticleSplitter.split(longText)
        precondition(chunks.count >= 2, "A long article must be divided")
        precondition(chunks.joined(separator: " ") == longText, "Chunking must preserve the text")

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
        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SpanishLearningStoreTest-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let firstStore = StudyStore(baseDirectory: testDirectory)
        try firstStore.addArticle(title: "Artículo", source: "Prueba", text: longText)
        let savedArticle = firstStore.data.articles.first!
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
        precondition(parsed.count == 2 && parsed[0].startSeconds == 0 && parsed[1].endSeconds == 6)
        let subtitleSource = testDirectory.deletingLastPathComponent().appendingPathComponent("SpanishTest-\(UUID().uuidString).vtt")
        defer { try? FileManager.default.removeItem(at: subtitleSource) }
        try Data(subtitle.utf8).write(to: subtitleSource)
        try firstStore.importSubtitles(from: subtitleSource, materialID: audioID)
        precondition(firstStore.data.audioMaterials[0].transcriptionComplete == true)
        precondition(firstStore.data.audioMaterials[0].sentences.count == 2)
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
        try firstStore.updateCardDraft(draftCardID, category: .expression,
                                       question: "如何问候熟人？", answer: "可以说 ¿Cómo estás?")
        precondition(firstStore.data.cards[0].revisionCount == 1)
        try firstStore.confirmCard(draftCardID)
        precondition(firstStore.data.cards[0].confirmedAt != nil && firstStore.data.cards[0].dueAt != nil)
        let schedulePreview = LocalFSRSScheduler.preview(card: firstStore.data.cards[0])
        precondition(schedulePreview[.again]! < schedulePreview[.hard]!)
        precondition(schedulePreview[.hard]! < schedulePreview[.good]!)
        precondition(schedulePreview[.good]! < schedulePreview[.easy]!)
        let firstReviewAt = Date()
        try firstStore.reviewCard(draftCardID, grade: .good, now: firstReviewAt)
        let reviewedDue = firstStore.data.cards[0].dueAt
        let reviewedState = firstStore.data.cards[0].fsrsState
        precondition(firstStore.data.reviewEvents.count == 1 && reviewedState != nil)

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
