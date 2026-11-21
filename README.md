# MacCommander

Ein Norton-Commander-Klon (NC 3/4/5-Look) als native macOS-App (Swift/AppKit, keine Abhängigkeiten).

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
