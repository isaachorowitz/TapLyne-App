import Foundation
import TaplyneServer

extension PhoneDriver {
    /// Paste the complete Unicode string so the active iPhone keyboard layout cannot transliterate it.
    /// Newlines are pasted, never emitted as Enter or Tab that could submit or leave a form.
    func typeVerified(_ text: String, replace: Bool) async throws -> Verification {
        guard text.count <= 1000 else { throw PhoneServiceError.invalidArgument("Text must be at most 1000 characters.") }
        let baseline = try await textBaseline()
        return try await ClipboardBridge.shared.transaction { lease in
            try lease.write(text)
            try await self.sleep(ms: self.profile.clipboardSyncMs)
            try lease.checkOwned()
            try await self.validateTextTarget(baseline)
            if replace { try await self.keyStroke(.a, modifiers: .leftGUI) }
            if replace && text.isEmpty { try await self.keyStroke(.backspace) }
            else { try await self.keyStroke(.v, modifiers: .leftGUI) }
            try await self.sleep(ms: 450)
            let sentinel = "taplyne-readback-\(UUID().uuidString)"
            try lease.write(sentinel)
            try await self.sleep(ms: self.profile.clipboardSyncMs)
            try lease.checkOwned()
            try await self.keyStroke(.a, modifiers: .leftGUI)
            try await self.keyStroke(.c, modifiers: .leftGUI)
            let copied = try await lease.receive(excluding: sentinel, timeoutMs: 2500)
            // Collapse selection without Enter, deletion or another paste.
            try await self.keyStroke(.rightArrow)
            guard let copied else {
                return Verification(.unverified, method: "clipboard_readback",
                                    detail: "Text was pasted once, but readback is unavailable. Check the field; do not repeat the paste automatically. Universal Clipboard requires Handoff and the same Apple Account.")
            }
            let passed = replace ? copied == text : copied.contains(text)
            return Verification(passed ? .verified : .failed, method: replace ? "exact_clipboard_readback" : "clipboard_fragment_readback",
                                detail: passed ? (replace ? "The focused field exactly matches the requested Unicode text." : "The focused field contains the exact Unicode text; insertion position was not checked.")
                                : "The field does not match the requested text. Nothing was resubmitted or pasted again.")
        }
    }
}
