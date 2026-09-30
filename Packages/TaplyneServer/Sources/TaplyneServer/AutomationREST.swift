import Foundation

/// REST exposes the same operation contract as MCP, with native pixel coordinates.
struct AutomationREST: Sendable {
    let controller: PhoneController

    func describe(_ id: String) async throws -> HTTPResponse {
        _ = try await controller.phone(id)
        let result = await controller.run(phoneID: id, serialized: false) {
            try await controller.automation.observe(phoneID: id)
        }
        return .json(try result.get().json())
    }

    func control(_ id: String, _ request: HTTPRequest) async throws -> HTTPResponse {
        _ = try await controller.phone(id)
        let body = try ActionParser.body(request)
        let command: PhoneControlCommand = try AutomationRequest.choice(body, "command", nil)
        guard command == .pause || command == .stop else { throw APIError.invalid("command", "Remote control supports pause and stop. Resume and takeover require the Mac UI.") }
        return .json(try await controller.service.control(phoneID: id, command: command).json)
    }

    func operation(_ id: String, name: String, request: HTTPRequest, isAsync: Bool) async throws -> HTTPResponse {
        _ = try await controller.phone(id)
        let command = try AutomationRequest.parse(name.replacingOccurrences(of: "-", with: "_"), ActionParser.body(request))
        let (job, done) = await controller.submitPayload(phoneID: id, serialized: name != "wait-for-text", deadline: command.deadlineBudget) {
            let outcome = try await command.run(controller.automation, phoneID: id)
            let json = JSON.data(outcome.json())
            return JobPayload(data: json, contentType: "application/json", resultData: json)
        }
        if isAsync { return .json(["job_id": job.id]) }
        await done.value
        return .json((await controller.jobs.get(job.id) ?? job).json)
    }
}
