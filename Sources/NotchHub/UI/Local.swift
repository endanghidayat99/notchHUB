import SwiftUI

/// Drop-in replacement for `@State` that does not rely on the `SwiftUIMacros` compiler plugin
/// (missing when building with Command Line Tools against newer SDKs, where `@State` is a macro).
/// It stores a plain `State` value, which SwiftUI discovers through `DynamicProperty`.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let state: State<Value>

    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
