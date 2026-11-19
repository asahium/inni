import Foundation
@testable import InniCore
import XCTest

final class ZstdTests: XCTestCase {
    private func cli(_ args: [String], input: Data) throws -> Data {
        let tool = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { throw XCTSkip("zstd CLI not installed") }
        let inURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try input.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args + ["-c", "-q", inURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }

    private func samples() -> [(String, Data)] {
        var rng = SplitMix64(seed: 42)
        let random = Data((0..<300_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        let words = ["apple", "banana", "cherry", "дерево", "時間", "<div>", "</div>", "{{c1::", "}}", " ", "\n", "the", "of"]
        var text = ""
        for _ in 0..<200_000 { text += words[Int(rng.next() % UInt64(words.count))] }
        let skewed = Data((0..<500_000).map { i in UInt8((i % 7 == 0) ? (rng.next() % 256) : UInt64(i % 13)) })
        return [("empty", Data()), ("tiny", Data("a".utf8)), ("random", random), ("text", Data(text.utf8)),
                ("skewed", skewed), ("zeros", Data(count: 1_000_000))]
    }

    func testDecodesCLIOutput() throws {
        for (name, data) in samples() {
            for level in ["-1", "-3", "-9", "-19", "--ultra", "--fast=5"] {
                let args = level == "--ultra" ? ["--ultra", "-22"] : [level]
                let compressed = try cli(args, input: data)
                let out = try Zstd.decompress(compressed)
                XCTAssertEqual(out, data, "\(name) at \(level)")
            }
        }
    }

    func testRawFramesAreReadableByCLI() throws {
        for (name, data) in samples() {
            let frame = Zstd.frame(data)
            XCTAssertEqual(try Zstd.decompress(frame), data, name)
            XCTAssertEqual(try cli(["-d"], input: frame), data, name)
        }
    }
}
