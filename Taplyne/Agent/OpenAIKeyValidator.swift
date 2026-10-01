import Foundation
import TaplyneServer

struct OpenAIKeyValidation: Equatable {
    let modelCount: Int
}

enum OpenAIKeyValidator {
    static func validate(
        _ rawKey: String,
        session: URLSession = PrivateHTTPClient.session,
        endpoint: URL = URL(string: "https://api.openai.com/v1/models")!
    ) async throws -> OpenAIKeyValidation {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ValidationError("No OpenAI API key is saved.") }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ValidationError("OpenAI returned an invalid network response.") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw ValidationError("OpenAI rejected this key. Replace it and validate again.")
            case 403: throw ValidationError("This key cannot list models. Check its project permissions.")
            case 429: throw ValidationError("OpenAI temporarily limited this project. The key remains saved.")
            default: throw ValidationError("OpenAI could not validate the key (HTTP \(http.statusCode)).")
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["data"] as? [[String: Any]],
              models.contains(where: { ($0["id"] as? String)?.isEmpty == false }) else {
            throw ValidationError("The key was accepted, but OpenAI returned no model catalog.")
        }
        return OpenAIKeyValidation(modelCount: models.count)
    }

    struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
