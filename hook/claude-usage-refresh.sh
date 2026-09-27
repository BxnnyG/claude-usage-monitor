#!/usr/bin/env bash
# claude-usage-refresh - holt frische Limits, ohne eine Nachricht zu schicken.
#
# Startet das offizielle Claude Code kurz in einem Pseudo-Terminal. Kommen nach
# STATUS_AFTER Sekunden noch keine Limits, wird `/status` eingetippt (lokaler
# Befehl, keine Nachricht ans Modell) und der Dialog nach 4 s mit Esc
# geschlossen. Dabei ruft Claude Code die statusLine mit frischen Limits auf, und
# unser Hook schreibt state.json. Danach (oder nach Timeout) wird Claude Code
# wieder beendet.
#
# Kein fremdes Token, kein Scraping - nur das echte `claude`. Aber: ob ein
# Start ohne Nachricht Kontingent kostet, ist nicht dokumentiert. Deshalb
# standardmaessig nur, wenn die Daten aelter als CLAUDE_USAGE_REFRESH_MIN_AGE sind.
#
# Nutzung: claude-usage-refresh [--force]
#   --force   auch laufen, wenn die Daten noch frisch sind
#   --debug   wie --force, Bildschirmausgabe von Claude Code nach
#             ~/.cache/claude-usage/refresh-debug.log mitschneiden
set -uo pipefail

STATE="${CLAUDE_USAGE_STATE:-$HOME/.cache/claude-usage/state.json}"
# Eigenes, leeres Verzeichnis: Claude Code merkt sich "vertraut" fuer $HOME nicht
# dauerhaft, fuer normale Ordner schon. Einmal manuell bestaetigen (siehe README).
WORKDIR="${CLAUDE_USAGE_REFRESH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-usage/cwd}"
MAX_WAIT="${CLAUDE_USAGE_REFRESH_TIMEOUT:-45}"        # Sekunden
MIN_AGE="${CLAUDE_USAGE_REFRESH_MIN_AGE:-300}"        # juengere Daten -> nichts tun
STATUS_AFTER="${CLAUDE_USAGE_REFRESH_STATUS_AFTER:-8}" # Sekunden bis /status getippt wird

FORCE=0
DEBUG=0
case "${1:-}" in
    --force) FORCE=1 ;;
    --debug) FORCE=1; DEBUG=1 ;;
    "") ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
esac

log() { echo "claude-usage-refresh: $*" >&2; }

find_claude() {
    local c
    for c in "${CLAUDE_USAGE_CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null)" \
             "$HOME/.local/bin/claude" "$HOME/.claude/local/claude"; do
        [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

CLAUDE_BIN="$(find_claude)" || { log "claude nicht gefunden (CLAUDE_USAGE_CLAUDE_BIN setzen)"; exit 1; }
command -v script >/dev/null 2>&1 || { log "'script' fehlt (Paket util-linux)"; exit 1; }

STATE_DIR="$(dirname "$STATE")"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

# Nie zwei Refreshes gleichzeitig (Timer + Klick im Widget)
exec 9>"$STATE_DIR/refresh.lock"
flock -n 9 || { log "laeuft bereits"; exit 0; }

if [[ $FORCE -eq 0 && -f "$STATE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$STATE") ))
    if (( age < MIN_AGE )); then
        log "Daten sind erst ${age}s alt - nichts zu tun"
        exit 0
    fi
fi

checksum() { if [[ -f "$STATE" ]]; then cksum <"$STATE"; else echo none; fi; }
before="$(checksum)"

tmp="$(mktemp -d)"
pid=""
cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null
        for _ in 1 2 3 4; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -KILL -- "-$pid" 2>/dev/null
    fi
    exec 3>&- 2>/dev/null
    [[ $DEBUG -eq 1 && -f "$tmp/screen" ]] && cp -- "$tmp/screen" "$STATE_DIR/refresh-debug.log"
    rm -rf -- "$tmp"
}
trap cleanup EXIT

# stdin fuer `script`: eine FIFO, deren Schreibseite wir offen halten. So sieht
# Claude Code kein EOF, und wir koennen gezielt `/status` eintippen.
mkfifo "$tmp/in"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || { log "Verzeichnis $WORKDIR fehlt"; exit 1; }
[[ -z "${TERM:-}" || "${TERM:-}" == dumb ]] && export TERM=xterm-256color
export DISABLE_AUTOUPDATER=1  # kein Update-Download bei jedem Hintergrundstart

TYPESCRIPT="$tmp/screen"  # Bildschirminhalt, um Dialoge zu erkennen
setsid script -qfec "stty cols 120 rows 40 2>/dev/null; exec $(printf '%q' "$CLAUDE_BIN")" "$TYPESCRIPT" \
    <"$tmp/in" >/dev/null 2>&1 &
pid=$!
exec 3>"$tmp/in"

for (( i = 0; i < MAX_WAIT; i++ )); do
    sleep 1
    if [[ "$(checksum)" != "$before" ]]; then
        log "state.json aktualisiert"
        exit 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    if (( i + 1 == STATUS_AFTER )); then
        # Nie blind in einen Dialog tippen. Text ohne Escape-Sequenzen und
        # Leerraum, weil die TUI Woerter per Cursorbewegung trennt.
        screen="$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$TYPESCRIPT" | tr -d '[:space:]')"
        if [[ "$screen" == *trustthisfolder* ]]; then
            log "Claude Code fragt, ob es $WORKDIR vertrauen soll. Einmal bestaetigen:"
            log "  cd $(printf '%q' "$WORKDIR") && claude   -> 'Yes, I trust this folder', dann beenden"
            exit 3
        fi
        # Zeichen und Enter getrennt, sonst haelt die TUI es fuer eingefuegten Text
        printf '/status' >&3
        sleep 0.5
        printf '\r' >&3
    fi
    # Die statusLine laeuft erst, wenn der Dialog wieder geschlossen wird
    # ("Settings dialog dismissed") - also nach ein paar Sekunden Esc druecken.
    if (( i + 1 == STATUS_AFTER + 4 )); then
        printf '\033' >&3
    fi
done

[[ $DEBUG -eq 1 ]] && log "Mitschnitt: $STATE_DIR/refresh-debug.log"
log "keine neuen Daten nach ${MAX_WAIT}s. Moegliche Ursachen: $WORKDIR in Claude Code" \
    "nicht als vertrauenswuerdig bestaetigt (einmal 'claude' dort starten), nicht eingeloggt," \
    "oder diese Claude-Code-Version holt die Limits beim Start nicht."
exit 1
