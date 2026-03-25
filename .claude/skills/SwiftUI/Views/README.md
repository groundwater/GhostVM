---
name: SwiftUI
description: Build SwiftUI apps with MVVM and @Observable. Use when implementing views, viewmodels, or state management. Views are functions of state, ViewModels hold logic. (project)
---

# SwiftUI

MVVM with `@Observable`. Views are functions of state.

## Architecture

| Component | Type | Role |
|-----------|------|------|
| Model | `struct`, Codable | Data only, no logic |
| View | `struct: View` | Render UI, forward actions |
| ViewModel | `@Observable class` | State + logic |
| Service | `@Observable class` | Long-lived resources (network, hardware) |

## @Observable

Use `@Observable`, not `ObservableObject`:

```swift
@MainActor
@Observable
class ItemListViewModel {
    private(set) var items: [Item] = []
    private(set) var isLoading = false

    private let repository: ItemRepository

    init(repository: ItemRepository) {
        self.repository = repository
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        items = try! await repository.fetchAll()
    }
}
```

- No `@Published` needed - SwiftUI tracks automatically
- Use `private(set)` for read-only state
- Always `@MainActor` for UI-bound ViewModels

## Views

```swift
struct ItemListView: View {
    var viewModel: ItemListViewModel  // Plain property, no wrapper

    var body: some View {
        List(viewModel.items) { Text($0.name) }
            .task { await viewModel.load() }
    }
}
```

Views own ViewModels with `@State`:

```swift
struct ContentView: View {
    @State private var viewModel = ItemListViewModel(repository: repo)

    var body: some View {
        ItemListView(viewModel: viewModel)
    }
}
```

## @Bindable

For two-way binding to `@Observable`:

```swift
struct EditItemView: View {
    @Bindable var item: Item  // Item is @Observable

    var body: some View {
        TextField("Name", text: $item.name)
    }
}
```

## State Ownership

| Wrapper | Use |
|---------|-----|
| `@State` | View-local values, view-owned @Observable |
| `@Bindable` | Two-way binding to @Observable from parent |
| `@Binding` | Two-way binding to parent's @State primitive |
| Plain property | Read-only @Observable from parent |

One owner per piece of state. Owner uses `@State`, children receive value or binding.

## When to Skip ViewModel

Simple screens can use `@State` directly:

```swift
struct SettingsView: View {
    @AppStorage("notifications") var notifications = true

    var body: some View {
        Toggle("Notifications", isOn: $notifications)
    }
}
```

Use ViewModel when you need: async ops, business logic, dependency injection, multiple related state.

## Don't

- Put logic in Views
- Put UI code in ViewModels
- Skip `@MainActor` on ViewModels
- Use `@Published` with `@Observable`
- Use `@StateObject`/`@ObservedObject` (old pattern)
- Call async methods in `body` (use `.task`)
- Nest NavigationStacks
