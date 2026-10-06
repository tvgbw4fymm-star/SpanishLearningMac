import SwiftUI

struct ReadingView: View {
    @EnvironmentObject private var store: StudyStore
    @EnvironmentObject private var editingDrafts: EditingDraftStore
    @Binding var selectedArticleID: UUID?
    @State private var chunkIndex = 0
    @State private var difficulty: ReadingDifficulty = .understood
    @State private var questionDraft = ""
    @State private var note = ""
    @State private var importSheet = false
    @State private var newText = ""
    @State private var status: String?
    @State private var working = false
    @State private var isAuditingCards = false

    private let ink = Color(red: 0.91, green: 0.89, blue: 0.95)
    private let secondaryInk = Color(red: 0.78, green: 0.75, blue: 0.84)
    private let accentInk = Color(red: 0.88, green: 0.78, blue: 1.00)

    private var article: ReadingArticle? {
        store.data.articles.first(where: { $0.id == selectedArticleID }) ?? store.data.articles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.data.articles.isEmpty {
                PageHeading(eyebrow: "Reading room", title: "从一篇文章开始。",
                            subtitle: "粘贴西语原文，按约 50 词切段。")
                emptyReadingWorkspace
            } else if let article, !article.chunks.isEmpty {
                HStack(spacing: 16) {
                    Menu {
                        ForEach(store.data.articles) { item in
                            Button(item.title) {
                                saveCurrentReadingDraft()
                                selectedArticleID = item.id
                                chunkIndex = 0
                                resetCompletionDraft()
                                restoreCurrentReadingDraft()
                            }
                        }
                    } label: {
                        HStack {
                            Text(article.title)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(AppType.ui(13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel("选择文章")
                    .studyPickerChrome()
                    .frame(maxWidth: 520)
                    Spacer(minLength: 0)
                    Button("粘贴文章", systemImage: "plus") { importSheet = true }
                        .buttonStyle(AppActionButtonStyle())
                }
                let safeIndex = min(chunkIndex, article.chunks.count - 1)
                let chunk = article.chunks[safeIndex]
                GeometryReader { geometry in
                    if geometry.size.width >= 560 {
                        HStack(spacing: 16) {
                            originalPanel(article: article, chunk: chunk)
                                .frame(width: (geometry.size.width - 16) * 0.52)
                            studyPanel(article: article, chunk: chunk)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 16) {
                                originalPanel(article: article, chunk: chunk)
                                    .frame(height: 400)
                                studyPanel(article: article, chunk: chunk)
                                    .frame(height: 540)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            do { try store.resegmentUnstudiedArticles() }
            catch { status = error.localizedDescription }
            restoreCurrentReadingDraft()
        }
        .onChange(of: questionDraft) { _, _ in saveCurrentReadingDraft() }
        .onChange(of: note) { _, _ in saveCurrentReadingDraft() }
        .sheet(isPresented: $importSheet) {
            ArticleImportSheet(errorMessage: $status, working: $working) { text in
                importArticle(text, fromSheet: true)
            }
        }
    }

    private var emptyReadingWorkspace: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 900 {
                        HStack(alignment: .top, spacing: 24) {
                            readingIntroduction
                                .frame(maxWidth: .infinity, minHeight: 440, alignment: .topLeading)
                            inlineArticleImport
                                .frame(maxWidth: .infinity, minHeight: 440, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            readingIntroduction
                            inlineArticleImport
                        }
                    }
                }
                .frame(maxWidth: 1160)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var readingIntroduction: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "text.book.closed.fill")
                .font(AppType.ui(34, weight: .light))
                .foregroundStyle(GlassTheme.cyan)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 12) {
                Text("从一篇文章开始。")
                    .font(AppType.ui(30, weight: .semibold))
                    .foregroundStyle(.white)
                Text("粘贴你感兴趣的西语原文。导入后会分成约 50 词的段落，方便逐段通读、提问和积累卡片。")
                    .font(AppType.ui(16))
                    .lineSpacing(7)
                    .foregroundStyle(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Label("逐段精读", systemImage: "text.alignleft")
                Label("提问与卡片", systemImage: "rectangle.stack")
            }
            .font(AppType.ui(15, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 34))
        .overlay(RoundedRectangle(cornerRadius: 34).strokeBorder(.white.opacity(0.17)))
    }

    private var inlineArticleImport: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入文章")
                .font(AppType.ui(23, weight: .semibold))
                .foregroundStyle(.white)
            TextEditor(text: $newText)
                .font(AppType.ui(16))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 200)
                .studyInputChrome()
            if let status { Text(status).font(AppType.ui(13)).foregroundStyle(.secondary) }
            HStack {
                Text("粘贴西语正文")
                    .font(AppType.ui(15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Button("导入并切段", systemImage: "arrow.right") { importInlineArticle() }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(working || newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 34))
        .overlay(RoundedRectangle(cornerRadius: 34).strokeBorder(.white.opacity(0.17)))
    }

    private func importInlineArticle() { importArticle(newText, fromSheet: false) }

    private func importArticle(_ text: String, fromSheet: Bool) {
        guard !working else { return }
        working = true
        status = "正在生成简短标题…"
        Task {
            do {
                let title = try await TitleGenerationService.generate(from: text, kind: "阅读文章")
                try store.addArticle(title: title, source: "", text: text)
                selectedArticleID = store.data.articles.last?.id
                chunkIndex = 0
                resetCompletionDraft()
                restoreCurrentReadingDraft()
                newText = ""
                if fromSheet { importSheet = false }
                status = nil
            } catch { status = error.localizedDescription }
            working = false
        }
    }

    private func originalPanel(article: ReadingArticle, chunk: ReadingChunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(chunk.text)
                    .font(AppType.reading(20))
                    .lineSpacing(9)
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
            }
            Divider().overlay(secondaryInk.opacity(0.16))
            HStack(spacing: 12) {
                Button("上一段", systemImage: "chevron.left") { changeChunk(-1) }
                    .disabled(chunkIndex == 0)
                Spacer()
                Text("\(chunk.ordinal) / \(article.chunks.count)")
                    .font(AppType.ui(15, weight: .medium))
                    .foregroundStyle(secondaryInk)
                Spacer()
                Button("下一段", systemImage: "chevron.right") { changeChunk(1) }
                    .disabled(chunkIndex >= article.chunks.count - 1)
            }
            .foregroundStyle(accentInk)
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(.white.opacity(0.18)).allowsHitTesting(false))
    }

    private func studyPanel(article: ReadingArticle, chunk: ReadingChunk) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("精读提问")
                .font(AppType.ui(17, weight: .semibold))
                .foregroundStyle(ink)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if (chunk.discussion ?? []).isEmpty {
                        Text("选中文中不懂的地方，直接提问。")
                            .font(AppType.ui(15, weight: .regular))
                            .foregroundStyle(secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                    }
                    ForEach(chunk.discussion ?? []) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            // Question (highlighted)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(accentInk.opacity(0.18))
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(accentInk)
                                        .frame(width: 4, height: 18)
                                    Text(item.question)
                                        .font(AppType.ui(15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(nil)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                            // Answer
                            Text(item.answer)
                                .font(AppType.ui(15, weight: .regular))
                                .foregroundStyle(ink)
                                .lineSpacing(6)
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider().overlay(secondaryInk.opacity(0.16))
            HStack(alignment: .bottom, spacing: 10) {
                TextField("想问什么？", text: $questionDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(ink)
                    .lineLimit(1...3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .studyInputChrome()
                    .onSubmit { ask(article: article, chunk: chunk) }
                Button("提问") { ask(article: article, chunk: chunk) }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
            Text("理解难度")
                .font(AppType.ui(12, weight: .semibold))
                .foregroundStyle(secondaryInk)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ReadingDifficulty.allCases) { value in
                    Button { difficulty = value } label: {
                        Text(value.rawValue)
                            .font(AppType.ui(14, weight: .medium))
                            .foregroundStyle(difficulty == value ? ink : secondaryInk)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(difficulty == value ? .white.opacity(0.22) : .white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 19))
                            .overlay(RoundedRectangle(cornerRadius: 19)
                                .strokeBorder(.white.opacity(difficulty == value ? 0.48 : 0.14))
                                .allowsHitTesting(false))
                            .contentShape(RoundedRectangle(cornerRadius: 19))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(difficulty == value ? [.isSelected] : [])
                }
            }
            TextField("本段备注（可留空）", text: $note)
                .textFieldStyle(.plain)
                .foregroundStyle(ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .studyInputChrome()
            HStack {
                if working { ProgressView().controlSize(.small) }
                if let status {
                    Text(status)
                        .font(AppType.ui(12, weight: .regular))
                        .foregroundStyle(secondaryInk)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("完成本段并整理卡片") { complete(article: article, chunk: chunk) }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(working)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(.white.opacity(0.18)).allowsHitTesting(false))
    }

    private func changeChunk(_ delta: Int) {
        saveCurrentReadingDraft()
        chunkIndex += delta
        resetCompletionDraft()
        restoreCurrentReadingDraft()
    }

    private func resetCompletionDraft() {
        difficulty = .understood
        questionDraft = ""
        note = ""
        status = nil
    }

    private func currentReadingDraftPrefix(for article: ReadingArticle? = nil,
                                           chunkIndex: Int? = nil) -> String? {
        let targetChunkIndex = chunkIndex ?? self.chunkIndex
        guard let article = article ?? self.article,
              article.chunks.indices.contains(targetChunkIndex) else { return nil }
        return "reading.\(article.id.uuidString).\(article.chunks[targetChunkIndex].id.uuidString)."
    }

    private func saveCurrentReadingDraft() {
        guard let prefix = currentReadingDraftPrefix() else { return }
        editingDrafts.save(questionDraft, for: prefix + "question")
        editingDrafts.save(note, for: prefix + "note")
    }

    private func restoreCurrentReadingDraft() {
        guard let prefix = currentReadingDraftPrefix() else {
            questionDraft = ""
            note = ""
            return
        }
        questionDraft = editingDrafts.draft(for: prefix + "question") ?? ""
        note = editingDrafts.draft(for: prefix + "note") ?? ""
    }

    private func apiKey() throws -> String {
        let key = try AIProviderSettings.textKey() ?? ""
        guard !key.isEmpty else { throw AIProviderError.missingKey }
        return key
    }

    private func ask(article: ReadingArticle, chunk: ReadingChunk) {
        let question = questionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let requestDraftPrefix = "reading.\(article.id.uuidString).\(chunk.id.uuidString)."
        let key: String
        do { key = try apiKey() }
        catch { status = error.localizedDescription; return }
        working = true
        status = "正在结合当前段落回答…"
        let previous = chunk.discussion ?? []
        Task {
            do {
                let result = try await ReadingAIService.answer(articleTitle: article.title,
                                                               chunkText: chunk.text,
                                                               previous: previous,
                                                               question: question, apiKey: key)
                try store.saveReadingDiscussion(articleID: article.id, chunkID: chunk.id,
                                                question: question, answer: result.answer)
                if questionDraft.trimmingCharacters(in: .whitespacesAndNewlines) == question {
                    editingDrafts.removeDraft(for: requestDraftPrefix + "question")
                    if currentReadingDraftPrefix() == requestDraftPrefix { questionDraft = "" }
                }
                if currentReadingDraftPrefix() == requestDraftPrefix {
                    status = "回答已保存在本段精读记录中。"
                }
            } catch { status = error.localizedDescription }
            working = false
        }
    }

    private func complete(article: ReadingArticle, chunk: ReadingChunk) {
        let discussion = store.pendingReadingDiscussions(articleID: article.id, chunkID: chunk.id)
        if discussion.isEmpty {
            do {
                try store.completeReadingWithCards(articleID: article.id, chunkID: chunk.id,
                                                   difficulty: difficulty, note: note, result: nil)
                let requestDraftPrefix = "reading.\(article.id.uuidString).\(chunk.id.uuidString)."
                if currentReadingDraftPrefix() == requestDraftPrefix {
                    editingDrafts.removeDraft(for: requestDraftPrefix + "note")
                    note = ""
                    status = "本段阅读记录已保存；没有新的待整理提问。"
                }
            } catch { status = error.localizedDescription }
            return
        }
        let key: String
        do { key = try apiKey() }
        catch { status = error.localizedDescription; return }
        working = true
        status = "正在把本段提问整理为详细卡片草稿…"
        // Freeze the difficulty/note the user chose for THIS chunk before the AI round-trip;
        // otherwise a slow response would read whatever difficulty/note the UI shows later
        // (e.g. after navigating to a different chunk) and write it into this chunk's record.
        let requestedDifficulty = difficulty
        let requestedNote = note
        let requestDraftPrefix = "reading.\(article.id.uuidString).\(chunk.id.uuidString)."
        Task {
            do {
                let result = try await ReadingAIService.organizeCards(articleTitle: article.title,
                                                                      chunkText: chunk.text,
                                                                      discussion: discussion,
                                                                      apiKey: key)
                isAuditingCards = true
                status = "正在整理卡片…"
                var auditedCards: [ReadingCardsResult.Card] = []
                var fallbackCount = 0
                for card in result.cards {
                    guard card.create else {
                        auditedCards.append(card)
                        continue
                    }
                    let draft = CardDraft(category: card.category, mergeKey: card.mergeKey,
                                          question: card.question, answer: card.answer)
                    let audited = await CardAuditService.auditOrFallback(draft, apiKey: key)
                    if audited.usedFallback { fallbackCount += 1 }
                    auditedCards.append(.init(discussionID: card.discussionID, create: true,
                                              category: card.category, mergeKey: card.mergeKey,
                                              title: audited.title, question: audited.question,
                                              answer: audited.answer))
                }
                let auditedResult = ReadingCardsResult(cards: auditedCards)
                try store.completeReadingWithCards(articleID: article.id, chunkID: chunk.id,
                                                   difficulty: requestedDifficulty, note: requestedNote, result: auditedResult)
                let count = result.cards.filter(\.create).count
                if note == requestedNote, currentReadingDraftPrefix() == requestDraftPrefix {
                    editingDrafts.removeDraft(for: requestDraftPrefix + "note")
                    note = ""
                }
                if currentReadingDraftPrefix() == requestDraftPrefix {
                    status = fallbackCount == 0
                        ? "本段阅读已完成，新增整理 \(count) 个卡片要点。"
                        : "本段阅读已完成，新增整理 \(count) 个卡片要点。\(fallbackCount) 张使用基础整理版本；可在卡片详情中重新整理。"
                }
            } catch { status = error.localizedDescription }
            isAuditingCards = false
            working = false
        }
    }
}

struct ArticleImportSheet: View {
    @Binding var errorMessage: String?
    @Binding var working: Bool
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("粘贴文章").font(AppType.ui(26, weight: .semibold))
            TextEditor(text: $text)
                .font(AppType.ui(15))
                .studyInputChrome()
            if let errorMessage { Text(errorMessage).font(AppType.ui(13)).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }
                Button("生成标题并导入") { onImport(text) }
                    .buttonStyle(AppActionButtonStyle(prominent: true))
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 650, height: 500)
        .interactiveDismissDisabled(!text.isEmpty || working)
    }
}

struct ReadingHistoryView: View {
    @EnvironmentObject private var store: StudyStore
    @Binding var selectedArticleID: UUID?
    @Binding var selectedScreen: StudyScreen?
    @State private var filterID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(eyebrow: "Reading history", title: "按文章回看精读。",
                        subtitle: "评级、对话、卡片和完成时间都跟随原文保存。")
            Picker("文章", selection: $filterID) {
                Text("全部文章").tag(Optional<UUID>.none)
                ForEach(store.data.articles) { item in Text(item.title).tag(Optional(item.id)) }
            }
            .labelsHidden()
            .studyPickerChrome()
            .frame(maxWidth: 450)
            if store.data.readingRecords.isEmpty {
                StudyEmptyState(title: "还没有阅读记录", message: "完成一段精读后，文章和提问会出现在这里。",
                                symbol: "books.vertical")
            } else {
                HistoryPanel {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(store.data.articles.filter { filterID == nil || $0.id == filterID }) { article in
                                let records = store.data.readingRecords.filter { $0.articleID == article.id }
                                if !records.isEmpty {
                                    GroupBox(article.title) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text("\(Set(records.map(\.chunkID)).count) 段已读 · \(records.count) 次精读")
                                                .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                                            ForEach(records.reversed()) { record in
                                                VStack(alignment: .leading, spacing: 7) {
                                                    HStack {
                                                        Text("第 \((article.chunks.first(where: { $0.id == record.chunkID })?.ordinal) ?? 1) 段 · \(record.difficulty.rawValue)")
                                                            .font(AppType.ui(17, weight: .semibold))
                                                        Spacer()
                                                        Button("回到文章") {
                                                            selectedArticleID = article.id
                                                            selectedScreen = .reading
                                                        }
                                                    }
                                                    Text(record.completedAt.formatted(date: .abbreviated, time: .shortened))
                                                        .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                                                    if !record.questions.isEmpty {
                                                        Text("精读问题：\(record.questions.joined(separator: "；"))")
                                                            .font(AppType.ui(14, weight: .regular))
                                                    }
                                                    if let cardIDs = record.cardIDs, !cardIDs.isEmpty {
                                                        Label("已关联 \(cardIDs.count) 张卡片草稿", systemImage: "rectangle.on.rectangle")
                                                            .font(AppType.ui(12, weight: .regular)).foregroundStyle(.secondary)
                                                    }
                                                    if !record.note.isEmpty { Text(record.note).foregroundStyle(.secondary) }
                                                }
                                                .historyEntryChrome()
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}
