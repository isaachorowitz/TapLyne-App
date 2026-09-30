import Foundation

/// HIDP control state is per phone, including the last report and LED state.
struct HIDSession {
    private(set) var reports: [UInt8: Data] = [
        ReportID.mouse.rawValue: MouseReport.zero.data,
        ReportID.keyboard.rawValue: KeyboardReport.zero.data,
        ReportID.systemControl.rawValue: SystemControlReport.zero.data,
        ReportID.consumerControl.rawValue: ConsumerReport.zero.data
    ]
    private(set) var keyboardLEDs: UInt8 = 0
    private var idle: UInt8 = 0

    mutating func input(_ payload: Data, reportID: ReportID) -> Data {
        reports[reportID.rawValue] = payload
        return Data([0xA1, reportID.rawValue]) + payload
    }

    /// Returns a control-channel reply. Nil means the message has no reply.
    mutating func receive(_ packet: Data) -> Data? {
        let bytes = Array(packet)
        guard let header = bytes.first else { return nil }
        switch header & 0xF0 {
        case 0x00, 0x10: return nil
        case 0x40: // GET_REPORT, optional little-endian buffer size
            guard header & 3 == 1 else { return Data([3]) }
            guard bytes.count >= 2 else { return Data([4]) }
            guard let payload = reports[bytes[1]] else { return Data([2]) }
            var report = Data([bytes[1]]) + payload
            if header & 8 != 0 {
                guard bytes.count >= 4 else { return Data([4]) }
                report = Data(report.prefix(Int(bytes[2]) | Int(bytes[3]) << 8))
            }
            return Data([0xA1]) + report
        case 0x50, 0xA0: // SET_REPORT or unsolicited output DATA
            guard header & 3 == 2, bytes.count == 3,
                  bytes[1] == ReportID.keyboardLEDs.rawValue else {
                return header & 0xF0 == 0x50 ? Data([4]) : nil
            }
            keyboardLEDs = bytes[2] & 0x1F
            return header & 0xF0 == 0x50 ? Data([0]) : nil
        case 0x60: return Data([0xA0, 1]) // GET_PROTOCOL: report mode
        case 0x70: return Data([header & 0x0F == 1 ? 0 : 3]) // boot mode is not advertised
        case 0x80: return Data([0xA0, idle])
        case 0x90:
            guard bytes.count == 2 else { return Data([4]) }
            idle = bytes[1]
            return Data([0])
        default: return Data([3])
        }
    }
}
