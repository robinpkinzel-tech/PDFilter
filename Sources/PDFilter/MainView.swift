import SwiftUI
import UniformTypeIdentifiers
import PDFilterCore
import PDFilterParsing

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                VStack(spacing: 12) {
                    dropZone
                    queueList
                    footer
                }
                .padding(16)
                .frame(minWidth: 460)
                if model.showLog {
                    LogView()
                        .frame(minWidth: 260, idealWidth: 320)
                }
            }
        }
        .sheet(item: $model.dialog) { request in
            DialogHost(request: request)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Label(model.settings.rootFolder.path, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Aktenordner / \(model.settings.pathTemplate) / \(model.settings.gesamtakteFileName)", systemImage: "arrow.turn.down.right")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
            Toggle(isOn: $model.showLog) { Label("Protokoll", systemImage: "list.bullet.rectangle") }
                .toggleStyle(.button)
            SettingsLink { Label("Einstellungen", systemImage: "gearshape") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 12).fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear))
            VStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("PDFs oder Scans (JPG, PNG, HEIC) hierher ziehen")
                    .font(.headline)
                Text("Das Aktenzeichen wird aus dem Dateinamen gelesen (z. B. »34/26_Anschreiben.pdf«). Fehlt es, fragt PDFilter nach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Dateien auswählen …") { model.chooseFiles() }
                    .padding(.top, 4)
            }
            .padding()
        }
        .frame(height: 170)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            model.handleDrop(providers)
        }
    }

    private var queueList: some View {
        Group {
            if model.queue.isEmpty {
                Text("Noch keine Dateien in der Warteschlange.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.queue) { item in
                        HStack {
                            Image(systemName: SearchablePDFWriter.isPDF(item.url) ? "doc.richtext" : "photo")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.lastPathComponent).lineLimit(1)
                                Text(item.url.deletingLastPathComponent().path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            statusBadge(item.status)
                            if !model.isProcessing {
                                Button { model.remove(item) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Aus der Liste entfernen")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func statusBadge(_ status: String) -> some View {
        let color: Color
        switch status {
        case "Erledigt": color = .green
        case "Entwurf erstellt": color = .orange
        case "Fehler", "Nicht verarbeitet", "Abgebrochen": color = .red
        case "Bereit", "Übersprungen": color = .secondary
        default: color = .accentColor
        }
        return Text(status)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isProcessing {
                ProgressView().controlSize(.small)
                Text(model.progressText).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Erledigte entfernen") { model.clearFinished() }
                .disabled(model.isProcessing || model.queue.isEmpty)
            Button("Liste leeren") { model.clearQueue() }
                .disabled(model.isProcessing || model.queue.isEmpty)
            Button {
                model.startProcessing()
            } label: {
                Label("Verarbeiten", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.isProcessing || model.queue.isEmpty)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Protokoll").font(.headline)
                Spacer()
                Button("Datei zeigen") { model.revealLogFile() }
                    .controlSize(.small)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(8)
                }
                .onChange(of: model.logLines.count) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
