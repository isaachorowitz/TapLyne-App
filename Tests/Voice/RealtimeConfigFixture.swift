import Foundation

@main
enum RealtimeConfigFixture {
    @MainActor
    static func main() throws {
        var configuration = RealtimeVoice.configuration
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let option = arguments.removeFirst()
            guard !arguments.isEmpty else { throw FixtureError("Missing value for \(option)") }
            let value = arguments.removeFirst()
            switch option {
            case "--model":
                guard value.hasPrefix("gpt-realtime") else {
                    throw FixtureError("The fixture only accepts Realtime API models.")
                }
                configuration["model"] = value
            case "--max-output-tokens":
                guard let count = Int(value), (1...256).contains(count) else {
                    throw FixtureError("Output token cap must be between 1 and 256.")
                }
                configuration["max_output_tokens"] = count
            default:
                throw FixtureError("Unknown option \(option)")
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private struct FixtureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
