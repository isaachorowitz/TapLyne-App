// Vendored from jqssun/darwin-bt-remote (commit ad7a76c, BTRemote/Classic), AGPL-3.0-only.
// See LICENSE-AGPL-3.0 in this folder. Taplyne changes: nest HID language entries per HID Profile 1.1.

#if os(macOS)
    import Foundation

    /// keys carry the SDP attribute ID as the first 4 hex digits; suffix is informational
    enum SDPRecord {
        /// HID combo (keyboard + mouse) classic Bluetooth service record (same descriptor as low energy HID)
        static func buildHID(
            reportDescriptor: Data,
            name: String,
            serviceDescription: String,
            providerName: String
        ) -> [String: Any] {
            [
                "0000 - ServiceRecordHandle": 65536 as NSNumber,
                "0001 - ServiceClassIDList": [
                    _uuid16(0x1124)
                ],

                // L2CAP/PSM=0x0011: HIDP (control channel)
                "0004 - ProtocolDescriptorList": [
                    [
                        _uuid16(0x0100),
                        _uint(value: 0x0011, byteCount: 2)
                    ],
                    [
                        _uuid16(0x0011)
                    ]
                ],

                "0005 - BrowseGroupList": [
                    _uuid16(0x1002)
                ],

                // LANGID English, charset UTF-8 (0x006A), base attribute ID 0x0100
                "0006 - LanguageBaseAttributeIDList": [
                    _uint(value: 0x656E, byteCount: 2),
                    _uint(value: 0x006A, byteCount: 2),
                    _uint(value: 0x0100, byteCount: 2)
                ],

                // BluetoothProfileDescriptorList: HID profile v1.1
                "0009 - BluetoothProfileDescriptorList": [
                    [
                        _uuid16(0x1124),
                        _uint(value: 0x0101, byteCount: 2)
                    ]
                ],

                // L2CAP/PSM=0x0013: HIDP (interrupt channel)
                "000D - AdditionalProtocolDList": [
                    [
                        [
                            _uuid16(0x0100),
                            _uint(value: 0x0013, byteCount: 2)
                        ],
                        [
                            _uuid16(0x0011)
                        ]
                    ]
                ],

                "0100 - ServiceName": name,
                "0101 - ServiceDescription": serviceDescription,
                "0102 - ProviderName": providerName,

                "0201 - HIDParserVersion": _uint(value: 0x0111, byteCount: 2),
                // HIDDeviceSubclass 0xC0: combo keyboard + pointing device
                "0202 - HIDDeviceSubclass": _uint(value: 0xC0, byteCount: 1),
                // HIDCountryCode 0x21: US
                "0203 - HIDCountryCode": _uint(value: 0x21, byteCount: 1),
                "0204 - HIDVirtualCable": true,
                "0205 - HIDReconnectInitiate": true,

                // HIDDescriptorList: [ [<descriptorType=0x22>, <descriptor bytes>] ]
                "0206 - HIDDescriptorList": [
                    [
                        _uint(value: 0x22, byteCount: 1),
                        _text(reportDescriptor)
                    ]
                ],

                // HIDLANGIDBaseList: en-US (base attribute 0x0100)
                "0207 - HIDLANGIDBaseList": [
                    [
                        _uint(value: 0x0409, byteCount: 2),
                        _uint(value: 0x0100, byteCount: 2)
                    ]
                ],

                "0209 - HIDBatteryPower": true,
                "020A - HIDRemoteWake": true,
                "020B - HIDProfileVersion": _uint(value: 0x0100, byteCount: 2),
                "020C - HIDSupervisionTimeout": _uint(value: 0x1F40, byteCount: 2),
                "020D - HIDNormallyConnectable": true,
                "020E - HIDBootDevice": true
            ]
        }

        /// unsigned integer: type=1, value stored big-endian in N bytes
        private static func _uint(value: UInt32, byteCount: Int) -> [String: Any] {
            var data = Data()
            switch byteCount {
            case 1: data.append(UInt8(value & 0xFF))
            case 2: data.append(contentsOf: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
            case 4: data.append(contentsOf: [
                    UInt8((value >> 24) & 0xFF),
                    UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF),
                    UInt8(value & 0xFF)
                ])
            default: fatalError("unsupported uint byteCount")
            }
            // DataElementSize=0: natural size inferred from value length
            return [
                "DataElementSize": 0,
                "DataElementType": 1,
                "DataElementValue": data
            ]
        }

        private static func _uuid16(_ value: UInt16) -> Data {
            Data([UInt8(value >> 8), UInt8(value & 0xFF)])
        }

        private static func _text(_ bytes: Data) -> [String: Any] {
            [
                "DataElementType": 4,
                "DataElementValue": bytes
            ]
        }
    }
#endif
