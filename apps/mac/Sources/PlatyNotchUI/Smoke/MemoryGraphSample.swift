import PlatyNotchKit

/// A made-up week of memory for renders: three apps, their pages and documents, two
/// sites and two open loops (one whose thread was purged, so it hangs off its app).
enum MemoryGraphSample {
    static let week: MemoryGraph = {
        let nodes: [GraphNode] = [
            GraphNode(id: "app:safari", kind: "app", label: "Safari", weight: 24),
            GraphNode(id: "app:mail", kind: "app", label: "Mail", weight: 14),
            GraphNode(id: "app:notes", kind: "app", label: "Notes", weight: 9),
            GraphNode(id: "app:slack", kind: "app", label: "Slack", weight: 8),
            GraphNode(id: "site:github.com", kind: "site", label: "github.com", weight: 14),
            GraphNode(id: "loop:deck", kind: "loop", label: "Send Sam the budget deck", weight: 7),
            GraphNode(id: "t-pr", kind: "thread", label: "Fix the flaky panel test · Pull Request #212", weight: 8),
            GraphNode(id: "t-inbox", kind: "thread", label: "Inbox — Lisbon offsite", weight: 7),
            GraphNode(id: "t-issues", kind: "thread", label: "Issues · platynotch", weight: 6),
            GraphNode(id: "t-budget", kind: "thread", label: "Budget 2027", weight: 6),
            GraphNode(id: "site:docs.google.com", kind: "site", label: "docs.google.com", weight: 6),
            GraphNode(id: "t-sam", kind: "thread", label: "Sam (DM)", weight: 5),
            GraphNode(id: "t-reply", kind: "thread", label: "Re: Venue options", weight: 4),
            GraphNode(id: "t-ideas", kind: "thread", label: "Ideas", weight: 4),
            GraphNode(id: "t-team", kind: "thread", label: "#team", weight: 3),
            GraphNode(id: "t-groceries", kind: "thread", label: "Groceries", weight: 3),
            GraphNode(id: "t-ci", kind: "thread", label: "Actions · CI run 4411", weight: 2),
            GraphNode(id: "t-mdn", kind: "thread", label: "Canvas — MDN", weight: 2),
            GraphNode(id: "site:developer.mozilla.org", kind: "site", label: "developer.mozilla.org", weight: 2),
            GraphNode(id: "loop:venue", kind: "loop", label: "Book the venue by Friday", weight: 1),
        ]
        let edges: [GraphEdge] = [
            GraphEdge(from: "app:safari", to: "t-pr", kind: "in", weight: 8),
            GraphEdge(from: "app:safari", to: "t-issues", kind: "in", weight: 6),
            GraphEdge(from: "app:safari", to: "t-budget", kind: "in", weight: 6),
            GraphEdge(from: "app:safari", to: "t-ci", kind: "in", weight: 2),
            GraphEdge(from: "app:safari", to: "t-mdn", kind: "in", weight: 2),
            GraphEdge(from: "app:mail", to: "t-inbox", kind: "in", weight: 7),
            GraphEdge(from: "app:mail", to: "t-reply", kind: "in", weight: 4),
            GraphEdge(from: "app:notes", to: "t-ideas", kind: "in", weight: 4),
            GraphEdge(from: "app:notes", to: "t-groceries", kind: "in", weight: 3),
            GraphEdge(from: "app:slack", to: "t-sam", kind: "in", weight: 5),
            GraphEdge(from: "app:slack", to: "t-team", kind: "in", weight: 3),
            GraphEdge(from: "t-pr", to: "site:github.com", kind: "on", weight: 8),
            GraphEdge(from: "t-issues", to: "site:github.com", kind: "on", weight: 6),
            GraphEdge(from: "t-ci", to: "site:github.com", kind: "on", weight: 2),
            GraphEdge(from: "t-budget", to: "site:docs.google.com", kind: "on", weight: 6),
            GraphEdge(from: "t-mdn", to: "site:developer.mozilla.org", kind: "on", weight: 2),
            GraphEdge(from: "loop:deck", to: "t-sam", kind: "detected_in", weight: 7),
            GraphEdge(from: "loop:venue", to: "app:mail", kind: "from_app", weight: 1),
            GraphEdge(from: "t-pr", to: "t-issues", kind: "together", weight: 5),
            GraphEdge(from: "t-budget", to: "t-sam", kind: "together", weight: 4),
            GraphEdge(from: "t-inbox", to: "t-reply", kind: "together", weight: 3),
            GraphEdge(from: "t-pr", to: "t-ci", kind: "together", weight: 2),
        ]
        return MemoryGraph(nodes: nodes, edges: edges)
    }()
}
