import Foundation
import AVFoundation

@main
struct AudioPipelineSmoke {
    static func main() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SpanishAudioTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("sample.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                                       AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsNonInterleaved: true]
        do {
            let output = try AVAudioFile(forWriting: source, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            for _ in 0..<3 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
                buffer.frameLength = 16_000
                for i in 0..<16_000 { buffer.floatChannelData![0][i] = sin(Float(i) / 30) * 0.1 }
                try output.write(from: buffer)
            }
        }
        guard let chunk = try AudioChunker.next(source, after: 0, into: work) else { preconditionFailure("No audio chunk") }
        let restored = try AVAudioFile(forReading: chunk.url)
        precondition(abs(chunk.duration - 3.0) < 0.01)
        precondition(restored.length > 40_000 && restored.length < 50_000)
        let remaining = try AudioChunker.next(source, after: chunk.offset + chunk.duration, into: work)
        precondition(remaining == nil)

        let longSource = work.appendingPathComponent("long.wav")
        do {
            let output = try AVAudioFile(forWriting: longSource, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            for second in 0..<42 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
                buffer.frameLength = 16_000
                for i in 0..<16_000 {
                    buffer.floatChannelData![0][i] = second == 33 ? 0 : sin(Float(i) / 30) * 0.1
                }
                try output.write(from: buffer)
            }
        }
        let firstLong = try AudioChunker.next(longSource, after: 0, into: work)!
        let secondLong = try AudioChunker.next(longSource, after: firstLong.offset + firstLong.duration, into: work)!
        precondition(firstLong.duration < 36)
        precondition(abs(secondLong.offset + secondLong.duration - 42) < 0.01)
        let thirdLong = try AudioChunker.next(longSource, after: secondLong.offset + secondLong.duration, into: work)
        precondition(thirdLong == nil)

        let json = Data("""
        {"segments":[{"start":0.0,"end":4.0,"text":"Hola. ¿Cómo estás?"}]}
        """.utf8)
        let response = try JSONDecoder().decode(WhisperResponse.self, from: json)
        let sentences = SentenceSegmenter.sentences(from: response.segments[0], offset: 10)
        precondition(sentences.count == 2)
        precondition(sentences[0].startSeconds == 10 && sentences[1].endSeconds == 14)
        precondition(sentences[0].status == .generated)

        var punctuationSegmenter = NativeSpeechSentenceSegmenter()
        let punctuation = punctuationSegmenter.consume([
            NativeSpeechSegment(substring: "Hola.", timestamp: 0, duration: 0.5),
            NativeSpeechSegment(substring: "¿Cómo", timestamp: 0.6, duration: 0.5),
            NativeSpeechSegment(substring: "estás?", timestamp: 1.2, duration: 0.5)
        ])
        precondition(punctuation.count == 2)
        precondition(punctuation[0].transcript == "Hola.")
        precondition(punctuation[1].transcript == "¿Cómo estás?")
        precondition(punctuationSegmenter.finish().isEmpty)

        var pauseSegmenter = NativeSpeechSentenceSegmenter()
        let pauseFirst = pauseSegmenter.consume([
            NativeSpeechSegment(substring: "Primera", timestamp: 0, duration: 1),
            NativeSpeechSegment(substring: "frase", timestamp: 1.1, duration: 1)
        ])
        precondition(pauseFirst.isEmpty)
        let pauseSecond = pauseSegmenter.consume([
            NativeSpeechSegment(substring: "Segunda", timestamp: 3.0, duration: 1),
            NativeSpeechSegment(substring: "frase", timestamp: 4.1, duration: 1)
        ])
        precondition(pauseSecond.count == 1)
        precondition(pauseSecond[0].transcript == "Primera frase")
        let pauseTail = pauseSegmenter.finish()
        precondition(pauseTail.count == 1 && pauseTail[0].transcript == "Segunda frase")

        var shortPauseSegmenter = NativeSpeechSentenceSegmenter()
        precondition(shortPauseSegmenter.consume([
            NativeSpeechSegment(substring: "alguna", timestamp: 100.52, duration: 0.24),
            NativeSpeechSegment(substring: "historia y", timestamp: 100.76, duration: 0.45),
            NativeSpeechSegment(substring: "por", timestamp: 101.21, duration: 0.15)
        ]).isEmpty)
        let shortPause = shortPauseSegmenter.consume([
            NativeSpeechSegment(substring: "Bueno", timestamp: 129.01, duration: 0.15)
        ])
        precondition(shortPause.count == 1)
        precondition(shortPause[0].transcript == "alguna historia y por")
        let shortPauseTail = shortPauseSegmenter.finish()
        precondition(shortPauseTail.count == 1)
        precondition(shortPauseTail[0].transcript == "Bueno")
        precondition(shortPause[0].endSeconds < shortPauseTail[0].startSeconds)

        var crossChunkPauseSegmenter = NativeSpeechSentenceSegmenter()
        precondition(crossChunkPauseSegmenter.consume([
            NativeSpeechSegment(substring: "español", timestamp: 1021.02, duration: 0.45)
        ]).isEmpty)
        let crossChunkPause = crossChunkPauseSegmenter.consume([
            NativeSpeechSegment(substring: "Luego tuve un desamor y de aquí", timestamp: 1051.79, duration: 3.0)
        ])
        precondition(crossChunkPause.count == 1)
        precondition(crossChunkPause[0].transcript == "español")
        let crossChunkPauseTail = crossChunkPauseSegmenter.finish()
        precondition(crossChunkPauseTail.count == 1)
        precondition(crossChunkPauseTail[0].transcript == "Luego tuve un desamor y de aquí")
        precondition(crossChunkPause[0].endSeconds < crossChunkPauseTail[0].startSeconds)

        var longSegmenter = NativeSpeechSentenceSegmenter()
        let longSegments = (0..<25).map {
            NativeSpeechSegment(substring: "palabra\($0)", timestamp: Double($0), duration: 0.4)
        }
        let longSentences = longSegmenter.consume(longSegments) + longSegmenter.finish()
        precondition(longSentences.count >= 2)
        precondition(longSentences.allSatisfy { $0.startSeconds < $0.endSeconds })
        precondition(zip(longSentences, longSentences.dropFirst()).allSatisfy {
            $0.endSeconds <= $1.startSeconds
        })

        var chunkSegmenter = NativeSpeechSentenceSegmenter()
        precondition(chunkSegmenter.consume([
            NativeSpeechSegment(substring: "跨块", timestamp: 30, duration: 1)
        ]).isEmpty)
        let chunkSentences = chunkSegmenter.consume([
            NativeSpeechSegment(substring: "句子。", timestamp: 31.2, duration: 1)
        ])
        precondition(chunkSentences.count == 1)
        precondition(chunkSentences[0].startSeconds == 30)
        precondition(chunkSentences[0].endSeconds == 32.2)

        var abnormalSegmenter = NativeSpeechSentenceSegmenter()
        let abnormal = abnormalSegmenter.consume([
            NativeSpeechSegment(substring: "超长片段", timestamp: 0, duration: 25)
        ]) + abnormalSegmenter.finish()
        precondition(abnormal.count == 1)
        precondition(abnormal[0].startSeconds < abnormal[0].endSeconds)

        print("Audio pipeline smoke passed: native WAV slicing and timestamped sentence parsing")
    }
}
