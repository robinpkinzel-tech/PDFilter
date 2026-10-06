import SwiftUI
import PDFilterCore
import PDFilterParsing

struct DialogHost: View {
    @EnvironmentObject var model: AppModel
    let request: DialogRequest

    var body: some View {
        switch request.kind {
        case .aktenzeichen(let fileName, let suggestions, let preview, let resumer):
            AktenzeichenDialog(fileName: fileName, suggestions: suggestions, preview: preview) { answer in
                model.completeDialog { resumer.resume(answer) }
            }
        case .akteFolder(let az, let candidates, let resumer):
            AkteFolderDialog(az: az, candidates: candidates) { url in
                model.completeDialog { resumer.resume(url) }
            }
        case .date(let fileName, let candidates, let preview, let resumer):
            DateDialog(fileName: fileName, candidates: candidates, preview: preview) { answer in
                model.completeDialog { resumer.resume(answer) }
            }
        case .gesamtakte(let folder, let candidates, let all, let resumer):
            GesamtakteDialog(folder: folder, candidates: candidates, all: all) { choice in
                model.completeDialog { resumer.resume(choice) }
            }
        case .plan(let plan, let resumer):
            PlanDialog(plan: plan) { decision in
                model.completeDialog { resumer.resume(decision) }
            }
        case .report(let outcomes):
            ReportDialog(outcomes: outcomes) {
                model.completeDialog {}
            }
        }
    }
}

/// Seitenvorschau links, Inhalt rechts.
struct PreviewLayout<Content: View>: View {
    let preview: NSImage?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 300)
                    .border(Color.secondary.opacity(0.3))
            }
            content
        }
    }
}

struct AktenzeichenDialog: View {
    let fileName: String
    let suggestions: [Aktenzeichen]
    let preview: NSImage?
    let onAnswer: (AktenzeichenAnswer) -> Void
    @State private var input = ""

    private var parsed: Aktenzeichen? { Aktenzeichen.parse(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aktenzeichen fehlt").font(.title2).bold()
            Text("Im Dateinamen »\(fileName)« wurde kein Aktenzeichen im Format »Nummer/Jahr« gefunden.")
                .fixedSize(horizontal: false, vertical: true)
            PreviewLayout(preview: preview) {
                VStack(alignment: .leading, spacing: 12) {
                    if !suggestions.isEmpty {
                        Text("Im Dokument gefunden (anklicken zum Übernehmen):").font(.subheadline)
                        HStack {
                            ForEach(suggestions, id: \.self) { az in
                                Button(az.display) { input = az.display }
                            }
                        }
                    }
                    Text("Aktenzeichen eingeben, z. B. 34/26:").font(.subheadline)
                    TextField("34/26", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { if let az = parsed { onAnswer(.value(az)) } }
                    if !input.isEmpty && parsed == nil {
                        Text("Bitte im Format »Nummer/Jahr« eingeben (z. B. 34/26).").font(.caption).foregroundStyle(.red)
                    } else if let az = parsed {
                        Text("Erkannt: \(az.display)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(minWidth: 320, alignment: .leading)
            }
            HStack {
                Button("Alles abbrechen", role: .destructive) { onAnswer(.cancelAll) }
                Button("Diese Datei überspringen") { onAnswer(.skipFile) }
                Spacer()
                Button("Übernehmen") { if let az = parsed { onAnswer(.value(az)) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 640)
        .onAppear { if let first = suggestions.first { input = first.display } }
    }
}

struct AkteFolderDialog: View {
    let az: Aktenzeichen
    let candidates: [URL]
    let onAnswer: (URL?) -> Void
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mehrere Akten gefunden").font(.title2).bold()
            Text("Für das Aktenzeichen \(az.display) passen mehrere Ordner. Bitte den richtigen auswählen:")
                .fixedSize(horizontal: false, vertical: true)
            List(candidates, id: \.self, selection: $selection) { url in
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent)
                    Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                }
                .tag(url)
            }
            .frame(minHeight: 160)
            HStack {
                Button("Abbrechen", role: .cancel) { onAnswer(nil) }
                Spacer()
                Button("Diese Akte verwenden") { onAnswer(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .onAppear { selection = candidates.first }
    }
}

struct DateDialog: View {
    let fileName: String
    let candidates: [DateCandidate]
    let preview: NSImage?
    let onAnswer: (DateAnswer) -> Void
    @State private var input = ""

    private var parsed: DayDate? { DayDate.parse(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Datum des Dokuments unklar").font(.title2).bold()
            Text("Für »\(fileName)« konnte das Dokumentdatum nicht sicher erkannt werden. Es wird für die chronologische Einsortierung benötigt.")
                .fixedSize(horizontal: false, vertical: true)
            PreviewLayout(preview: preview) {
                VStack(alignment: .leading, spacing: 12) {
                    if !candidates.isEmpty {
                        Text("Gefundene Datumsangaben (anklicken zum Übernehmen):").font(.subheadline)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(candidates.prefix(8)) { c in
                                Button {
                                    input = c.date.german
                                } label: {
                                    HStack {
                                        Text(c.date.german).bold()
                                        if !c.context.isEmpty {
                                            Text("… \(c.context)").foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    } else {
                        Text("Im Dokument wurde keine Datumsangabe gefunden.").foregroundStyle(.secondary)
                    }
                    Text("Datum eingeben (TT.MM.JJJJ):").font(.subheadline)
                    TextField("01.12.2024", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { if let d = parsed { onAnswer(.date(d)) } }
                    if !input.isEmpty && parsed == nil {
                        Text("Ungültiges Datum.").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                }
                .frame(minWidth: 320, alignment: .leading)
            }
            HStack {
                Button("Alles abbrechen", role: .destructive) { onAnswer(.cancelAll) }
                Button("Datei überspringen") { onAnswer(.skipFile) }
                Button("Ohne Datum (ans Ende)") { onAnswer(.noDate) }
                Spacer()
                Button("Datum übernehmen") { if let d = parsed { onAnswer(.date(d)) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 680)
        .onAppear { if let first = candidates.first { input = first.date.german } }
    }
}

struct GesamtakteDialog: View {
    let folder: URL
    let candidates: [URL]
    let all: [URL]
    let onAnswer: (GesamtakteChoice) -> Void
    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welche Datei ist die Gesamtakte?").font(.title2).bold()
            Text("Im Zielordner »\(folder.path)« liegen mehrere PDFs, die als Gesamtakte in Frage kommen. Die übrigen Dateien werden als Einzeldokumente behandelt und in die gewählte Gesamtakte einsortiert.")
                .fixedSize(horizontal: false, vertical: true)
            List(all, id: \.self, selection: $selection) { url in
                HStack {
                    Text(url.lastPathComponent)
                    if candidates.contains(url) {
                        Text("vermutlich Gesamtakte").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(url)
            }
            .frame(minHeight: 160)
            HStack {
                Button("Abbrechen", role: .cancel) { onAnswer(.cancel) }
                Button("Keine – alle als Einzeldokumente sortieren") { onAnswer(.treatAllAsSingles) }
                Spacer()
                Button("Als Gesamtakte verwenden") { if let s = selection { onAnswer(.file(s)) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 600)
        .onAppear { selection = candidates.first }
    }
}

struct PlanDialog: View {
    let plan: ProcessingPlan
    let onAnswer: (PlanDecision) -> Void
    @State private var appendAtEnd = false
    @State private var writeIntoAkte = false
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vorschau: Akte \(plan.aktenzeichen.display)").font(.title2).bold()
            Text(plan.kind.german).font(.headline)
            Text("Akte: \(plan.akteFolder.lastPathComponent)").foregroundStyle(.secondary)

            if !plan.uncertainReasons.isEmpty {
                box(color: .orange, title: "Sortierung unsicher", lines: plan.uncertainReasons +
                    (plan.usesDraftByDefault ? ["Die Gesamtakte wird deshalb im Entwurfsordner »\(plan.draftURL.deletingLastPathComponent().lastPathComponent)« angelegt. Die Akte bleibt unverändert."] : []))
            }
            if !plan.warnings.isEmpty {
                box(color: .yellow, title: "Hinweise", lines: plan.warnings)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        Text(step).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

            VStack(alignment: .leading, spacing: 6) {
                if plan.canAppendAtEnd {
                    Toggle("Alle neuen Dokumente ans Ende anhängen (nicht nach Datum einsortieren)", isOn: $appendAtEnd)
                }
                if plan.usesDraftByDefault {
                    Toggle("Trotz unsicherer Sortierung direkt in die Akte schreiben (nicht in den Entwurfsordner)", isOn: $writeIntoAkte)
                }
                Toggle("Für diese Akte künftig nicht mehr nachfragen (bei Hinweisen wird trotzdem gefragt)", isOn: $remember)
            }
            HStack {
                Button("Abbrechen", role: .cancel) { onAnswer(.cancel) }
                Spacer()
                Button("Ausführen") {
                    onAnswer(PlanDecision(execute: true, appendAtEnd: appendAtEnd, writeIntoAkteDespiteUncertainty: writeIntoAkte, rememberNoConfirm: remember))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 720)
    }

    private func box(color: Color, title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle").bold()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text("• \(l)").fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
    }
}

struct ReportDialog: View {
    @EnvironmentObject var model: AppModel
    let outcomes: [ProcessingOutcome]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ergebnis").font(.title2).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(outcomes) { o in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: o.success ? (o.isDraft ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "xmark.octagon.fill")
                                    .foregroundStyle(o.success ? (o.isDraft ? .orange : .green) : .red)
                                Text(o.title).bold()
                                Spacer()
                                if let url = o.resultURL {
                                    Button("Im Finder zeigen") { model.revealInFinder(url) }.controlSize(.small)
                                }
                            }
                            ForEach(Array(o.details.enumerated()), id: \.offset) { _, d in
                                Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 420)
            HStack {
                Spacer()
                Button("OK") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680)
    }
}
