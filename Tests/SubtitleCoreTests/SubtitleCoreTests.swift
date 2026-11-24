import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import SubtitleCore

@Suite struct SubtitleTrackerTests {
    @Test func emitsOnlyAfterStableReads() {
        var t = SubtitleTracker(requiredStableReads: 2)
        #expect(t.ingest("Where are we going?") == nil)
        #expect(t.ingest("Where are we going?") == .show("Where are we going?"))
        #expect(t.ingest("Where are we going?") == nil)
    }

    @Test func typewriterTextIsNotEmittedUntilItSettles() {
        var t = SubtitleTracker(requiredStableReads: 2)
        #expect(t.ingest("We need") == nil)
        #expect(t.ingest("We need to move") == nil)
        #expect(t.ingest("We need to move, now!") == nil)
        #expect(t.ingest("We need to move, now!") == .show("We need to move, now!"))
    }

    @Test func ocrJitterDoesNotRetranslate() {
        var t = SubtitleTracker(requiredStableReads: 2)
        _ = t.ingest("Boy, stay close.")
        #expect(t.ingest("Boy, stay close.") == .show("Boy, stay close."))
        _ = t.ingest("Boy. stay c1ose.")
        #expect(t.ingest("Boy. stay c1ose.") == nil)
    }

    @Test func clearsAfterEmptyReads() {
        var t = SubtitleTracker(requiredStableReads: 2, clearAfterEmptyReads: 3)
        _ = t.ingest("Hello there")
        _ = t.ingest("Hello there")
        #expect(t.ingest("") == nil)
        #expect(t.ingest("") == nil)
        #expect(t.ingest("") == .clear)
        _ = t.ingest("Hello there")
        #expect(t.ingest("Hello there") == .show("Hello there"))
    }
}

/// Renders text onto a dark 1920x1080 frame, like a game screenshot.
func renderFrame(_ items: [(String, CGPoint, CGFloat)]) -> CGImage {
    let w = 1920, h = 1080
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    for (text, origin, size) in items {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        // origin is top-left based; AppKit draws bottom-left based.
        NSAttributedString(string: text, attributes: attrs).draw(at: CGPoint(x: origin.x, y: CGFloat(h) - origin.y - size))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

@Suite struct OCRTests {
    let frame = renderFrame([
        ("Objective: Find the key to the old tower", CGPoint(x: 60, y: 60), 30),
        ("HP 120 / 200", CGPoint(x: 1600, y: 60), 28),
        ("Press X to open the door", CGPoint(x: 760, y: 600), 30),
        ("Kratos: We must keep moving, boy.", CGPoint(x: 560, y: 900), 44),
    ])

    @Test func readsSubtitleRegionOnly() {
        let text = OCRService().recognize(cgImage: frame, roi: CGRect(x: 0.1, y: 0.74, width: 0.8, height: 0.22))
        #expect(text.contains("We must keep moving"))
        #expect(!text.contains("Objective"))
    }

    @Test func fullFrameSpeed() {
        let ocr = OCRService(minTextHeight: 0)
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        _ = ocr.recognize(cgImage: frame, roi: full)  // warm up model
        let runs = 5
        let start = Date()
        var text = ""
        for _ in 0..<runs { text = ocr.recognize(cgImage: frame, roi: full) }
        let ms = Date().timeIntervalSince(start) / Double(runs) * 1000
        print("FULL-FRAME OCR 1920x1080: \(Int(ms)) ms/frame -> \(text)")
        #expect(text.contains("Objective"))
        #expect(text.contains("open the door"))
    }
}

@Suite struct ScreenModeTests {
    let frame = renderFrame([
        ("Objective: Find the key to the old tower", CGPoint(x: 60, y: 60), 30),
        ("HP 120 / 200", CGPoint(x: 1600, y: 60), 28),
        ("A rusty blade forged in the north.", CGPoint(x: 1200, y: 400), 26),
        ("It still holds a sharp edge.", CGPoint(x: 1200, y: 434), 26),
        ("Press X to open the door", CGPoint(x: 760, y: 600), 30),
        ("Kratos: We must keep moving, boy.", CGPoint(x: 560, y: 900), 44),
    ])

    @Test func linesHaveFramePositions() {
        // Subtitle ROI: boxes must still be relative to the whole frame.
        let lines = OCRService(minTextHeight: 0).recognizeLines(cgImage: frame, roi: CGRect(x: 0.1, y: 0.74, width: 0.8, height: 0.22))
        let sub = try! #require(lines.first { $0.text.contains("keep moving") })
        #expect(abs(sub.box.minY - 900.0 / 1080) < 0.03)
        #expect(abs(sub.box.minX - 560.0 / 1920) < 0.03)
    }

    @Test func groupsParagraphsAndSkipsNumbers() {
        let lines = OCRService(minTextHeight: 0).recognizeLines(cgImage: frame, roi: CGRect(x: 0, y: 0, width: 1, height: 1))
        let blocks = ScreenTextTracker.group(lines).filter { ScreenTextTracker.isTranslatable($0.text) }
        print("BLOCKS:", blocks.map { "\($0.lineCount)| \($0.text)" })
        #expect(blocks.count == 4)
        #expect(blocks.contains { $0.lineCount == 2 && $0.text.contains("rusty blade") && $0.text.contains("sharp edge") })
        #expect(!blocks.contains { $0.text.contains("HP") })
    }

    @Test func translatesEachBlockOnceAndOnlyChangedBlocksAgain() {
        var t = ScreenTextTracker(requiredStableReads: 2)
        let a = OCRLine(box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03), text: "Find the key")
        let b = OCRLine(box: CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.04), text: "We must keep moving")
        #expect(t.ingest([a, b]).isEmpty)
        let first = t.ingest([a, b])
        #expect(Set(first.map(\.english)) == ["Find the key", "We must keep moving"])
        for job in first { t.setTranslation("TH:" + job.english, for: job) }
        #expect(t.ingest([a, b]).isEmpty)  // nothing changed

        let b2 = OCRLine(box: b.box, text: "Stay close to me, boy")
        #expect(t.ingest([a, b2]).isEmpty)  // not stable yet
        let second = t.ingest([a, b2])
        #expect(second.map(\.english) == ["Stay close to me, boy"])
        // Old Thai stays on screen until the new one arrives.
        #expect(t.blocks.first { $0.english == "Stay close to me, boy" }?.thai == "TH:We must keep moving")

        _ = t.ingest([b2]); _ = t.ingest([b2]); _ = t.ingest([b2])
        #expect(t.blocks.count == 1)  // "Find the key" left the screen
    }
}

/// Fakes Ollama's /api/chat so the request and parsing can be checked without a model.
final class FakeOllama: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]
    nonisolated(unsafe) static var reply = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = Data(); var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&chunk, maxLength: chunk.count); if n <= 0 { break }; buf.append(chunk, count: n) }
            data = buf
        }
        Self.lastBody = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
        let body = try! JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": Self.reply], "done": true])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct OllamaBackendTests {
    func makeTranslator() -> Translator {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeOllama.self]
        return Translator(session: URLSession(configuration: cfg))
    }

    @Test func singleLine() async throws {
        FakeOllama.reply = "เราต้องไปต่อ"
        let t = makeTranslator()
        let th = try await t.translate("We must keep moving", config: TranslatorConfig(backend: .ollama, model: "gemma3:12b"))
        #expect(th == "เราต้องไปต่อ")
        #expect(FakeOllama.lastBody["model"] as? String == "gemma3:12b")
        #expect(FakeOllama.lastBody["stream"] as? Bool == false)
        #expect(FakeOllama.lastBody["format"] == nil)
    }

    @Test func batchUsesJSONSchema() async throws {
        FakeOllama.reply = #"{"translations":[{"id":0,"thai":"ค้นหากุญแจ"},{"id":1,"thai":"กด X เพื่อเปิดประตู"}]}"#
        let t = makeTranslator()
        let out = try await t.translateBatch(["Find the key", "Press X to open the door"],
                                             config: TranslatorConfig(backend: .ollama, model: "qwen3:8b"))
        #expect(out["Find the key"] == "ค้นหากุญแจ")
        #expect(out["Press X to open the door"] == "กด X เพื่อเปิดประตู")
        #expect((FakeOllama.lastBody["format"] as? [String: Any])?["type"] as? String == "object")
        #expect(FakeOllama.lastBody["think"] as? Bool == false)
    }
}

/// Hits a real local Ollama. Run with: OLLAMA_LIVE=1 OLLAMA_MODEL=gemma3:12b swift test --filter LiveOllama
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"))
struct LiveOllamaTests {
    let config = TranslatorConfig(backend: .ollama,
                                  model: ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "gemma3:12b",
                                  gameContext: "God of War Ragnarök. Kratos speaks to his son Atreus ('boy').")

    @Test func speedAndQuality() async throws {
        let t = Translator()
        await t.warmUp(config: config)
        let lines = [
            "Kratos: We must keep moving, boy.",
            "Atreus: Do you think she's still out there?",
            "Stay close. Do not let your guard down.",
            "The bridge is out. We'll have to find another way across.",
            "Press X to open the door",
        ]
        for line in lines {
            let start = Date()
            let th = try await t.translate(line, config: config)
            print(String(format: "LIVE %.2fs | %@ -> %@", Date().timeIntervalSince(start), line, th))
        }
        let start = Date()
        let batch = try await t.translateBatch([
            "Objective: Find the key to the old tower",
            "A rusty blade forged in the north. It still holds a sharp edge.",
            "Options", "Resume Game", "Load Game",
        ], config: config)
        print(String(format: "LIVE BATCH %.2fs (5 blocks)", Date().timeIntervalSince(start)))
        for (en, th) in batch.sorted(by: { $0.key < $1.key }) { print("LIVE BATCH | \(en) -> \(th)") }
        #expect(batch.count == 5)
    }
}
