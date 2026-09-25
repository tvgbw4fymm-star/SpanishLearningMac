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

    private var cards: [StudyCard] {
        store.data.cards.filter { card in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(eyebrow: "Card library", title: "让学过的内容，真正留下来。",
                        subtitle: "检查草稿后进入 FSRS 复习；重复内容共用一张卡，并保留全部来源。")
            StudyChoiceBar(title: "卡片范围", options: CardLibrarySection.allCases,
                           selection: $section) { "\($0.rawValue) \(count(for: $0))" }
            HStack {
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
            }
            if cards.isEmpty {
                StudyEmptyState(title: emptyTitle, message: emptyDescription,
                                symbol: "rectangle.on.rectangle")
            } else {
                List(cards) { card in
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
        case .drafts: store.data.cards.filter { $0.confirmedAt == nil }.count
        case .due: store.data.cards.filter { $0.confirmedAt != nil && ($0.dueAt ?? .distantPast) <= .now }.count
        case .all: store.data.cards.count
        }
    }

    private var emptyTitle: String {
        section == .drafts ? "没有待确认草稿" : section == .due ? "今天没有到期卡片" : "还没有卡片"
    }
    private var emptyDescription: String {
        section == .drafts ? "在听写中填写积累点并调用 AI 后，草稿会出现在这里。" :
            section == .due ? "FSRS 会在需要复习时把卡片放到这里。" : "卡片将在这里按分类保存。"
    }

}

private struct CardLibraryRow: View {
    let card: StudyCard
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(card.category.rawValue)
                    .font(AppType.ui(12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.green.opacity(0.10), in: Capsule())
                Text(statusText).font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            Text(card.question).font(AppType.ui(17, weight: .semibold)).multilineTextAlignment(.leading)
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.16)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusText: String {
        if card.confirmedAt == nil { return "待确认" }
        if (card.dueAt ?? .distantPast) <= .now { return "待复习" }
        return "下次 \((card.dueAt ?? .now).formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct CardDetailSheet: View {
    @EnvironmentObject private var store: StudyStore
    let cardID: UUID
    let onClose: () -> Void
    @State private var feedback = ""
    @State private var working = false
    @State private var notice: String?
    @State private var answerVisible = false
    @State private var shownSourceIndex: Int?

    private var card: StudyCard? { store.data.cards.first(where: { $0.id == cardID }) }
    private var isDue: Bool { card?.confirmedAt != nil && (card?.dueAt ?? .distantPast) <= .now }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(card?.confirmedAt == nil ? "检查卡片草稿" : isDue ? "复习卡片" : "学习卡片")
                        .font(AppType.ui(27, weight: .semibold))
                    Spacer()
                    Button("关闭") { onClose() }
                }
                if let card {
                    metadata(card)
                    cardFace(card)
                    if !card.sources.isEmpty { sources(card) }
                    if card.confirmedAt == nil { draftControls(card) }
                    else if isDue && answerVisible { reviewControls(card) }
                    if let notice { Text(notice).font(AppType.ui(15, weight: .regular)).foregroundStyle(.secondary).textSelection(.enabled) }
                } else {
                    ContentUnavailableView("卡片已不存在", systemImage: "rectangle.slash")
                }
            }
            .padding(28)
        }
        .frame(width: 720, height: 700)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(.white.opacity(0.22)))
        .shadow(color: .black.opacity(0.3), radius: 26, y: 12)
    }

    private func metadata(_ card: StudyCard) -> some View {
        HStack {
            Text(card.category.rawValue)
                .font(AppType.ui(12, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18)))
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
        VStack(alignment: .leading, spacing: 14) {
            Text("正面")
                .font(AppType.ui(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
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
        GroupBox("来源 · \(card.sources.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(card.sources.enumerated()), id: \.offset) { index, source in
                    Button {
                        shownSourceIndex = index
                    } label: {
                        Label("查看原文 · \(sourceName(source))", systemImage: "link")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .help(String(sourceText(source).prefix(320)))
                    .popover(isPresented: Binding(
                        get: { shownSourceIndex == index },
                        set: { if !$0 { shownSourceIndex = nil } }
                    )) {
                        ScrollView {
                            Text(sourceText(source))
                                .font(AppType.reading(16))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                        }
                        .frame(width: 460, height: 300)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
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

    private func draftControls(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("修改意见").font(AppType.ui(17, weight: .semibold))
            TextField("例如：增加例句；解释得更具体；突出动词本质含义", text: $feedback, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("按意见修订") { revise(card) }
                    .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("确认并加入复习") { confirm() }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(working)
            }
        }
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
                try store.updateCardDraft(card.id, category: result.category,
                                          question: result.question, answer: result.answer)
                feedback = ""
                notice = "已显示修改后的完整卡片，请检查后再确认。"
            } catch { notice = error.localizedDescription }
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

