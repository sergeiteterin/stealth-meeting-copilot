import SwiftUI
import AppKit

/// Browse past sessions saved when you stop listening: a master list of sessions
/// on the left, the full speaker-labelled transcript on the right.
struct HistoryView: View {
    @ObservedObject var sessions: SessionStore
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedID: SessionRecord.ID?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.sessions = coordinator.sessions
    }

    private var selected: SessionRecord? {
        sessions.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
            Divider()
            detail
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            if selectedID == nil { selectedID = sessions.sessions.first?.id }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Встречи")
                .font(.headline)
                .padding(12)
            if sessions.sessions.isEmpty {
                Text("Сохранённых встреч пока нет.\nРазговор сохраняется сюда после «Стоп».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                List(selection: $selectedID) {
                    ForEach(sessions.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.system(size: 13, weight: .medium))
                            Text("\(session.lineCount) реплик · \(session.durationLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(session.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 220)
    }

    /// Markdown → attributed text, keeping the line breaks of headings and lists.
    private static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plainHeadings = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("## ") ? "**\(t.dropFirst(3))**" : String(line)
            }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: plainHeadings, options: options)) ?? AttributedString(markdown)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.headline)
                        Text([session.profile, "\(session.lineCount) реплик", session.durationLabel,
                              session.costUSD.map(CostMeter.format)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.plainText, forType: .string)
                    } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    Button {
                        coordinator.summarize(session)
                    } label: {
                        Label(coordinator.summarizingID == session.id ? "Пишу…" : (session.summary == nil ? "Резюме" : "Обновить резюме"),
                              systemImage: "text.badge.checkmark")
                    }
                    .disabled(coordinator.summarizingID != nil)
                    .help("Итоги, договорённости, задачи и черновик письма по этой встрече")
                    Button {
                        TranscriptExporter.export(session)
                    } label: { Label("Сохранить…", systemImage: "square.and.arrow.down") }
                    Button(role: .destructive) {
                        let toDelete = session
                        selectedID = nil
                        sessions.delete(toDelete)
                        selectedID = sessions.sessions.first?.id
                    } label: { Label("Удалить", systemImage: "trash") }
                }
                .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let summary = session.summary, !summary.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Резюме встречи").font(.system(size: 12, weight: .bold))
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(summary, forType: .string)
                                    } label: { Label("Копировать резюме", systemImage: "doc.on.doc") }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                }
                                Text(Self.rendered(summary))
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
                            .padding(.bottom, 6)
                        }
                        ForEach(session.lines) { line in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(line.speaker.rawValue)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(line.speaker == .you ? .blue : .green)
                                    Text(line.clock)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(line.content)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let ru = line.translation {
                                    Text(ru)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            VStack {
                Spacer()
                Text("Выберите встречу").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
