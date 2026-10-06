# PDFilter

Native macOS-App (Swift/SwiftUI), die eingehende PDFs und Scans anhand des Aktenzeichens
(»Nummer/Jahr«, z. B. `34/26`) der richtigen Akte auf dem Schreibtisch zuordnet und dort
chronologisch in die Gesamtakte einsortiert.

## Was die App macht

1. **Aufnehmen**: PDFs oder Bild-Scans (JPG, PNG, HEIC, TIFF) per Drag & Drop ins Fenster,
   per »Öffnen mit« im Finder oder durch Ziehen aufs Dock-Symbol.
2. **Aktenzeichen bestimmen**: aus dem Dateinamen (`34/26_Anschreiben.pdf`, `34-26 …`, `34_26 …`).
   Fehlt es, liest die App die erste Seite (Textebene oder OCR), schlägt gefundene Aktenzeichen vor
   (vorhandene Akten zuerst) und fragt nach.
3. **Akte finden**: Ordner auf dem Schreibtisch, dessen Name das Aktenzeichen enthält
   (z. B. `34/26 - Kinzel ./. Robin`). Zielordner laut einstellbarem Muster, Standard
   `01_Akte/01_Gesamtakte`. Passt die Struktur nicht, meldet die App genau, welcher Ordner fehlt,
   und verändert nichts.
4. **Einsortieren**:
   - Zielordner leer → neue `Gesamtakte.pdf`.
   - Eine PDF vorhanden → sie ist die Gesamtakte; neue Dokumente werden **nach Datum einsortiert**
     (Lesezeichen und Kopfzeilen-Daten der Seiten), im Zweifel ans Ende. Die Datei wird in
     `Gesamtakte.pdf` umbenannt.
   - Mehrere Einzel-PDFs → nach Nummerierung (`01_`, `02_` …) und Datum sortieren, Gesamtakte erzeugen,
     Einzeldateien nummeriert in den Unterordner `Einzeldokumente` verschieben.
   - Sortierung unsicher (Dateien ohne Nummer und Datum) → Gesamtakte nur im Unterordner
     `_PDFilter_Entwurf`; die Akte bleibt unverändert.
5. **Datum erkennen**: zuerst Dateiname (`2024-12-01`, `01.12.2024`, `241201`), sonst Dokumenttext
   (Briefkopf: »Berlin, den 01.12.2024«, »Datum: …«), bei Scans per OCR (Apple Vision, deutsch).
   Unsicher → Rückfrage mit Seitenvorschau und Eingabefeld. Nummerierung im Dateinamen hat Vorrang;
   Widersprüche zum Datum werden ausdrücklich angezeigt.
6. **Sicherheit**: Vorschau vor jedem Schreibvorgang, Sicherungskopie der Gesamtakte
   (die letzten 5 je Akte), atomares Schreiben mit Rücklese-Prüfung, Originale in den Papierkorb
   (nicht löschen), Protokoll aller Schritte. Scans werden per OCR durchsuchbar gemacht.

## Installation

### Variante A: Fertige App aus GitHub Actions laden (kein Xcode nötig)

1. Auf GitHub das Repository öffnen → Reiter **Actions**.
2. Den obersten grünen Lauf »Build & Test (macOS)« anklicken.
3. Unten unter **Artifacts** `PDFilter-macOS` herunterladen (ZIP, Anmeldung bei GitHub nötig).
4. ZIP entpacken, `PDFilter.app` nach **Programme** ziehen.
5. Erster Start: **Rechtsklick → Öffnen** (die App ist nicht von Apple signiert). Falls macOS die App
   weiterhin blockiert: **Systemeinstellungen → Datenschutz & Sicherheit** → unten »Dennoch öffnen«.
   Alternativ im Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/PDFilter.app
   ```
6. Beim ersten Zugriff fragt macOS nach der Erlaubnis für den **Schreibtisch** (und ggf. Downloads).
   Mit »OK« bestätigen. Nachträglich: Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner.

### Variante B: Selbst bauen (Xcode installiert)

```bash
cd ~/Downloads
git clone https://github.com/robinpkinzel-tech/PDFilter.git
cd PDFilter
Scripts/make-app.sh          # erzeugt build/PDFilter.app
open build
```
Dann `PDFilter.app` nach Programme ziehen. Zum Entwickeln: `open Package.swift` öffnet das Projekt in Xcode
(Schema »PDFilter« wählen, ⌘R).

## Einstellungen (⌘,)

| Einstellung | Standard | Bedeutung |
|---|---|---|
| Wurzelordner | Schreibtisch | Hier liegen die Aktenordner |
| Unterordner durchsuchen | aus | Auch z. B. `Schreibtisch/Archiv/…` |
| Pfadmuster | `01_Akte/01_Gesamtakte` | Weg vom Aktenordner zum Zielordner |
| Dateiname der Gesamtakte | `Gesamtakte.pdf` | `{AZ}` wird ersetzt |
| Trennzeichen im Präfix | `/` | `34/26_Name.pdf` (auf der Platte `34:26_…`, der Finder zeigt `/`) |
| OCR durchsuchbar | an | Scans erhalten eine unsichtbare Textebene |
| Originale in Papierkorb | an | Nach Erfolg |
| Kopien in »Einzeldokumente« | an | Je eingefügtem Dokument eine Kopie |
| Sicherungen je Akte | 5 | Ältere werden gelöscht |
| OCR-Obergrenze Gesamtakte | 150 Seiten | Für die Einsortierung in Gesamtakten ohne Textebene |
| Vorschau bestätigen | an | »Für diese Akte nicht mehr fragen« je Akte möglich |

Dateien: `~/Library/Application Support/PDFilter/` (settings.json, protokoll.log, Sicherungen/, Seitendaten-Cache).

## Hinweis zu »/« in Dateinamen

macOS erlaubt kein `/` in Datei- und Ordnernamen. Was im Finder als `34/26` erscheint, ist auf der
Platte `34:26`. PDFilter behandelt `34/26`, `34:26`, `34-26` und `34_26` als dasselbe Aktenzeichen.

## Projektstruktur

- `Sources/PDFilterParsing` – reine Logik ohne Apple-Frameworks: Aktenzeichen, Datumserkennung,
  Nummerierung, Sortierung, Einsortierungs-Entscheidung (Unit-Tests in `Tests/PDFilterParsingTests`).
- `Sources/PDFilterCore` – PDFKit/Vision: Textebene, OCR, durchsuchbare PDFs, Bild→PDF, Aktensuche,
  Zielordner-Analyse, Lesezeichen-Index, Zusammenbau, sicheres Schreiben, Sicherungen, Ablaufsteuerung
  (`Processor`) mit dem Protokoll `UserInteraction` für Rückfragen.
- `Sources/PDFilter` – SwiftUI-App (Hauptfenster, Dialoge, Einstellungen, Protokoll).
- `Scripts/make-app.sh` – baut `build/PDFilter.app` (Release, ad-hoc signiert).
- `.github/workflows/build.yml` – baut und testet auf einem macOS-Runner, lädt die App als Artefakt hoch.

```bash
swift build && swift test     # auf einem Mac
```
