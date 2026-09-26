# claude-usage-plasmoid

Zeigt dein Claude-Nutzungslimit (5-Stunden-Session und 7-Tage-Fenster) als Widget
in der KDE-Plasma-6-Kontrollleiste.

```
Kontrollleiste:   5h 42%   7d 15%
                  ▔▔▔▔▔    ▔▔
```

Klick öffnet ein Popup mit Balken, Reset-Countdown und Datenstand, Mittelklick liest
neu ein, Rechtsklick bietet „Nutzung auf claude.ai öffnen“.

## Wie es funktioniert

```
Claude Code ──(statusLine, JSON auf stdin)──▶ claude-usage-hook
                                                  │ schreibt atomar
                                                  ▼
                                   ~/.cache/claude-usage/state.json
                                                  ▲ liest alle 10 s (cat)
                                   Plasmoid "Claude Usage" (QML)
```

Claude Code übergibt jedem [statusLine-Skript](https://code.claude.com/docs/en/statusline)
offiziell das Feld `rate_limits.five_hour` / `rate_limits.seven_day` mit
`used_percentage` und `resets_at`. Der Hook schreibt genau das in eine Datei, das
Widget zeigt sie an.

- **Kein Netzwerk.** Weder Hook noch Widget stellen eine einzige Verbindung her.
- **Keine Credentials.** `~/.claude/.credentials.json`, OAuth-Tokens oder Browser-Cookies
  werden nicht angefasst.
- **Keine Abhängigkeiten** außer `python3` und Plasma 6. Kein pip, kein npm, kein sudo.

## Grenzen – bitte lesen

- **Nur mit Claude Code.** Die Werte kommen ausschließlich aus Claude Code (Pro/Max-Abo,
  per `claude` eingeloggt, nicht per API-Key). Ohne Claude-Code-Nutzung bleibt das Widget leer.
- **Nur so aktuell wie deine letzte Claude-Code-Antwort.** Das Limit ist zwar zwischen
  claude.ai und Claude Code geteilt, aber was du im Browser verbrauchst, sieht das Widget
  erst, wenn Claude Code die nächste Antwort bekommt. Nach `staleMinutes` (Standard 30)
  ohne Update wird die Anzeige abgeblendet.
- **Nach einem Reset** zeigt das Widget `–` statt eines geratenen Werts, bis neue Daten kommen.
- Wer den exakten Live-Stand braucht: Rechtsklick → „Nutzung auf claude.ai öffnen“
  (`https://claude.ai/settings/usage`).

## Warum nicht einfach die bestehenden Tools?

| Ansatz | Problem |
|---|---|
| OAuth-Token aus `~/.claude/.credentials.json` + `/v1/messages`-Ping (z. B. claude-usage-monitor-linux) | Schickt bei jedem Poll eine echte Anfrage an Haiku → verbraucht selbst Kontingent. Anthropic untersagt die Nutzung von Abo-OAuth-Tokens außerhalb von Claude Code/claude.ai ausdrücklich und blockt das serverseitig. |
| OAuth-Token + undokumentierter Endpoint `/api/oauth/usage` (z. B. ccusage) | Kein Kontingentverbrauch, aber gleiche Token-Regel; Endpoint ist undokumentiert und hat sein Format 2026 schon einmal geändert. Manche Tools rotieren zusätzlich Tokens und schreiben in deine Credentials. |
| claude.ai-Session-Cookie + Headless-Browser (z. B. claude-usage-indicator) | Cookie liegt im Klartext auf Platte, Playwright/Chromium als Abhängigkeit, automatisierter Zugriff auf die Web-App; der Installer braucht sudo und ist apt-only. |
| **dieses Repo** | Nutzt nur das dokumentierte statusLine-Interface. Preis: Daten nur so frisch wie Claude Code. |

## Voraussetzungen

- KDE Plasma 6 (getestet gegen die Plasma-6-API; `plasma5support` ist bei Plasma 6 dabei)
- `python3`, `kpackagetool6` (bei CachyOS/Arch vorhanden über `python` bzw. `kpackage`)
- Claude Code, eingeloggt mit Pro- oder Max-Abo

## Installation

```bash
./install.sh
```

Das Skript

1. kopiert `hook/claude-usage-hook.py` nach `~/.local/bin/claude-usage-hook`,
2. installiert das Widget per `kpackagetool6` nach `~/.local/share/plasma/plasmoids/local.claudeusage`,
3. trägt in `~/.claude/settings.json` die `statusLine` ein – **nur wenn dort noch keine
   ist** – und legt vorher ein Backup `settings.json.bak-<datum>` an.

Danach: Rechtsklick auf die Kontrollleiste → „Widgets hinzufügen…“ → **Claude Usage**
in die Leiste ziehen. Claude Code starten, eine Nachricht schicken, fertig.

### Du hast schon eine eigene statusLine

```bash
./install.sh --wrap-existing
```

macht aus deiner Zeile `claude-usage-hook --chain '<dein altes kommando>'`. Der Hook
schreibt den State und gibt dann exakt die Ausgabe deines alten Skripts zurück.
Alternativ im eigenen Skript das JSON weiterreichen:

```bash
input=$(cat)
printf '%s' "$input" | ~/.local/bin/claude-usage-hook --quiet
# ... dein bisheriger Code mit "$input"
```

### Update

```bash
git pull && ./install.sh
systemctl --user restart plasma-plasmashell.service   # Plasma lädt Widget-Code nur neu nach Shell-Neustart
```

## Testen ohne Claude Code

```bash
# Fake-Daten in den State schreiben (bash -c, damit es auch unter fish läuft)
bash -c 'now=$(date +%s); echo "{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":73,\"resets_at\":$((now+7200))},\"seven_day\":{\"used_percentage\":21,\"resets_at\":$((now+400000))}}}" | ~/.local/bin/claude-usage-hook'

~/.local/bin/claude-usage-hook --show        # Stand im Terminal

# Widget isoliert starten (braucht: sudo pacman -S plasma-sdk)
plasmoidviewer -a local.claudeusage -f horizontal
```

Hook-Tests: `python3 -m unittest discover -v tests`

## Einstellungen

Rechtsklick aufs Widget → „Claude Usage einrichten…“:

| Option | Standard | Bedeutung |
|---|---|---|
| Datei lesen alle | 10 s | Nur lokales `cat`, kostet praktisch nichts |
| Gelb ab / Rot ab | 70 % / 90 % | Farbschwellen (Theme-Farben neutral/negative) |
| Abblenden nach | 30 min | Ab wann Werte ohne Update aus Claude Code als veraltet gelten |
| 7-Tage-Wert anzeigen | an | In der Leiste; im Popup immer sichtbar |

## Dateien

| Pfad | Zweck |
|---|---|
| `hook/claude-usage-hook.py` | statusLine-Befehl. Liest stdin, schreibt `state.json` (0600, atomar), gibt Statuszeile aus |
| `plasmoid/contents/ui/main.qml` | Widget-Logik: Datei lesen, Aufbereitung, Leiste, Popup, Tooltip, Kontextmenü |
| `plasmoid/contents/ui/UsageChip.qml` | Ein Wert in der Leiste (Text + dünner Balken) |
| `plasmoid/contents/ui/WindowRow.qml` | Eine Zeile im Popup |
| `plasmoid/contents/ui/configGeneral.qml`, `contents/config/*` | Einstellungsdialog + Schema |
| `install.sh` / `uninstall.sh` | User-lokale (De-)Installation, settings.json mit Backup |
| `tests/test_hook.py` | Unit-Tests für den Hook |

Format von `~/.cache/claude-usage/state.json`:

```json
{
  "version": 1,
  "source": "claude-code-statusline",
  "updated_at": 1790000000,
  "claude_code_version": "2.1.260",
  "windows": {
    "five_hour": {"used_percentage": 42.0, "resets_at": 1790010000, "seen_at": 1790000000},
    "seven_day": {"used_percentage": 15.0, "resets_at": 1790400000, "seen_at": 1790000000}
  }
}
```

## Troubleshooting

- **Widget zeigt `–`, `--show` sagt „Keine Daten“:** Claude Code liefert `rate_limits` erst
  nach der ersten API-Antwort einer Session und nur bei Pro/Max-Login. `claude --debug`
  zeigt Fehler des statusLine-Skripts.
- **Statusline in Claude Code bleibt leer:** Claude Code führt statusLine-Befehle erst aus,
  wenn du dem Ordner vertraut hast (Trust-Dialog). Außerdem deaktivieren `disableAllHooks`
  bzw. `allowManagedHooksOnly` eigene statusLines.
- **Widget-Änderungen greifen nicht:** `systemctl --user restart plasma-plasmashell.service`
- **Debug-Ausgabe des Widgets:** `journalctl --user -f -t plasmashell` bzw. `plasmoidviewer` im Terminal.

## Deinstallation

Erst das Widget aus der Leiste entfernen, dann:

```bash
./uninstall.sh
```

Entfernt Widget, Hook und Cache. Eine per `--wrap-existing` eingebundene eigene
statusLine wird wiederhergestellt, sonst wird der `statusLine`-Eintrag gelöscht.
