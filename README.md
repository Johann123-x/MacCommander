# MacCommander

Ein Zwei-Panel-Dateimanager für macOS, inspiriert vom Norton Commander (NC 3/4/5-Look), als native App (Swift/AppKit, keine Abhängigkeiten).

> MacCommander ist ein unabhängiges Projekt und nicht mit Gen Digital Inc. (Norton) verbunden. „Norton Commander“ ist eine Marke ihrer jeweiligen Inhaber.

## Download

Die fertige App gibt es unter [Releases](https://github.com/Johann123-x/MacCommander/releases): `MacCommander-v1.0-macOS.zip` herunterladen, entpacken und `MacCommander.app` nach `/Applications` ziehen. Läuft ab macOS 13 auf Apple-Silicon- und Intel-Macs (Universal).

**Erster Start:** Die App ist nicht von Apple notarisiert, daher meldet macOS beim ersten Öffnen, dass sie nicht geprüft werden kann. So startest du sie trotzdem:

- Rechtsklick auf `MacCommander.app` → **Öffnen** → **Öffnen**, oder
- **Systemeinstellungen → Datenschutz & Sicherheit** → unten bei MacCommander auf **Trotzdem öffnen** klicken, oder
- im Terminal: `xattr -dr com.apple.quarantine /Applications/MacCommander.app`

Das ist nur einmal nötig.

## Bauen & Starten

```bash
./build.sh
open build/MacCommander.app
```

Zum Installieren `build/MacCommander.app` nach `/Applications` ziehen.

## Funktionen

- Zwei blaue Panels mit Doppelrahmen, Voll-/Kurzanzeige, Sortierung, Uhr, freier Speicher
- F1 Hilfe · F2 Benutzermenü · F3 Viewer (Text/Hex, Markdown formatiert) · F4 Editor · F5 Kopieren · F6 Umbenennen/Verschieben
  · F7 Verzeichnis · F8 Löschen (Papierkorb) · F9 Pulldown-Menü · F10 Beenden
- Alt-F1/F2 Orte & Volumes, Alt-F7 Datei suchen, Alt-F8 Historie, Ctrl-S Schnellsuche
- Kommandozeile (zsh) mit Ausgabe hinter den Panels (Ctrl-O), `cd` steuert das Panel
- Markieren mit Leertaste/Insert/Shift-Pfeilen, `+` `-` `*` für Gruppen
- Maus: Klick, Doppelklick, Rechtsklick markiert, Klick auf die Tastenleiste
- Cmd-1 … Cmd-0 ersetzen F1 … F10 (Mac-Tastaturen), Cmd-+/- Schriftgröße

Alle Löschvorgänge (auch beim Überschreiben) gehen in den Papierkorb.

### Markdown

Bei `.md`-Dateien schaltet **F3** im Viewer und im Editor zwischen Rohtext und formatierter Ansicht um (Überschriften, fett/kursiv, Code, Listen, Zitate, Tabellen, Codeblöcke). Der Viewer startet formatiert, der Editor im Rohtext; die formatierte Ansicht im Editor ist nur zum Lesen.

### Panel-Optionen (F9 → Left/Right)

- **Hidden files**: versteckte Dateien nur für dieses Panel ein/aus (Ctrl-H = aktives Panel)
- **Permissions**: zusätzliche Spalte „Attr“ mit Unix-Rechten (z. B. `drwxr-xr-x`), nur in der Vollanzeige

### Maus in Menüs und Dialogen

- F9-Menü: Klick auf einen Titel wechselt das Menü, Klick auf einen Eintrag führt ihn aus, Klick daneben schließt; der Mauszeiger hebt Einträge hervor
- Auswahllisten (Alt-F1/F2, Historie …): Klick wählt, Mausrad scrollt
- Dialoge: Knöpfe anklicken, Klick ins Eingabefeld setzt den Fokus
