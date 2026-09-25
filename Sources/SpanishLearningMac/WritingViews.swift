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
                        .foregroundStyle(.white.opacity(0.94))
                }
                HStack(spacing: 10) {
                    ForEach(WritingMode.allCases) { option in
                        Button {
                            guard option != mode else { return }
                            mode = option
                            resetForModeChange()
                        } label: {
                            Text(option.rawValue)
                                .font(AppType.ui(15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .foregroundStyle(.white)
                                .background(mode == option ? .white.opacity(0.22) : .white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22)
                                    .strokeBorder(.white.opacity(mode == option ? 0.40 : 0.14))
                                    .allowsHitTesting(false))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))

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
            if let chineseReview, newValue != reviewedChinese && newValue != chineseReview.revisedChinese {
                self.chineseReview = nil
            }
        }
    }

    @ViewBuilder private var preparationPanel: some View {
        GroupBox(mode == .material ? "从材料生成中文题目" : "确定你想表达的中文") {
            VStack(alignment: .leading, spacing: 12) {
                if mode == .material {
                    HStack(spacing: 10) {
                        ForEach(WritingSourceKind.allCases) { kind in
                            Button {
                                guard kind != sourceKind else { return }
                                sourceKind = kind
                                changeSource(to: allSources.first(where: { $0.kind == kind })?.segmentID)
                            } label: {
                                Label(kind.rawValue, systemImage: kind == .listening ? "waveform" : "book.closed")
                                    .font(AppType.ui(14, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(sourceKind == kind ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.07),
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(.white.opacity(sourceKind == kind ? 0.38 : 0.14))
                                        .allowsHitTesting(false))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
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
                                        .foregroundStyle(.white.opacity(0.86))
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
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
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
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
    }

    private func loadSelectedExercise() {
        guard let exercise = currentExercise else { return }
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
        notice = "已载入这道练习，可以在原稿上继续修改并提交新版本。"
    }

    private func changeSource(to segmentID: UUID?) {
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
        let source = mode == .material ? selectedSource : nil
        working = true
        notice = "正在检查意思、语法、用词和自然度…"
        Task {
            do {
                let evaluated = try await WritingAIService.evaluate(chinesePrompt: prompt,
                                                                     referenceSpanish: mode == .material ? referenceSpanish : nil,
                                                                     sourceSpanish: source?.text,
                                                                     learnerSpanish: spanish,
                                                                     mode: mode, apiKey: key)
                let saved = try store.saveWritingFeedback(exerciseID: selectedExerciseID,
                                                           mode: mode,
                                                           sourceID: source?.materialID,
                                                           sourceSegmentID: source?.segmentID,
                                                           sourceQuote: source?.text,
                                                           chinesePrompt: prompt,
                                                           referenceSpanish: mode == .material ? referenceSpanish : nil,
                                                           focus: focus.isEmpty ? nil : focus,
                                                           learnerSpanish: spanish,
                                                           result: evaluated)
                selectedExerciseID = saved.exerciseID
                feedback = WritingFeedbackDisplay(feedback: evaluated.feedback,
                                                  correctedSpanish: evaluated.correctedSpanish,
                                                  meaning: evaluated.scores.meaning,
                                                  grammar: evaluated.scores.grammar,
                                                  wording: evaluated.scores.wording,
                                                  naturalness: evaluated.scores.naturalness,
                                                  errors: evaluated.errors.map {
                    WritingError(id: UUID(), original: $0.original,
                                 correction: $0.correction, explanation: $0.explanation)
                }, createdCard: saved.cardID != nil)
                notice = saved.cardID == nil ? "反馈和本次版本已保存。" : "反馈已保存，并生成了待确认的纠错卡片。"
            } catch { notice = error.localizedDescription }
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
                List(exercises) { exercise in
                    WritingHistoryBlock(exercise: exercise,
                                        versions: visibleVersions(exercise),
                                        sourceTitle: sourceTitle(exercise)) {
                        selectedExerciseID = exercise.id
                        selectedScreen = .writing
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }
        }
        .padding(32)
    }

    private var visibleVersionCount: Int { exercises.reduce(0) { $0 + visibleVersions($1).count } }
    private func visibleVersions(_ exercise: WritingExercise) -> [WritingVersion] {
        exercise.versions.filter { selectedDate == "all" || writingDayKey($0.submittedAt) == selectedDate }
            .sorted { $0.submittedAt > $1.submittedAt }
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
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("第 \(exercise.versions.firstIndex(where: { $0.id == version.id }).map { $0 + 1 } ?? 1) 稿 · \(version.submittedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                    Text(version.spanishText).textSelection(.enabled)
                    WritingScoreTags(meaning: version.meaningScore ?? 0,
                                     grammar: version.grammarScore ?? 0,
                                     wording: version.wordingScore ?? 0,
                                     naturalness: version.naturalnessScore ?? 0)
                    if let feedback = version.feedback { Text(feedback).font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary) }
                    if let corrected = version.correctedSpanish, !corrected.isEmpty {
                        Label(corrected, systemImage: "checkmark.circle")
                            .font(AppType.ui(15, weight: .regular)).textSelection(.enabled)
                    }
                    ForEach(version.errors ?? []) { error in
                        Text("\(error.original) → \(error.correction)：\(error.explanation)")
                            .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .padding(.vertical, 5)
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
