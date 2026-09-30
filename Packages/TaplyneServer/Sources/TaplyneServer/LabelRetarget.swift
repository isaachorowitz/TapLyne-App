import Foundation

/// Conservative page identity check for refreshing a named target after layout motion.
enum LabelRetarget {
    static func samePage(_ before: ScreenDescription, _ after: ScreenDescription) -> Bool {
        guard before.width == after.width, before.height == after.height else { return false }
        func anchors(_ screen: ScreenDescription) -> Set<String> {
            Set(screen.elements.filter { $0.confidence >= 0.6 }.map { ScreenDescription.normalized($0.text) }
                .filter { $0.count >= 3 && $0.unicodeScalars.contains(where: CharacterSet.letters.contains) })
        }
        let old = anchors(before), new = anchors(after)
        let shared = old.intersection(new).count
        // Several independent labels must agree. A repeated Save/Back button
        // on a different page is not enough to justify a click.
        return shared >= 4 && Double(shared) / Double(max(old.count, new.count)) >= 0.8
    }
}
