import Foundation

/// The TapKit-compatible /v1 API.
final class REST: Sendable {
    let controller: PhoneController
    private var service: any PhoneService { controller.service }

    init(controller: PhoneController) { self.controller = controller }

    func handle(_ request: HTTPRequest, parts: [String]) async -> HTTPResponse {
        do {
            return try await route(request, parts: parts)
        } catch let error as InvalidParams {
            return APIError.invalid("body", error.message).response
        } catch let error as APIError {
            return error.response
        } catch {
            return APIError.from(error).response
        }
    }

    private func wrongMethod() -> APIError {
        APIError(status: 405, code: "METHOD_NOT_ALLOWED", message: "Method not allowed")
    }

    private func route(_ r: HTTPRequest, parts: [String]) async throws -> HTTPResponse {
        let isAsync = r.query["async"]?.lowercased() == "true"
        switch parts.first {
        case "phones":
            if parts.count == 1 {
                guard r.method == "GET" else { throw wrongMethod() }
                return .json(await service.listPhones().map(phoneJSON))
            }
            let id = parts[1]
            guard parts.count >= 3 else { throw APIError.notFound() }
            let leaf = parts[2]
            switch (r.method, leaf, parts.count) {
            case ("GET", "status", 3): return try await status(id)
            case ("PATCH", "settings", 3): return try await rename(id, r)
            case ("GET", "apps", 3): return try await apps(id, refresh: false)
            case ("POST", "apps", 4) where parts[3] == "refresh": return try await apps(id, refresh: true)
            case ("GET", "describe", 3): return try await AutomationREST(controller: controller).describe(id)
            case ("POST", "control", 3): return try await AutomationREST(controller: controller).control(id, r)
            case ("POST", _, 3) where AutomationRequest.names.contains(leaf.replacingOccurrences(of: "-", with: "_")):
                return try await AutomationREST(controller: controller).operation(id, name: leaf, request: r, isAsync: isAsync)
            case ("GET", "screenshot", 3): return try await screenshot(id, async: isAsync)
            case ("POST", _, 3) where ActionParser.names.contains(leaf):
                return try await action(id, name: leaf, request: r, async: isAsync)
            default:
                if ["status", "settings", "apps", "screenshot", "describe", "control"].contains(leaf) || ActionParser.names.contains(leaf) || AutomationRequest.names.contains(leaf.replacingOccurrences(of: "-", with: "_")) {
                    throw wrongMethod()
                }
                throw APIError.notFound()
            }
        case "jobs":
            guard r.method == "GET" else { throw wrongMethod() }
            if parts.count == 2 {
                guard let job = await controller.jobs.get(parts[1]) else {
                    throw APIError(status: 404, code: "JOB_NOT_FOUND", message: "Job not found", context: ["job_id": parts[1]])
                }
                return .json(job.json)
            }
            if parts.count == 3, parts[2] == "download" {
                guard let job = await controller.jobs.get(parts[1]), let data = job.data else {
                    throw APIError(status: 404, code: "DATA_NOT_FOUND", message: "No data for this job", context: ["job_id": parts[1]])
                }
                return .data(data, contentType: job.contentType)
            }
            throw APIError.notFound()
        default:
            throw APIError.notFound("No route for \(r.method) \(r.path)")
        }
    }

    private func status(_ id: String) async throws -> HTTPResponse {
        let p = try await controller.phone(id)
        var body: [String: Any] = [
            "phone_id": p.id, "phone_name": p.displayName ?? p.name,
            "connection_status": p.connectionStatus.rawValue,
            "width": p.width ?? NSNull(), "height": p.height ?? NSNull(),
            "status_reason": p.statusReason ?? NSNull(),
        ]
        body["control"] = try await service.controlState(phoneID: id).json
        return .json(body)
    }

    private func rename(_ id: String, _ r: HTTPRequest) async throws -> HTTPResponse {
        _ = try await controller.phone(id)
        let body = try ActionParser.body(r)
        guard body.keys.contains("display_name") else { throw APIError.invalid("display_name", "is required") }
        var name: String?
        if let raw = body["display_name"], !(raw is NSNull) {
            guard let s = raw as? String else { throw APIError.invalid("display_name", "must be a string or null") }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            name = trimmed.isEmpty ? nil : trimmed
        }
        do {
            return .json(phoneJSON(try await service.rename(phoneID: id, displayName: name)))
        } catch { throw APIError.from(error, phoneID: id) }
    }

    private func apps(_ id: String, refresh: Bool) async throws -> HTTPResponse {
        _ = try await controller.phone(id)
        do {
            let list = try await service.apps(phoneID: id, refresh: refresh)
            var out: [String: Any] = [
                "apps": list.apps.map { ["name": $0.name, "bundle_id": $0.bundleID] },
                "app_count": list.apps.count, "source": list.source,
            ]
            if let at = list.updatedAt { out["updated_at"] = JSON.iso(at) }
            return .json(out)
        } catch { throw APIError.from(error, phoneID: id) }
    }

    private func screenshot(_ id: String, async isAsync: Bool) async throws -> HTTPResponse {
        _ = try await controller.phone(id)
        let automation = controller.automation
        let capture: @Sendable () async throws -> JobPayload = {
            let result = try await automation.observe(phoneID: id)
            guard let png = ImageEncoding.png(result.image.image) else { throw PhoneServiceError.failed("Could not encode the screenshot") }
            return JobPayload(data: png, resultData: JSON.data(result.json()))
        }
        if isAsync {
            let (job, _) = await controller.submitPayload(phoneID: id, serialized: false, work: capture)
            return .json(["job_id": job.id])
        }
        let result = try await controller.run(phoneID: id, serialized: false, work: capture).get()
        var response = HTTPResponse.data(result.data ?? Data(), contentType: "image/png")
        if let metadata = result.resultData.flatMap(JSON.object) as? [String: Any],
           let screen = metadata["screen"] as? [String: Any], let frameID = screen["frame_id"] as? String {
            response.headers.append(("X-Taplyne-Frame-Id", frameID))
        }
        return response
    }

    private func action(_ id: String, name: String, request: HTTPRequest, async isAsync: Bool) async throws -> HTTPResponse {
        let phone = try await controller.onlinePhone(id)
        let body = try ActionParser.body(request)
        let action = try ActionParser.parse(name: name, body: body, phone: phone)
        let frame = try AutomationRequest.optionalString(body, "frame_id")
        let expectation = try AutomationRequest.expectation(body)
        if action.requiresFrameReference, frame == nil { throw APIError.invalid("frame_id", "is required; call GET describe or screenshot first") }
        let automation = controller.automation
        let (job, done) = await controller.submitPayload(phoneID: id, serialized: true) {
            let result = try await automation.act(phoneID: id, action: action, frameID: frame, expectation: expectation)
            let json = JSON.data(result.json())
            return JobPayload(data: json, contentType: "application/json", resultData: json)
        }
        if isAsync { return .json(["job_id": job.id]) }
        await done.value
        return .json((await controller.jobs.get(job.id) ?? job).json)
    }
}
