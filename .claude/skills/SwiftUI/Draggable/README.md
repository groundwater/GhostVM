---
name: Draggable
description: Implement drag and drop in SwiftUI with List editActions or Transferable. Use when adding list reordering (iOS 18+) or drag between containers with .draggable/.dropDestination. (project)
---

# Drag and Drop

### For Reordering Within a List:

- iOS 18+

```swift
struct ConnectionListView: View {
    @Binding var connections: [Connection]

    var body: some View {
        List($connections, editActions: .move) { $connection in
            ConnectionRowView(connection: connection)
        }
    }
}
```

That's it. No delegates, no manual move logic. SwiftUI handles everything.

---

### For Drag Between Containers or Custom Layouts:

**1. Make your type Transferable:**
```swift
struct Connection: Codable, Transferable, Identifiable {
    let id: UUID
    var name: String
    // ... rest of your properties

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .connection)
    }
}

extension UTType {
    static var connection = UTType(exportedAs: "com.yourapp.connection")
}
```

**2. Use `.draggable()` and `.dropDestination()`:**
```swift
struct ConnectionListView: View {
    @State private var connections: [Connection] = []

    var body: some View {
        ForEach(connections) { connection in
            ConnectionRowView(connection: connection)
                .draggable(connection)
        }
        .dropDestination(for: Connection.self) { items, location in
            // Handle drop - reorder, move between lists, etc.
            return true
        }
    }
}
```
