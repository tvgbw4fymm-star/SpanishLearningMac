import Foundation

/// 学习统计。侧边栏打卡徽章与总览页共用同一套计算,避免两处口径不一致。
struct StudyStats {
    let database: StudyDatabase
    private let calendar = Calendar.current

    init(database: StudyDatabase) {
        self.database = database
    }

    private func isToday(_ date: Date) -> Bool { calendar.isDateInToday(date) }
    private func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    // MARK: 累计

    var listeningWords: Int {
        database.dictationAttempts.reduce(0) { $0 + words($1.text) }
    }

    var readingWords: Int {
        database.readingRecords.reduce(0) { total, record in
            let chunk = database.articles
                .first(where: { $0.id == record.articleID })?
                .chunks.first(where: { $0.id == record.chunkID })
            return total + words(chunk?.text ?? "")
        }
    }

    var writingWords: Int {
        database.writingExercises.flatMap(\.versions).reduce(0) { $0 + words($1.spanishText) }
    }

    var confirmedCards: Int {
        database.cards.filter { $0.deletedAt == nil && $0.confirmedAt != nil }.count
    }

    var dueCards: Int {
        database.cards.filter {
            $0.deletedAt == nil && $0.confirmedAt != nil && ($0.dueAt ?? .distantPast) <= .now
        }.count
    }

    // MARK: 今日

    var todaySentences: Int {
        Set(database.dictationAttempts.filter { isToday($0.submittedAt) }.map(\.sentenceID)).count
    }

    var todayArticles: Int {
        Set(database.readingRecords.filter { isToday($0.completedAt) }.map(\.articleID)).count
    }

    var todayReadingWords: Int {
        database.readingRecords
            .filter { isToday($0.completedAt) }
            .reduce(0) { total, record in
                let chunk = database.articles
                    .first(where: { $0.id == record.articleID })?
                    .chunks.first(where: { $0.id == record.chunkID })
                return total + words(chunk?.text ?? "")
            }
    }

    var todayWriting: Int {
        database.writingExercises.flatMap(\.versions).filter { isToday($0.submittedAt) }.count
    }

    var todayReviewedCards: Int {
        database.reviewEvents.filter { isToday($0.reviewedAt) }.count
    }

    // MARK: 连续天数

    /// 所有有学习行为的日期
    private var activeDays: Set<Date> {
        var days = Set(database.dictationAttempts.map { calendar.startOfDay(for: $0.submittedAt) })
        days.formUnion(database.readingRecords.map { calendar.startOfDay(for: $0.completedAt) })
        days.formUnion(database.writingExercises.flatMap(\.versions).map { calendar.startOfDay(for: $0.submittedAt) })
        days.formUnion(database.reviewEvents.map { calendar.startOfDay(for: $0.reviewedAt) })
        return days
    }

    /// 连续学习天数。今天还没学时从昨天起算,避免"当天未打卡就断签"。
    var streak: Int {
        let days = activeDays
        var day = calendar.startOfDay(for: .now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    var hasStudiedToday: Bool { activeDays.contains(calendar.startOfDay(for: .now)) }

    /// 当周七天(周一为首)是否已学习 —— 给打卡徽章的七个小点。
    var currentWeekActive: [Bool] {
        let days = activeDays
        var calendar = self.calendar
        calendar.firstWeekday = 2 // 周一
        let today = calendar.startOfDay(for: .now)
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start else {
            return Array(repeating: false, count: 7)
        }
        return (0..<7).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return false }
            return days.contains(date)
        }
    }

    /// 侧栏打卡徽章的一行摘要。
    var todaySummary: String {
        guard hasStudiedToday else { return "今天还没打卡" }
        var parts: [String] = []
        if todaySentences > 0 { parts.append("听写 \(todaySentences) 句") }
        if todayArticles > 0 { parts.append("精读 \(todayArticles) 篇") }
        if todayWriting > 0 { parts.append("写作 \(todayWriting) 次") }
        if todayReviewedCards > 0 { parts.append("复习 \(todayReviewedCards) 张") }
        return parts.isEmpty ? "今天已开始学习" : parts.joined(separator: " · ")
    }
}
