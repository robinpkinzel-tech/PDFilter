# PDFilter – Umsetzungsplan (Entwurf, Stand 06.10.2026)

Dieses Dokument ist der Planungsentwurf. Die offenen Fragen (unten) werden nach
Rückmeldung eingearbeitet, danach beginnt die Umsetzung.

## 1. Ziel

Native macOS-App "PDFilter", die eingehende PDFs

1. anhand des Aktenzeichens (Format `X/Jahr`, z. B. `34/26`) einer Akte auf dem
   Schreibtisch zuordnet (fehlt es im Dateinamen: Eingabedialog),
2. das Aktenzeichen vorne an den Dateinamen hängt (`34/26_DATEINAME.pdf`),
3. den passenden Aktenordner findet und über ein in der UI konfigurierbares
   Pfadmuster (z. B. `01_Akte/01_Gesamtakte`) den Zielordner bestimmt,
4. dort an die bestehende Gesamt-PDF anhängt bzw. aus Einzel-PDFs sortiert eine
   Gesamt-PDF erzeugt (Sortierung: Nummerierung im Dateinamen, Datum im
   Dateinamen, sonst Dokumentdatum per Textebene/OCR),
5. bei jeder Unsicherheit (keine/mehrere Akten, abweichende Ordnerstruktur,
   unklares Datum) ausdrücklich nachfragt bzw. deutlich meldet und nichts an der
   Akte verändert (Ausweichordner für unsichere Sortierungen).

## 2. Technik (Vorschlag)

| Baustein | Entscheidung | Begründung |
|---|---|---|
| Sprache/UI | Swift + SwiftUI, Ziel macOS 13+ | Native App, keine Fremdabhängigkeiten, kein Python/Homebrew nötig |
| PDF-Verarbeitung | Apple PDFKit | Seiten anhängen, zusammenführen, Lesezeichen setzen, Vorschau rendern |
| OCR | Apple Vision (`VNRecognizeTextRequest`, Sprache de-DE) | Auf dem Gerät, kostenlos, sehr gute Qualität, kein Tesseract |
| Datums-/AZ-Erkennung | Swift Regex, eigene Heuristik | deterministisch, testbar |
| Projektstruktur | Swift Package: `PDFilterCore` (Logik, Unit-Tests) + `PDFilter` (App) | Logik ohne UI testbar |
| Build/Test ohne Mac | GitHub Actions (`macos-latest`): `swift build`, `swift test`, App-Bundle als Download-Artefakt | Ich arbeite in einer Linux-Cloud und kann Swift hier nicht kompilieren |
| Installation | a) Xcode öffnet `Package.swift` direkt, b) oder fertige `PDFilter.app` aus GitHub Actions laden | kein Developer-Account nötig |

Wichtiger macOS-Fallstrick: `/` ist in Datei- und Ordnernamen nicht erlaubt.
Der Finder zeigt `34/26`, speichert auf der Platte aber `34:26`. Die App
behandelt beide Schreibweisen als identisch und schreibt `:` auf die Platte.

## 3. Ablauf (Pipeline)

```
Eingang (Drag&Drop / "Öffnen mit")
  └─ Aktenzeichen ermitteln: Dateiname → (optional) Vorschlag aus Dokumenttext → Dialog
  └─ Umbenennen: 34:26_DATEINAME.pdf
  └─ Akte suchen: Wurzelordner (Standard: Schreibtisch) nach Ordnern mit Präfix "34/26" bzw. "34:26"
       0 Treffer → Fehler + Dialog (anderen Ordner wählen / abbrechen)
       >1 Treffer → Auswahl-Dialog
  └─ Zielordner aus Pfadmuster bilden, Existenz prüfen → sonst ausdrückliche Fehlermeldung
  └─ Zustand des Zielordners analysieren:
       A) leer                    → neue Gesamt-PDF anlegen
       B) genau eine Gesamt-PDF   → Seiten anhängen (+ Lesezeichen mit Datum/Name)
       C) Einzel-PDFs             → eingehende Datei einsortieren + nummerieren,
                                     Reihenfolge bestimmen, Gesamt-PDF erzeugen
       D) unklar                  → Vorschau, Nachfrage, ggf. Ausweichordner
  └─ Vorschau der geplanten Schritte → Bestätigung → Ausführung
  └─ Sicherung der alten Gesamt-PDF, atomares Schreiben, Protokoll
```

### Reihenfolge-Bestimmung
1. Nummernpräfix im Dateinamen (`01_`, `02_` …) – hat Vorrang.
2. Datum im Dateinamen (`2024-12-01_…`, `01.12.2024_…`).
3. Dokumentdatum: Textebene der 1. Seite, sonst OCR der 1. Seite (300 dpi).
   Heuristik: Datumsangaben im oberen Seitendrittel, nach "Datum"/", den"
   bevorzugt; mehrere Kandidaten werden bewertet; unter Schwellwert → Nachfrage
   mit Seitenvorschau und Eingabefeld.
4. Keine sichere Zuordnung → Gesamt-PDF nur im Ausweichordner erzeugen, Akte
   bleibt unverändert, deutlicher Hinweis.

### Sicherheitsnetz
- Vor jeder Änderung an einer Gesamt-PDF: Sicherungskopie.
- Schreiben in temporäre Datei, dann atomar ersetzen.
- Jeder Lauf wird protokolliert (Protokollansicht in der App).
- Kein Löschen ohne Papierkorb.

## 4. Offene Fragen

Siehe Chat; werden nach Rückmeldung hier mit Antworten eingetragen.
