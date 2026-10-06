import SwiftUI
import PDFilterCore
import PDFilterParsing

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Ablage") {
                HStack {
                    TextField("Wurzelordner", text: $model.settings.rootFolderPath)
                    Button("Auswählen …") { model.chooseRootFolder() }
                }
                Toggle("Auch Unterordner des Wurzelordners nach Akten durchsuchen (z. B. Archiv)", isOn: $model.settings.searchSubfolders)
                TextField("Pfadmuster innerhalb der Akte", text: $model.settings.pathTemplate, prompt: Text("01_Akte/01_Gesamtakte"))
                Text("Vom Aktenordner aus, Ebenen mit »/« trennen. Beispiel: Schreibtisch/»34:26 - Kinzel ./. Robin«/01_Akte/01_Gesamtakte")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Dateiname der Gesamtakte", text: $model.settings.gesamtakteFileName, prompt: Text("Gesamtakte.pdf"))
                Text("»{AZ}« wird durch das Aktenzeichen ersetzt, z. B. »{AZ}_Gesamtakte.pdf«.").font(.caption).foregroundStyle(.secondary)
                Picker("Trennzeichen im Aktenzeichen-Präfix", selection: $model.settings.visibleSeparator) {
                    Text("34/26 (im Finder; auf der Platte als 34:26)").tag("/")
                    Text("34-26").tag("-")
                    Text("34_26").tag("_")
                }
            }
            Section("Verarbeitung") {
                Toggle("Scans ohne Textebene per OCR durchsuchbar machen", isOn: $model.settings.makeSearchable)
                Toggle("Originaldateien nach Erfolg in den Papierkorb legen", isOn: $model.settings.moveOriginalsToTrash)
                Toggle("Kopie jedes eingefügten Dokuments im Unterordner »Einzeldokumente« behalten", isOn: $model.settings.keepCopiesInEinzeldokumente)
                Stepper("Sicherungen je Akte aufbewahren: \(model.settings.backupCount)", value: $model.settings.backupCount, in: 1...50)
                Stepper("Höchstens \(model.settings.maxOCRPagesForSorting) Seiten einer Gesamtakte per OCR für die Einsortierung lesen",
                        value: $model.settings.maxOCRPagesForSorting, in: 0...2000, step: 25)
                Text("Gesamtakten ohne Textebene müssen für die chronologische Einsortierung einmal gelesen werden; das Ergebnis wird zwischengespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Bestätigung") {
                Toggle("Vor dem Schreiben eine Vorschau zur Bestätigung zeigen", isOn: $model.settings.confirmBeforeWriting)
                if !model.settings.noConfirmAkten.isEmpty {
                    HStack(alignment: .top) {
                        Text("Ohne Nachfrage: \(model.settings.noConfirmAkten.joined(separator: ", "))")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Zurücksetzen") { model.settings.noConfirmAkten = [] }
                    }
                }
            }
            Section("Dateien") {
                HStack {
                    Button("Protokolldatei zeigen") { model.revealLogFile() }
                    Button("Sicherungsordner öffnen") { model.revealBackups() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640)
        .padding(.bottom, 8)
    }
}
