import Foundation

/// Encodes Bluetooth SDP service records in the wire format bluetoothd stores
/// (a data element sequence of attribute ID and value pairs, Core spec Vol 3 Part B).
enum SDPElement {
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uuid16(UInt16)
    case text(Data)
    case bool(Bool)
    case sequence([SDPElement])

    var encoded: Data {
        switch self {
        case let .uint8(v): return Data([0x08, v])
        case let .uint16(v): return Data([0x09, UInt8(v >> 8), UInt8(v & 0xFF)])
        case let .uint32(v): return Data([0x0A, UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        case let .uuid16(v): return Data([0x19, UInt8(v >> 8), UInt8(v & 0xFF)])
        case let .bool(v): return Data([0x28, v ? 1 : 0])
        case let .text(bytes): return Self.withLength(typeBits: 4 << 3, body: bytes)
        case let .sequence(items): return Self.withLength(typeBits: 6 << 3, body: items.reduce(into: Data()) { $0.append($1.encoded) })
        }
    }

    private static func withLength(typeBits: UInt8, body: Data) -> Data {
        var out = Data()
        if body.count < 256 {
            out.append(typeBits | 5)
            out.append(UInt8(body.count))
        } else {
            out.append(typeBits | 6)
            out.append(UInt8(body.count >> 8))
            out.append(UInt8(body.count & 0xFF))
        }
        out.append(body)
        return out
    }
}

enum SDPEncoder {
    /// A record: attribute ID to value, emitted in ascending attribute order.
    static func record(_ attributes: [UInt16: SDPElement]) -> Data {
        let pairs = attributes.keys.sorted().flatMap { [SDPElement.uint16($0), attributes[$0]!] }
        return SDPElement.sequence(pairs).encoded
    }

    /// The HID keyboard-and-mouse record: control on PSM 0x11, interrupt on 0x13.
    static func hidRecord(reportDescriptor: Data, name: String) -> Data {
        let l2cap: UInt16 = 0x0100, hidp: UInt16 = 0x0011, hidService: UInt16 = 0x1124
        return record([
            0x0001: .sequence([.uuid16(hidService)]),
            0x0004: .sequence([
                .sequence([.uuid16(l2cap), .uint16(0x0011)]),
                .sequence([.uuid16(hidp)])
            ]),
            0x0005: .sequence([.uuid16(0x1002)]),
            0x0006: .sequence([.uint16(0x656E), .uint16(0x006A), .uint16(0x0100)]),
            0x0009: .sequence([.sequence([.uuid16(hidService), .uint16(0x0101)])]),
            0x000D: .sequence([.sequence([
                .sequence([.uuid16(l2cap), .uint16(0x0013)]),
                .sequence([.uuid16(hidp)])
            ])]),
            0x0100: .text(Data(name.utf8)),
            0x0101: .text(Data("Keyboard and mouse".utf8)),
            0x0102: .text(Data("Taplyne".utf8)),
            0x0201: .uint16(0x0111),
            0x0202: .uint8(0xC0),
            0x0203: .uint8(0x21),
            0x0204: .bool(true),
            0x0205: .bool(true),
            0x0206: .sequence([.sequence([.uint8(0x22), .text(reportDescriptor)])]),
            0x0207: .sequence([.sequence([.uint16(0x0409), .uint16(0x0100)])]),
            0x0209: .bool(true),
            0x020A: .bool(true),
            0x020B: .uint16(0x0100),
            0x020C: .uint16(0x1F40),
            0x020D: .bool(true),
            0x020E: .bool(true)
        ])
    }
}
