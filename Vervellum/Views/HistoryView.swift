import SwiftUI

/// Earlier threads, searchable.
///
/// Research is worth keeping precisely because the expensive part is the evidence:
/// re-asking a question costs another set of searches and another model call, and
/// gets a slightly different answer. So threads persist by default and are reopened
/// whole — questions, answers, verdicts and sources — rather than summarised.
struct HistoryView: View {

    @Environment(\.panelTextScale) private var textScale

    @ObservedObject var store: ThreadStore
    var onOpen: (ResearchThread) -> Void
    /// Deletion is the root view's, not the store's alone: the thread may be the one
    /// the engine is showing, and only the root view can take it out of both.
    var onDelete: (ResearchThread) -> Void
    var onClose: () -> Void

    @State private var query = ""

    private var results: [ResearchThread] { store.library.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(PanelTheme.Palette.hairline)
            if store.library.threads.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: PanelTheme.Space.small) {
            Image(systemName: "magnifyingglass")
                .font(PanelTheme.Font.at(10, textScale))
                .foregroundStyle(PanelTheme.Palette.tertiaryText)
            TextField("Search earlier threads", text: $query)
                .textFieldStyle(.plain)
                .font(PanelTheme.Font.body(textScale))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PanelTheme.Font.at(10, textScale))
                        .foregroundStyle(PanelTheme.Palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PanelTheme.Space.medium)
        .padding(.vertical, PanelTheme.Space.small)
    }

    private var emptyState: some View {
        VStack(spacing: PanelTheme.Space.small) {
            Spacer()
            Text(store.isHistoryEnabled ? "No threads yet." : "History is turned off.")
                .font(PanelTheme.Font.body(textScale))
                .foregroundStyle(PanelTheme.Palette.secondaryText)
            if !store.isHistoryEnabled {
                Text("Turn it on in Settings ▸ General to keep past research.")
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { thread in
                    HistoryRow(thread: thread,
                               onOpen: { onOpen(thread) },
                               onDelete: { onDelete(thread) })
                }
                if results.isEmpty {
                    Text("Nothing matches “\(query)”.")
                        .font(PanelTheme.Font.caption(textScale))
                        .foregroundStyle(PanelTheme.Palette.tertiaryText)
                        .padding(PanelTheme.Space.large)
                }
            }
            .padding(.vertical, PanelTheme.Space.small)
        }
    }
}

/// One thread in the history list.
private struct HistoryRow: View {
    @Environment(\.panelTextScale) private var textScale

    let thread: ResearchThread
    var onOpen: () -> Void
    var onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: PanelTheme.Space.small) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(PanelTheme.Font.at(12, textScale, weight: .medium))
                        .foregroundStyle(PanelTheme.Palette.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(PanelTheme.Font.at(10.5, textScale))
                        .foregroundStyle(PanelTheme.Palette.tertiaryText)
                }
                Spacer(minLength: 0)
                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(PanelTheme.Font.at(10, textScale))
                            .foregroundStyle(PanelTheme.Palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this thread")
                }
            }
            .padding(.horizontal, PanelTheme.Space.medium)
            .padding(.vertical, PanelTheme.Space.small)
            .background(isHovering ? PanelTheme.Palette.chipFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        let turns = "\(thread.turns.count) turn\(thread.turns.count == 1 ? "" : "s")"
        return "\(turns) · \(Self.formatter.localizedString(for: thread.updatedAt, relativeTo: Date()))"
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
