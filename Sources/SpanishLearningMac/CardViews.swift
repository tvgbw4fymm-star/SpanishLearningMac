import SwiftUI

private enum CardLibrarySection: String, CaseIterable, Identifiable {
    case drafts = "待确认草稿"
    case due = "今日复习"
    case all = "全部卡片"
    var id: String { rawValue }
}

struct CardsView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var section: CardLibrarySection = .drafts
    @State private var category: CardCategory?
    @Binding var query: String
    @Binding var showDueCards: Bool
    @State private var selectedCardID: UUID?
    @State private var showingTrash = false

    private var cards: [StudyCard] {
        store.data.cards.filter { card in
            guard card.deletedAt == nil else { return false }
            let sectionMatches: Bool
            switch section {
            case .drafts: sectionMatches = card.confirmedAt == nil
            case .due: sectionMatches = card.confirmedAt != nil && (card.dueAt ?? .distantPast) <= .now
            case .all: sectionMatches = true
            }

            let categoryMatches = category == nil || card.category == category
            let searchMatches = query.isEmpty || card.question.localizedCaseInsensitiveContains(query) ||
                card.answer.localizedCaseInsensitiveContains(query)
            return sectionMatches && categoryMatches && searchMatches
        }.sorted { lhs, rhs in
            if section == .due { return (lhs.dueAt ?? .distantPast) < (rhs.dueAt ?? .distantPast) }
            return (lhs.updatedAt ?? lhs.createdAt ?? .distantPast) > (rhs.updatedAt ?? rhs.createdAt ?? .distantPast)
        }
    }

    private var trashCards: [StudyCard] {
        store.data.cards.filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(eyebrow: "Card library", title: "让学过的内容，真正留下来。",
                        subtitle: "检查草稿后进入 FSRS 复习；重复内容共用一张卡，并保留全部来源。")
            StudyChoiceBar(title: "卡片范围", options: CardLibrarySection.allCases,
                           selection: $section) { "\($0.rawValue) \(count(for: $0))" }
            HStack {
                Button(showingTrash ? "返回卡片" : "回收站") { showingTrash.toggle() }
                    .buttonStyle(AppActionButtonStyle(prominent: showingTrash))
                if showingTrash {
                    Text("已移入回收站的卡片不会参与复习。")
                        .font(AppType.ui(13))
                        .foregroundStyle(.secondary)
                }
            }
            if !showingTrash { HStack {
                Picker("分类", selection: $category) {
                    Text("全部分类").tag(Optional<CardCategory>.none)
                    ForEach(CardCategory.allCases) { item in Text(item.rawValue).tag(Optional(item)) }
                }
                .labelsHidden()
                .studyPickerChrome()
                .frame(width: 250)
                TextField("搜索问题或答案", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(maxWidth: 360)
            } }
            if (showingTrash ? trashCards : cards).isEmpty {
                StudyEmptyState(title: emptyTitle, message: emptyDescription,
                                symbol: "rectangle.on.rectangle")
            } else {
                List(showingTrash ? trashCards : cards) { card in
                    Button { selectedCardID = card.id } label: {
                        CardLibraryRow(card: card)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .padding(32)
        .background(.clear)
        .onAppear {
            if showDueCards {
                section = .due
                showDueCards = false
            } else if !query.isEmpty {
                section = .all
            }
        }
        .overlay {
            if let cardID = selectedCardID {
                ZStack {
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                        .onTapGesture { selectedCardID = nil }
                    CardDetailSheet(cardID: cardID, onClose: { selectedCardID = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }

    }

    private func count(for section: CardLibrarySection) -> Int {
        switch section {
        case .drafts: store.data.cards.filter { $0.deletedAt == nil && $0.confirmedAt == nil }.count
        case .due: store.data.cards.filter { $0.deletedAt == nil && $0.confirmedAt != nil && ($0.dueAt ?? .distantPast) <= .now }.count
        case .all: store.data.cards.filter { $0.deletedAt == nil }.count
        }
    }

    private var emptyTitle: String {
        if showingTrash { return "回收站为空" }
        return section == .drafts ? "没有待确认草稿" : section == .due ? "今天没有到期卡片" : "还没有卡片"
    }
    private var emptyDescription: String {
        if showingTrash { return "移入回收站的卡片会保留内容、来源和复习历史。" }
        return section == .drafts ? "在听写中填写积累点并调用 AI 后，草稿会出现在这里。" :
            section == .due ? "FSRS 会在需要复习时把卡片放到这里。" : "卡片将在这里按分类保存。"
    }

}

private struct CardLibraryRow: View {
    @EnvironmentObject private var store: StudyStore
    let card: StudyCard
    var body: some View {
        GlassCard(accent: GlassTheme.violet) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    CardTagView(kind: .category(card.category), showsIcon: false)
                    if let source = card.sources.first {
                        CardTagView(kind: CardSourceResolver.kind(for: source, in: store.data).tagKind,
                                    showsIcon: true)
                    }
                    Text(statusText).font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                Text(card.title ?? card.question)
                    .font(AppType.ui(17, weight: .semibold))
                    .multilineTextAlignment(.leading)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusText: String {
        if let deletedAt = card.deletedAt { return "已删除 \(deletedAt.formatted(date: .abbreviated, time: .shortened))" }
        if card.confirmedAt == nil { return "待确认" }
        if (card.dueAt ?? .distantPast) <= .now { return "待复习" }
        return "下次 \((card.dueAt ?? .now).formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct CardDetailSheet: View {
    private enum Layout {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let section: CGFloat = 16
        static let large: CGFloat = 20
    }

    @EnvironmentObject private var store: StudyStore
    @EnvironmentObject private var editingDrafts: EditingDraftStore
    let cardID: UUID
    let onClose: () -> Void
    @State private var feedback = ""
    @State private var working = false
    @State private var isAuditingCards = false
    @State private var notice: String?
    @State private var answerVisible = false
    @State private var sourcesExpanded = false
    @State private var aiPanelExpanded = false
    @State private var editing = false
    @State private var confirmingTrash = false
    @State private var confirmingDiscardEdit = false
    @State private var editTitle = ""
    @State private var editQuestion = ""
    @State private var editAnswer = ""

    private var card: StudyCard? { store.data.cards.first(where: { $0.id == cardID }) }
    private var isDue: Bool { card?.confirmedAt != nil && (card?.dueAt ?? .distantPast) <= .now }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.section) {
                HStack {
                    Text(card?.confirmedAt == nil ? "检查卡片草稿" : isDue ? "复习卡片" : "学习卡片")
                        .font(AppType.ui(27, weight: .semibold))
                    Spacer()
                    Button("关闭") { onClose() }
                }
                if let card {
                    metadata(card)
                    if editing { editForm(card) } else { cardFace(card) }
                    if !card.sources.isEmpty { sources(card) }
                    if card.deletedAt != nil {
                        Divider()
                        HStack {
                            Spacer()
                            Button("恢复") { restore(card) }
                                .buttonStyle(AppActionButtonStyle(prominent: true))
                        }
                    } else if !editing {
                        if card.confirmedAt == nil {
                            if aiPanelExpanded { aiRevisionPanel(card) }
                            Divider()
                            actionBar(card, includesConfirmation: true)
                        } else {
                            if aiPanelExpanded { aiRevisionPanel(card) }
                            Divider()
                            actionBar(card)
                            if isDue && answerVisible { reviewControls(card) }
                        }
                    }
                    if let notice { Text(notice).font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary).textSelection(.enabled) }
                } else {
                    ContentUnavailableView("卡片已不存在", systemImage: "rectangle.slash")
                }

            }
            .padding(Layout.large)
        }
        .frame(width: 720)
        .frame(maxHeight: 760)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(.white.opacity(0.22)))
        .shadow(color: .black.opacity(0.3), radius: 26, y: 12)
        .confirmationDialog("确定将这张卡片移到回收站吗？之后可以恢复。",
                           isPresented: $confirmingTrash, titleVisibility: .visible) {
            Button("移到回收站", role: .destructive) {
                if let card { moveToTrash(card) }
            }

            Button("取消", role: .cancel) {}
        }
        .alert("放弃尚未保存的卡片修改？", isPresented: $confirmingDiscardEdit) {
            Button("放弃修改", role: .destructive) { discardEdit() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("放弃后会恢复卡片原文。")
        }
        .onAppear { restoreEditDraftIfPresent() }
        .onChange(of: editTitle) { _, value in saveEditDraft(value, field: "title") }
        .onChange(of: editQuestion) { _, value in saveEditDraft(value, field: "question") }
        .onChange(of: editAnswer) { _, value in saveEditDraft(value, field: "answer") }
        .onChange(of: feedback) { _, value in
            editingDrafts.save(value, for: cardDraftPrefix + "feedback")
        }
    }

    private func actionBar(_ card: StudyCard, includesConfirmation: Bool = false) -> some View {
        HStack(alignment: .center, spacing: Layout.small) {
            HStack(spacing: Layout.small) {
            Button("编辑") {
                loadEditDraft(for: card)
                editing = true
            }
            .buttonStyle(AppActionButtonStyle())
            Button {
                withAnimation(GlassTheme.animation) { aiPanelExpanded.toggle() }
            } label: {
                Label("AI 整理", systemImage: "sparkles")
            }
                .buttonStyle(AppActionButtonStyle())
                .disabled(working)
            Menu {
                Button("移到回收站", role: .destructive) { confirmingTrash = true }
                    .disabled(working)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("更多管理操作")
            }
            if includesConfirmation {
                Spacer(minLength: 24)
                Button("确认并加入复习") { confirm() }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(working)
            }
        }
    }

    private func editForm(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: Layout.medium) {
            Text("卡片名称").font(AppType.ui(15, weight: .semibold))
            TextField("卡片名称", text: $editTitle)
            Text("正面").font(AppType.ui(15, weight: .semibold))
            TextEditor(text: $editQuestion).frame(minHeight: 80).studyInputChrome()
            Text("背面").font(AppType.ui(15, weight: .semibold))
            TextEditor(text: $editAnswer).frame(minHeight: 150).studyInputChrome()
            HStack {
                Button("放弃修改") {
                    if hasUnsavedCardChanges(card) {
                        confirmingDiscardEdit = true
                    } else {
                        discardEdit()
                    }
                }
                Spacer()
                Button("保存修改") { saveEditedCard(card) }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
            }
        }
    }

    private func saveEditedCard(_ card: StudyCard) {
        do {
            try store.updateCardContent(card.id, title: editTitle, question: editQuestion, answer: editAnswer)
            editingDrafts.removeDrafts(withPrefix: cardDraftPrefix)
            editing = false
            notice = "卡片修改已保存。"
        } catch { notice = error.localizedDescription }
    }

    private var cardDraftPrefix: String { "card.\(cardID.uuidString)." }

    private func saveEditDraft(_ value: String, field: String) {
        guard editing, let card else { return }
        let original: String
        switch field {
        case "title": original = card.title ?? card.question
        case "question": original = card.question
        case "answer": original = card.answer
        default: return
        }
        let key = cardDraftPrefix + field
        if value == original {
            editingDrafts.removeDraft(for: key)
        } else {
            editingDrafts.save(value, for: key)
        }
    }

    private func loadEditDraft(for card: StudyCard) {
        editTitle = editingDrafts.draft(for: cardDraftPrefix + "title") ?? (card.title ?? card.question)
        editQuestion = editingDrafts.draft(for: cardDraftPrefix + "question") ?? card.question
        editAnswer = editingDrafts.draft(for: cardDraftPrefix + "answer") ?? card.answer
    }

    private func restoreEditDraftIfPresent() {
        feedback = editingDrafts.draft(for: cardDraftPrefix + "feedback") ?? ""
        aiPanelExpanded = !feedback.isEmpty
        guard let card,
              ["title", "question", "answer"].contains(where: {
                  editingDrafts.draft(for: cardDraftPrefix + $0) != nil
              }) else { return }
        loadEditDraft(for: card)
        editing = true
    }

    private func hasUnsavedCardChanges(_ card: StudyCard) -> Bool {
        editTitle != (card.title ?? card.question) ||
            editQuestion != card.question ||
            editAnswer != card.answer
    }

    private func discardEdit() {
        editingDrafts.removeDrafts(withPrefix: cardDraftPrefix)
        if let card { loadEditDraft(for: card) }
        editing = false
        notice = "已放弃修改；卡片原文未更改。"
    }

    private func moveToTrash(_ card: StudyCard) {
        do {
            try store.moveCardToTrash(card.id)
            onClose()
        } catch { notice = error.localizedDescription }
    }

    private func restore(_ card: StudyCard) {
        do {
            try store.restoreCard(card.id)
            onClose()
        } catch { notice = error.localizedDescription }
    }

    private func metadata(_ card: StudyCard) -> some View {
        HStack(spacing: 8) {
            CardTagView(kind: .category(card.category), showsIcon: false)
            ForEach(sourceKinds(for: card), id: \.self) { source in
                CardTagView(kind: source.tagKind)
            }
            if card.sources.count > 1 {
                Label("已合并 \(card.sources.count) 个来源", systemImage: "arrow.triangle.merge")
                    .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
            }
            if let revisions = card.revisionCount, revisions > 0 {
                Text("已修订 \(revisions) 次").font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
            }
        }
    }

    private func cardFace(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: Layout.medium) {
            Text("正面")
                .font(AppType.ui(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(AppType.ui(17, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(card.question)
                .font(AppType.ui(23, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if card.confirmedAt == nil || answerVisible || !isDue {
                Divider()
                Text("背面")
                    .font(AppType.ui(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(card.answer).font(AppType.ui(17)).lineSpacing(5).textSelection(.enabled)
            } else {
                Button("显示答案") { answerVisible = true }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            LinearGradient(colors: [
                Color.white.opacity(0.08),
                Color.white.opacity(0.05)
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                .blendMode(.overlay)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private func sources(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: Layout.small) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("来源")
                    .font(AppType.ui(12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let source = card.sources.first {
                    CardTagView(kind: CardSourceResolver.kind(for: source, in: store.data).tagKind)
                    Text(sourceName(source))
                        .font(AppType.ui(13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if card.sources.count > 1 {
                    Text("+\(card.sources.count - 1)")
                        .font(AppType.ui(12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(sourcesExpanded ? "收起来源" : "查看来源") {
                    withAnimation(GlassTheme.animation) { sourcesExpanded.toggle() }
                }
                .buttonStyle(.link)
                .font(AppType.ui(13, weight: .medium))
            }
            if sourcesExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(card.sources.enumerated()), id: \.offset) { _, source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sourceName(source))
                                .font(AppType.ui(12, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Text(sourceText(source))
                                .font(AppType.reading(15))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func sourceKinds(for card: StudyCard) -> [CardSourceKind] {
        var seen = Set<CardSourceKind>()
        return card.sources.compactMap { source in
            let kind = CardSourceResolver.kind(for: source, in: store.data)
            return seen.insert(kind).inserted ? kind : nil
        }
    }

    private func sourceText(_ source: SourceReference) -> String {
        if let article = store.data.articles.first(where: { $0.id == source.materialID }) {
            return article.originalText
        }
        if let material = store.data.audioMaterials.first(where: { $0.id == source.materialID }),
           let sentence = material.sentences.first(where: { $0.id == source.segmentID }) {
            return sentence.transcript
        }
        return source.quote ?? "原文已不可用"
    }

    private func sourceName(_ source: SourceReference) -> String {
        if let material = store.data.audioMaterials.first(where: { $0.id == source.materialID }) {
            let ordinal = material.sentences.first(where: { $0.id == source.segmentID })?.ordinal
            return ordinal.map { "\(material.title) · 第 \($0) 句" } ?? material.title
        }
        if let article = store.data.articles.first(where: { $0.id == source.materialID }) {
            let ordinal = article.chunks.first(where: { $0.id == source.segmentID })?.ordinal
            return ordinal.map { "\(article.title) · 第 \($0) 段" } ?? article.title
        }
        if let exercise = store.data.writingExercises.first(where: { $0.id == source.materialID }) {
            let version = exercise.versions.firstIndex(where: { $0.id == source.segmentID }).map { $0 + 1 }
            return version.map { "写作练习 · 第 \($0) 稿" } ?? "写作练习"
        }
        return "来源资料已缺失"
    }

    private func aiRevisionPanel(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: Layout.small) {
            Text("修改意见")
                .font(AppType.ui(14, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("例如：增加例句；解释得更具体；突出动词本质含义", text: $feedback)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("按意见修订") { revise(card) }
                    .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                Button("自动整理") { reAudit(card) }
                    .disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            .font(AppType.ui(13, weight: .medium))
        }
        .padding(.top, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func reviewControls(_ card: StudyCard) -> some View {
        let preview = LocalFSRSScheduler.preview(card: card)
        return VStack(alignment: .leading, spacing: 12) {
            Text("这次回忆得怎么样？").font(AppType.ui(17, weight: .semibold))
            Text("按刚才真实的回忆难度评分，FSRS 会计算下次出现时间。")
                .font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(ReviewGrade.allCases) { grade in
                    Button {
                        review(grade)
                    } label: {
                        VStack(spacing: 4) {
                            Text(grade.title).fontWeight(.semibold)
                            Text(nextIntervalText(preview[grade])).font(AppType.ui(12, weight: .regular))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AppActionButtonStyle())
                    .tint(grade == .good ? Color.accentColor : Color.secondary)
                    .disabled(working)
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12)))
    }

    private func nextIntervalText(_ due: Date?) -> String {
        guard let due else { return "—" }
        let seconds = max(0, due.timeIntervalSinceNow)
        if seconds < 3_600 { return "\(max(1, Int(round(seconds / 60)))) 分钟" }
        if seconds < 86_400 { return "\(max(1, Int(round(seconds / 3_600)))) 小时" }
        return "\(max(1, Int(round(seconds / 86_400)))) 天"
    }

    private func revise(_ card: StudyCard) {
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { notice = error.localizedDescription; return }
        guard !key.isEmpty else { notice = AIProviderError.missingKey.localizedDescription; return }
        working = true
        notice = "正在按照意见修订…"
        let instruction = feedback
        Task {
            do {
                let result = try await AIStudyService.reviseCard(question: card.question, answer: card.answer,
                                                                 category: card.category, feedback: instruction,
                                                                 sourceQuote: card.sources.first?.quote, apiKey: key)
                isAuditingCards = true
                notice = "正在整理修订后的卡片…"
                let draft = CardDraft(category: result.category, mergeKey: card.mergeKey ?? "",
                                      question: result.question, answer: result.answer)
                let audited = await CardAuditService.auditOrFallback(draft, apiKey: key)
                try store.updateCardDraft(card.id, category: result.category,
                                          question: audited.question, answer: audited.answer,
                                          title: audited.title)
                feedback = ""
                notice = audited.usedFallback
                    ? "AI 卡片整理失败，当前显示基础整理版本，可重试。"
                    : "已显示修改后的完整卡片，请检查后再确认。"
            } catch { notice = error.localizedDescription }
            isAuditingCards = false
            working = false
        }
    }

    private func reAudit(_ card: StudyCard) {
        let key: String
        do { key = try AIProviderSettings.textKey() ?? "" }
        catch { notice = error.localizedDescription; return }
        guard !key.isEmpty else { notice = AIProviderError.missingKey.localizedDescription; return }
        working = true
        isAuditingCards = true
        notice = "正在重新整理卡片…"
        let draft = CardDraft(category: card.category, mergeKey: card.mergeKey ?? "",
                              question: card.question, answer: card.answer)
        Task {
            let audited = await CardAuditService.auditOrFallback(draft, apiKey: key)
            do {
                try store.updateCardDraft(card.id, category: card.category,
                                          question: audited.question, answer: audited.answer,
                                          title: audited.title)
                notice = audited.usedFallback
                    ? "AI 卡片整理失败，当前显示基础整理版本，可重试。"
                    : "卡片已重新整理，请检查后确认。"
            } catch {
                notice = error.localizedDescription
            }
            isAuditingCards = false
            working = false
        }
    }

    private func confirm() {
        do {
            try store.confirmCard(cardID)
            answerVisible = false
            notice = "已加入复习；现在可以先做第一次回忆。"
        } catch { notice = error.localizedDescription }
    }

    private func review(_ grade: ReviewGrade) {
        working = true
        do {
            try store.reviewCard(cardID, grade: grade)
            let due = store.data.cards.first(where: { $0.id == cardID })?.dueAt
            notice = "已记录为“\(grade.title)”，下次复习：\(due?.formatted(date: .abbreviated, time: .shortened) ?? "待计算")。"
            answerVisible = false
        } catch { notice = error.localizedDescription }
        working = false
    }
}
