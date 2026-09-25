import Foundation

struct ReviewScheduleResult {
    let state: FSRSCardState
    let dueAt: Date
    let scheduledDays: Double
    let elapsedDays: Double
}

enum LocalFSRSScheduler {
    private static let engine = FSRS(parameters: FSRSParameters(
        requestRetention: 0.90,
        maximumInterval: 36_500,
        w: FSRSDefaults.defaultWv6,
        enableFuzz: false,
        enableShortTerm: true,
        learningSteps: ["1m", "10m"],
        relearningSteps: ["10m"]
    ))

    static func schedule(card: StudyCard, grade: ReviewGrade, now: Date = .now) throws -> ReviewScheduleResult {
        let prior = makeFSRSCard(from: card, now: now)
        guard let rating = Rating(rawValue: grade.rawValue) else { throw StoreError.invalidReviewGrade }
        let reviewed = try engine.next(card: prior, now: now, grade: rating).card
        let interval = max(0, reviewed.due.timeIntervalSince(now) / 86_400)
        let state = FSRSCardState(
            difficulty: reviewed.difficulty,
            stability: reviewed.stability,
            lastReviewedAt: now,
            lapses: reviewed.lapses,
            stateRawValue: reviewed.state.rawValue,
            scheduledDays: reviewed.scheduledDays,
            learningSteps: reviewed.learningSteps,
            reps: reviewed.reps
        )
        return ReviewScheduleResult(state: state, dueAt: reviewed.due,
                                    scheduledDays: interval, elapsedDays: prior.elapsedDays)
    }

    static func preview(card: StudyCard, now: Date = .now) -> [ReviewGrade: Date] {
        Dictionary(uniqueKeysWithValues: ReviewGrade.allCases.compactMap { grade in
            guard let result = try? schedule(card: card, grade: grade, now: now) else { return nil }
            return (grade, result.dueAt)
        })
    }

    private static func makeFSRSCard(from card: StudyCard, now: Date) -> Card {
        guard let state = card.fsrsState else {
            return Card(due: card.dueAt ?? now, state: .new)
        }
        let last = state.lastReviewedAt
        let elapsed = max(0, now.timeIntervalSince(last) / 86_400)
        return Card(
            due: card.dueAt ?? now,
            stability: state.stability,
            difficulty: state.difficulty,
            elapsedDays: elapsed,
            scheduledDays: state.scheduledDays ?? max(0, (card.dueAt ?? now).timeIntervalSince(last) / 86_400),
            learningSteps: state.learningSteps ?? 0,
            reps: state.reps ?? 1,
            lapses: state.lapses,
            state: CardState(rawValue: state.stateRawValue ?? CardState.review.rawValue) ?? .review,
            lastReview: last
        )
    }
}
