import Foundation

/// References are bound to a phone, its capture geometry, and its input generation.
actor ScreenObserver {
    struct Observation: Sendable {
        var phoneID: String
        var screen: ScreenDescription
        var reference: ActionReference
    }
    private var observations: [String: Observation] = [:]
    private var order: [String] = []

    func save(_ observation: Observation) {
        let id = observation.screen.frameID
        observations[id] = observation
        order.append(id)
        while order.count > 64 { observations[order.removeFirst()] = nil }
    }

    func reference(_ id: String, phoneID: String) throws -> Observation {
        guard let observation = observations[id], observation.phoneID == phoneID else {
            throw PhoneServiceError.failed("STALE_FRAME: Frame is unknown, consumed, or belongs to another phone. Describe the screen again.")
        }
        return observation
    }

    func invalidate(_ phoneID: String) {
        let ids = observations.filter { $0.value.phoneID == phoneID }.map(\.key)
        for id in ids { observations[id] = nil }
        order.removeAll { ids.contains($0) }
    }
}
