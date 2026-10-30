import SwiftUI

/// HUD4 (PLAN_SESSION_HUD §3.4): the queued session's tasks, set before the start — one line per Return, up to 8, a ✕ on each.
/// A queued objective arrives with the tasks it was left with last time. Shown in the Current Session card's queued state.
struct QueuedTasks: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        let tasks = store.queued?.tasks ?? []
        VStack(alignment: .leading, spacing: Space.tight) {
            MonoLabel(tasks.isEmpty ? "tasks for this session · optional" : "tasks · \(tasks.count)", color: Theme.muted)
            ForEach(Array(tasks.enumerated()), id: \.offset) { i, t in
                HStack(spacing: Space.stack) {
                    Icon("square", .small, color: Theme.muted)
                    Text(t).font(Type.body).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button { store.removeQueuedTask(at: i) } label: { Icon("xmark", .tiny, color: Theme.muted2) }.buttonStyle(.plain).accessibilityLabel("Remove \(t)")
                }
            }
            if tasks.count < SessionTasks.maxTasks {
                HStack(spacing: Space.stack) {
                    Icon("plus", .small, color: Theme.muted)
                    if snapshot { Text("add a task · return adds it").font(Type.body).foregroundStyle(Theme.muted2) }
                    else {
                        TextField("add a task · return adds it", text: $draft)
                            .textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink)
                            .focused($focused)
                            .onSubmit { store.addQueuedTask(draft); draft = ""; focused = true }
                    }
                }
            }
        }
    }
}
