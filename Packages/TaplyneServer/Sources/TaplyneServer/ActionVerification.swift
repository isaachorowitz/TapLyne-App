import Foundation

enum ActionVerification {
    static func evaluate(_ expectation: ActionExpectation, before: ScreenImage, after: ScreenImage,
                         description: ScreenDescription, receipt: InputReceipt, beforeDescription: ScreenDescription? = nil) -> Verification {
        if receipt.textVerification?.status == .failed { return receipt.textVerification! }
        let changed = ScreenComparison.changed(before.image, after.image)
        if !expectation.isEmpty {
            if [expectation.textPresent, expectation.textAbsent].compactMap({ $0 }).contains(where: { !description.canVerifyText($0) }) {
                return Verification(.unverified, method: "ocr", detail: "Text recognition is incomplete. Inspect the returned screen.")
            }
            let text = ScreenDescription.normalized(description.text)
            let present = expectation.textPresent.map { text.contains(ScreenDescription.normalized($0)) } ?? true
            let absent = expectation.textAbsent.map { !text.contains(ScreenDescription.normalized($0)) } ?? true
            let image = expectation.screenChanged.map { $0 == changed } ?? true
            let passed = present && absent && image
            if passed, let beforeDescription {
                let oldText = ScreenDescription.normalized(beforeDescription.text)
                let wasPresent = expectation.textPresent.map { oldText.contains(ScreenDescription.normalized($0)) } ?? true
                let wasAbsent = expectation.textAbsent.map { !oldText.contains(ScreenDescription.normalized($0)) } ?? true
                let transitionRequested = expectation.screenChanged == true
                if wasPresent && wasAbsent && !transitionRequested {
                    return Verification(.unverified, method: "already_satisfied", detail: "The condition held before input, so it does not prove this action achieved its result.")
                }
            }
            return Verification(passed ? .verified : .failed, method: "expectation",
                                detail: passed ? "The requested screen conditions are visible." : "The requested result was not observed. Input was not repeated.")
        }
        if let verification = receipt.textVerification { return verification }
        return Verification(.unverified, method: "screen_comparison",
                            detail: changed ? "The screen changed. Supply an expectation to verify the intended result." : "The screen did not visibly change. Input was not repeated.")
    }
}
