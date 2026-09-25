import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct ListeningView: View {
    @EnvironmentObject private var store: StudyStore
    @Binding var selectedID: UUID?
    @Binding var selectedSentenceID: UUID?
    @State private var player: AVAudioPlayer?
    @State private var playbackID = UUID()
    @State private var playing = false
    @State private var playbackSentenceID: UUID?
    @State private var playbackEndSeconds = 0.0
    @State private var draft = ""
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var showReview = false
    @State private var status: String?
    @State private var learningPoints: [LearningPointRequest] = ListeningView.defaultPoints()
    @State private var isAnalyzingListening = false
    @State private var isGeneratingCards = false
    @State private var isAuditingCards = false
    @State private var showPasteSubtitles = false

    private var material: AudioMaterial? {
        store.data.audioMaterials.first(where: { $0.id == selectedID }) ?? store.data.audioMaterials.first
    }
    private var sentence: ListeningSentence? {
        guard let material else { return nil }
        return material.sentences.first(where: { $0.id == selectedSentenceID }) ?? material.sentences.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "Listening studio", title: "听一遍，再写下来。",
                                subtitle: "选择语料，逐句核对，按自己的节奏练习。")
                }
                if store.data.audioMaterials.isEmpty {
                    ContentUnavailableView("尚无音频", systemImage: "waveform",
                                           description: Text("选择本机的 MP3、M4A 或 WAV 文件开始。"))
                } else if let material {
                    Picker("选择语料", selection: $selectedID) {
                        ForEach(store.data.audioMaterials) { item in
                            Text(item.title).tag(Optional(item.id))
                        }
                    }
                    .labelsHidden()
                    .studyPickerChrome()
                    .frame(maxWidth: 620)
                    .onChange(of: selectedID) { _, _ in selectedSentenceID = nil }
                    HStack(spacing: 12) {
                        Button("导入音频/视频", systemImage: "plus") { importMedia() }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                        Button("导入字幕文件", systemImage: "captions.bubble") { importSubtitles(material) }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                            .disabled(store.activeTranscriptions.contains(material.id))
                        Button("粘贴字幕", systemImage: "doc.on.clipboard") { showPasteSubtitles = true }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                        Text("支持 SRT / VTT；按字幕时间自动切成练习句。")
                            .font(AppType.ui(12)).foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 18) {
                                    materialSummary(material)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer(minLength: 8)
                                    materialActions(material)
                                }
                                VStack(alignment: .leading, spacing: 16) {
                                    materialSummary(material)
                                    materialActions(material)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if store.activeTranscriptions.contains(material.id) {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("正在转写并保存进度…").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("暂停") { store.pauseTranscription(materialID: material.id) }
                                }
                            }
                            if let progress = store.transcriptionStatus[material.id] {
                                Text(progress).font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                            }
                            if !material.sentences.isEmpty {
                                HStack(spacing: 12) {
                                    Button("核对字幕与分句", systemImage: "text.badge.checkmark") { showReview = true }
                                        .buttonStyle(AppActionButtonStyle())
                                    if material.transcriptionComplete == true,
                                       material.sentences.contains(where: { $0.status == .generated }) {
                                        Button("开始逐句听写", systemImage: "play.fill") {
                                            do {
                                                try store.verifyTranscript(materialID: material.id)
                                                selectedSentenceID = material.sentences.first?.id
                                                status = "已进入逐句听写。可以先播放，再写下听到的内容。"
                                            } catch { status = error.localizedDescription }
                                        }
                                        .buttonStyle(AppActionButtonStyle(prominent: true))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    if !material.sentences.isEmpty,
                       material.transcriptionComplete == true,
                       !material.sentences.contains(where: { $0.status == .generated }),
                       let sentence {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 16) {
                                Picker("选择句子", selection: $selectedSentenceID) {
                                    ForEach(material.sentences) { item in
                                        Text("第 \(item.ordinal) 句 · \(formatTime(item.startSeconds))")
                                            .tag(Optional(item.id))
                                    }
                                }
                                .labelsHidden()
                                .studyPickerChrome()
                                .frame(maxWidth: 340)
                                HStack {
                                    Text("第 \(sentence.ordinal) 句 / 共 \(material.sentences.count) 句")
                                        .font(AppType.ui(17, weight: .semibold))
                                    Spacer()
                                    Text("\(formatTime(sentence.startSeconds)) – \(formatTime(sentence.endSeconds))")
                                        .font(AppType.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 12) {
                                    Button(playing && playbackSentenceID == sentence.id ? "暂停" :
                                           player != nil && playbackSentenceID == sentence.id ? "继续播放" : "播放本句",
                                           systemImage: playing && playbackSentenceID == sentence.id ? "pause.fill" : "play.fill") {
                                        togglePlayback(material: material, sentence: sentence)
                                    }
                                    .buttonStyle(AppActionButtonStyle(prominent: true))
                                    Button("下一句") {
                                        persistDraft()
                                        nextSentence(material, sentence)
                                    }
                                    .buttonStyle(SecondaryPlaybackButtonStyle())
                                    .disabled(sentence.ordinal >= material.sentences.count)
                                    Button("后退 2 秒", systemImage: "gobackward.2") { seek(sentence: sentence, by: -2) }
                                        .buttonStyle(SecondaryPlaybackButtonStyle())
                                        .disabled(player == nil || playbackSentenceID != sentence.id)
                                    Button("前进 2 秒", systemImage: "goforward.2") { seek(sentence: sentence, by: 2) }
                                        .buttonStyle(SecondaryPlaybackButtonStyle())
                                        .disabled(player == nil || playbackSentenceID != sentence.id)
                                    Button("重听", systemImage: "arrow.clockwise") { play(material: material, sentence: sentence) }
                                        .buttonStyle(SecondaryPlaybackButtonStyle())
                                }
                                Text("你听到了什么？").font(AppType.ui(14, weight: .semibold))
                                TextEditor(text: $draft)
                                    .font(AppType.ui(17))
                                    .frame(height: 88)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .studyInputChrome()
                                    .disabled(sentence.answerRevealed == true)
                                if sentence.answerRevealed == true {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("原句").font(AppType.ui(12, weight: .semibold)).foregroundStyle(.secondary)
                                        Text(sentence.transcript).font(AppType.reading(19)).textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    Button("再听，再写同一句", systemImage: "arrow.counterclockwise") {
                                        retry(material, sentence)
                                    }
                                    VStack(alignment: .leading, spacing: 16) {
                                        if let analysis = sentence.analysis {
                                            ListeningAnalysisView(analysis: analysis)
                                            if let count = sentence.learningPoints?.count, count > 0 {
                                                Text("已生成 \(count) 张卡片草稿，可到“卡片”中检查。")
                                                    .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                                            }
                                            HStack {
                                                Spacer()
                                                if isAnalyzingListening { ProgressView().controlSize(.small) }
                                                Button("重新分析", systemImage: "arrow.clockwise") {
                                                    analyzeListening(material, sentence)
                                                }
                                                .buttonStyle(.borderless)
                                                .disabled(isAnalyzingListening)
                                            }
                                        } else {
                                            HStack {
                                                Text("先分析这句为什么不容易听懂，再决定要积累什么。")
                                                    .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                                                Spacer()
                                                if isAnalyzingListening { ProgressView().controlSize(.small) }
                                                Button("AI 听力分析", systemImage: "waveform.and.magnifyingglass") {
                                                    analyzeListening(material, sentence)
                                                }
                                                .buttonStyle(AppActionButtonStyle(prominent: true))
                                                .disabled(isAnalyzingListening)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    LearningPointsEditor(points: $learningPoints)
                                    HStack {
                                        Spacer()
                                        if isGeneratingCards || isAuditingCards { ProgressView().controlSize(.small) }
                                        Button("生成卡片草稿") {
                                            generateListeningCards(material, sentence)
                                        }
                                        .buttonStyle(AppActionButtonStyle(prominent: true))
                                        .disabled(isGeneratingCards || isAuditingCards)
                                    }
                                } else {
                                    HStack {
                                        Spacer()
                                        Button("看答案") { reveal(material, sentence) }
                                            .buttonStyle(AppActionButtonStyle(prominent: true))
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    } else if !material.sentences.isEmpty {
                        Text(material.transcriptionComplete == true ? "字幕已切句。点击“核对字幕与分句”，完成后即可逐句听写。" : "本机转写尚未完成；也可导入带时间戳字幕开始核对。")
                            .font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary)
                    }
                }
                if let status { Text(status).font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .onAppear { if selectedID == nil { selectedID = store.data.audioMaterials.first?.id }; loadDraft(); loadLearningPoints() }
        .onDisappear { stopAudio(); persistDraft() }
        .onChange(of: selectedID) { _, _ in stopAudio(); loadDraft(); loadLearningPoints() }
        .onChange(of: selectedSentenceID) { _, _ in stopAudio(); loadDraft(); loadLearningPoints() }
        .onChange(of: draft) { _, _ in scheduleDraftSave() }
        .sheet(isPresented: $showReview) {
            if let material { TranscriptReviewSheet(materialID: material.id) }
        }
        .sheet(isPresented: $showPasteSubtitles) {
            if let material { PasteSubtitleSheet(materialID: material.id) }
        }
    }

    static func defaultPoints() -> [LearningPointRequest] {
        [LearningPointRequest(id: UUID(), category: .expression, prompt: ""),
         LearningPointRequest(id: UUID(), category: .grammar, prompt: ""),
         LearningPointRequest(id: UUID(), category: .knowledge, prompt: "")]
    }

    private func loadLearningPoints() {
        if let existing = sentence?.learningPoints, !existing.isEmpty {
            learningPoints = existing.map { LearningPointRequest(id: $0.id, category: $0.category, prompt: $0.prompt) }
        } else {
            learningPoints = Self.defaultPoints()
        }
    }

    private func analyzeListening(_ material: AudioMaterial, _ sentence: ListeningSentence) {
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { status = error.localizedDescription; return }
        guard !key.isEmpty else { status = AIProviderError.missingKey.localizedDescription; return }
        isAnalyzingListening = true
        status = "AI 正在分析听辨困难…"
        Task {
            do {
                let result = try await AIStudyService.analyzeListening(
                    transcript: sentence.transcript, attempt: draft, apiKey: key
                )
                try store.saveListeningAnalysis(materialID: material.id, sentenceID: sentence.id,
                                                attempt: draft, result: result)
                status = "听力分析已保存。"
                isAnalyzingListening = false
            } catch {
                status = error.localizedDescription
                isAnalyzingListening = false
            }
        }
    }

    private func generateListeningCards(_ material: AudioMaterial, _ sentence: ListeningSentence) {
        let filled = learningPoints.compactMap { point -> LearningPointRequest? in
            let text = point.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LearningPointRequest(id: point.id, category: point.category, prompt: text)
        }
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { status = error.localizedDescription; return }
        guard !key.isEmpty else { status = AIProviderError.missingKey.localizedDescription; return }
        guard !filled.isEmpty else {
            status = "请先填写至少一个积累要点。"
            return
        }
        isGeneratingCards = true
        status = "AI 正在生成卡片草稿…"
        Task {
            do {
                let result = try await AIStudyService.generateListeningCards(
                    transcript: sentence.transcript, points: filled, apiKey: key
                )
                isGeneratingCards = false
                isAuditingCards = true
                status = "正在整理卡片…"
                var auditedCards: [ListeningCardsResult.Card] = []
                var fallbackCount = 0
                for card in result.cards {
                    let draft = CardDraft(category: card.category, mergeKey: card.mergeKey,
                                          question: card.question, answer: card.answer)
                    let audited = await CardAuditService.auditOrFallback(draft, apiKey: key)
                    if audited.usedFallback { fallbackCount += 1 }
                    auditedCards.append(.init(requestID: card.requestID, category: card.category,
                                              mergeKey: card.mergeKey, title: audited.title,
                                              question: audited.question, answer: audited.answer))
                }
                let auditedResult = ListeningCardsResult(cards: auditedCards)
                try store.saveListeningCards(materialID: material.id, sentenceID: sentence.id,
                                             points: filled, result: auditedResult)
                status = fallbackCount == 0
                    ? "\(filled.count) 张卡片草稿已保存。"
                    : "\(filled.count) 张卡片草稿已保存。\(fallbackCount) 张使用基础整理版本；可在卡片详情中重新整理。"
                isGeneratingCards = false
                isAuditingCards = false
            } catch {
                status = error.localizedDescription
                isGeneratingCards = false
                isAuditingCards = false
            }
        }
    }

    private func materialSummary(_ material: AudioMaterial) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(material.title)
                .font(AppType.ui(17, weight: .semibold))
                .lineLimit(2)
            Text("\(material.sentences.count) 句 · \(material.transcriptionComplete == true ? "转写已完成" : material.transcribedThroughSeconds != nil ? "转写可继续" : "尚未转写")")
                .font(AppType.ui(12)).foregroundStyle(.secondary)
        }
    }

    private func materialActions(_ material: AudioMaterial) -> some View {
        HStack(spacing: 12) {
            Button(playing && playbackSentenceID == nil ? "暂停整段" :
                   player != nil && playbackSentenceID == nil ? "继续整段" : "整段播放",
                   systemImage: playing && playbackSentenceID == nil ? "pause.fill" : "play.circle") {
                togglePlayback(material: material, sentence: nil)
            }
            Button(material.transcribedThroughSeconds == nil ? "本机转写" : "继续转写") {
                startTranscription(material)
            }
            .buttonStyle(AppActionButtonStyle(prominent: true))
            .disabled(store.activeTranscriptions.contains(material.id) || material.transcriptionComplete == true ||
                      store.data.dictationAttempts.contains(where: { $0.materialID == material.id }))
        }
    }

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .mp3, .mpeg4Audio, .wav,
            .mpeg4Movie, .movie,
            UTType(filenameExtension: "mp4")!,
            UTType(filenameExtension: "mov")!
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importAudio(from: url)
            selectedID = store.data.audioMaterials.last?.id
            selectedSentenceID = nil
            status = "媒体已导入。请导入 SRT/VTT 字幕；没有字幕时可使用本机转写。"
        } catch { status = error.localizedDescription }
    }

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importAudio(from: url)
            selectedID = store.data.audioMaterials.last?.id
            selectedSentenceID = nil
            status = "音频已导入。请导入 SRT/VTT 字幕；没有字幕时可使用本机转写。"
        } catch { status = error.localizedDescription }
    }

    private func importSubtitles(_ material: AudioMaterial) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt")!, .init(filenameExtension: "vtt")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importSubtitles(from: url, materialID: material.id)
            selectedSentenceID = nil
            status = "已按时间戳切句。请核对字幕与音频，再开始逐句听写。"
            showReview = true
            Task {
                do { try await store.generateAudioTitle(materialID: material.id) }
                catch { status = "字幕已导入，标题生成失败：\(error.localizedDescription)" }
            }
        } catch { status = error.localizedDescription }
    }

    private func startTranscription(_ material: AudioMaterial) {
        do { try store.startTranscription(materialID: material.id) }
        catch { status = error.localizedDescription }
    }

    private func togglePlayback(material: AudioMaterial, sentence: ListeningSentence?) {
        if player != nil && playbackSentenceID == sentence?.id {
            if playing { pauseAudio() } else { resumeAudio() }
        } else {
            play(material: material, sentence: sentence)
        }
    }

    private func play(material: AudioMaterial, sentence: ListeningSentence?) {
        stopAudio()
        do {
            let current = try AVAudioPlayer(contentsOf: store.audioURL(for: material))
            current.currentTime = sentence?.startSeconds ?? 0
            current.play()
            player = current
            playbackSentenceID = sentence?.id
            playbackEndSeconds = min(sentence?.endSeconds ?? current.duration, current.duration)
            playing = true
            schedulePlaybackEnd()
        } catch { status = error.localizedDescription }
    }

    private func pauseAudio() {
        playbackID = UUID()
        player?.pause()
        playing = false
    }

    private func resumeAudio() {
        guard let player else { return }
        if player.currentTime >= playbackEndSeconds - 0.05 { stopAudio(); return }
        player.play()
        playing = true
        schedulePlaybackEnd()
    }

    private func seek(sentence: ListeningSentence, by seconds: Double) {
        guard let player, playbackSentenceID == sentence.id else { return }
        playbackID = UUID()
        let upper = min(sentence.endSeconds, player.duration)
        player.currentTime = min(max(player.currentTime + seconds, sentence.startSeconds), max(sentence.startSeconds, upper - 0.05))
        if playing { schedulePlaybackEnd() }
    }

    private func schedulePlaybackEnd() {
        guard let player, playing else { return }
        let token = UUID()
        playbackID = token
        let milliseconds = max(50, Int((playbackEndSeconds - player.currentTime) * 1000))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            if playbackID == token { stopAudio() }
        }
    }

    private func stopAudio() {
        playbackID = UUID()
        player?.stop()
        player = nil
        playbackSentenceID = nil
        playbackEndSeconds = 0
        playing = false
    }

    private func loadDraft() { draft = sentence?.draftText ?? "" }
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        guard let material, let sentence, sentence.answerRevealed != true else { return }
        let value = draft
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? store.saveDictationDraft(materialID: material.id, sentenceID: sentence.id, text: value)
        }
    }
    private func persistDraft() {
        draftSaveTask?.cancel()
        guard let material, let sentence, sentence.answerRevealed != true else { return }
        try? store.saveDictationDraft(materialID: material.id, sentenceID: sentence.id, text: draft)
    }
    private func reveal(_ material: AudioMaterial, _ sentence: ListeningSentence) {
        draftSaveTask?.cancel()
        do { try store.revealAnswer(materialID: material.id, sentenceID: sentence.id, text: draft) }
        catch { status = error.localizedDescription }
    }
    private func retry(_ material: AudioMaterial, _ sentence: ListeningSentence) {
        do {
            try store.startRetry(materialID: material.id, sentenceID: sentence.id)
            draft = ""
            play(material: material, sentence: sentence)
        } catch { status = error.localizedDescription }
    }
    private func nextSentence(_ material: AudioMaterial, _ sentence: ListeningSentence) {
        guard let next = material.sentences.first(where: { $0.ordinal == sentence.ordinal + 1 }) else { return }
        if next.answerRevealed == true {
            do { try store.startRetry(materialID: material.id, sentenceID: next.id) }
            catch { status = error.localizedDescription; return }
        }
        selectedSentenceID = next.id
    }

}

private struct ListeningAnalysisView: View {
    let analysis: ListeningAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI 听力分析")
                .font(AppType.ui(14, weight: .semibold))

            ListeningAnalysisSummaryCard(explanation: analysis.explanation)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(analysis.items ?? []) { item in
                    ListeningAnalysisItemCard(item: item)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

private struct ListeningAnalysisSummaryCard: View {
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("听力诊断", systemImage: "ear")
                .font(AppType.ui(13, weight: .semibold))
                .foregroundStyle(GlassTheme.cyan)
            Text(explanation)
                .font(AppType.ui(16))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.cyan.opacity(0.20), lineWidth: 1)
        }
    }
}

private struct ListeningAnalysisItemCard: View {
    let item: ListeningAnalysisItem

    private var isAttemptDifference: Bool {
        item.category == .attemptDifference
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(categoryTitle)
                .font(AppType.ui(12, weight: .semibold))
                .foregroundStyle(isAttemptDifference ? .orange : GlassTheme.cyan)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (isAttemptDifference ? Color.orange : GlassTheme.cyan).opacity(0.12),
                    in: Capsule()
                )

            Text(item.title)
                .font(AppType.ui(16, weight: .semibold))
                .lineSpacing(2)
                .textSelection(.enabled)

            Text(item.detail)
                .font(AppType.ui(15))
                .lineSpacing(5)
                .textSelection(.enabled)

            if let evidence = item.evidence?.trimmingCharacters(in: .whitespacesAndNewlines),
               !evidence.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("依据")
                        .font(AppType.ui(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(evidence)
                        .font(AppType.ui(12))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            isAttemptDifference ? Color.orange.opacity(0.07) : Color.white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isAttemptDifference ? Color.orange.opacity(0.20) : Color.white.opacity(0.13),
                    lineWidth: 1
                )
        }
    }

    private var categoryTitle: String {
        switch item.category {
        case .difficulty: "🎧 听辨难点"
        case .connectedSpeech: "🔗 连读 / 语流连接"
        case .reduction: "🔉 弱读 / 吞音 / 省音"
        case .accent: "🗣 口音特点"
        case .expression: "💬 口语表达"
        case .vocabulary: "📚 词汇 / 搭配"
        case .attemptDifference: "⚠️ 你的听写差异"
        }
    }
}

private struct LearningPointsEditor: View {
    @Binding var points: [LearningPointRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这句值得积累什么？").font(AppType.ui(14, weight: .semibold))
            Text("每个已填写的要点会分别生成一张草稿；空白项会被忽略。")
                .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
            ForEach($points) { $point in
                HStack(alignment: .center, spacing: 10) {
                    Picker("分类", selection: $point.category) {
                        ForEach(CardCategory.allCases) { category in Text(category.rawValue).tag(category) }
                    }
                    .labelsHidden()
                    .studyPickerChrome()
                    .frame(width: 150, alignment: .leading)
                    TextField(placeholder(for: point.category), text: $point.prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(role: .destructive) {
                        points.removeAll { $0.id == point.id }
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("新增要点", systemImage: "plus") {
                points.append(LearningPointRequest(id: UUID(), category: .expression, prompt: ""))
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .background(Color.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func placeholder(for category: CardCategory) -> String {
        switch category {
        case .vocabulary: "例如：aportar 在这里表达什么？"
        case .grammar: "例如：为什么这里使用条件式？"
        case .expression: "例如：¿Podrías…? 还可以怎样礼貌请求？"
        case .knowledge: "例如：墨西哥常见的辣椒有什么区别？"
        case .correction: "记录需要专门纠正的表达"
        }
    }
}

struct TranscriptReviewSheet: View {
    @EnvironmentObject private var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    let materialID: UUID
    @State private var selectedID: UUID?
    @State private var text = ""
    @State private var start = ""
    @State private var end = ""
    @State private var status: String?
    @State private var reviewPlayer: AVAudioPlayer?
    @State private var reviewPlaying = false
    @State private var playbackID = UUID()
    @State private var splitTarget: ListeningSentence?
    @State private var aiSuggestion: TranscriptProofreadingResult?
    @State private var aiWorking = false
    @State private var speechWorking = false
    @State private var speechReference: String?

    private var material: AudioMaterial? { store.data.audioMaterials.first(where: { $0.id == materialID }) }
    private var selected: ListeningSentence? { material?.sentences.first(where: { $0.id == selectedID }) ?? material?.sentences.first }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(material?.sentences ?? []) { sentence in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第 \(sentence.ordinal) 句").font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                        Text(sentence.transcript).lineLimit(2)
                    }
                    .tag(sentence.id)
                }
            }
            .frame(width: 260)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("核对转写").font(AppType.ui(22, weight: .semibold))
                    Spacer()
                    Button("关闭") { dismiss() }
                }
                Text("转写可能有误，请对照音频修正文字和起止时间。修改会保留原句 ID。")
                    .foregroundStyle(.secondary)
                if let selected {
                    HStack {
                        Text("第 \(selected.ordinal) 句").font(AppType.ui(17, weight: .semibold))
                        Spacer()
                        Button(reviewPlaying ? "暂停" : reviewPlayer == nil ? "播放本句" : "继续播放",
                               systemImage: reviewPlaying ? "pause.fill" : "play.fill") { togglePlayback(selected) }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                        Button("后退 2 秒", systemImage: "gobackward.2") { seek(selected, by: -2) }
                            .disabled(reviewPlayer == nil)
                        Button("前进 2 秒", systemImage: "goforward.2") { seek(selected, by: 2) }
                            .disabled(reviewPlayer == nil)
                    }
                    TextEditor(text: $text)
                        .font(AppType.ui(17))
                        .frame(height: 120)
                        .studyInputChrome()
                    HStack(spacing: 12) {
                        Button("本机语音复核", systemImage: "waveform") { recognize(selected) }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(speechWorking || aiWorking)
                        Button("语音 + AI 校对", systemImage: "sparkles") { proofread(selected, includeSpeech: true) }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(aiWorking || speechWorking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if aiWorking || speechWorking { ProgressView().controlSize(.small) }
                    }
                    if let speechReference {
                        Text("本机识别参考：\(speechReference)")
                            .font(AppType.ui(13)).textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("结合音频确认建议；AI 不会自动覆盖字幕。")
                            .font(AppType.ui(12)).foregroundStyle(.secondary)
                    }
                    if let aiSuggestion {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AI 建议").font(AppType.ui(15, weight: .semibold))
                            Text(aiSuggestion.suggestedText).textSelection(.enabled)
                            Text(aiSuggestion.explanation)
                                .font(AppType.ui(13)).foregroundStyle(.secondary)
                            Button("采用建议到编辑框") {
                                text = aiSuggestion.suggestedText
                                self.aiSuggestion = nil
                                status = "建议已填入编辑框，请对照音频确认后保存。"
                            }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    HStack {
                        TextField("开始（秒）", text: $start)
                            .studyInputChrome()
                        TextField("结束（秒）", text: $end)
                            .studyInputChrome()
                    }
                    HStack {
                        Button("保存这句修改") {
                            do {
                                try store.updateSentence(materialID: materialID, sentenceID: selected.id,
                                                         text: text, start: Double(start) ?? -1, end: Double(end) ?? -1)
                                status = "已保存。"
                            } catch { status = error.localizedDescription }
                        }
                        .buttonStyle(AppActionButtonStyle(prominent: true))
                        Menu("切句操作") {
                            Button("拆成两句…") { splitTarget = selected }
                            Button("与下一句合并") {
                                do {
                                    try store.mergeWithNext(materialID: materialID, sentenceID: selected.id)
                                    loadSelected()
                                    status = "已合并。"
                                } catch { status = error.localizedDescription }
                            }
                            .disabled(selected.ordinal >= (material?.sentences.count ?? 0))
                        }
                    }
                }
                Spacer()
                if let status { Text(status).font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("完成准备，开始逐句听写") {
                        do { try store.verifyTranscript(materialID: materialID); dismiss() }
                        catch { status = error.localizedDescription }
                    }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(material?.transcriptionComplete != true)
                }
            }
            .padding(24)
        }
        .frame(width: 850, height: 560)
        .onAppear { selectedID = material?.sentences.first?.id; loadSelected() }
        .onChange(of: selectedID) { _, _ in stopAudio(); loadSelected() }
        .onDisappear { stopAudio() }
        .sheet(item: $splitTarget) { target in
            SentenceSplitSheet(sentence: target) { first, second, splitTime in
                try store.splitSentence(materialID: materialID, sentenceID: target.id,
                                        firstText: first, secondText: second, at: splitTime)
                loadSelected()
                status = "已拆分，请检查两句的时间。"
            }
        }
    }

    private func recognize(_ sentence: ListeningSentence) {
        guard let material else { return }
        let sentenceID = sentence.id
        speechWorking = true
        speechReference = nil
        status = "正在识别这句音频…"
        Task {
            do {
                let result = try await TranscriptionService.recognizeSentence(
                    audioURL: store.audioURL(for: material), start: sentence.startSeconds, end: sentence.endSeconds)
                if selected?.id == sentenceID {
                    speechReference = result
                    status = "已取得本机识别参考；可再用 DeepSeek 对照校对。"
                }
            } catch { status = error.localizedDescription }
            speechWorking = false
        }
    }

    private func proofread(_ sentence: ListeningSentence, includeSpeech: Bool) {
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { status = error.localizedDescription; return }
        guard !key.isEmpty else { status = AIProviderError.missingKey.localizedDescription; return }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceID = sentence.id
        aiWorking = true
        aiSuggestion = nil
        status = "正在复核音频并校对字幕…"
        Task {
            do {
                let reference: String?
                if includeSpeech {
                    guard let material else { aiWorking = false; return }
                    reference = try await TranscriptionService.recognizeSentence(
                        audioURL: store.audioURL(for: material), start: sentence.startSeconds, end: sentence.endSeconds)
                    if selected?.id == sentenceID { speechReference = reference }
                } else {
                    reference = speechReference
                }
                let result = try await AIStudyService.proofreadTranscript(source, speechRecognition: reference, apiKey: key)
                guard selected?.id == sentenceID, text.trimmingCharacters(in: .whitespacesAndNewlines) == source else {
                    aiWorking = false
                    status = "文字已变化，请重新校对当前句。"
                    return
                }
                aiSuggestion = result
                status = "校对建议已生成；请结合音频检查。"
            } catch {
                status = error.localizedDescription
            }
            aiWorking = false
        }
    }

    private func togglePlayback(_ sentence: ListeningSentence) {
        if let reviewPlayer {
            if reviewPlaying {
                playbackID = UUID()
                reviewPlayer.pause()
                reviewPlaying = false
            } else {
                reviewPlayer.play()
                reviewPlaying = true
                schedulePlaybackEnd(sentence)
            }
        } else {
            play(sentence)
        }
    }

    private func play(_ sentence: ListeningSentence) {
        stopAudio()
        guard let material else { return }
        do {
            let current = try AVAudioPlayer(contentsOf: store.audioURL(for: material))
            current.currentTime = sentence.startSeconds
            current.play()
            reviewPlayer = current
            reviewPlaying = true
            schedulePlaybackEnd(sentence)
        } catch { status = error.localizedDescription }
    }

    private func seek(_ sentence: ListeningSentence, by seconds: Double) {
        guard let reviewPlayer else { return }
        playbackID = UUID()
        let upper = min(sentence.endSeconds, reviewPlayer.duration)
        reviewPlayer.currentTime = min(max(reviewPlayer.currentTime + seconds, sentence.startSeconds),
                                       max(sentence.startSeconds, upper - 0.05))
        if reviewPlaying { schedulePlaybackEnd(sentence) }
    }

    private func schedulePlaybackEnd(_ sentence: ListeningSentence) {
        guard let reviewPlayer, reviewPlaying else { return }
        let token = UUID()
        playbackID = token
        let remaining = max(0.05, min(sentence.endSeconds, reviewPlayer.duration) - reviewPlayer.currentTime)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            if playbackID == token { stopAudio() }
        }
    }

    private func stopAudio() {
        playbackID = UUID()
        reviewPlayer?.stop()
        reviewPlayer = nil
        reviewPlaying = false
    }

    private func loadSelected() {
        text = selected?.transcript ?? ""
        aiSuggestion = nil
        speechReference = nil
        start = selected.map { String(format: "%.2f", $0.startSeconds) } ?? ""
        end = selected.map { String(format: "%.2f", $0.endSeconds) } ?? ""
    }
}

private struct SentenceSplitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sentence: ListeningSentence
    let onSplit: (String, String, Double) throws -> Void
    @State private var errorMessage: String?
    @State private var first = ""
    @State private var second = ""
    @State private var splitTime = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("拆成两句").font(AppType.ui(22, weight: .semibold))
            Text("把原文分到两个输入框，再设置第二句开始的秒数。")
                .foregroundStyle(.secondary)
            Text("原文：\(sentence.transcript)")
                .font(AppType.ui(15, weight: .regular)).textSelection(.enabled)
            TextField("第一句", text: $first)
                .studyInputChrome()
            TextField("第二句", text: $second)
                .studyInputChrome()
            TextField("第二句开始时间（秒）", text: $splitTime)
                .studyInputChrome()
            if let errorMessage { Text(errorMessage).font(AppType.ui(12, weight: .regular)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存拆分") {
                    do { try onSplit(first, second, Double(splitTime) ?? -1); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(AppActionButtonStyle(prominent: true))
            }
        }
        .padding(26)
        .frame(width: 540)
        .onAppear {
            first = sentence.transcript
            splitTime = String(format: "%.2f", (sentence.startSeconds + sentence.endSeconds) / 2)
        }
    }
}

private struct PasteSubtitleSheet: View {
    @EnvironmentObject private var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    let materialID: UUID
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("粘贴字幕 (SRT/VTT)").font(AppType.ui(22, weight: .semibold))
            TextEditor(text: $text)
                .font(AppType.ui(15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.7)))
            if let errorMessage { Text(errorMessage).font(AppType.ui(12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("导入") { importPasted() }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func importPasted() {
        do {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PastedSubtitle-\(UUID().uuidString).srt")
            try text.data(using: .utf8)?.write(to: temp)
            try store.importSubtitles(from: temp, materialID: materialID)
            try? FileManager.default.removeItem(at: temp)
            Task {
                do { try await store.generateAudioTitle(materialID: materialID) }
                catch { store.errorMessage = "字幕已导入，标题生成失败：\(error.localizedDescription)" }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DictationHistoryView: View {
    @EnvironmentObject private var store: StudyStore
    @Binding var selectedMaterialID: UUID?
    @Binding var selectedSentenceID: UUID?
    @Binding var selectedScreen: StudyScreen?
    @State private var selectedDate: Date?
    @State private var errorMessage: String?

    private var dates: [Date] {
        Array(Set(store.data.dictationAttempts.map { Calendar.current.startOfDay(for: $0.submittedAt) })).sorted(by: >)
    }
    private var filtered: [DictationAttempt] {
        store.data.dictationAttempts.filter {
            selectedDate == nil || Calendar.current.isDate($0.submittedAt, inSameDayAs: selectedDate!)
        }.sorted { $0.submittedAt > $1.submittedAt }
    }

    private func attempts(on day: Date) -> [DictationAttempt] {
        filtered.filter { Calendar.current.isDate($0.submittedAt, inSameDayAs: day) }
    }

    private func material(for attempt: DictationAttempt) -> AudioMaterial? {
        store.data.audioMaterials.first { $0.id == attempt.materialID }
    }

    private func retry(_ attempt: DictationAttempt) {
        do {
            try store.startRetry(materialID: attempt.materialID, sentenceID: attempt.sentenceID)
            selectedMaterialID = attempt.materialID
            selectedSentenceID = attempt.sentenceID
            selectedScreen = .listening
        } catch { errorMessage = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(eyebrow: "Dictation history", title: "按日期重听，再写一次。",
                        subtitle: "一个日期下汇总当天练过的全部语料和句子。")
            if let errorMessage { Text(errorMessage).font(AppType.ui(12, weight: .regular)).foregroundStyle(.red) }
            Picker("日期", selection: $selectedDate) {
                Text("全部日期").tag(Optional<Date>.none)
                ForEach(dates, id: \.self) { day in
                    Text(day.formatted(date: .abbreviated, time: .omitted)).tag(Optional(day))
                }
            }
            .labelsHidden()
            .studyPickerChrome()
            .frame(maxWidth: 400)
            if filtered.isEmpty {
                StudyEmptyState(title: "还没有听写记录", message: "完成一条听写后，可按日期在这里重听和回顾。",
                                symbol: "clock.arrow.circlepath")
            } else {
                HistoryPanel {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(dates.filter { selectedDate == nil || $0 == selectedDate }, id: \.self) { day in
                                Text(day.formatted(date: .complete, time: .omitted))
                                    .font(AppType.ui(17, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(attempts(on: day)) { attempt in
                                    DictationHistoryRow(attempt: attempt, material: material(for: attempt)) {
                                        retry(attempt)
                                    }
                                    .historyEntryChrome()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(32)
    }
}

private struct DictationHistoryRow: View {
    let attempt: DictationAttempt
    let material: AudioMaterial?
    let onRetry: () -> Void

    private var sentence: ListeningSentence? {
        material?.sentences.first(where: { $0.id == attempt.sentenceID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(material?.title ?? "原语料已缺失").font(AppType.ui(17, weight: .semibold))
                Text("第 \(sentence?.ordinal ?? 0) 句").foregroundStyle(.secondary)
                Spacer()
                Text(attempt.submittedAt.formatted(date: .omitted, time: .shortened))
                    .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
            }
            Text("当时写下：\(attempt.text.isEmpty ? "（空白）" : attempt.text)")
            if let sentence {
                Text("原句：\(attempt.answerTextSnapshot ?? sentence.transcript)").foregroundStyle(.secondary)
                if let analysis = sentence.analysis, analysis.userAttemptSnapshot == attempt.text {
                    Text("听辨提示：\(analysis.explanation)")
                        .font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            Button("再次听写", action: onRetry).disabled(sentence == nil)
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    let safe = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", safe / 60, safe % 60)
}
