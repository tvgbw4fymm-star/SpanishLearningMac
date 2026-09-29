import Foundation

enum SubtitleImportError: LocalizedError {
    case unreadable, noTimedSpeech
    var errorDescription: String? {
        switch self {
        case .unreadable: "字幕文件无法读取，请使用 UTF-8 编码的 SRT 或 VTT。"
        case .noTimedSpeech: "没有找到带有效时间戳的字幕。请检查 SRT/VTT 格式。"
        }
    }
}

enum SubtitleImporter {
    static func parse(_ data: Data) throws -> [SubtitleCue] {
        guard var content = String(data: data, encoding: .utf8) else { throw SubtitleImportError.unreadable }
        content = content.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in content.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let stamps = lines[timeIndex].components(separatedBy: "-->")
            guard stamps.count == 2,
                  let start = seconds(stamps[0]), let end = seconds(stamps[1]), end > start else { continue }
            let raw = lines.dropFirst(timeIndex + 1).joined(separator: " ")
            let clean = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            cues.append(SubtitleCue(id: UUID(), ordinal: cues.count + 1,
                                    startSeconds: start, endSeconds: end, text: clean))
        }
        guard !cues.isEmpty else { throw SubtitleImportError.noTimedSpeech }
        return cues
    }

    private static func seconds(_ raw: String) -> Double? {
        let stamp = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first?.replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}
