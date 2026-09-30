import Foundation

@main enum HIDSessionTests {
    static func main() {
        var phone = HIDSession()
        let record = SDPRecord.buildHID(reportDescriptor: HIDProfile.reportMapData,
            name: "Test", serviceDescription: "Test", providerName: "Test")
        let languages = record["0207 - HIDLANGIDBaseList"] as? [[[String: Any]]]
        precondition(languages?.count == 1 && languages?.first?.count == 2)
        precondition(phone.receive(Data()) == nil)
        precondition(phone.receive(Data([0x41])) == Data([4]))
        precondition(phone.receive(Data([0x41, 99])) == Data([2]))
        precondition(phone.receive(Data([0x42, 1])) == Data([3]))
        precondition(phone.receive(Data([0x41, 2])) == Data([0xA1, 2] + Array(repeating: 0, count: 8)))
        let mouse = MouseReport(dX: -10, dY: 20).data
        precondition(phone.input(mouse, reportID: .mouse) == Data([0xA1, 1, 0, 246, 20, 0]))
        precondition(phone.receive(Data([0x41, 1])) == Data([0xA1, 1]) + mouse)
        precondition(phone.receive(Data([0x49, 1, 2, 0])) == Data([0xA1, 1, 0]))
        precondition(phone.receive(Data([0x49, 1])) == Data([4]))
        precondition(phone.receive(Data([0x60])) == Data([0xA0, 1]))
        precondition(phone.receive(Data([0x70])) == Data([3]))
        precondition(phone.receive(Data([0x71])) == Data([0]))
        precondition(phone.receive(Data([0x52, 3, 255])) == Data([0]))
        precondition(phone.keyboardLEDs == 31)
        precondition(phone.receive(Data([0x52, 3])) == Data([4]))
        precondition(phone.receive(Data([0x90])) == Data([4]))
        precondition(phone.receive(Data([0x90, 7])) == Data([0]))
        precondition(phone.receive(Data([0x80])) == Data([0xA0, 7]))
        var otherPhone = HIDSession()
        precondition(otherPhone.keyboardLEDs == 0)
        precondition(otherPhone.receive(Data([0x41, 1])) == Data([0xA1, 1, 0, 0, 0, 0]))
        print("PASS: HID report framing, control negotiation, malformed requests, per-phone isolation")
    }
}
