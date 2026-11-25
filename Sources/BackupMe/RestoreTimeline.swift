import BackupCore
import RestoreRules
import SwiftUI

/// The sidebar: how the last backup went, then every backup as a point on a vertical line.
struct RestoreTimeline: View {
    let model: RestoreModel
    /// Every backup, newest first, with what is known about it.
    let items: [TimelineItem]
    /// Bumped to bring the chosen backup into view when the choice comes from outside the list (shortcuts, «Mostra nel backup»): a click needs no scroll.
    let reveal: Int
    /// The app's history says nothing about another computer's archive: no status line there.
    let showStatus: Bool
    let statusText: String
    let statusColor: Color
    let statusSymbol: String
    let locale: Locale
    /// Shows a backup and leaves the search.
    let choose: (String) -> Void

    private var calendar: Calendar { .current }

    var body: some View {
        let sections = BackupTimeline.sections(items, calendar: calendar, locale: locale)
        let largest = BackupTimeline.largest(items)
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in row(item, largest: largest) }
                    } header: { header(section) }
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(sections.isEmpty)
            .safeAreaInset(edge: .top, spacing: 0) {
                if showStatus, !statusText.isEmpty { statusCard }
            }
            .onChange(of: reveal) { _, _ in
                if let id = model.selectedID { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay {
                if model.isLoading, model.hasDestination { ProgressView() }
                else if items.isEmpty, model.hasDestination, model.notConnectedText == nil {
                    ContentUnavailableView("Nessun backup", systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Compariranno qui dopo il primo salvataggio."))
                }
            }
        }
    }

    /// The panel's status line again, where the backups are read.
    private var statusCard: some View {
        Button { if let newest = items.first?.id { choose(newest) } } label: {
            HStack(spacing: 9) {
                Image(systemName: statusSymbol).font(.system(size: 12, weight: .bold)).foregroundStyle(statusColor).frame(width: 16)
                Text(statusText).font(.callout).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 10).padding(.bottom, 6)
        .help("Va all'ultimo backup. " + statusText)
        .accessibilityLabel("Va all'ultimo backup")
        .accessibilityValue(statusText)
    }

    private func header(_ section: TimelineSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title).textCase(.uppercase)
            Spacer()
            if let bytes = section.newBytes { Text("+" + BackupTimeline.bytesText(bytes, locale: locale)).monospacedDigit() }
        }
        .help("Dati nuovi salvati da questi backup")
    }

    private func row(_ item: TimelineItem, largest: Int64) -> some View {
        let selected = model.selectedID == item.id
        let warned = (item.warnings ?? 0) > 0
        let tip = BackupTimeline.detail(item, calendar: calendar, locale: locale)
        // the selected row is one filled capsule, so its line, point and bar are white
        let line = selected ? Color.white.opacity(0.45) : Color.secondary.opacity(0.3)
        let tint: Color = selected ? .white : warned ? .orange : Color.secondary.opacity(0.6)
        return Button { choose(item.id) } label: {
            HStack(spacing: 0) {
                // the line every point sits on, one row at a time: the rows touch, so it reads as one line
                Rectangle().fill(line).frame(width: 1.5).frame(maxHeight: .infinity)
                    .overlay {
                        Circle()
                            .fill(selected ? Color.white : warned ? Color.orange.opacity(0.35) : Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(selected ? Color.clear : tint, lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                    }
                    .frame(width: 24)
                Text(BackupTimeline.hourLabel(item.date, calendar: calendar, locale: locale))
                    .font(.callout.weight(selected ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(minWidth: 44, alignment: .leading).fixedSize()
                Bar(fraction: BackupTimeline.barWidth(item, largest: largest), tint: tint,
                    track: selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15))
                    .padding(.trailing, 8)
                Text(BackupTimeline.barLabel(item, locale: locale)).font(.caption).monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 60, alignment: .trailing)
                Image(systemName: warned ? "exclamationmark.triangle.fill" : "circle")
                    .font(.caption2).foregroundStyle(selected ? Color.white : Color.orange)
                    .opacity(warned ? 1 : 0).frame(width: 14)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.clear))
        .help(tip)
        .accessibilityLabel(tip) // the label alone is only an hour
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The data a backup saved, against the largest one; nothing at all when unknown.
private struct Bar: View {
    let fraction: Double?
    let tint: Color
    let track: Color

    var body: some View {
        if let fraction {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if fraction > 0 { Capsule().fill(tint).frame(width: max(3, g.size.width * fraction)) }
                }
            }
            .frame(height: 5)
        } else {
            Color.clear.frame(height: 5).frame(maxWidth: .infinity)
        }
    }
}
