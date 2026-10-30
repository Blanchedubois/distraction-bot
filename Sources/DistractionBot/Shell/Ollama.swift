import Foundation

/// The local judge's home: Ollama on localhost (§3.5). B0 only asks whether it is up and which models it has;
/// the streaming client comes across from Jeff 2 in B3.
enum Ollama {
    static let base = URL(string: "http://localhost:11434")!
    static let judgeModel = "qwen3:14b"       // §5a Q6
    static let visionModel = "qwen2.5vl:3b"

    static func status() async -> (online: Bool, models: [String]) {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return (false, []) }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let names = (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
        return (true, names.sorted())
    }
}
