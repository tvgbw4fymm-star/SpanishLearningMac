import SwiftUI

private struct OverviewStats {
    let database: StudyDatabase
    private let calendar = Calendar.current

    private func isToday(_ date: Date) -> Bool { calendar.isDateInToday(date) }
    private func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    var listeningWords: Int { database.dictationAttempts.reduce(0) { $0 + words($1.text) } }
    var readingWords: Int {
        database.readingRecords.reduce(0) { total, record in
            let chunk = database.articles.first(where: { $0.id == record.articleID })?.chunks.first(where: { $0.id == record.chunkID })
            return total + words(chunk?.text ?? "")
        }
    }
    var writingWords: Int { database.writingExercises.flatMap(\.versions).reduce(0) { $0 + words($1.spanishText) } }
    var confirmedCards: Int { database.cards.filter { $0.confirmedAt != nil }.count }
    var dueCards: Int { database.cards.filter { $0.confirmedAt != nil && ($0.dueAt ?? .distantPast) <= .now }.count }
    var todaySentences: Int { Set(database.dictationAttempts.filter { isToday($0.submittedAt) }.map(\.sentenceID)).count }
    var todayArticles: Int { Set(database.readingRecords.filter { isToday($0.completedAt) }.map(\.articleID)).count }
    var todayReadingWords: Int {
        let todays = database.readingRecords.filter { isToday($0.completedAt) }
        return todays.reduce(0) { total, record in
            let chunk = database.articles.first(where: { $0.id == record.articleID })?
                .chunks.first(where: { $0.id == record.chunkID })
            return total + words(chunk?.text ?? "")
        }
    }
    var todayWriting: Int { database.writingExercises.flatMap(\.versions).filter { isToday($0.submittedAt) }.count }
    var todayReviews: Int { Set(database.reviewEvents.filter { isToday($0.reviewedAt) }.map(\.cardID)).count }

    var streak: Int {
        var activeDays = Set(database.dictationAttempts.map { calendar.startOfDay(for: $0.submittedAt) })
        activeDays.formUnion(database.readingRecords.map { calendar.startOfDay(for: $0.completedAt) })
        activeDays.formUnion(database.writingExercises.flatMap(\.versions).map { calendar.startOfDay(for: $0.submittedAt) })
        activeDays.formUnion(database.reviewEvents.map { calendar.startOfDay(for: $0.reviewedAt) })
        var day = calendar.startOfDay(for: .now)
        if !activeDays.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var count = 0
        while activeDays.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: StudyStore
    @Binding var selectedScreen: StudyScreen?
    @Binding var cardSearchQuery: String
    @Binding var showDueCards: Bool
    @FocusState private var searchFocused: Bool

    private var stats: OverviewStats { OverviewStats(database: store.data) }
    private let sidePadding: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar(availableWidth: geometry.size.width)
                        .padding(.bottom, 34)
                    welcome
                        .padding(.bottom, 32)
                    if geometry.size.width >= 1000 {
                        wideCards
                    } else {
                        compactCards
                    }
                    activitySection
                        .padding(.top, 38)
                        .padding(.bottom, 120)
                }
                .frame(maxWidth: 1400)
                .padding(.horizontal, sidePadding)
                .padding(.top, 22)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func topBar(availableWidth: CGFloat) -> some View {
        let searchWidth = max(190, min(330, availableWidth - 260))
        return HStack(spacing: 18) {
            Image(systemName: "sparkle")
                .font(AppType.ui(19, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Text("西语学习")
                .font(AppType.ui(16, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(AppType.ui(17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                TextField("搜索卡片或内容…", text: $cardSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { selectedScreen = .cards }
                    .font(AppType.ui(15, weight: .regular))
                Text("⌘ K")
                    .font(AppType.ui(12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .frame(width: searchWidth, height: 44)
            .background(.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .background {
                Button("聚焦搜索") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
        .frame(height: 48)
    }

    private var welcome: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 11) {
                Text("HOLA, BIENVENIDO")
                    .font(AppType.latin(13, weight: .medium))
                    .tracking(2.8)
                    .foregroundStyle(.white.opacity(0.75))
                Text("每天的学习，慢慢留下来。")
                    .font(AppType.ui(36, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 10) {
                Text(Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
                    .font(AppType.ui(17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("保持学习，遇见更好的自己。")
                    .font(AppType.ui(13))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.bottom, 5)
        }
    }

    private var wideCards: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                listeningCard
                readingCard
                writingCard
            }
            HStack(spacing: 16) {
                cardsCard
                progressCard
            }
        }
    }

    private var compactCards: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            listeningCard
            readingCard
            writingCard
            cardsCard
            progressCard
        }
    }

    private var listeningCard: some View {
        OverviewMetricCard(title: "听写练习", value: stats.listeningWords.formatted(),
                           note: "今日完成 \(stats.todaySentences) 句", illustration: "listening",
                           colors: [.init(red: 0.53, green: 0.10, blue: 0.36), .init(red: 0.85, green: 0.22, blue: 0.54), .init(red: 1.00, green: 0.48, blue: 0.69)]) {
            selectedScreen = .listening
        }
    }
    private var readingCard: some View {
        OverviewMetricCard(title: "阅读理解", value: stats.readingWords.formatted(),
                           note: "今日阅读 \(stats.todayReadingWords) 词", illustration: "reading",
                           colors: [.init(red: 0.12, green: 0.27, blue: 0.65), .init(red: 0.20, green: 0.47, blue: 0.91), .init(red: 0.32, green: 0.75, blue: 0.96)]) {
            selectedScreen = .reading
        }
    }
    private var writingCard: some View {
        OverviewMetricCard(title: "写作练习", value: stats.writingWords.formatted(),
                           note: "今日完成 \(stats.todayWriting) 篇", illustration: "writing",
                           colors: [.init(red: 0.59, green: 0.21, blue: 0.20), .init(red: 0.91, green: 0.39, blue: 0.25), .init(red: 1.00, green: 0.67, blue: 0.33)]) {
            selectedScreen = .writing
        }
    }
    private var cardsCard: some View {
        OverviewMetricCard(title: "单词卡片", value: stats.confirmedCards.formatted(),
                           note: "今日复习 \(stats.todayReviews) 个", illustration: "cards",
                           colors: [.init(red: 0.34, green: 0.18, blue: 0.65), .init(red: 0.56, green: 0.31, blue: 0.87), .init(red: 0.77, green: 0.51, blue: 1.00)]) {
            selectedScreen = .cards
        }
    }
    private var progressCard: some View {
        OverviewMetricCard(title: "学习进度", value: stats.streak == 0 ? "从今天开始" : "连续 \(stats.streak) 天",
                           note: stats.streak == 0 ? "每一天都可以是新的开始" : "继续加油，别打断！", illustration: "progress",
                           colors: [.init(red: 0.08, green: 0.37, blue: 0.39), .init(red: 0.12, green: 0.57, blue: 0.50), .init(red: 0.33, green: 0.80, blue: 0.60)]) {
            selectedScreen = .cards
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("学习热力图")
                        .font(AppType.ui(20, weight: .semibold))
                    Text("最近 90 天 · 听、读、写合计")
                        .font(AppType.ui(15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                HStack(spacing: 7) {
                    Text("少")
                    ForEach([0, 1, 30, 100, 250], id: \.self) { words in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ActivityHeatmap.color(for: words))
                            .frame(width: 17, height: 17)
                    }
                    Text("多")
                }
                .font(AppType.ui(12, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))
            }
            ActivityHeatmap(database: store.data)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}

private struct OverviewToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.20 : 0.10), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.21), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct StickerArtwork: View {
    let name: String

    var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let artwork = NSImage(contentsOf: url) {
                Image(nsImage: artwork)
                    .resizable()
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct OverviewMetricCard: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    let value: String
    let note: String
    let illustration: String
    let colors: [Color]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(LinearGradient(colors: colors.map { $0.opacity(reduceTransparency ? 1 : 0.96) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(RadialGradient(colors: [.white.opacity(reduceTransparency ? 0 : 0.20), .clear],
                                                 center: .topTrailing, startRadius: 8, endRadius: 250))
                    }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(title)
                            .font(AppType.ui(21, weight: .semibold))
                        Spacer()
                    }
                    Spacer()
                    Text(value)
                        .font(AppType.ui(value.count > 6 ? 32 : 43, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(alignment: .bottom) {
                        Text(note)
                            .font(AppType.ui(17, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(.white.opacity(0.86))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(AppType.ui(16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.16), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 1))
                    }
                    .padding(.top, 6)
                }
                .padding(22)
                StickerArtwork(name: illustration)
                    .scaledToFit()
                    .frame(width: 105, height: 105)
                    .rotationEffect(.degrees(-7))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 24)
                    .padding(.top, 17)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 218)
            .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.43 : 0.27), lineWidth: 1.2))
            .shadow(color: colors[0].opacity(hovering ? 0.34 : 0.20), radius: hovering ? 22 : 14, y: 10)
            .offset(y: hovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 36))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(GlassTheme.animation, value: hovering)
        .accessibilityLabel("\(title)，\(value)，\(note)")
    }
}

