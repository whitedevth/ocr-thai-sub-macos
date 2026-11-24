import Foundation

public enum TranslatorBackend: String, Codable, CaseIterable, Sendable {
    /// Claude Messages API (cloud): best quality, ~1-3 s per request.
    case claude
    /// A local model served by Ollama on this Mac: no network, no API cost.
    case ollama
}

public struct TranslatorConfig: Sendable {
    public var backend: TranslatorBackend
    public var apiKey: String
    /// Model name for the chosen backend (a Claude model ID, or an Ollama tag such as "gemma3:12b").
    public var model: String
    public var ollamaURL: URL
    /// Optional: game title / characters / tone, helps keep names and register consistent.
    public var gameContext: String

    public init(backend: TranslatorBackend = .claude, apiKey: String = "", model: String = "claude-opus-5-5",
                ollamaURL: URL = URL(string: "http://localhost:11434")!, gameContext: String = "") {
        self.backend = backend
        self.apiKey = apiKey
        self.model = model
        self.ollamaURL = ollamaURL
        self.gameContext = gameContext
    }
}

public enum TranslatorError: LocalizedError {
    case http(Int, String)
    case refusal(String?)
    case emptyResponse
    case badResponse
    case ollamaUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .http(code, message): return "HTTP \(code): \(message)"
        case let .refusal(category): return "Claude ปฏิเสธการแปลบรรทัดนี้" + (category.map { " (\($0))" } ?? "")
        case .emptyResponse: return "โมเดลไม่ได้ส่งคำแปลกลับมา"
        case .badResponse: return "อ่านคำตอบจากโมเดลไม่ได้"
        case let .ollamaUnavailable(url): return "ต่อ Ollama ที่ \(url) ไม่ได้ — เปิด Ollama ก่อน (ollama serve)"
        }
    }
}

/// Translates English game text to Thai, through the Claude Messages API (raw HTTP; there is no official
/// Swift SDK) or a local model served by Ollama.
public actor Translator {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private var cache: [String: String] = [:]
    private let cacheLimit = 2000
    /// Backend, model and game context the cache and history were made with.
    private var cacheOwner = ""
    /// Recent (English, Thai) pairs, sent as context so names, pronouns and tone stay consistent.
    private var history: [(en: String, th: String)] = []
    private let historyLimit = 6

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func resetContext() {
        history.removeAll()
        cache.removeAll()
    }

    private static func owner(_ config: TranslatorConfig) -> String {
        "\(config.backend.rawValue)|\(config.model)|\(config.gameContext)"
    }

    /// Drops cached translations made with another backend, model or game context, and caps the cache.
    private func checkCache(_ config: TranslatorConfig) {
        let owner = Self.owner(config)
        if owner != cacheOwner {
            cacheOwner = owner
            resetContext()
        } else if cache.count > cacheLimit {
            cache.removeAll()
        }
    }

    public func translate(_ english: String, config: TranslatorConfig) async throws -> String {
        checkCache(config)
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = cache[text] { return hit }

        // Keep "NAME:" ourselves; models (small local ones especially) tend to drop or translate it.
        let (speaker, line) = Self.splitSpeaker(text)
        let translated = try await send(system: systemPrompt(gameContext: config.gameContext, backend: config.backend),
                                        user: userPrompt(for: line, backend: config.backend), format: nil, config: config)
        let thai = speaker.map { "\($0): \(translated)" } ?? translated
        // Another backend/model/context may have taken over while this request ran.
        if cacheOwner == Self.owner(config) {
            cache[text] = thai
            remember(line, translated)
        }
        return thai
    }

    /// "Kratos: We must go." -> ("Kratos", "We must go."). Up to three capitalised words before the colon.
    static func splitSpeaker(_ text: String) -> (String?, String) {
        let pattern = #"^([A-Z][\p{L}'’.\-]*(?: [A-Z][\p{L}'’.\-]*){0,2}):\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let name = Range(m.range(at: 1), in: text), let body = Range(m.range(at: 2), in: text)
        else { return (nil, text) }
        return (String(text[name]), String(text[body]))
    }

    /// Full-screen mode: translates several on-screen texts in one request.
    /// Returns a dictionary from input text to Thai; texts already translated before come from the cache.
    public func translateBatch(_ texts: [String], config: TranslatorConfig) async throws -> [String: String] {
        checkCache(config)
        var result: [String: String] = [:]
        var pending: [String] = []
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hit = cache[text] { result[raw] = hit } else if !pending.contains(text) { pending.append(text) }
        }
        guard !pending.isEmpty else { return result }

        var user = "Translate each on-screen text below. They are separate pieces of UI, menus, item descriptions or dialogue from the same frame.\n"
        for (i, text) in pending.enumerated() {
            user += "<text id=\"\(i)\">\(text)</text>\n"
        }
        let schema: [String: Any] = [
            "type": "json_schema",
            "schema": [
                "type": "object",
                "properties": [
                    "translations": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["id": ["type": "integer"], "thai": ["type": "string"]],
                            "required": ["id", "thai"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["translations"],
                "additionalProperties": false,
            ],
        ]
        let json = try await send(system: systemPrompt(gameContext: config.gameContext, backend: config.backend, screenMode: true),
                                  user: user, format: schema, config: config)
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["translations"] as? [[String: Any]] else { throw TranslatorError.badResponse }

        var byText: [String: String] = [:]
        for item in items {
            guard let id = item["id"] as? Int, pending.indices.contains(id),
                  let thai = (item["thai"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !thai.isEmpty else { continue }
            byText[pending[id]] = thai
            if cacheOwner == Self.owner(config) { cache[pending[id]] = thai }
        }
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let thai = byText[text] { result[raw] = thai }
        }
        return result
    }

    private func remember(_ en: String, _ th: String) {
        history.append((en, th))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    /// Must match between warm-up and real requests, or Ollama reloads the model.
    private static let ollamaContext = 4096

    /// Loads the Ollama model into memory so the first real line isn't slowed by model loading.
    public func warmUp(config: TranslatorConfig) async {
        guard config.backend == .ollama else { return }
        var request = URLRequest(url: config.ollamaURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": config.model, "keep_alive": "30m", "options": ["num_ctx": Self.ollamaContext]])
        _ = try? await session.data(for: request)
    }

    /// One model call; returns the text of the reply (JSON text when `format` is given).
    private func send(system: String, user: String, format: [String: Any]?, config: TranslatorConfig) async throws -> String {
        switch config.backend {
        case .claude: return try await sendClaude(system: system, user: user, format: format, config: config)
        case .ollama: return try await sendOllama(system: system, user: user, format: format, config: config)
        }
    }

    private func sendOllama(system: String, user: String, format: [String: Any]?, config: TranslatorConfig) async throws -> String {
        var request = URLRequest(url: config.ollamaURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "keep_alive": "30m",
            // Short prompts and answers: a small context window loads faster and uses less memory.
            "options": ["temperature": 0.2, "num_ctx": Self.ollamaContext, "num_predict": format == nil ? 256 : 1536],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        // Ollama takes the bare JSON schema (no Anthropic-style wrapper).
        if let schema = format?["schema"] { body["format"] = schema }
        // Reasoning models think before answering by default; that only adds latency here.
        if config.model.lowercased().hasPrefix("qwen3") { body["think"] = false }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw TranslatorError.ollamaUnavailable(config.ollamaURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw TranslatorError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            throw TranslatorError.http(http.statusCode, json?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "")
        }
        let text = ((json?["message"] as? [String: Any])?["content"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslatorError.emptyResponse }
        return text
    }

    private func sendClaude(system: String, user: String, format: [String: Any]?, config: TranslatorConfig) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        var outputConfig: [String: Any] = ["effort": "low"]  // short, latency-sensitive task
        if let format { outputConfig["format"] = format }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 8192,
            "system": system,
            "output_config": outputConfig,
            "messages": [["role": "user", "content": user]],
        ]
        // If a safety classifier declines, let the API retry on Anthropic's recommended
        // fallback model instead of returning a refusal. Haiku has no server-side fallback.
        if !config.model.contains("haiku") {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslatorError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard http.statusCode == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? ""
            throw TranslatorError.http(http.statusCode, message)
        }
        guard let json else { throw TranslatorError.badResponse }

        if json["stop_reason"] as? String == "refusal" {
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String
            throw TranslatorError.refusal(category)
        }

        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslatorError.emptyResponse }
        return text
    }

    /// Whole on-screen phrases with a fixed Thai wording (keys lowercased). Used before any model.
    public static let glossaryExact: [String: String] = [
        "resume game": "เล่นต่อ", "resume": "เล่นต่อ", "continue": "เล่นต่อ",
        "new game": "เริ่มเกมใหม่", "load game": "โหลดเกม", "save game": "บันทึกเกม",
        "options": "ตั้งค่า", "settings": "ตั้งค่า", "quit": "ออก", "quit game": "ออกจากเกม",
        "inventory": "กระเป๋า", "map": "แผนที่", "skills": "สกิล", "equipment": "อุปกรณ์",
    ]

    /// Fixed Thai for a whole UI phrase, tolerating one stray OCR character in front ("• Load Game").
    public static func glossaryLookup(_ text: String) -> String? {
        let words = ColorAnnotator.plain(text).lowercased().split(separator: " ")
        if let hit = glossaryExact[words.joined(separator: " ")] { return hit }
        if words.count > 1, words[0].count == 1 { return glossaryExact[words.dropFirst().joined(separator: " ")] }
        return nil
    }

    /// Common game UI terms whose usual Thai wording models often get wrong.
    private static let glossary = """
        Glossary: Resume/Continue = เล่นต่อ, New Game = เริ่มเกมใหม่, Load Game = โหลดเกม, Save = บันทึก, \
        Options/Settings = ตั้งค่า, Quit = ออก, Objective/Quest = ภารกิจ, Key (item) = กุญแจ, \
        Inventory = กระเป๋า, Equip = สวมใส่, Skill = สกิล, Health/HP = พลังชีวิต.
        """

    private func systemPrompt(gameContext: String, backend: TranslatorBackend, screenMode: Bool = false) -> String {
        let context = gameContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = context.isEmpty ? "" : "\nGame: \(context)"

        if backend == .ollama {
            // Local models: short and direct (every prompt token costs latency), plus the glossary.
            let task = screenMode
                ? "Translate each English game screen text (menu, quest, item, dialogue) to short natural Thai. Keep button names (X, R2) as is."
                : "Translate the English game subtitle to natural spoken Thai. Reply with the Thai only."
            return task + " Input may have OCR errors. Keep « » around the Thai for words inside « ».\n" + Self.glossary + about
        }

        var prompt = screenMode ? """
        You translate English text seen on a video game screen (menus, HUD, quest log, item descriptions, dialogue) into Thai for a player reading it live.

        - Return one translation per input id. Keep each about as short as the English so it fits in the same space.
        - Use the usual Thai wording for game UI; keep button names like X, R2, Options as they are.
        """ : """
        You translate English video game subtitles into natural, spoken Thai for a player reading them live on screen.

        - Reply with the Thai translation only: no quotes, notes, romanisation, or the English original.
        - Keep it short enough to read at a glance; match the speaker's tone (casual, formal, angry, joking).
        """
        prompt += """

        - Keep character names, place names and game terms in their usual form; use the same Thai rendering every time.
        - Choose Thai pronouns and particles (ผม/ฉัน/ข้า, ครับ/ค่ะ/นะ) from context and stay consistent across lines.
        - The input comes from OCR and may contain small recognition errors; translate what was most likely meant.
        - Words inside « » are highlighted in the game: keep « » around their Thai translation.

        """
        prompt += Self.glossary
        if !context.isEmpty {
            prompt += "\n\nAbout this game (from the player):\n\(context)"
        }
        return prompt
    }

    private func userPrompt(for text: String, backend: TranslatorBackend) -> String {
        // Fewer context lines for local models: each one adds prompt-processing time.
        let recent = backend == .ollama ? history.suffix(2) : history.suffix(historyLimit)
        var prompt = ""
        if !recent.isEmpty {
            prompt += backend == .ollama ? "Previous lines:\n" : "<previous_lines>\n"
            for pair in recent {
                prompt += "EN: \(pair.en)\nTH: \(pair.th)\n"
            }
            prompt += backend == .ollama ? "\n" : "</previous_lines>\n\n"
        }
        prompt += backend == .ollama ? "Translate: \(text)" : "Translate this subtitle line:\n<line>\(text)</line>"
        return prompt
    }
}
