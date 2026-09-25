import Foundation

struct ReadingAnswerResult: Decodable, Sendable {
    let answer: String
}

struct ReadingCardsResult: Decodable, Sendable {
    struct Card: Decodable, Sendable {
        let discussionID: String
        let create: Bool
        let category: CardCategory
        let mergeKey: String
        let title: String?
        let question: String
        let answer: String

        init(discussionID: String, create: Bool, category: CardCategory, mergeKey: String,
             title: String? = nil, question: String, answer: String) {
            self.discussionID = discussionID
            self.create = create
            self.category = category
            self.mergeKey = mergeKey
            self.title = title
            self.question = question
            self.answer = answer
        }

        private enum CodingKeys: String, CodingKey {
            case discussionID, create, category, mergeKey, title, question, answer
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            discussionID = try container.decode(String.self, forKey: .discussionID)
            create = try container.decode(Bool.self, forKey: .create)
            category = try container.decode(CardCategory.self, forKey: .category)
            mergeKey = try container.decode(String.self, forKey: .mergeKey)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            question = try container.decode(String.self, forKey: .question)
            answer = try container.decode(String.self, forKey: .answer)
        }
    }
    let cards: [Card]
}

private struct ReadingResponsesEnvelope: Decodable {
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

enum ReadingAIService {
    static func answer(articleTitle: String, chunkText: String,
                       previous: [ReadingDiscussionItem], question: String,
                       apiKey: String) async throws -> ReadingAnswerResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["answer": ["type": "string"]],
            "required": ["answer"],
            "additionalProperties": false
        ]
        let context = previous.suffix(5).map { "学习者：\($0.question)\n教师：\($0.answer)" }.joined(separator: "\n")
        let input = """
        文章：\(articleTitle)
        当前段落：
        \(chunkText)
        前面的精读对话：
        \(context.isEmpty ? "（无）" : context)
        学习者的新问题：\(question)
        """
        let instructions = """
        你是西班牙语精读教师。用中文给出短而准确的回答，目标是不打断阅读节奏，通常控制在 120 个汉字以内；必要的西语词或短句可以保留。只结合当前段落及稳定语言知识回答，不编造外部事实。若问题涉及动词，先用一句话说明其本质语义，再解释本句中的作用；详细例句留到完成阅读后生成的卡片。若信息不足，明确说明需要更多上下文。
        """
        return try await request(input: input, instructions: instructions,
                                 schemaName: "reading_answer", schema: schema,
                                 apiKey: apiKey, result: ReadingAnswerResult.self)
    }

    static func organizeCards(articleTitle: String, chunkText: String,
                              discussion: [ReadingDiscussionItem],
                              apiKey: String) async throws -> ReadingCardsResult {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "cards": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "discussionID": ["type": "string"],
                            "create": ["type": "boolean"],
                            "category": ["type": "string", "enum": CardCategory.allCases.map(\.rawValue)],
                            "mergeKey": ["type": "string"],
                            "title": ["type": ["string", "null"], "description": "可选的极简学习点名称，不写解释句。"],
                            "question": ["type": "string"],
                            "answer": ["type": "string"]
                        ],
                        "required": ["discussionID", "create", "category", "mergeKey", "title", "question", "answer"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["cards"],
            "additionalProperties": false
        ]
        let items = discussion.map {
            "ID=\($0.id.uuidString)\n提问：\($0.question)\n即时回答：\($0.answer)"
        }.joined(separator: "\n\n")
        let input = """
        文章：\(articleTitle)
        当前段落：
        \(chunkText)
        本段精读对话：
        \(items)
        """
        let instructions = """
        你是严谨的西班牙语精读教师。为每条对话原样返回 discussionID，并判断是否值得做成长期复习卡。低价值、只与当下操作有关或重复的问题 create=false，其余字段返回空字符串，category 仍选择最接近的分类。值得积累的问题生成一张详细卡片：正面只写简洁的学习点名称，词汇卡仅写西语词元（例如 conmoción），语法和表达卡写简短结构名；不要在正面加入“本句”“如何理解”“是什么意思”等提问句式，也不要复述文章来源。背面分段解释词义或结构、当前语境和可迁移用法，避免一整段拥挤文字。动词必须先解释本质语义，再解释本句作用，并给一到两个不同语境的西语例句和中文说明。文化知识与语言问题使用不同分类；事实性内容只写有把握的稳定知识。mergeKey 使用“分类|规范化词元、结构或主题|具体义项”，相同内容复用，同一词不同义项分开。
        """
        let result: ReadingCardsResult = try await request(input: input, instructions: instructions,
                                                            schemaName: "reading_cards", schema: schema,
                                                            apiKey: apiKey, result: ReadingCardsResult.self)
        let requested = Set(discussion.map { $0.id.uuidString })
        let returned = Set(result.cards.map(\.discussionID))
        guard requested == returned, result.cards.count == discussion.count else { throw AIStudyError.invalidResponse }
        return result
    }

    private static func request<T: Decodable>(input: String, instructions: String,
                                               schemaName: String, schema: [String: Any],
                                               apiKey: String, result: T.Type) async throws -> T {
        try await AITextClient.request(input: input, instructions: instructions,
                                       schemaName: schemaName, schema: schema,
                                       apiKey: apiKey, result: result)
    }
}
