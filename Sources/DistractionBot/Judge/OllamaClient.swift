import Foundation

/// Ollama's HTTP API on localhost (§3.5), from Jeff 2's client, reduced to what the judge needs:
/// one JSON-mode chat call with a time budget, a warm-up, the model list. Nothing leaves the machine.
struct OllamaClient {
    var base: URL = URL(string: ProcessInfo.processInfo.environment["DBOT_OLLAMA"] ?? "http://localhost:11434")!
    static let keepAlive = "30m"

    struct Message: Codable { var role: String; var content: String; var images: [String]? = nil }
    struct Stats { var promptTokens = 0; var evalTokens = 0; var loadSeconds = 0.0; var totalSeconds = 0.0 }
    enum Failure: Error { case offline, timeout, badReply(String) }

    /// A single answer in JSON mode, no thinking, temperature 0. Throws past `budget` seconds.
    func chatJSON(model: String, messages: [Message], budget: TimeInterval) async throws -> (String, Stats) {
        try await chat(model: model, messages: messages, budget: budget, json: true)
    }

    /// A single plain answer (the vision description), same settings.
    func chat(model: String, messages: [Message], budget: TimeInterval, json: Bool = false, maxTokens: Int = 120) async throws -> (String, Stats) {
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = budget
        var body: [String: Any] = ["model": model, "stream": false, "think": false, "keep_alive": Self.keepAlive,
                                   "options": ["temperature": 0, "num_predict": maxTokens],
                                   "messages": messages.map { m -> [String: Any] in var d: [String: Any] = ["role": m.role, "content": m.content]; if let i = m.images { d["images"] = i }; return d }]
        if json { body["format"] = "json" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw Failure.timeout }
        catch { throw Failure.offline }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = j["message"] as? [String: Any], let content = msg["content"] as? String else { throw Failure.badReply(String(data: data, encoding: .utf8) ?? "") }
        var st = Stats()
        st.promptTokens = j["prompt_eval_count"] as? Int ?? 0; st.evalTokens = j["eval_count"] as? Int ?? 0
        st.loadSeconds = Double(j["load_duration"] as? Int ?? 0) / 1e9; st.totalSeconds = Date().timeIntervalSince(t0)
        return (content, st)
    }

    /// Loads the model so the first real verdict is warm (§2.3: 14b cold load 4.6 s).
    func warm(model: String) async {
        var req = URLRequest(url: base.appendingPathComponent("api/generate")); req.httpMethod = "POST"; req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": Self.keepAlive])
        _ = try? await URLSession.shared.data(for: req)
    }
}
