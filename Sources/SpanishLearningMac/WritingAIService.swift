import Foundation

struct WritingPromptResult: Decodable, Sendable {
    let chinesePrompt: String
    let referenceSpanish: String
    let focus: String
}

struct ChineseDraftReviewResult: Decodable, Sendable {
    let assessment: String
    let suggestions: [String]
    let revisedChinese: String
}

struct WritingFeedbackResult: Decodable, Sendable {
    struct Scores: Decodable, Sendable {
        let meaning: Int
        let grammar: Int
        let wording: Int
        let naturalness: Int
    }
    struct ErrorItem: Decodable, Sendable {
        let original: String
        let correction: String
        let explanation: String
    }
    struct CorrectionCard: Decodable, Sendable {
        let create: Bool
        let mergeKey: String
        let question: String
        let answer: String
    }

    let feedback: String
    let correctedSpanish: String
    let scores: Scores
    let errors: [ErrorItem]
    let card: CorrectionCard
}

private struct WritingResponsesEnvelope: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }
        let type: String
        let content: [Content]?
    }
    let output: [Output]
}

enum WritingAIService {
    static func generatePrompt(sourceSpanish: String, sourceKind: String,
                               sourceTitle: String, apiKey: String) async throws -> WritingPromptResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "chinesePrompt": ["type": "string", "description": "供学习者翻译成西语的一到两句自然中文"],
                "referenceSpanish": ["type": "string", "description": "忠实使用来源表达的自然西语参考答案"],
                "focus": ["type": "string", "description": "一句中文说明本题要主动使用的表达、语法或句型"]
            ],
            "required": ["chinesePrompt", "referenceSpanish", "focus"],
            "additionalProperties": false
        ]
        let input = """
        来源类型：\(sourceKind)
        来源名称：\(sourceTitle)
        西语原文：
        \(sourceSpanish)
        """
        let instructions = """
        你是严谨的西班牙语写作教师。学习者处于积累阶段。请从原文中挑选一个可迁移的高价值表达、固定搭配、动词用法或句型，改写成一到两句自然中文，让学习者翻译回西语。题目要能依托原文完成，但不能直接暴露西语答案。referenceSpanish 必须自然、忠实，并尽量复用原文中的目标表达。focus 用中文简洁指出练习重点。不要引入原文之外的实时事实。
        """
        return try await request(modelInput: input, instructions: instructions,
                                 schemaName: "writing_prompt", schema: schema,
                                 apiKey: apiKey, result: WritingPromptResult.self)
    }

    static func reviewChineseDraft(_ draft: String, apiKey: String) async throws -> ChineseDraftReviewResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "assessment": ["type": "string", "description": "一句话说明原稿是否清楚、适合后续译成西语"],
                "suggestions": ["type": "array", "items": ["type": "string"], "maxItems": 3],
                "revisedChinese": ["type": "string", "description": "保留原意的完整中文改写；无需修改时返回原文"]
            ],
            "required": ["assessment", "suggestions", "revisedChinese"],
            "additionalProperties": false
        ]
        let instructions = """
        你是西班牙语写作教师。学习者先用中文构思，再独立译成西语。只审核这段中文的意思是否完整、指代是否清楚、句子是否适合翻译练习。用中文简短提出最多三条具体修改建议；不提前给西语译文，不加入原文没有的事实或观点，不替学习者改变意图。revisedChinese 给出可直接采用的中文版本；如果原文已清楚，原样返回。
        """
        return try await request(modelInput: "学习者中文原稿：\n\(draft)", instructions: instructions,
                                 schemaName: "chinese_writing_review", schema: schema,
                                 apiKey: apiKey, result: ChineseDraftReviewResult.self)
    }

    static func evaluate(chinesePrompt: String, referenceSpanish: String?, sourceSpanish: String?,
                         learnerSpanish: String, mode: WritingMode,
                         apiKey: String) async throws -> WritingFeedbackResult {
        let score: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 5]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "feedback": ["type": "string", "description": "先肯定具体做对之处，再按重要性说明最值得修改的两到四点"],
                "correctedSpanish": ["type": "string", "description": "保留学习者原意并修正后的完整自然西语"],
                "scores": [
                    "type": "object",
                    "properties": ["meaning": score, "grammar": score, "wording": score, "naturalness": score],
                    "required": ["meaning", "grammar", "wording", "naturalness"],
                    "additionalProperties": false
                ],
                "errors": [
                    "type": "array",
                    "maxItems": 5,
                    "items": [
                        "type": "object",
                        "properties": [
                            "original": ["type": "string"],
                            "correction": ["type": "string"],
                            "explanation": ["type": "string"]
                        ],
                        "required": ["original", "correction", "explanation"],
                        "additionalProperties": false
                    ]
                ],
                "card": [
                    "type": "object",
                    "properties": [
                        "create": ["type": "boolean"],
                        "mergeKey": ["type": "string", "description": "写作纠错|规范化结构或词元|具体错误义项；不制卡时为空字符串"],
                        "question": ["type": "string", "description": "可主动回忆的卡片正面；不制卡时为空字符串"],
                        "answer": ["type": "string", "description": "详细解释和一到两个不同语境例句；不制卡时为空字符串"]
                    ],
                    "required": ["create", "mergeKey", "question", "answer"],
                    "additionalProperties": false
                ]
            ],
            "required": ["feedback", "correctedSpanish", "scores", "errors", "card"],
            "additionalProperties": false
        ]
        let input = """
        练习方式：\(mode.rawValue)
        中文题目：\(chinesePrompt)
        参考表达：\(referenceSpanish ?? "（自由表达，没有唯一参考答案）")
        来源原文：\(sourceSpanish ?? "（无指定来源）")
        学习者的西语：\(learnerSpanish)
        """
        let instructions = """
        你是严谨但简洁的西班牙语写作教师。用中文反馈，不要因为与参考答案措辞不同就判错；先检查意思是否完整，再检查语法、用词和自然度。四项分别按 1 到 5 分评分，并逐项如实区分。errors 只列真实且值得改进的问题；original 必须引用学习者文本中的短片段，correction 给出局部修改，explanation 简明说明原因。correctedSpanish 应保留学习者想表达的内容，不扩写成另一篇文章。

        只有错误具有迁移价值、以后很可能再次出现时才创建一张写作纠错卡。卡片要能主动回忆，mergeKey 对相同结构与同一错误义项保持稳定。若涉及动词，先解释动词的本质语义，再解释本题中的作用，并给一到两个不同语境的西语例句和中文说明。若没有值得制卡的错误，create=false，其余三个字段返回空字符串。
        """
        return try await request(modelInput: input, instructions: instructions,
                                 schemaName: "writing_feedback", schema: schema,
                                 apiKey: apiKey, result: WritingFeedbackResult.self)
    }

    private static func request<T: Decodable>(modelInput: String, instructions: String,
                                               schemaName: String, schema: [String: Any],
                                               apiKey: String, result: T.Type) async throws -> T {
        try await AITextClient.request(input: modelInput, instructions: instructions,
                                       schemaName: schemaName, schema: schema,
                                       apiKey: apiKey, result: result)
    }
}
