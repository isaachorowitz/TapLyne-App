# Argent integration

Taplyne's REST and MCP tools provide a USB capture and Bluetooth HID transport for a real iPhone. Argent's physical iPhone automation uses its own on-device runner and app-scoped APIs. The inspected Argent distribution has no custom device-transport registration for Taplyne.

An agent can connect to both MCP servers today. It chooses Taplyne to describe the current screen, tap a label, fill a field, navigate or hand control back. It chooses Argent for a supported test application, simulator or device workflow. Running both MCP servers does not make Taplyne a native Argent device.

Native integration would need an Argent transport extension:

| Argent operation | Taplyne capability | Limit |
|---|---|---|
| Device listing | `list_phones` | Connected real iPhones only |
| Screenshot | `screenshot` | USB capture and a fresh frame reference |
| Description | `describe_screen` | OCR text and bounds, without native accessibility roles |
| Tap | `tap_label` or `tap` | Current frame required; pointer feedback may reject aiming |
| Text | `fill_field` or `type_text` | English uses HID; experimental Unicode paste uses Universal Clipboard; verification remains explicit |
| Navigation | `navigate` or `open_app` | Visible UI, with app-dependent results |
| Wait | `wait_for_text` | Visible OCR condition |
| Pause | `control_phone` | Cancels queued input and invalidates frames; resume is human-only in the Mac UI |

The frame reference and verification contract must survive an adapter. Mapping a successful HTTP response to a successful test would lose the distinction between input delivery and a checked result. Taplyne cannot provide native component trees, app-internal debugging or all Argent gestures from pixels and HID.

No changes to the installed Argent package or its device registry are included in this release. A native extension needs support from Argent's integration surface; Taplyne's existing APIs are ready for a separate adapter when that surface is available.
