import Foundation

struct CardDraft: Sendable {
    let category: CardCategory
    let mergeKey: String
    let question: String
    let answer: String
}

struct CardAuditResult: Decodable, Sendable {
    let title: String
    let question: String
    let answer: String
}

struct CardAuditDecision: Sendable {
    let title: String
    let question: String
    let answer: String
    let usedFallback: Bool
}

enum CardContentNormalizer {
    static func normalize(_ draft: CardDraft) -> CardDraft {
        CardDraft(category: draft.category,
                  mergeKey: clean(draft.mergeKey),
                  question: clean(draft.question),
                  answer: cleanAnswer(draft.answer))
    }

    static func title(for draft: CardDraft, auditedTitle: String? = nil) -> String {
        let proposed = clean(auditedTitle ?? "")
        if !proposed.isEmpty, proposed.count <= 80 { return proposed }
        let mergeKey = clean(draft.mergeKey)
        if !mergeKey.isEmpty, mergeKey.count <= 80 {
            let parts = mergeKey.split(separator: "|", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                let key = clean(String(parts[1]))
                if !key.isEmpty { return key }
            }
            return mergeKey
        }
        let firstLine = clean(draft.question).components(separatedBy: .newlines).first ?? ""
        return firstLine.count <= 80 ? firstLine : draft.category.rawValue
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanAnswer(_ value: String) -> String {
        let normalized = clean(value)
        return normalized
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }
}

enum CardAuditService {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "极简卡片名称，只写单词、短语、固定搭配或语法结构本身，不写解释句。"],
            "question": ["type": "string", "description": "适合主动回忆的正面问题，不直接泄露目标答案。"],
            "answer": ["type": "string", "description": "核心答案、解释、例句和注意事项，使用清晰换行分段。"]
        ],
        "required": ["title", "question", "answer"],
        "additionalProperties": false
    ]

    static func audit(_ draft: CardDraft, apiKey: String) async throws -> CardAuditResult {
        let normalized = CardContentNormalizer.normalize(draft)
        let input = """
        分类：\(normalized.category.rawValue)
        学习点稳定标识：\(normalized.mergeKey)
        当前卡片正面：
        \(normalized.question)
        当前卡片背面：
        \(normalized.answer)
        """
        let instructions = """
        你是西班牙语 SRS/Anki 卡片编辑器，不是普通语言老师。请只整理当前这一张卡，保持原学习目标、分类和语义不变，不增加第二个学习点，不创建额外卡片。
        输出必须 atomic、concise、recallable、scannable。title 使用能唯一识别学习点的最短自然标签，优先使用西语单词、短语、固定搭配或语法结构本身；不要写解释句、完整例句、“关于……的用法”“……的表达”“如何使用……”等冗余标题。
        question 只保留适合主动回忆的问题或提示。不要在正面同时写出中文答案和目标西语表达；如果目标是产出结构，不能在正面泄露完整目标表达。answer 先给核心答案，再用清晰换行分开“解释”“例句”“注意”（只有确实存在时才保留），不要把重复内容堆成一段，也不要保留 Markdown 代码围栏。
        不得改变原本的西语学习目标、关键语法限制、词义或表达；不得凭空添加事实。若原内容已经合适，只做必要的最小整理。
        """
        return try await AITextClient.request(input: input, instructions: instructions,
                                              schemaName: "card_audit",
                                              schema: schema, apiKey: apiKey,
                                              result: CardAuditResult.self)
    }

    static func auditOrFallback(
        _ draft: CardDraft,
        apiKey: String,
        audit: ((CardDraft) async throws -> CardAuditResult)? = nil
    ) async -> CardAuditDecision {
        let normalized = CardContentNormalizer.normalize(draft)
        do {
            let result = try await (audit ?? { try await self.audit($0, apiKey: apiKey) })(normalized)
            let audited = CardContentNormalizer.normalize(CardDraft(
                category: normalized.category, mergeKey: normalized.mergeKey,
                question: result.question, answer: result.answer))
            return CardAuditDecision(title: CardContentNormalizer.title(for: audited, auditedTitle: result.title),
                                     question: audited.question, answer: audited.answer,
                                     usedFallback: false)
        } catch {
            return CardAuditDecision(title: CardContentNormalizer.title(for: normalized),
                                     question: normalized.question, answer: normalized.answer,
                                     usedFallback: true)
        }
    }
}
