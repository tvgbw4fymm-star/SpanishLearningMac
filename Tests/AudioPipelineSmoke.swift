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
        print("Audio pipeline smoke passed: native WAV slicing and timestamped sentence parsing")
    }
}
