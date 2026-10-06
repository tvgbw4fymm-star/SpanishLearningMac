import SwiftUI

private enum WritingSourceKind: String, CaseIterable, Identifiable {
    case listening = "听力材料"
    case reading = "阅读材料"
    var id: String { rawValue }
}

private struct WritingSourceChoice: Identifiable, Hashable {
    let materialID: UUID
    let segmentID: UUID
    let kind: WritingSourceKind
    let title: String
    let location: String
    let text: String
    var id: UUID { segmentID }
    var label: String { "\(title) · \(location)" }
}

private struct WritingFeedbackDisplay {
    let feedback: String
    let correctedSpanish: String
    let meaning: Int
    let grammar: Int
    let wording: Int
    let naturalness: Int
    let errors: [WritingError]
    let createdCard: Bool
}

struct WritingView: View {
    @EnvironmentObject private var store: StudyStore
    @EnvironmentObject private var editingDrafts: EditingDraftStore
    @Binding var selectedExerciseID: UUID?
    @State private var mode: WritingMode = .material
    @State private var sourceKind: WritingSourceKind = .reading
    @State private var selectedSegmentID: UUID?
    @State private var chinesePrompt = ""
    @State private var referenceSpanish = ""
    @State private var focus = ""
    @State private var isHintRevealed = false
    @State private var writingHint: WritingHintResult?
    @State private var isGeneratingHint = false
    @State private var hintError: String?
    @State private var learnerSpanish = ""
    @State private var feedback: WritingFeedbackDisplay?
    @State private var working = false
    @State private var isAuditingCards = false
    @State private var notice: String?
    @State private var chineseReview: ChineseDraftReviewResult?
    @State private var reviewedChinese = ""

    private var allSources: [WritingSourceChoice] {
        let listening = store.data.audioMaterials.flatMap { material in
            material.sentences.filter { !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                WritingSourceChoice(materialID: material.id, segmentID: $0.id, kind: .listening,
                                    title: material.title, location: "第 \($0.ordinal) 句", text: $0.transcript)
            }
        }
        let reading = store.data.articles.flatMap { article in
            article.chunks.map {
                WritingSourceChoice(materialID: article.id, segmentID: $0.id, kind: .reading,
                                    title: article.title, location: "第 \($0.ordinal) 段", text: $0.text)
            }
        }
        return listening + reading
    }

    private var visibleSources: [WritingSourceChoice] { allSources.filter { $0.kind == sourceKind } }
    private var selectedSource: WritingSourceChoice? { allSources.first { $0.segmentID == selectedSegmentID } }
    private var currentExercise: WritingExercise? {
        selectedExerciseID.flatMap { id in store.data.writingExercises.first(where: { $0.id == id }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WRITING DESK")
                        .font(AppType.latin(12, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(GlassTheme.cyan)
                    Text("把听过、读过的，写成自己的西语。")
                        .font(AppType.ui(32, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Label("输入草稿会自动保存在本机；提交后才写入练习记录。", systemImage: "externaldrive")
                        .font(AppType.ui(12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(WritingMode.allCases) { option in
                        Button {
                            guard option != mode else { return }
                            saveCurrentWritingDraft()
                            mode = option
                            resetForModeChange()
                            restoreCurrentWritingDraft()
                        } label: {
                            Text(option.rawValue)
                                .font(AppType.ui(15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .foregroundStyle(AppPalette.ink)
                                .foregroundStyle(mode == option ? Color.accentColor : AppPalette.secondaryInk)
                                .background(mode == option ? AppPalette.selected : AppPalette.surface,
                                            in: RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22)
                                    .strokeBorder(mode == option ? Color.accentColor.opacity(0.45) : AppPalette.separator)
                                    .allowsHitTesting(false))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(AppPalette.sidebar, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 16) {
                    preparationPanel
                    if !chinesePrompt.isEmpty { writingPanel }
                    if let feedback { feedbackPanel(feedback) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onAppear { prepareInitialState() }
        .onChange(of: selectedExerciseID) { _, _ in loadSelectedExercise() }
        .onChange(of: chinesePrompt) { _, newValue in
            saveCurrentWritingDraft()
            if let chineseReview, newValue != reviewedChinese && newValue != chineseReview.revisedChinese {
                self.chineseReview = nil
            }
        }
        .onChange(of: learnerSpanish) { _, _ in saveCurrentWritingDraft() }
        .onChange(of: referenceSpanish) { _, _ in saveCurrentWritingDraft() }
        .onChange(of: focus) { _, _ in saveCurrentWritingDraft() }
    }

    @ViewBuilder private var preparationPanel: some View {
        GroupBox(mode == .material ? "从材料生成中文题目" : "确定你想表达的中文") {
            VStack(alignment: .leading, spacing: 12) {
                if mode == .material {
                    HStack(spacing: 10) {
                        ForEach(WritingSourceKind.allCases) { kind in
                            Button {
                                guard kind != sourceKind else { return }
                                saveCurrentWritingDraft()
                                sourceKind = kind
                                changeSource(to: allSources.first(where: { $0.kind == kind })?.segmentID,
                                            savePreviousDraft: false)
                            } label: {
                                Label(kind.rawValue, systemImage: kind == .listening ? "waveform" : "book.closed")
                                    .font(AppType.ui(14, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .foregroundStyle(sourceKind == kind ? Color.accentColor : AppPalette.secondaryInk)
                                    .background(sourceKind == kind ? AppPalette.selected : AppPalette.surface,
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(sourceKind == kind ? Color.accentColor.opacity(0.45) : AppPalette.separator)
                                        .allowsHitTesting(false))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(AppPalette.sidebar, in: RoundedRectangle(cornerRadius: 10))
                    if visibleSources.isEmpty {
                        ContentUnavailableView(sourceKind == .reading ? "还没有阅读材料" : "还没有听力句子",
                                               systemImage: sourceKind == .reading ? "text.book.closed" : "waveform",
                                               description: Text("先在相应板块导入并完成材料准备。"))
                            .frame(minHeight: 150)
                    } else {
                        HStack(spacing: 12) {
                            Menu {
                                ForEach(visibleSources) { source in
                                    Button(source.label) {
                                        changeSource(to: source.segmentID)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(selectedSource?.label ?? "选择来源")
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.down")
                                        .font(AppType.ui(13, weight: .semibold))
                                        .foregroundStyle(AppPalette.secondaryInk)
                                }
                            }
                            .menuIndicator(.hidden)
                            .accessibilityLabel("选择来源")
                            .studyPickerChrome()
                            .frame(maxWidth: .infinity)
                            Button(chinesePrompt.isEmpty ? "生成中文题目" : "换一道中文题目") { generatePrompt() }
                                .buttonStyle(AppActionButtonStyle(prominent: true))
                                .controlSize(.large)
                                .disabled(selectedSource == nil || working)
                        }
                    }
                } else {
                    Text("先用中文写清楚自己想表达的内容，再尝试用西语完成。")
                        .font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary)
                    TextEditor(text: $chinesePrompt)
                        .font(AppType.ui(17))
                        .scrollContentBackground(.hidden)
                        .padding(16)
                        .frame(minHeight: 185)
                        .studyInputChrome()
                    HStack {
                        Spacer()
                        Button("AI 审核中文构思", systemImage: "sparkles") { reviewChineseDraft() }
                            .buttonStyle(AppActionButtonStyle(prominent: true))
                            .disabled(chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                    if let chineseReview {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("审核意见")
                                .font(AppType.ui(16, weight: .semibold))
                            Text(chineseReview.assessment)
                            ForEach(chineseReview.suggestions, id: \.self) { suggestion in
                                Text("• \(suggestion)")
                            }
                            if !chineseReview.revisedChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               chineseReview.revisedChinese != reviewedChinese {
                                Divider()
                                Text("建议改写：\(chineseReview.revisedChinese)")
                                    .textSelection(.enabled)
                                Button("采用改写") { chinesePrompt = chineseReview.revisedChinese }
                                    .buttonStyle(AppActionButtonStyle())
                            }
                        }
                        .font(AppType.ui(14))
                        .foregroundStyle(AppPalette.ink)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if working { ProgressView().controlSize(.small) }
                if let notice { Text(notice).font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .padding(.vertical, 8)
        }
    }

    private var writingPanel: some View {
        GroupBox("中文题目") {
            VStack(alignment: .leading, spacing: 14) {
                Text(chinesePrompt)
                .font(AppType.ui(23, weight: .semibold))
                .lineSpacing(6).textSelection(.enabled)
                Button {
                if writingHint != nil {
                    isHintRevealed.toggle()
                } else {
                    generateWritingHint()
                }
                } label: {
                Label(
                    isGeneratingHint ? "正在生成提示…" :
                        (isHintRevealed ? "收起提示" : "提示"),
                    systemImage: isGeneratingHint ? "hourglass" :
                        (isHintRevealed ? "lightbulb.slash" : "lightbulb")
                )
                }
                .buttonStyle(AppActionButtonStyle())
                .disabled(isGeneratingHint)
                if let hintError {
                Text(hintError)
                    .font(AppType.ui(13))
                    .foregroundStyle(.orange)
                }
                if isHintRevealed, let writingHint {
                VStack(alignment: .leading, spacing: 12) {
                    Label("表达思路", systemImage: "lightbulb")
                        .font(AppType.ui(15, weight: .semibold))
                        .foregroundStyle(GlassTheme.cyan)
                    ForEach(writingHint.expressionIdeas, id: \.self) { idea in
                        Text("• \(idea)")
                    }
                    if !writingHint.cautions.isEmpty {
                        Divider()
                        Label("注意", systemImage: "exclamationmark.triangle")
                            .font(AppType.ui(15, weight: .semibold))
                            .foregroundStyle(.orange)
                        ForEach(writingHint.cautions, id: \.self) { caution in
                            Text("• \(caution)")
                        }
                    }
                }
                .font(AppType.ui(15))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Divider()
                Text("你的西语").font(AppType.ui(17, weight: .semibold))
                TextEditor(text: $learnerSpanish)
                    .font(AppType.ui(17))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 145)
                    .studyInputChrome()
                HStack {
                    Text("\(writingWordCount(learnerSpanish)) 词")
                        .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                    Spacer()
                    Button(currentExercise == nil ? "提交并获取反馈" : "提交新版本并获取反馈") { submit() }
                        .buttonStyle(AppActionButtonStyle(prominent: true))
                        .disabled(learnerSpanish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func feedbackPanel(_ value: WritingFeedbackDisplay) -> some View {
        GroupBox("本次反馈") {
            VStack(alignment: .leading, spacing: 14) {
                WritingScoreTags(meaning: value.meaning, grammar: value.grammar,
                                 wording: value.wording, naturalness: value.naturalness)
                Text(value.feedback).lineSpacing(5).textSelection(.enabled)
                if !value.errors.isEmpty {
                    Divider()
                    Text("需要修改的地方").font(AppType.ui(17, weight: .semibold))
                    ForEach(value.errors) { error in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(error.original).strikethrough().foregroundStyle(.red)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(error.correction).foregroundStyle(.green)
                            }
                            Text(error.explanation).font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                Divider()
                Text("修改后的完整表达").font(AppType.ui(17, weight: .semibold))
                Text(value.correctedSpanish).textSelection(.enabled).lineSpacing(5)
                if mode == .material && !referenceSpanish.isEmpty {
                    Text("参考表达之一").font(AppType.ui(17, weight: .semibold)).padding(.top, 4)
                    Text(referenceSpanish).textSelection(.enabled).foregroundStyle(.secondary)
                }
                if value.createdCard {
                    Label("已生成一张待确认的“写作纠错”卡片，可到卡片页检查。",
                          systemImage: "rectangle.badge.plus")
                        .font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func prepareInitialState() {
        if selectedExerciseID != nil { loadSelectedExercise(); return }
        if store.data.articles.isEmpty && !store.data.audioMaterials.isEmpty { sourceKind = .listening }
        selectedSegmentID = visibleSources.first?.segmentID
        restoreCurrentWritingDraft()
    }

    private func loadSelectedExercise() {
        guard let exercise = currentExercise else {
            restoreCurrentWritingDraft()
            return
        }
        mode = exercise.mode ?? .material
        chinesePrompt = exercise.chinesePrompt
        chineseReview = nil
        reviewedChinese = ""
        referenceSpanish = exercise.referenceSpanish ?? ""
        focus = exercise.focus ?? ""
        isHintRevealed = false
        writingHint = nil
        hintError = nil
        learnerSpanish = exercise.versions.last?.spanishText ?? ""
        selectedSegmentID = exercise.sourceSegmentID
        if let id = exercise.sourceID, store.data.audioMaterials.contains(where: { $0.id == id }) {
            sourceKind = .listening
        } else if exercise.sourceID != nil { sourceKind = .reading }
        if let latest = exercise.versions.last { feedback = display(latest) }
        restoreCurrentWritingDraft()
        notice = "已载入这道练习，可以在原稿上继续修改并提交新版本。"
    }

    private func changeSource(to segmentID: UUID?, savePreviousDraft: Bool = true) {
        if savePreviousDraft { saveCurrentWritingDraft() }
        selectedSegmentID = segmentID
        selectedExerciseID = nil
        chinesePrompt = ""
        chineseReview = nil
        reviewedChinese = ""
        referenceSpanish = ""
        focus = ""
        isHintRevealed = false
        writingHint = nil
        hintError = nil
        learnerSpanish = ""
        feedback = nil
        notice = nil
        restoreCurrentWritingDraft()
    }

    private func resetForModeChange() {
        selectedExerciseID = nil
        chinesePrompt = ""
        chineseReview = nil
        reviewedChinese = ""
        referenceSpanish = ""
        focus = ""
        isHintRevealed = false
        writingHint = nil
        hintError = nil
        learnerSpanish = ""
        feedback = nil
        notice = nil
        if mode == .material { selectedSegmentID = visibleSources.first?.segmentID }
    }

    private var currentWritingDraftPrefix: String {
        if let selectedExerciseID { return "writing.exercise.\(selectedExerciseID.uuidString)." }
        switch mode {
        case .free:
            return "writing.free."
        case .material:
            return "writing.material.\(sourceKind.rawValue).\(selectedSegmentID?.uuidString ?? "none")."
        }
    }

    private func saveCurrentWritingDraft() {
        editingDrafts.save(chinesePrompt, for: currentWritingDraftPrefix + "prompt")
        editingDrafts.save(learnerSpanish, for: currentWritingDraftPrefix + "spanish")
        editingDrafts.save(referenceSpanish, for: currentWritingDraftPrefix + "reference")
        editingDrafts.save(focus, for: currentWritingDraftPrefix + "focus")
    }

    private func restoreCurrentWritingDraft() {
        let prefix = currentWritingDraftPrefix
        guard ["prompt", "spanish", "reference", "focus"].contains(where: {
            editingDrafts.draft(for: prefix + $0) != nil
        }) else { return }
        chinesePrompt = editingDrafts.draft(for: prefix + "prompt") ?? chinesePrompt
        learnerSpanish = editingDrafts.draft(for: prefix + "spanish") ?? learnerSpanish
        referenceSpanish = editingDrafts.draft(for: prefix + "reference") ?? referenceSpanish
        focus = editingDrafts.draft(for: prefix + "focus") ?? focus
    }

    private func clearWritingDraft(for prefix: String) {
        editingDrafts.removeDrafts(withPrefix: prefix)
    }

    private func reviewChineseDraft() {
        let draft = chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { notice = error.localizedDescription; return }
        guard !key.isEmpty else { notice = AIProviderError.missingKey.localizedDescription; return }
        working = true
        notice = "正在审核中文构思…"
        Task {
            do {
                let result = try await WritingAIService.reviewChineseDraft(draft, apiKey: key)
                guard chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines) == draft,
                      mode == .free else {
                    working = false
                    return
                }
                reviewedChinese = draft
                chineseReview = result
                notice = "审核完成。可以按建议修改，也可以直接采用改写。"
            } catch { notice = error.localizedDescription }
            working = false
        }
    }

    private func generatePrompt() {
        guard let source = selectedSource else { return }
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { notice = error.localizedDescription; return }
        guard !key.isEmpty else { notice = AIProviderError.missingKey.localizedDescription; return }
        working = true
        notice = "正在从这段材料准备一道中文题目…"
        selectedExerciseID = nil
        isHintRevealed = false
        writingHint = nil
        hintError = nil
        Task {
            do {
                let generated = try await WritingAIService.generatePrompt(sourceSpanish: source.text,
                                                                          sourceKind: source.kind.rawValue,
                                                                          sourceTitle: source.label,
                                                                          apiKey: key)
                chinesePrompt = generated.chinesePrompt
                referenceSpanish = generated.referenceSpanish
                focus = generated.focus
                isHintRevealed = false
                writingHint = nil
                hintError = nil
                learnerSpanish = ""
                feedback = nil
                notice = "题目已生成。参考西语会在提交后显示。"
            } catch { notice = error.localizedDescription }
            working = false
        }
    }

    private func generateWritingHint() {
        guard !isGeneratingHint else { return }
        let prompt = chinesePrompt
        let staticHint = focus
        let sourceContext = mode == .material ? selectedSource?.text : nil
        let draft = learnerSpanish
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch {
            hintError = error.localizedDescription
            return
        }
        guard !key.isEmpty else {
            hintError = AIProviderError.missingKey.localizedDescription
            return
        }
        isGeneratingHint = true
        hintError = nil
        Task {
            do {
                let result = try await WritingAIService.generateWritingHint(
                    chinesePrompt: prompt,
                    staticHint: staticHint,
                    sourceContext: sourceContext,
                    learnerDraft: draft,
                    apiKey: key
                )
                guard chinesePrompt == prompt else {
                    isGeneratingHint = false
                    return
                }
                writingHint = result
                isHintRevealed = true
            } catch {
                hintError = "提示生成失败，请重试"
            }
            isGeneratingHint = false
        }
    }

    private func submit() {
        let prompt = chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let spanish = learnerSpanish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !spanish.isEmpty else { notice = StoreError.emptyWriting.localizedDescription; return }
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { notice = error.localizedDescription; return }
        guard !key.isEmpty else { notice = AIProviderError.missingKey.localizedDescription; return }
        let requestedMode = mode
        let source = requestedMode == .material ? selectedSource : nil
        let requestedReferenceSpanish = requestedMode == .material ? referenceSpanish : nil
        let requestedFocus = focus
        let requestedContext = WritingSubmissionContext(
            exerciseID: selectedExerciseID, mode: requestedMode, prompt: prompt,
            learnerSpanish: spanish, sourceID: source?.materialID,
            sourceSegmentID: source?.segmentID, sourceQuote: source?.text,
            referenceSpanish: requestedReferenceSpanish, focus: requestedFocus
        )
        let submittedDraftPrefix = currentWritingDraftPrefix
        working = true
        notice = "正在检查意思、语法、用词和自然度…"
        Task {
            do {
                let evaluated = try await WritingAIService.evaluate(chinesePrompt: prompt,
                                                                     referenceSpanish: requestedReferenceSpanish,
                                                                     sourceSpanish: source?.text,
                                                                     learnerSpanish: spanish,
                                                                     mode: requestedMode, apiKey: key)
                var audited = evaluated
                var usedCardFallback = false
                if evaluated.card.create {
                    isAuditingCards = true
                    notice = "正在整理纠错卡片…"
                    let draft = CardDraft(category: .correction, mergeKey: evaluated.card.mergeKey,
                                          question: evaluated.card.question, answer: evaluated.card.answer)
                    let result = await CardAuditService.auditOrFallback(draft, apiKey: key)
                    usedCardFallback = result.usedFallback
                    audited = WritingFeedbackResult(
                        feedback: evaluated.feedback, correctedSpanish: evaluated.correctedSpanish,
                        scores: evaluated.scores, errors: evaluated.errors,
                        card: .init(create: true, mergeKey: evaluated.card.mergeKey,
                                    title: result.title, question: result.question, answer: result.answer))
                    notice = result.usedFallback
                        ? "AI 卡片整理失败，当前显示基础整理版本，可重试。"
                        : "正在保存反馈…"
                    isAuditingCards = false
                }
                let saved = try store.saveWritingFeedback(exerciseID: requestedContext.exerciseID,
                                                           mode: requestedMode,
                                                           sourceID: source?.materialID,
                                                           sourceSegmentID: source?.segmentID,
                                                           sourceQuote: source?.text,
                                                           chinesePrompt: prompt,
                                                           referenceSpanish: requestedReferenceSpanish,
                                                           focus: requestedFocus.isEmpty ? nil : requestedFocus,
                                                           learnerSpanish: spanish,
                                                           result: audited)
                let currentSource = mode == .material ? selectedSource : nil
                let currentReferenceSpanish = mode == .material ? referenceSpanish : nil
                let currentContext = WritingSubmissionContext(
                    exerciseID: selectedExerciseID, mode: mode,
                    prompt: chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    learnerSpanish: learnerSpanish.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceID: currentSource?.materialID, sourceSegmentID: currentSource?.segmentID,
                    sourceQuote: currentSource?.text,
                    referenceSpanish: currentReferenceSpanish, focus: focus
                )
                let stillShowingSubmittedContext = currentContext == requestedContext
                if stillShowingSubmittedContext {
                    clearWritingDraft(for: submittedDraftPrefix)
                    selectedExerciseID = saved.exerciseID
                    feedback = WritingFeedbackDisplay(feedback: audited.feedback,
                                                      correctedSpanish: audited.correctedSpanish,
                                                      meaning: audited.scores.meaning,
                                                      grammar: audited.scores.grammar,
                                                      wording: audited.scores.wording,
                                                      naturalness: audited.scores.naturalness,
                                                      errors: audited.errors.map {
                        WritingError(id: UUID(), original: $0.original,
                                     correction: $0.correction, explanation: $0.explanation)
                    }, createdCard: saved.cardID != nil)
                    notice = usedCardFallback
                        ? "反馈已保存；AI 卡片整理失败，当前使用基础整理版本，可在卡片详情中重试。"
                        : (saved.cardID == nil ? "反馈和本次版本已保存。" : "反馈已保存，并生成了待确认的纠错卡片。")
                }
            } catch {
                let currentSource = mode == .material ? selectedSource : nil
                let currentReferenceSpanish = mode == .material ? referenceSpanish : nil
                let currentContext = WritingSubmissionContext(
                    exerciseID: selectedExerciseID, mode: mode,
                    prompt: chinesePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    learnerSpanish: learnerSpanish.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceID: currentSource?.materialID, sourceSegmentID: currentSource?.segmentID,
                    sourceQuote: currentSource?.text,
                    referenceSpanish: currentReferenceSpanish, focus: focus
                )
                if currentContext == requestedContext {
                    notice = error.localizedDescription
                }
            }
            isAuditingCards = false
            working = false
        }
    }

    private func display(_ version: WritingVersion) -> WritingFeedbackDisplay {
        WritingFeedbackDisplay(feedback: version.feedback ?? "", correctedSpanish: version.correctedSpanish ?? "",
                               meaning: version.meaningScore ?? 0, grammar: version.grammarScore ?? 0,
                               wording: version.wordingScore ?? 0, naturalness: version.naturalnessScore ?? 0,
                               errors: version.errors ?? [], createdCard: version.cardID != nil)
    }
}

struct WritingScoreTags: View {
    let meaning: Int
    let grammar: Int
    let wording: Int
    let naturalness: Int

    var body: some View {
        HStack(spacing: 8) {
            tag("意思", meaning)
            tag("语法", grammar)
            tag("用词", wording)
            tag("自然度", naturalness)
        }
    }

    private func tag(_ title: String, _ score: Int) -> some View {
        Text("\(title) \(score)/5")
            .font(AppType.ui(12, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color(score).opacity(0.12), in: Capsule())
            .foregroundStyle(color(score))
    }

    private func color(_ score: Int) -> Color {
        switch score {
        case 5: .green
        case 4: .teal
        case 3: .orange
        default: .red
        }
    }
}

struct WritingHistoryView: View {
    @EnvironmentObject private var store: StudyStore
    @Binding var selectedExerciseID: UUID?
    @Binding var selectedScreen: StudyScreen?
    @State private var selectedDate = "all"
    @State private var expandedVersionIDs = Set<UUID>()
    @State private var formattingCache: [UUID: WritingFeedbackPresentation] = [:]
    @State private var formattingLoadingIDs = Set<UUID>()
    @State private var formattingFailureIDs = Set<UUID>()

    private var dates: [String] {
        Array(Set(store.data.writingExercises.flatMap(\.versions).map { writingDayKey($0.submittedAt) })).sorted(by: >)
    }

    private var exercises: [WritingExercise] {
        store.data.writingExercises.filter { exercise in
            selectedDate == "all" || exercise.versions.contains { writingDayKey($0.submittedAt) == selectedDate }
        }.sorted { ($0.versions.last?.submittedAt ?? $0.createdAt ?? .distantPast) >
            ($1.versions.last?.submittedAt ?? $1.createdAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(eyebrow: "Writing history", title: "每一次表达，都留得住。",
                        subtitle: "按日期回看中文题目、历次西语版本、评分和具体错误。")
            HStack {
                Text("\(exercises.count) 个练习 · \(visibleVersionCount) 次提交")
                    .font(AppType.ui(17, weight: .semibold))
                Spacer()
                Picker("日期", selection: $selectedDate) {
                    Text("全部日期").tag("all")
                    ForEach(dates, id: \.self) { date in Text(date).tag(date) }
                }
                .labelsHidden()
                .studyPickerChrome()
                .frame(width: 250)
            }
            if exercises.isEmpty {
                StudyEmptyState(title: "还没有写作记录",
                                message: "完成第一次翻译或自由表达后，记录会按日期出现在这里。",
                                symbol: "square.and.pencil")
            } else {
                HistoryPanel {
                    List(exercises) { exercise in
                        WritingHistoryBlock(exercise: exercise,
                                            versions: visibleVersions(exercise),
                                            sourceTitle: sourceTitle(exercise),
                                            continueAction: {
                                                selectedExerciseID = exercise.id
                                                selectedScreen = .writing
                                            },
                                            expandedVersionIDs: $expandedVersionIDs,
                                            presentation: { formattingCache[ $0.id ] },
                                            isFormatting: { formattingLoadingIDs.contains($0.id) },
                                            formattingFailed: { formattingFailureIDs.contains($0.id) },
                                            requestFormatting: { version in
                                                requestFormatting(for: version, exercise: exercise)
                                            })
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
        }
        .padding(32)
        .onChange(of: selectedDate) { _, _ in
            expandedVersionIDs.removeAll()
        }
    }

    private var visibleVersionCount: Int { exercises.reduce(0) { $0 + visibleVersions($1).count } }
    private func visibleVersions(_ exercise: WritingExercise) -> [WritingVersion] {
        exercise.versions.filter { selectedDate == "all" || writingDayKey($0.submittedAt) == selectedDate }
            .sorted { $0.submittedAt > $1.submittedAt }
    }

    private func requestFormatting(for version: WritingVersion, exercise: WritingExercise) {
        guard !formattingLoadingIDs.contains(version.id) else { return }
        formattingLoadingIDs.insert(version.id)
        formattingFailureIDs.remove(version.id)
        Task {
            do {
                let key = try AIProviderSettings.textKey() ?? ""
                guard !key.isEmpty else { throw AIProviderError.missingKey }
                let result = try await WritingAIService.formatWritingFeedback(
                    chinesePrompt: exercise.chinesePrompt,
                    learnerSpanish: version.spanishText,
                    scores: (version.meaningScore ?? 0, version.grammarScore ?? 0,
                             version.wordingScore ?? 0, version.naturalnessScore ?? 0),
                    feedback: version.feedback,
                    correctedSpanish: version.correctedSpanish,
                    errors: version.errors,
                    apiKey: key)
                formattingCache[version.id] = result
            } catch {
                formattingCache[version.id] = WritingFeedbackDetailView.fallbackPresentation(for: version)
                formattingFailureIDs.insert(version.id)
            }
            formattingLoadingIDs.remove(version.id)
        }
    }
    private func sourceTitle(_ exercise: WritingExercise) -> String {
        guard let id = exercise.sourceID else { return "自由表达" }
        if let audio = store.data.audioMaterials.first(where: { $0.id == id }) {
            let ordinal = audio.sentences.first(where: { $0.id == exercise.sourceSegmentID })?.ordinal
            return ordinal.map { "听力 · \(audio.title) · 第 \($0) 句" } ?? "听力 · \(audio.title)"
        }
        if let article = store.data.articles.first(where: { $0.id == id }) {
            let ordinal = article.chunks.first(where: { $0.id == exercise.sourceSegmentID })?.ordinal
            return ordinal.map { "阅读 · \(article.title) · 第 \($0) 段" } ?? "阅读 · \(article.title)"
        }
        return "来源资料已缺失"
    }
}

private struct WritingHistoryBlock: View {
    let exercise: WritingExercise
    let versions: [WritingVersion]
    let sourceTitle: String
    let continueAction: () -> Void
    @Binding var expandedVersionIDs: Set<UUID>
    let presentation: (WritingVersion) -> WritingFeedbackPresentation?
    let isFormatting: (WritingVersion) -> Bool
    let formattingFailed: (WritingVersion) -> Bool
    let requestFormatting: (WritingVersion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceTitle).font(AppType.ui(12, weight: .semibold)).foregroundStyle(.secondary)
                    Text(exercise.chinesePrompt)
                        .font(AppType.ui(20, weight: .semibold))
                }
                Spacer()
                Button("继续修改") { continueAction() }.buttonStyle(AppActionButtonStyle())
            }
            ForEach(versions) { version in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("第 \(exercise.versions.firstIndex(where: { $0.id == version.id }).map { $0 + 1 } ?? 1) 稿 · \(version.submittedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(version.spanishText).textSelection(.enabled)
                    WritingScoreTags(meaning: version.meaningScore ?? 0,
                                     grammar: version.grammarScore ?? 0,
                                     wording: version.wordingScore ?? 0,
                                     naturalness: version.naturalnessScore ?? 0)
                    Button {
                        let shouldRequest = !expandedVersionIDs.contains(version.id) &&
                            presentation(version) == nil
                        withAnimation(GlassTheme.animation) {
                            if expandedVersionIDs.contains(version.id) {
                                expandedVersionIDs.remove(version.id)
                            } else {
                                expandedVersionIDs.insert(version.id)
                            }
                        }
                        if shouldRequest {
                            requestFormatting(version)
                        }
                    } label: {
                        Label(expandedVersionIDs.contains(version.id) ? "收起修改意见" : "查看修改意见",
                              systemImage: expandedVersionIDs.contains(version.id) ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.link)
                    .font(AppType.ui(13, weight: .medium))
                    if expandedVersionIDs.contains(version.id) {
                        feedbackDetails(version,
                                        presentation: presentation(version),
                                        isFormatting: isFormatting(version),
                                        formattingFailed: formattingFailed(version))
                    }
                }
                .padding(.top, 4)
            }
        }
        .historyEntryChrome()
    }

    @ViewBuilder
    private func feedbackDetails(_ version: WritingVersion,
                                 presentation: WritingFeedbackPresentation?,
                                 isFormatting: Bool,
                                 formattingFailed: Bool) -> some View {
        WritingFeedbackDetailView(
            version: version,
            presentation: presentation,
            isFormatting: isFormatting,
            formattingFailed: formattingFailed,
            retryAction: { requestFormatting(version) })
    }
}

private struct WritingFeedbackDetailView: View {
    let version: WritingVersion
    let presentation: WritingFeedbackPresentation?
    let isFormatting: Bool
    let formattingFailed: Bool
    let retryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isFormatting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理修改意见…")
                }
                .foregroundStyle(.secondary)
            } else if let presentation {
                if formattingFailed {
                    HStack {
                        Text("AI 排版失败，以下显示原始修改意见。")
                            .font(AppType.ui(13, weight: .regular))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重新整理", action: retryAction)
                            .buttonStyle(.link)
                    }
                }
                WritingFeedbackPresentationView(presentation: presentation)
            } else {
                Text("正在整理修改意见…")
                    .font(AppType.ui(13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 800, alignment: .leading)
        .padding(.top, 4)
    }

    static func fallbackPresentation(for version: WritingVersion) -> WritingFeedbackPresentation {
        let blocks = WritingFeedbackDisplayFormatter.blocks(from: version.feedback ?? "")
        let issueBlocks = blocks.filter(\.isBullet)
        let paragraphs = blocks.filter { !$0.isBullet }
        let issues = issueBlocks.map {
            WritingFeedbackPresentationItem(title: "修改意见", explanation: $0.text, example: nil)
        }
        let summary = paragraphs.first?.text
        let corrected = version.correctedSpanish?.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedbackNormalized = WritingFeedbackDisplayFormatter.normalized(version.feedback ?? "")
        let recommended = corrected.flatMap {
            feedbackNormalized.contains(WritingFeedbackDisplayFormatter.normalized($0)) ? nil : $0
        }
        let improvements = (version.errors ?? []).map {
            WritingFeedbackPresentationItem(
                title: "\($0.original) → \($0.correction)",
                explanation: $0.explanation,
                example: nil)
        }
        return WritingFeedbackPresentation(summary: summary,
                                           issues: issues,
                                           recommendedExpression: recommended,
                                           improvements: improvements)
    }
}

private struct WritingFeedbackPresentationView: View {
    let presentation: WritingFeedbackPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = presentation.summary, !summary.isEmpty {
                WritingFeedbackSection(title: "修改意见") {
                    Text(summary)
                        .font(AppType.ui(14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            if !presentation.issues.isEmpty {
                WritingFeedbackSection(title: "核心问题") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(presentation.issues.enumerated()), id: \.offset) { index, item in
                            WritingFeedbackPresentationItemView(index: index + 1, item: item)
                        }
                    }
                }
            }
            if let expression = presentation.recommendedExpression, !expression.isEmpty {
                WritingFeedbackExampleView(text: expression)
            }
            if !presentation.improvements.isEmpty {
                WritingFeedbackSection(title: "进一步改进") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(presentation.improvements.enumerated()), id: \.offset) { _, item in
                            WritingFeedbackPresentationItemView(index: nil, item: item)
                        }
                    }
                }
            }
            if presentation.summary == nil &&
                presentation.issues.isEmpty &&
                presentation.recommendedExpression == nil &&
                presentation.improvements.isEmpty {
                Text("没有额外修改意见。")
                    .font(AppType.ui(13))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct WritingFeedbackPresentationItemView: View {
    let index: Int?
    let item: WritingFeedbackPresentationItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index.map { "\($0)." } ?? "•")
                .font(AppType.ui(14, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(AppType.ui(14, weight: .semibold))
                Text(item.explanation)
                    .font(AppType.ui(14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                if let example = item.example, !example.isEmpty {
                    Text(example)
                        .font(AppType.latin(14))
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WritingFeedbackSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppType.ui(15, weight: .semibold))
                .foregroundStyle(.primary)
            content
        }
    }
}

private struct WritingFeedbackItemView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(AppType.ui(14, weight: .semibold))
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WritingFeedbackBlockView: View {
    let block: WritingFeedbackDisplayFormatter.Block

    var body: some View {
        if block.isBullet {
            WritingFeedbackItemView {
                Text(block.text)
                    .font(AppType.ui(14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text(block.text)
                .font(AppType.ui(14, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }
}

private struct WritingFeedbackExampleView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("推荐表达", systemImage: "checkmark.circle")
                .font(AppType.ui(15, weight: .semibold))
            Text(text)
                .font(AppType.latin(15))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(GlassTheme.magenta.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: GlassTheme.controlRadius / 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassTheme.controlRadius / 2, style: .continuous)
                .strokeBorder(GlassTheme.magenta.opacity(0.16), lineWidth: 1)
        }
    }
}

private enum WritingFeedbackDisplayFormatter {
    struct Block {
        let text: String
        let isBullet: Bool
    }

    static func blocks(from text: String) -> [Block] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let value = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(Block(text: value, isBullet: false)) }
            paragraph.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            let pieces = splitNumberedItems(line)
            if pieces.count > 1 {
                flushParagraph()
                blocks.append(contentsOf: pieces.map { Block(text: $0, isBullet: true) })
            } else if let bullet = bulletText(line) {
                flushParagraph()
                blocks.append(Block(text: bullet, isBullet: true))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func bulletText(_ line: String) -> String? {
        let markers = ["•", "-", "–", "—"]
        guard let marker = markers.first(where: { line.hasPrefix($0) }) else { return nil }
        let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : String(value)
    }

    private static func splitNumberedItems(_ line: String) -> [String] {
        let pattern = #"(?=(?:[①②③④⑤⑥⑦⑧⑨⑩]|\d+[.)])\s*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [line] }
        let range = NSRange(line.startIndex..., in: line)
        let starts = regex.matches(in: line, range: range).map(\.range.location)
        guard starts.count > 1 else { return [line] }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : line.utf16.count
            let startIndex = String.Index(utf16Offset: start, in: line)
            let endIndex = String.Index(utf16Offset: end, in: line)
            var item = String(line[startIndex..<endIndex]).trimmingCharacters(in: .whitespaces)
            item = item.replacingOccurrences(of: #"^(?:[①②③④⑤⑥⑦⑧⑨⑩]|\d+[.)])\s*"#,
                                             with: "", options: .regularExpression)
            return item.isEmpty ? nil : item
        }
    }
}

private func writingDayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func writingWordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}
