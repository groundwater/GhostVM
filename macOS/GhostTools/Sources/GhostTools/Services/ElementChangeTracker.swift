import Foundation

/// Tracks accessibility element changes across snapshots.
/// Each element gets a `changeAge` (0 = just changed/new, 1+ = stable).
final class ElementChangeTracker {
    static let shared = ElementChangeTracker()
    private init() {}

    /// Identity key: role + frame rounded to 4px grid
    private struct Fingerprint: Hashable {
        let role: String
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    /// Tracked properties for change detection
    private struct TrackedState {
        let label: String?
        let title: String?
        let value: String?
        var age: Int
    }

    private var previous: [Fingerprint: TrackedState] = [:]

    /// Track elements and return a map of elementId -> changeAge.
    /// changeAge 0 = new/changed, 1+ = stable (capped at 255).
    func track(_ elements: [AccessibilityService.InteractiveElement]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var current: [Fingerprint: TrackedState] = [:]

        for elem in elements {
            let fp = Fingerprint(
                role: elem.role,
                x: roundTo4(elem.frame.x),
                y: roundTo4(elem.frame.y),
                w: roundTo4(elem.frame.width),
                h: roundTo4(elem.frame.height)
            )

            if let prev = previous[fp],
               prev.label == elem.label,
               prev.title == elem.title,
               prev.value == elem.value {
                // Same element, same properties — stable
                let newAge = min(prev.age + 1, 255)
                result[elem.id] = newAge
                current[fp] = TrackedState(
                    label: elem.label,
                    title: elem.title,
                    value: elem.value,
                    age: newAge
                )
            } else {
                // New or changed element
                result[elem.id] = 0
                current[fp] = TrackedState(
                    label: elem.label,
                    title: elem.title,
                    value: elem.value,
                    age: 0
                )
            }
        }

        previous = current
        return result
    }

    func reset() {
        previous = [:]
    }

    private func roundTo4(_ value: Double) -> Int {
        Int((value / 4.0).rounded()) * 4
    }
}
