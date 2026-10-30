import SwiftUI

// PLAN_OBJECTIVE_LIFECYCLE L1–L2: the shared pieces of completing, reopening and deleting an objective.

private let completedDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

extension Catalog.Objective {
    /// `completed 28 Oct` for the pill on a done card or pane.
    var completedLabel: String? { completedAt.map { "completed \(completedDay.string(from: $0))" } }
}

/// The Complete / Reopen pill (§3.3): `.ok` with a check while open, a neutral `reopen` once done; during a session on the
/// objective it reads *complete when this session ends* (§5a Q2), and *stays open* undoes that.
struct CompletePill: View {
    @Environment(Store.self) private var store
    let objective: Objective
    var accent: Color = Theme.accent
    var body: some View {
        let o = objective
        if store.completeOnEnd == o.id {
            PillButton(text: "completes when this session ends · keep open", kind: .warn) { store.reopen(o.id) }
        } else if o.isDone {
            PillButton(text: "reopen", kind: .neutral) { store.reopen(o.id) }
        } else if store.session?.objectiveId == o.id {
            PillButton(text: "complete when this session ends", kind: .ok) { store.complete(o.id) }
        } else {
            PillButton(text: "✓ complete", kind: .ok) { store.complete(o.id) }
        }
    }
}

/// The delete confirmation (§3.4, §5a Q5): names the sessions and hours that stay in the log and return to the inbox.
struct DeleteObjectiveConfirm: ViewModifier {
    @Environment(Store.self) private var store
    let objective: Objective
    @Binding var isPresented: Bool
    var after: () -> Void = {}
    func body(content: Content) -> some View {
        let cost: (sessions: Int, seconds: Int) = isPresented ? store.deleteCost(objective.id) : (0, 0)
        content.confirmationDialog("Delete “\(objective.title)”?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Delete objective", role: .destructive) { store.deleteObjective(objective.id); store.show("objective deleted"); after() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if cost.sessions == 0 { Text("No sessions were logged for it. This cannot be undone.") }
            else { Text("Its \(cost.sessions) session\(cost.sessions == 1 ? "" : "s") (\(minutes(TimeInterval(cost.seconds)))) stay in the log and still count in Stats and History; they just lose this name and go back to the Unsorted inbox. This cannot be undone.") }
        }
    }
}

extension View {
    func deleteObjectiveConfirm(_ o: Objective, isPresented: Binding<Bool>, after: @escaping () -> Void = {}) -> some View {
        modifier(DeleteObjectiveConfirm(objective: o, isPresented: isPresented, after: after))
    }
}
