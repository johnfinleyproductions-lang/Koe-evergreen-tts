import AppKit
import Foundation

enum KoeLog { static func d(_ message: String) {} }

// Refuse actual networking while preserving the same cache identity URL.
final class RefuseNetwork: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@main struct KokoroCacheSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let url = URL(string: CommandLine.arguments[1])!
        let voice = CommandLine.arguments[2]
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("koe-kokoro-cache-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let text = "We build routines one day at a time. A small ritual can help us pause and pay attention. Reading a book gives us time to think. This is the final sentence of our short reading."
        let count = WordTokenizer.tokenize(text).count
        var done = false, problem: TTSError?, heard: [Int] = []
        let live = KokoroEngine(baseURL: url, voice: voice, bookCache: cache, stopOnFailure: true)
        live.speak(text: text, rate: 2, onWord: { heard.append($0) }, onStateChange: { _ in }, onFinish: { done = true }, onError: { problem = $0 })
        waitUntil(seconds: 50) { done || problem != nil }
        precondition(problem == nil && done && heard.last == count - 1, "Live Kokoro did not complete the reading")
        let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        precondition(!files.isEmpty)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RefuseNetwork.self]
        let offline = KokoroEngine(baseURL: url, voice: voice, bookCache: cache, stopOnFailure: true, sessionConfiguration: config)
        done = false; problem = nil; heard = []
        let target = count / 2
        offline.speakFromWord(text: text, startingAt: target, rate: 2, onWord: { heard.append($0) }, onStateChange: { _ in }, onFinish: { done = true }, onError: { problem = $0 })
        waitUntil(seconds: 25) { done || problem != nil }
        precondition(done && problem == nil && heard.first! >= target && heard.last == count - 1)
        precondition(RefuseNetwork.requests == 0, "Cached resume attempted to contact Kokoro")
        let missing = KokoroEngine(baseURL: url, voice: voice + "-different-profile", bookCache: cache, stopOnFailure: true, sessionConfiguration: config)
        done = false; problem = nil; heard = []
        missing.speak(text: text, rate: 2, onWord: { heard.append($0) }, onStateChange: { _ in }, onFinish: { done = true }, onError: { problem = $0 })
        waitUntil(seconds: 5) { problem != nil || done }
        precondition(problem != nil && !done && heard.isEmpty, "An unavailable voice skipped the book or reused another voice's audio")
        missing.stop(); offline.stop(); live.stop()
        print("PASS: live Kokoro audio and word timing, persistent cache, resumed word offsets, offline replay with zero network requests, separate voice profiles and explicit failure without skipped passages.")
    }
    @MainActor static func waitUntil(seconds: Double, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
