import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

private struct ListeningLearningPointsDraft: Codable {
    struct Item: Codable {
        let id: UUID
        let category: CardCategory
        let prompt: String
    }

    let items: [Item]

    init(points: [LearningPointRequest]) {
        items = points.map { Item(id: $0.id, category: $0.category, prompt: $0.prompt) }
    }

    var points: [LearningPointRequest] {
        items.map { LearningPointRequest(id: $0.id, category: $0.category, prompt: $0.prompt) }
    }
}

struct ListeningView: View {
    @EnvironmentObject private var store: StudyStore
    @EnvironmentObject private var editingDrafts: EditingDraftStore
    @Binding var selectedID: UUID?
    @Binding var selectedSentenceID: UUID?
    @State private var player: AVAudioPlayer?
    @State private var playbackID = UUID()
    @State private var playing = false
    @State private var playbackSentenceID: UUID?
    @State private var playbackEndSeconds = 0.0
    @State private var draft = ""
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var draftMaterialID: UUID?
    @State private var draftSentenceID: UUID?
    @State private var isLoadingDraft = false
    @State private var isReviewingTranscript = false
    @State private var reviewText = ""
    @State private var reviewStart = ""
    @State private var reviewEnd = ""
    @State private var reviewMaterialID: UUID?
    @State private var reviewSentenceID: UUID?
    @State private var reviewStatus: String?
    @State private var reviewSpeechReference: String?
    @State private var reviewAISuggestion: TranscriptProofreadingResult?
    @State private var isReviewSpeechWorking = false
    @State private var isReviewAIWorking = false
    @State private var reviewSplitTarget: ListeningSentence?
    @State private var confirmingReviewDiscard = false
    @State private var status: String?
    @State private var learningPoints: [LearningPointRequest] = ListeningView.defaultPoints()
    @State private var isAnalyzingListening = false
    @State private var isGeneratingCards = false
    @State private var isAuditingCards = false
    @State private var showPasteSubtitles = false
    @State private var hoveredSentenceID: UUID?
    @FocusState private var dictationIsFocused: Bool

    private var material: AudioMaterial? {
        store.data.audioMaterials.first(where: { $0.id == selectedID }) ?? store.data.audioMaterials.first
    }
    private var sentence: ListeningSentence? {
        guard let material, let selectedSentenceID else { return nil }
        return material.sentences.first(where: { $0.id == selectedSentenceID })
    }

    var body: some View {
        Group {
            if let material {
                HStack(alignment: .top, spacing: 24) {
                        listeningNavigator(material)
                            .padding(14)
                            .frame(minWidth: 205, idealWidth: 235, maxWidth: 285, maxHeight: .infinity)
                            .background {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [
                                                    GlassTheme.cyan.opacity(0.10),
                                                    GlassTheme.violet.opacity(0.08)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                    }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            }

                        studyCanvas(material)
                            .padding(18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [
                                                    GlassTheme.violet.opacity(0.15),
                                                    GlassTheme.cyan.opacity(0.10)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ))
                                    }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                            }
                }
                .padding(12)
                .background(AppGlassBackground())
            } else {
                emptyLibrary
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = store.data.audioMaterials.first?.id }
            if let material, !material.sentences.contains(where: { $0.id == selectedSentenceID }) {
                selectedSentenceID = material.sentences.first?.id
            }
            loadDraft()
            loadLearningPoints()
        }
        .onDisappear {
            stopAudio()
            persistDraft()
            persistTranscriptReviewDraft()
        }
        .onChange(of: selectedID) { _, _ in
            persistDraft()
            stopAudio()
            persistTranscriptReviewDraft()
            if let material, !material.sentences.contains(where: { $0.id == selectedSentenceID }) {
                selectedSentenceID = material.sentences.first?.id
            }
            loadDraft()
            if isReviewingTranscript { loadTranscriptReviewDraft() }
            loadLearningPoints()
        }
        .onChange(of: selectedSentenceID) { _, _ in
            persistDraft()
            stopAudio()
            persistTranscriptReviewDraft()
            loadDraft()
            if isReviewingTranscript { loadTranscriptReviewDraft() }
            loadLearningPoints()
        }
        .onChange(of: draft) { _, _ in
            if !isLoadingDraft { scheduleDraftSave() }
        }
        .onChange(of: reviewText) { _, _ in persistTranscriptReviewDraft() }
        .onChange(of: reviewStart) { _, _ in persistTranscriptReviewDraft() }
        .onChange(of: reviewEnd) { _, _ in persistTranscriptReviewDraft() }
        .sheet(isPresented: $showPasteSubtitles) {
            if let material { PasteSubtitleSheet(materialID: material.id) }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("开始一次听力练习", systemImage: "waveform")
        } description: {
            Text("导入本机音频或视频。转写和学习资料保留在这台 Mac 上。")
        } actions: {
            Button("导入音频或视频…", systemImage: "plus") { importMedia() }
                .buttonStyle(AppActionButtonStyle(prominent: true))
            Button("导入字幕文件…", systemImage: "captions.bubble") {
                status = "请先导入音频，再为对应语料导入字幕文件或粘贴字幕。"
            }
            .buttonStyle(AppActionButtonStyle())
            Text("支持 MP3、M4A、WAV、MP4、MOV，以及 SRT / VTT 字幕。")
                .font(AppType.supporting)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let status {
                Text(status)
                    .font(AppType.supporting)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private func listeningNavigator(_ material: AudioMaterial) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("当前媒体", selection: $selectedID) {
                    ForEach(store.data.audioMaterials) { item in
                        Text(item.title)
                            .lineLimit(1)
                            .tag(Optional(item.id))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("当前媒体")
                .frame(maxWidth: .infinity, alignment: .leading)
                .studyPickerChrome()

                Button(action: importMedia) {
                    Image(systemName: "plus")
                }
                .buttonStyle(AppActionButtonStyle())
                .help("导入音频或视频")
                .accessibilityLabel("导入音频或视频")
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Label("\(material.sentences.count) 句 · \(materialState(material))",
                  systemImage: materialStateSymbol(material))
                    .font(AppType.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)

            Divider()
                .padding(.vertical, 2)

            HStack(alignment: .firstTextBaseline) {
                Text("句子")
                    .font(AppType.sectionTitle)
                Spacer()
                Text("\(material.sentences.count)")
                    .font(AppType.supporting.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if material.sentences.isEmpty {
                ContentUnavailableView("尚无句子", systemImage: "text.alignleft",
                                       description: Text("导入字幕或开始本机转写后，句子会显示在这里。"))
                    .font(AppType.supporting)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(material.sentences) { item in
                            Button {
                                selectedSentenceID = item.id
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(item.id == selectedSentenceID ? GlassTheme.cyan.opacity(0.85) : .clear)
                                        .frame(width: 3, height: 30)
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(spacing: 8) {
                                            Text("句子 \(item.ordinal)")
                                                .font(AppType.ui(14, weight: .semibold))
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 0)
                                            Label(sentenceStateLabel(item, isSelected: item.id == selectedSentenceID),
                                                  systemImage: sentenceStateSymbol(item))
                                                .font(AppType.ui(12, weight: .medium))
                                                .foregroundStyle(sentenceStateColor(item))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                        Text("\(formatTime(item.startSeconds)) – \(formatTime(item.endSeconds))")
                                            .font(AppType.ui(12).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 9)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(rowBackgroundColor(for: item))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(rowBorderColor(for: item), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredSentenceID = item.id
                                } else if hoveredSentenceID == item.id {
                                    hoveredSentenceID = nil
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "句子 \(item.ordinal)，\(sentenceStateLabel(item, isSelected: item.id == selectedSentenceID))"
                            )
                            .accessibilityValue(
                                "\(formatTime(item.startSeconds)) 到 \(formatTime(item.endSeconds))"
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func studyCanvas(_ material: AudioMaterial) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 10) {
                    materialSummary(material)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        materialActions(material)
                        if isReviewingTranscript {
                            Button("返回练习", systemImage: "arrow.uturn.backward") {
                                exitTranscriptReview()
                            }
                            .buttonStyle(AppActionButtonStyle())
                            Button("完成核对", systemImage: "checkmark.circle") {
                                completeTranscriptReview(material)
                            }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                            .disabled(material.transcriptionComplete != true ||
                                      hasOtherTranscriptReviewDrafts(material))
                            .help(reviewCompletionHelp(material))
                        } else {
                            Button("核对分句", systemImage: "text.badge.checkmark") {
                                enterTranscriptReview()
                            }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(material.sentences.isEmpty)
                        }
                        Menu("字幕") {
                            Button("导入字幕文件…", systemImage: "captions.bubble") {
                                importSubtitles(material)
                            }
                            .disabled(store.activeTranscriptions.contains(material.id))
                            Button("粘贴字幕…", systemImage: "doc.on.clipboard") {
                                showPasteSubtitles = true
                            }
                        }
                        .buttonStyle(AppActionButtonStyle())
                    }
                }

                if store.activeTranscriptions.contains(material.id) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(material.referenceSubtitleCues?.isEmpty == false
                             ? "正在校准字幕时间…"
                             : "正在本机转写…")
                            .font(AppType.supporting)
                        Spacer()
                        Button("暂停") { store.pauseTranscription(materialID: material.id) }
                            .buttonStyle(AppActionButtonStyle())
                    }
                } else if let progress = store.transcriptionStatus[material.id] {
                    Text(progress)
                        .font(AppType.supporting)
                        .foregroundStyle(.secondary)
                }

                if !material.sentences.isEmpty {
                    HStack {
                        Button(playing && playbackSentenceID == nil ? "暂停整段" :
                               player != nil && playbackSentenceID == nil ? "继续整段" : "整段播放",
                               systemImage: playing && playbackSentenceID == nil ? "pause.fill" : "play.fill") {
                            togglePlayback(material: material, sentence: nil)
                        }
                        .buttonStyle(AppActionButtonStyle())
                        Text("整段音频")
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 10)

            if isReviewingTranscript {
                transcriptReviewWorkspace(material)
            } else if canDictate(material) {
                if let sentence {
                    dictationWorkspace(material, sentence)
                } else {
                    ContentUnavailableView("选择一句开始", systemImage: "text.alignleft",
                                           description: Text("从左侧列表选择要听写的句子。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                preparationState(material)
            }
                learningCardSection(material)
                    .padding(.top, 36)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dictationWorkspace(_ material: AudioMaterial, _ sentence: ListeningSentence) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("句子 \(sentence.ordinal)")
                        .font(AppType.pageTitle)
                    Text("of \(material.sentences.count)")
                        .font(AppType.supporting.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(formatTime(sentence.startSeconds)) – \(formatTime(sentence.endSeconds))")
                    .font(AppType.supporting.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    togglePlayback(material: material, sentence: sentence)
                } label: {
                    Label(playing && playbackSentenceID == sentence.id ? "暂停" :
                          player != nil && playbackSentenceID == sentence.id ? "继续播放" : "播放本句",
                          systemImage: playing && playbackSentenceID == sentence.id ? "pause.fill" : "play.fill")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(AppActionButtonStyle(prominent: true))
                .controlSize(.small)
                .frame(height: 44)
                .keyboardShortcut("r", modifiers: [.command])
                Button("重听", systemImage: "arrow.clockwise") {
                    play(material: material, sentence: sentence)
                }
                .buttonStyle(AppActionButtonStyle())
                .controlSize(.small)
                .frame(height: 44)
                .help("重听本句")
                Button {
                    seek(sentence: sentence, by: -2)
                } label: {
                    Label("2 秒", systemImage: "arrow.left")
                }
                .buttonStyle(AppActionButtonStyle())
                .controlSize(.small)
                .frame(height: 44)
                .help("后退 2 秒")
                .disabled(player == nil || playbackSentenceID != sentence.id)
                Button {
                    seek(sentence: sentence, by: 2)
                } label: {
                    Label("2 秒", systemImage: "arrow.right")
                }
                .buttonStyle(AppActionButtonStyle())
                .controlSize(.small)
                .frame(height: 44)
                .help("前进 2 秒")
                .disabled(player == nil || playbackSentenceID != sentence.id)
                Button("下一句", systemImage: "chevron.right") {
                    persistDraft()
                    nextSentence(material, sentence)
                }
                .padding(.leading, 20)
                .buttonStyle(AppActionButtonStyle())
                .controlSize(.small)
                .frame(height: 44)
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(sentence.ordinal >= material.sentences.count)
                .fixedSize()
                .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(sentence.answerRevealed == true ? "你的听写" : "你听到了什么？")
                        .font(AppType.sectionTitle)
                    Spacer()
                    Text("草稿自动保存")
                        .font(AppType.supporting)
                        .foregroundStyle(.tertiary)
                }
                if sentence.answerRevealed == true {
                    Text(draft.isEmpty ? "（未填写听写）" : draft)
                        .font(AppType.studyText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                        .padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原句")
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                        Text(sentence.transcript)
                            .font(AppType.reading(20))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                    Button("再听，再写同一句", systemImage: "arrow.counterclockwise") {
                        retry(material, sentence)
                    }
                    .buttonStyle(AppActionButtonStyle())
                } else {
                    TextEditor(text: $draft)
                        .font(AppType.studyText)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .frame(minHeight: 160, maxHeight: 300)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(dictationIsFocused ? GlassTheme.cyan : .white.opacity(0.18),
                                              lineWidth: dictationIsFocused ? 1.5 : 1)
                                .allowsHitTesting(false)
                        }
                        .focused($dictationIsFocused)
                        .disabled(sentence.answerRevealed == true)
                        .accessibilityLabel("西班牙语听写")
                    HStack {
                        Text("\(draft.split(whereSeparator: { $0.isWhitespace }).count) 词")
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("看答案", systemImage: "eye") {
                            reveal(material, sentence)
                        }
                        .buttonStyle(AppActionButtonStyle(prominent: true))
                        .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }
            Spacer(minLength: 0)
            if let status {
                Label(status, systemImage: "info.circle")
                    .font(AppType.supporting)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func transcriptReviewWorkspace(_ material: AudioMaterial) -> some View {
        VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("字幕复核", systemImage: "text.badge.checkmark")
                            .font(AppType.ui(18, weight: .semibold))
                        Text(material.title)
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(transcriptReviewProgress(material))
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let sentence {
                        Text(sentenceStateLabel(sentence, isSelected: true))
                            .font(AppType.supporting)
                            .foregroundStyle(sentenceStateColor(sentence))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.10), in: Capsule())
                    }
                }

                if let sentence {
                    HStack(alignment: .firstTextBaseline) {
                        Text("句子 \(sentence.ordinal)")
                            .font(AppType.pageTitle)
                        Text("of \(material.sentences.count)")
                            .font(AppType.supporting.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            navigateTranscriptReview(by: -1, in: material)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(AppActionButtonStyle())
                        .help("上一句")
                        .accessibilityLabel("上一句")
                        .disabled(sentence.ordinal <= 1)
                        Button {
                            navigateTranscriptReview(by: 1, in: material)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(AppActionButtonStyle())
                        .help("下一句")
                        .accessibilityLabel("下一句")
                        .disabled(sentence.ordinal >= material.sentences.count)
                        Spacer(minLength: 8)
                        Text(sentenceStateLabel(sentence, isSelected: true))
                            .font(AppType.supporting)
                            .foregroundStyle(sentenceStateColor(sentence))
                    }

                    HStack(spacing: 10) {
                        Button(playing && playbackSentenceID == sentence.id ? "暂停" :
                               player != nil && playbackSentenceID == sentence.id ? "继续播放" : "播放本句",
                               systemImage: playing && playbackSentenceID == sentence.id ? "pause.fill" : "play.fill") {
                            togglePlayback(material: material, sentence: sentence)
                        }
                        .buttonStyle(AppActionButtonStyle(prominent: true))
                        Button("重听", systemImage: "arrow.clockwise") {
                            play(material: material, sentence: sentence)
                        }
                        .buttonStyle(AppActionButtonStyle())
                    }
                    HStack(spacing: 10) {
                        Button("后退 2 秒", systemImage: "gobackward") {
                            seek(sentence: sentence, by: -2)
                        }
                        .buttonStyle(AppActionButtonStyle())
                        .disabled(player == nil || playbackSentenceID != sentence.id)
                        Button("前进 2 秒", systemImage: "goforward") {
                            seek(sentence: sentence, by: 2)
                        }
                        .buttonStyle(AppActionButtonStyle())
                        .disabled(player == nil || playbackSentenceID != sentence.id)
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("字幕文本")
                                .font(AppType.ui(13, weight: .semibold))
                            Spacer()
                            if hasCurrentTranscriptReviewDraft {
                                Label("未保存", systemImage: "pencil.circle.fill")
                                    .font(AppType.supporting)
                                    .foregroundStyle(.orange)
                            }
                        }
                        TextEditor(text: $reviewText)
                            .font(AppType.ui(17))
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .frame(minHeight: 170, maxHeight: 260)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                            .accessibilityLabel("字幕文本")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("起止时间（秒）")
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("开始").font(AppType.supporting).foregroundStyle(.secondary)
                                TextField("开始（秒）", text: $reviewStart)
                                    .studyInputChrome()
                                    .font(AppType.body.monospacedDigit())
                                    .accessibilityLabel("开始时间，秒")
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("结束").font(AppType.supporting).foregroundStyle(.secondary)
                                TextField("结束（秒）", text: $reviewEnd)
                                    .studyInputChrome()
                                    .font(AppType.body.monospacedDigit())
                                    .accessibilityLabel("结束时间，秒")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button("本机语音复核", systemImage: "waveform") {
                                recognizeReviewSentence(sentence, material: material)
                            }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(isReviewSpeechWorking || isReviewAIWorking)
                            Button("语音 + AI 校对", systemImage: "sparkles") {
                                proofreadReviewSentence(sentence, material: material, includeSpeech: true)
                            }
                            .buttonStyle(AppActionButtonStyle())
                            .disabled(isReviewAIWorking || isReviewSpeechWorking ||
                                      reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if isReviewAIWorking || isReviewSpeechWorking {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Text("结合音频确认建议；AI 不会自动覆盖字幕。")
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                        if let reviewSpeechReference {
                            LabeledContent("本机识别参考", value: reviewSpeechReference)
                                .font(AppType.supporting)
                                .textSelection(.enabled)
                        }
                        if let reviewAISuggestion {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("AI 建议")
                                    .font(AppType.ui(14, weight: .semibold))
                                Text(reviewAISuggestion.suggestedText)
                                    .font(AppType.ui(15))
                                    .textSelection(.enabled)
                                Text(reviewAISuggestion.explanation)
                                    .font(AppType.supporting)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button("采用建议到编辑框") {
                                    reviewText = reviewAISuggestion.suggestedText
                                    self.reviewAISuggestion = nil
                                    reviewStatus = "建议已填入编辑框，请对照音频确认后保存。"
                                }
                                .buttonStyle(AppActionButtonStyle())
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("保存此句修改", systemImage: "square.and.arrow.down") {
                            saveTranscriptReview(sentence, material: material)
                        }
                        .buttonStyle(AppActionButtonStyle(prominent: true))
                        .disabled(!hasCurrentTranscriptReviewDraft)
                        Button("放弃草稿", systemImage: "trash", role: .destructive) {
                            confirmingReviewDiscard = true
                        }
                        .buttonStyle(AppActionButtonStyle())
                        .disabled(!hasCurrentTranscriptReviewDraft)
                        Spacer(minLength: 0)
                        Menu("切句操作") {
                            Button("拆成两句…", systemImage: "scissors") {
                                beginSentenceSplit(sentence, material: material)
                            }
                            Button("与下一句合并", systemImage: "arrow.down.to.line") {
                                mergeWithNextSentence(sentence, material: material)
                            }
                            .disabled(sentence.ordinal >= material.sentences.count)
                        }
                        .disabled(store.transferInProgress)
                    }

                    if let reviewStatus {
                        Label(reviewStatus, systemImage: "info.circle")
                            .font(AppType.ui(12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if hasOtherTranscriptReviewDrafts(material) {
                        Label("其他句子还有未保存校对草稿；逐句保存或放弃后才能完成核对。",
                              systemImage: "externaldrive")
                            .font(AppType.ui(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if material.transcriptionComplete != true {
                        Label("请等整段转写完成后再确认核对。",
                              systemImage: "clock")
                            .font(AppType.ui(12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("选择一句核对", systemImage: "text.badge.checkmark",
                                           description: Text("从左侧 Listening Navigator 选择要检查的字幕和时间。"))
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        .confirmationDialog("放弃当前句尚未保存的校对？", isPresented: $confirmingReviewDiscard,
                            titleVisibility: .visible) {
            Button("放弃草稿", role: .destructive) {
                discardTranscriptReviewDraft()
            }
            Button("继续校对", role: .cancel) {}
        }
        .sheet(item: $reviewSplitTarget) { target in
            SentenceSplitSheet(sentence: target) { first, second, splitTime in
                try store.splitSentence(materialID: material.id, sentenceID: target.id,
                                        firstText: first, secondText: second, at: splitTime)
                selectedSentenceID = target.id
                loadTranscriptReviewDraft()
                reviewStatus = "已拆分，请检查两句的时间。"
            }
        }
    }

    private func preparationState(_ material: AudioMaterial) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if material.sentences.isEmpty {
                ContentUnavailableView("等待字幕或转写", systemImage: "waveform",
                                       description: Text("导入 SRT / VTT 字幕，或在上方开始本机转写。"))
            } else {
                ContentUnavailableView("先核对字幕与分句", systemImage: "text.badge.checkmark",
                                       description: Text("检查句子文本和起止时间；确认后开始逐句听写。"))
                HStack {
                    Spacer()
                    Button("核对字幕与分句", systemImage: "text.badge.checkmark") {
                        enterTranscriptReview()
                    }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    Spacer()
                }
            }
            if let status {
                Text(status).font(AppType.supporting).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func learningCardSection(_ material: AudioMaterial) -> some View {
        if let sentence, sentence.answerRevealed == true {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("创建卡片")
                            .font(AppType.sectionTitle)
                        Text("积累要点会自动保存在本机。")
                            .font(AppType.supporting)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if isGeneratingCards || isAuditingCards {
                        ProgressView().controlSize(.small)
                    }
                }

                if let count = sentence.learningPoints?.count, count > 0 {
                    Label("\(count) 张卡片草稿已保存", systemImage: "checkmark.circle")
                        .font(AppType.supporting)
                        .foregroundStyle(.secondary)
                }

                LearningPointsEditor(points: Binding(
                    get: { learningPoints },
                    set: { points in
                        learningPoints = points
                        persistLearningPointsDraft(points)
                    }
                ))

                let filledCount = learningPoints.filter {
                    !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.count
                HStack(spacing: 12) {
                    Button {
                        learningPoints.append(
                            LearningPointRequest(id: UUID(), category: .expression, prompt: "")
                        )
                        persistLearningPointsDraft(learningPoints)
                    } label: {
                        Label("新增要点", systemImage: "plus")
                            .font(AppType.ui(14, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(
                                .white.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        generateListeningCards(material, sentence)
                    } label: {
                        Label(
                            filledCount > 0 ? "生成 \(filledCount) 张卡片草稿" : "生成卡片草稿",
                            systemImage: "rectangle.stack.badge.plus"
                        )
                        .font(AppType.ui(14, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: 210, height: 42)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [GlassTheme.magenta.opacity(0.86), GlassTheme.violet.opacity(0.86)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(filledCount == 0 || isGeneratingCards || isAuditingCards)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }

    private func canDictate(_ material: AudioMaterial) -> Bool {
        !material.sentences.isEmpty &&
            material.transcriptionComplete == true &&
            !material.sentences.contains(where: { $0.status == .generated })
    }

    private func materialState(_ material: AudioMaterial) -> String {
        if store.activeTranscriptions.contains(material.id) { return "处理中" }
        if material.transcriptionComplete == true {
            return material.sentences.contains(where: { $0.status == .generated }) ? "待核对" : "已核对"
        }
        return material.sentences.isEmpty ? "待转写" : "转写未完成"
    }

    private func sentenceStateColor(_ sentence: ListeningSentence) -> Color {
        if isReviewingTranscript && hasTranscriptReviewDraft(sentence, materialID: material?.id) {
            return .orange
        }
        if sentence.answerRevealed == true { return Color(red: 0.62, green: 0.78, blue: 0.69) }
        if sentence.status == .generated { return .orange }
        if sentence.status == .verified || sentence.status == .corrected {
            return Color(red: 0.62, green: 0.78, blue: 0.69)
        }
        return Color(red: 0.58, green: 0.72, blue: 0.75)
    }

    private func rowBackgroundColor(for sentence: ListeningSentence) -> Color {
        if sentence.id == selectedSentenceID {
            return GlassTheme.cyan.opacity(0.11)
        }
        if sentence.id == hoveredSentenceID {
            return Color.white.opacity(0.055)
        }
        return .clear
    }

    private func rowBorderColor(for sentence: ListeningSentence) -> Color {
        if sentence.id == selectedSentenceID {
            return GlassTheme.cyan.opacity(0.25)
        }
        if sentence.id == hoveredSentenceID {
            return Color.white.opacity(0.12)
        }
        return .clear
    }

    private func sentenceStateLabel(_ sentence: ListeningSentence, isSelected: Bool = false) -> String {
        if isReviewingTranscript {
            if hasTranscriptReviewDraft(sentence, materialID: material?.id) { return "未保存校对" }
            if isSelected { return "正在核对" }
            switch sentence.status {
            case .generated, .pending: return "待核对"
            case .verified: return "已核对"
            case .corrected: return "已修正"
            }
        }
        if sentence.answerRevealed == true { return "已完成听写" }
        if sentence.status == .generated { return "待核对" }
        return "待练习"
    }

    private func sentenceStateSymbol(_ sentence: ListeningSentence) -> String {
        if isReviewingTranscript {
            if hasTranscriptReviewDraft(sentence, materialID: material?.id) { return "pencil.circle.fill" }
            switch sentence.status {
            case .generated, .pending: return "exclamationmark.circle.fill"
            case .verified: return "checkmark.circle.fill"
            case .corrected: return "checkmark.seal.fill"
            }
        }
        if sentence.answerRevealed == true { return "checkmark.circle.fill" }
        if sentence.status == .generated { return "exclamationmark.circle.fill" }
        return "circle"
    }

    private func materialStateSymbol(_ material: AudioMaterial) -> String {
        if store.activeTranscriptions.contains(material.id) { return "arrow.triangle.2.circlepath" }
        if material.transcriptionComplete == true {
            return material.sentences.contains(where: { $0.status == .generated })
                ? "exclamationmark.circle"
                : "checkmark.circle"
        }
        return material.sentences.isEmpty ? "waveform" : "pause.circle"
    }

    static func defaultPoints() -> [LearningPointRequest] {
        [LearningPointRequest(id: UUID(), category: .expression, prompt: ""),
         LearningPointRequest(id: UUID(), category: .grammar, prompt: ""),
         LearningPointRequest(id: UUID(), category: .knowledge, prompt: "")]
    }

    private func loadLearningPoints() {
        if let key = learningPointsDraftKey,
           let raw = editingDrafts.draft(for: key),
           let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode(ListeningLearningPointsDraft.self, from: data) {
            learningPoints = saved.points
            return
        }
        if let existing = sentence?.learningPoints, !existing.isEmpty {
            learningPoints = existing.map { LearningPointRequest(id: $0.id, category: $0.category, prompt: $0.prompt) }
        } else {
            learningPoints = Self.defaultPoints()
        }
    }

    private var learningPointsDraftKey: String? {
        guard let material, let sentence else { return nil }
        return "listening.points.\(material.id.uuidString).\(sentence.id.uuidString)"
    }

    private func persistLearningPointsDraft(_ points: [LearningPointRequest]) {
        guard let key = learningPointsDraftKey,
              let data = try? JSONEncoder().encode(ListeningLearningPointsDraft(points: points)),
              let value = String(data: data, encoding: .utf8) else { return }
        editingDrafts.save(value, for: key)
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
        let submittedPointsDraftKey = "listening.points.\(material.id.uuidString).\(sentence.id.uuidString)"
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
                editingDrafts.removeDraft(for: submittedPointsDraftKey)
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
        let state: String
        if let cues = material.referenceSubtitleCues, !cues.isEmpty {
            if material.segmentationSource == .subtitleCalibrated {
                let calibrated = material.sentences.filter { $0.timingSource == .speechCalibrated }.count
                state = calibrated == material.sentences.count ? "字幕时间已校准" : "字幕时间部分校准"
            } else if material.segmentationSource == .speech, !material.sentences.isEmpty {
                state = "字幕已导入，待主动校准（\(cues.count) 条）"
            } else {
                state = material.transcribedThroughSeconds != nil
                    ? "本机音频校准可继续"
                    : "字幕 + 本机音频校准（\(cues.count) 条字幕）"
            }
        } else {
            switch material.segmentationSource {
            case .subtitle:
                state = "旧版字幕切片（未迁移）"
            case .subtitleCalibrated:
                state = "字幕 + 本机音频校准"
            case .speech:
                state = material.transcriptionComplete == true ? "本机转写已完成" :
                    material.transcribedThroughSeconds != nil ? "本机转写可继续" : "本机转写未开始"
            case nil:
                state = material.transcriptionComplete == true ? "转写已完成" :
                    material.transcribedThroughSeconds != nil ? "转写可继续" : "尚未转写"
            }
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(material.title)
                .font(AppType.ui(15, weight: .semibold))
                .lineLimit(1)
            Text("\(material.sentences.count) 句 · \(state)")
                .font(AppType.ui(12))
                .foregroundStyle(.secondary)
        }
    }

    private func materialActions(_ material: AudioMaterial) -> some View {
        let hasSubtitleReference = material.referenceSubtitleCues?.isEmpty == false
        let needsExplicitSubtitleCalibration = hasSubtitleReference &&
            material.segmentationSource == .speech && !material.sentences.isEmpty
        let transcriptionButtonTitle = hasSubtitleReference
            ? (needsExplicitSubtitleCalibration
                ? "用字幕重新校准"
                : store.whisperModelInstalled ? "字幕 + 本机音频校准" : "准备本地转写模型")
            : (store.whisperModelInstalled ? "本机转写" : "准备本地转写模型")
        return HStack(spacing: 8) {
            if material.segmentationSource == .subtitle {
                Label("旧版字幕切片（未迁移）", systemImage: "captions.bubble")
                    .font(AppType.ui(13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if material.segmentationSource == .subtitleCalibrated {
                Label("字幕 + 本机音频校准", systemImage: "waveform")
                    .font(AppType.ui(13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if needsExplicitSubtitleCalibration {
                Button(transcriptionButtonTitle) {
                    startWhisperSubtitleRecalibration(material)
                }
                .buttonStyle(AppActionButtonStyle(prominent: true))
                .disabled(!store.canRecalibrateSubtitles(materialID: material.id))
            } else {
                Button(transcriptionButtonTitle) {
                    startTranscription(material)
                }
                .buttonStyle(AppActionButtonStyle(prominent: true))
                .disabled(store.activeTranscriptions.contains(material.id) || material.transcriptionComplete == true ||
                          store.data.dictationAttempts.contains(where: { $0.materialID == material.id }))
            }
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
            status = material.transcriptionComplete == true
                ? "字幕已保存；点击“用字幕重新校准”以字幕 cue 生成练习句。"
                : "字幕已保存；点击“字幕 + 本机音频校准”生成字幕句子并局部校准时间。"
        } catch { status = error.localizedDescription }
    }

    private func startTranscription(_ material: AudioMaterial) {
        do { try store.startTranscription(materialID: material.id) }
        catch { status = error.localizedDescription }
    }

    private func startWhisperSubtitleRecalibration(_ material: AudioMaterial) {
        do { try store.startWhisperSubtitleRecalibration(materialID: material.id) }
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

    private func loadDraft() {
        isLoadingDraft = true
        draftMaterialID = material?.id
        draftSentenceID = sentence?.id
        draft = sentence?.draftText ?? ""
        isLoadingDraft = false
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        guard let materialID = draftMaterialID, let sentenceID = draftSentenceID,
              let sentence = store.data.audioMaterials.first(where: { $0.id == materialID })?
                .sentences.first(where: { $0.id == sentenceID }),
              sentence.answerRevealed != true else { return }
        let value = draft
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? store.saveDictationDraft(materialID: materialID, sentenceID: sentenceID, text: value)
        }
    }

    private func persistDraft() {
        draftSaveTask?.cancel()
        guard let materialID = draftMaterialID, let sentenceID = draftSentenceID,
              let sentence = store.data.audioMaterials.first(where: { $0.id == materialID })?
                .sentences.first(where: { $0.id == sentenceID }),
              sentence.answerRevealed != true else { return }
        try? store.saveDictationDraft(materialID: materialID, sentenceID: sentenceID, text: draft)
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

    private var hasCurrentTranscriptReviewDraft: Bool {
        guard let materialID = reviewMaterialID, let sentenceID = reviewSentenceID,
              let sentence = store.data.audioMaterials.first(where: { $0.id == materialID })?
                .sentences.first(where: { $0.id == sentenceID }) else { return false }
        return reviewText != sentence.transcript ||
            reviewStart != String(format: "%.2f", sentence.startSeconds) ||
            reviewEnd != String(format: "%.2f", sentence.endSeconds)
    }

    private func transcriptReviewDraftPrefix(materialID: UUID, sentenceID: UUID) -> String {
        "transcript.\(materialID.uuidString).\(sentenceID.uuidString)."
    }

    private func hasTranscriptReviewDraft(_ sentence: ListeningSentence, materialID: UUID?) -> Bool {
        guard let materialID else { return false }
        let prefix = transcriptReviewDraftPrefix(materialID: materialID, sentenceID: sentence.id)
        let text = editingDrafts.draft(for: prefix + "text")
        let start = editingDrafts.draft(for: prefix + "start")
        let end = editingDrafts.draft(for: prefix + "end")
        return (text != nil && text != sentence.transcript) ||
            (start != nil && start != String(format: "%.2f", sentence.startSeconds)) ||
            (end != nil && end != String(format: "%.2f", sentence.endSeconds))
    }

    private func hasOtherTranscriptReviewDrafts(_ material: AudioMaterial) -> Bool {
        material.sentences.contains { item in
            item.id != reviewSentenceID && hasTranscriptReviewDraft(item, materialID: material.id)
        }
    }

    private func transcriptReviewProgress(_ material: AudioMaterial) -> String {
        let pending = material.sentences.filter { $0.status == .generated || $0.status == .pending }.count
        let reviewed = material.sentences.count - pending
        return "\(reviewed) / \(material.sentences.count) 句已核对 · \(pending) 句待核对"
    }

    private func reviewCompletionHelp(_ material: AudioMaterial) -> String {
        if material.transcriptionComplete != true { return "请等整段转写完成后再确认核对。" }
        if hasOtherTranscriptReviewDrafts(material) {
            return "请先逐句保存或放弃其他未保存的校对草稿。"
        }
        return "保存当前修改并完成字幕核对。"
    }

    private func enterTranscriptReview() {
        persistDraft()
        isReviewingTranscript = true
        reviewStatus = nil
        loadTranscriptReviewDraft()
    }

    private func exitTranscriptReview() {
        let hasDraft = hasCurrentTranscriptReviewDraft
        persistTranscriptReviewDraft()
        stopAudio()
        isReviewingTranscript = false
        status = hasDraft ? "未保存的字幕校对草稿已保留，可稍后继续复核。" : nil
    }

    private func loadTranscriptReviewDraft() {
        guard let material, let sentence else {
            reviewMaterialID = nil
            reviewSentenceID = nil
            reviewText = ""
            reviewStart = ""
            reviewEnd = ""
            reviewAISuggestion = nil
            reviewSpeechReference = nil
            return
        }
        let prefix = transcriptReviewDraftPrefix(materialID: material.id, sentenceID: sentence.id)
        reviewMaterialID = material.id
        reviewSentenceID = sentence.id
        reviewText = editingDrafts.draft(for: prefix + "text") ?? sentence.transcript
        reviewStart = editingDrafts.draft(for: prefix + "start") ??
            String(format: "%.2f", sentence.startSeconds)
        reviewEnd = editingDrafts.draft(for: prefix + "end") ??
            String(format: "%.2f", sentence.endSeconds)
        reviewAISuggestion = nil
        reviewSpeechReference = nil
    }

    private func persistTranscriptReviewDraft() {
        guard let materialID = reviewMaterialID, let sentenceID = reviewSentenceID,
              store.data.audioMaterials.first(where: { $0.id == materialID })?
                .sentences.contains(where: { $0.id == sentenceID }) == true else { return }
        let prefix = transcriptReviewDraftPrefix(materialID: materialID, sentenceID: sentenceID)
        guard hasCurrentTranscriptReviewDraft else {
            editingDrafts.removeDrafts(withPrefix: prefix)
            return
        }
        editingDrafts.save(reviewText, for: prefix + "text")
        editingDrafts.save(reviewStart, for: prefix + "start")
        editingDrafts.save(reviewEnd, for: prefix + "end")
    }

    private func saveTranscriptReview(_ sentence: ListeningSentence, material: AudioMaterial) {
        do {
            try commitTranscriptReview(sentence, material: material)
            reviewStatus = "已保存。"
        } catch {
            reviewStatus = error.localizedDescription
        }
    }

    private func commitTranscriptReview(_ sentence: ListeningSentence, material: AudioMaterial) throws {
        guard hasCurrentTranscriptReviewDraft else { return }
        try store.updateSentence(materialID: material.id, sentenceID: sentence.id,
                                 text: reviewText, start: Double(reviewStart) ?? -1,
                                 end: Double(reviewEnd) ?? -1)
        editingDrafts.removeDrafts(withPrefix:
            transcriptReviewDraftPrefix(materialID: material.id, sentenceID: sentence.id))
        loadTranscriptReviewDraft()
    }

    private func discardTranscriptReviewDraft() {
        guard let materialID = reviewMaterialID, let sentenceID = reviewSentenceID else { return }
        editingDrafts.removeDrafts(withPrefix:
            transcriptReviewDraftPrefix(materialID: materialID, sentenceID: sentenceID))
        loadTranscriptReviewDraft()
        reviewStatus = "已放弃校对草稿；原字幕内容未更改。"
    }

    private func completeTranscriptReview(_ material: AudioMaterial) {
        guard let sentence else { return }
        do {
            try commitTranscriptReview(sentence, material: material)
            let unresolvedCount = material.sentences.filter {
                $0.id != sentence.id && hasTranscriptReviewDraft($0, materialID: material.id)
            }.count
            guard unresolvedCount == 0 else {
                reviewStatus = "还有 \(unresolvedCount) 句存在未保存校对；请逐句保存或放弃后再完成。"
                return
            }
            try store.verifyTranscript(materialID: material.id)
            stopAudio()
            isReviewingTranscript = false
            reviewStatus = nil
            status = "字幕核对完成，可以开始逐句听写。"
        } catch {
            reviewStatus = error.localizedDescription
        }
    }

    private func beginSentenceSplit(_ sentence: ListeningSentence, material: AudioMaterial) {
        do {
            try commitTranscriptReview(sentence, material: material)
            guard let updated = store.data.audioMaterials.first(where: { $0.id == material.id })?
                .sentences.first(where: { $0.id == sentence.id }) else {
                throw StoreError.missingSentence
            }
            reviewSplitTarget = updated
            reviewStatus = nil
        } catch {
            reviewStatus = error.localizedDescription
        }
    }

    private func navigateTranscriptReview(by offset: Int, in material: AudioMaterial) {
        guard let sentence,
              let next = material.sentences.first(where: { $0.ordinal == sentence.ordinal + offset }) else { return }
        selectedSentenceID = next.id
    }

    private func mergeWithNextSentence(_ sentence: ListeningSentence, material: AudioMaterial) {
        do {
            try commitTranscriptReview(sentence, material: material)
            guard let next = material.sentences.first(where: { $0.ordinal == sentence.ordinal + 1 }) else {
                throw StoreError.missingSentence
            }
            guard !hasTranscriptReviewDraft(next, materialID: material.id) else {
                reviewStatus = "下一句有未保存校对；请先选择该句并保存或放弃草稿，再合并。"
                return
            }
            try store.mergeWithNext(materialID: material.id, sentenceID: sentence.id)
            editingDrafts.removeDrafts(withPrefix:
                transcriptReviewDraftPrefix(materialID: material.id, sentenceID: next.id))
            selectedSentenceID = sentence.id
            loadTranscriptReviewDraft()
            reviewStatus = "已合并；当前选择保留在合并后的句子。"
        } catch {
            reviewStatus = error.localizedDescription
        }
    }

    private func recognizeReviewSentence(_ sentence: ListeningSentence, material: AudioMaterial) {
        let sentenceID = sentence.id
        let materialID = material.id
        isReviewSpeechWorking = true
        reviewSpeechReference = nil
        reviewStatus = "正在识别这句音频…"
        Task {
            do {
                let result = try await TranscriptionService.recognizeSentence(
                    audioURL: store.audioURL(for: material),
                    start: sentence.startSeconds,
                    end: sentence.endSeconds
                )
                if selectedID == materialID, selectedSentenceID == sentenceID {
                    reviewSpeechReference = result
                    reviewStatus = "已取得本机识别参考；可再用 AI 对照校对。"
                }
            } catch {
                if selectedID == materialID, selectedSentenceID == sentenceID {
                    reviewStatus = error.localizedDescription
                }
            }
            isReviewSpeechWorking = false
        }
    }

    private func proofreadReviewSentence(_ sentence: ListeningSentence, material: AudioMaterial,
                                        includeSpeech: Bool) {
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { reviewStatus = error.localizedDescription; return }
        guard !key.isEmpty else { reviewStatus = AIProviderError.missingKey.localizedDescription; return }
        let source = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceID = sentence.id
        let materialID = material.id
        isReviewAIWorking = true
        reviewAISuggestion = nil
        reviewStatus = "正在复核音频并校对字幕…"
        Task {
            do {
                let reference: String?
                if includeSpeech {
                    reference = try await TranscriptionService.recognizeSentence(
                        audioURL: store.audioURL(for: material),
                        start: sentence.startSeconds,
                        end: sentence.endSeconds
                    )
                    if selectedID == materialID, selectedSentenceID == sentenceID {
                        reviewSpeechReference = reference
                    }
                } else {
                    reference = reviewSpeechReference
                }
                let result = try await AIStudyService.proofreadTranscript(
                    source, speechRecognition: reference, apiKey: key
                )
                guard selectedID == materialID, selectedSentenceID == sentenceID,
                      reviewText.trimmingCharacters(in: .whitespacesAndNewlines) == source else {
                    isReviewAIWorking = false
                    if selectedID == materialID, selectedSentenceID == sentenceID {
                        reviewStatus = "文字已变化，请重新校对当前句。"
                    }
                    return
                }
                reviewAISuggestion = result
                reviewStatus = "校对建议已生成；请结合音频检查。"
            } catch {
                if selectedID == materialID, selectedSentenceID == sentenceID {
                    reviewStatus = error.localizedDescription
                }
            }
            isReviewAIWorking = false
        }
    }

}

private struct ListeningAnalysisView: View {
    let analysis: ListeningAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListeningAnalysisSummaryCard(explanation: analysis.explanation)
            if !(analysis.items ?? []).isEmpty {
                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(height: 1)
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
                .font(AppType.sectionTitle)
                .foregroundStyle(GlassTheme.cyan)
            Text(explanation)
                .font(AppType.body)
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
    }
}

private struct ListeningAnalysisItemCard: View {
    let item: ListeningAnalysisItem

    private var isAttemptDifference: Bool {
        item.category == .attemptDifference
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(categoryTitle)
                .font(AppType.supporting)
                .foregroundStyle(isAttemptDifference ? .orange : GlassTheme.cyan)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    (isAttemptDifference ? Color.orange : GlassTheme.cyan).opacity(0.12),
                    in: Capsule()
                )

            Text(item.title)
                .font(AppType.sectionTitle)
                .lineSpacing(2)
                .textSelection(.enabled)

            Text(item.detail)
                .font(AppType.body)
                .lineSpacing(5)
                .textSelection(.enabled)

            if let evidence = item.evidence?.trimmingCharacters(in: .whitespacesAndNewlines),
               !evidence.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("依据")
                        .font(AppType.supporting)
                        .foregroundStyle(.secondary)
                    Text(evidence)
                        .font(AppType.supporting)
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
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
    @State private var hoveredRemovalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach($points) { $point in
                HStack(spacing: 14) {
                    Menu {
                        ForEach(CardCategory.allCases) { category in
                            Button {
                                point.category = category
                            } label: {
                                if point.category == category {
                                    Label(category.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(category.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(point.category.rawValue)
                            Image(systemName: "chevron.down")
                                .font(AppType.ui(10, weight: .semibold))
                        }
                        .font(AppType.ui(14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(width: 96, height: 44)
                        .background(
                            LinearGradient(
                                colors: [.white.opacity(0.12), .white.opacity(0.07)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .buttonStyle(.plain)

                    TextField(
                        "",
                        text: $point.prompt,
                        prompt: Text(placeholder(for: point.category))
                            .foregroundColor(.white.opacity(0.72)),
                        axis: .vertical
                    )
                        .font(AppType.body)
                        .lineLimit(1...3)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .studyInputChrome()

                    Button {
                        points.removeAll { $0.id == point.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(AppType.ui(11, weight: .semibold))
                            .frame(width: 24, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(hoveredRemovalID == point.id ? Color.red : Color.secondary)
                    .onHover { isHovering in
                        hoveredRemovalID = isHovering ? point.id : nil
                    }
                    .help("移除此要点")
                    .accessibilityLabel("移除此要点")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .interactiveDismissDisabled(true)
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
                .font(AppType.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(12)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .interactiveDismissDisabled(!text.isEmpty)
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
