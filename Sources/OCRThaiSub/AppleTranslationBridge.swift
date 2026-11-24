import SubtitleCore
import SwiftUI
import Translation

/// Apple's on-device translation (English -> Thai, ~0.05 s per line).
///
/// A `TranslationSession` can only be used inside SwiftUI's `.translationTask` closure, so the
/// closure stays alive and serves requests from an `AsyncStream` for as long as the window exists.
@MainActor
final class AppleTranslationBridge: ObservableObject {
    enum BridgeError: LocalizedError {
        case notReady
        var errorDescription: String? { "Apple Translation ยังไม่พร้อม" }
    }

    private struct Job {
        let id: UUID
        let texts: [String]
    }

    /// Set once to start the `.translationTask` attached in ContentView.
    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?

    private var jobs: AsyncStream<Job>.Continuation?
    /// Which serve() call owns `jobs`; an older one ending must not tear down a newer one.
    private var currentSession: UUID?
    /// Callers waiting for a job; whatever is left when the session ends gets an error.
    private var waiting: [UUID: (session: UUID, reply: CheckedContinuation<[String: String], Error>)] = [:]

    func activate() {
        guard configuration == nil else { return }
        configuration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                                                         target: Locale.Language(identifier: "th"))
    }

    /// Runs inside `.translationTask`; returns only when the view goes away.
    func serve(_ session: TranslationSession) async {
        do {
            // Shows the system download sheet if the English/Thai pack is missing.
            try await session.prepareTranslation()
        } catch {
            errorMessage = "เตรียม Apple Translation ไม่สำเร็จ: \(error.localizedDescription)"
            return
        }
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        let sessionID = UUID()
        currentSession = sessionID
        jobs = continuation
        isReady = true
        errorMessage = nil
        defer {
            continuation.finish()
            if currentSession == sessionID {
                currentSession = nil
                isReady = false
                jobs = nil
            }
            // Jobs sent to this session and still buffered: fail them so their callers don't hang.
            for (id, entry) in waiting where entry.session == sessionID {
                waiting[id] = nil
                entry.reply.resume(throwing: BridgeError.notReady)
            }
        }

        for await job in stream {
            guard let reply = waiting.removeValue(forKey: job.id)?.reply else { continue }
            var result: [String: String] = [:]
            var requests: [TranslationSession.Request] = []
            for (i, text) in job.texts.enumerated() {
                // Fixed UI phrases Apple tends to translate literally ("Resume Game").
                if let known = Translator.glossaryLookup(text) {
                    result[text] = known
                } else {
                    requests.append(TranslationSession.Request(sourceText: text, clientIdentifier: String(i)))
                }
            }
            // Highlighted words (« ») are also translated on their own: Apple sometimes leaves a
            // bracketed name in English, and then the stand-alone translation is used instead.
            var phrases: [String] = []
            for text in job.texts {
                for (segment, index) in ColorAnnotator.segments(text) where index != nil && !phrases.contains(segment) {
                    phrases.append(segment)
                    requests.append(TranslationSession.Request(sourceText: segment, clientIdentifier: "p\(phrases.count - 1)"))
                }
            }
            do {
                var phraseThai: [String: String] = [:]
                if !requests.isEmpty {
                    for response in try await session.translations(from: requests) {
                        guard let id = response.clientIdentifier else { continue }
                        if id.hasPrefix("p"), let k = Int(id.dropFirst()), phrases.indices.contains(k) {
                            phraseThai[phrases[k]] = response.targetText
                        } else if let i = Int(id), job.texts.indices.contains(i) {
                            result[job.texts[i]] = response.targetText
                        }
                    }
                }
                for (english, thai) in result where english.contains("«") {
                    result[english] = Self.fixUntranslatedHighlights(english: english, thai: thai, phraseThai: phraseThai)
                }
                reply.resume(returning: result)
            } catch {
                reply.resume(throwing: error)
            }
        }
    }

    /// Replaces a highlight that came back still in English with its stand-alone translation.
    nonisolated static func fixUntranslatedHighlights(english: String, thai: String, phraseThai: [String: String]) -> String {
        let source = ColorAnnotator.segments(english).filter { $0.1 != nil }.map(\.0)
        var out = "", k = 0
        for (segment, index) in ColorAnnotator.segments(thai) {
            guard index != nil else { out += segment; continue }
            let original = k < source.count ? source[k] : nil
            k += 1
            if let original, segment.trimmingCharacters(in: .whitespaces).lowercased() == original.lowercased(),
               let translated = phraseThai[original] {
                out += "«\(translated)»"
            } else {
                out += "«\(segment)»"
            }
        }
        return out
    }

    /// Returns a dictionary from each input text to Thai.
    func translate(_ texts: [String]) async throws -> [String: String] {
        guard let jobs, let session = currentSession else { throw BridgeError.notReady }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            waiting[id] = (session, continuation)
            jobs.yield(Job(id: id, texts: texts))
        }
    }
}
