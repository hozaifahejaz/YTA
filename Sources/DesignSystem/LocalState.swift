import Combine
import SwiftUI

/// View-local state without SwiftUI's `@State`.
///
/// From the macOS 27 SDK on, `@State` is a macro whose plugin ships only with Xcode,
/// so it does not compile with the Command Line Tools. Views keep their local values in
/// this box instead: `@StateObject private var hovering = LocalState(false)`, then read
/// `hovering.value` and bind `$hovering.value`. Do not use SwiftUI's State, Entry,
/// Animatable or Preview macros anywhere in YTA. CI fails if they appear.
@MainActor
public final class LocalState<Value>: ObservableObject {
    @Published public var value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
