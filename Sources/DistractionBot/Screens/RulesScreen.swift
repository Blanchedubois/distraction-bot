import SwiftUI

/// The Rules tab (PLAN_STRUCTURE §3.2, M1): Apps + Websites in one page — 1 Apps · 2 Sites · 3 Searches · 4 Allowed.
/// Each section is the old tab's body lifted as a sub-view (`AppsView`, `WebsitesView` keep their files and names so the
/// catcher plan's additive rows survive); the page head carries one filter field for the app and site rows.
struct RulesScreen: View {
    @State private var query = ""

    var body: some View {
        Page(kicker: "what is blocked · what is judged · what is always work", title: "Rules", trailing: AnyView(PillField(placeholder: "filter", text: $query))) {
            AppsView(filter: query)
            WebsitesView(filter: query)
        }
    }
}
