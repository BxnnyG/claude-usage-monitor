#!/usr/bin/env bash
# Installiert Hook + Plasmoid rein user-lokal. Kein sudo, kein Netzwerk.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLASMOID_ID="local.claudeusage"
HOOK_SRC="$REPO_DIR/hook/claude-usage-hook.py"
HOOK_DST="$HOME/.local/bin/claude-usage-hook"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

WRAP_EXISTING=0
SKIP_SETTINGS=0

usage() {
    cat <<EOF
Nutzung: ./install.sh [--wrap-existing] [--no-settings]

  --wrap-existing  Hast du schon eine eigene statusLine in $SETTINGS,
                   wird sie per --chain eingebunden statt übersprungen.
  --no-settings    $SETTINGS nicht anfassen (statusLine selbst eintragen).
EOF
}

for arg in "$@"; do
    case "$arg" in
        --wrap-existing) WRAP_EXISTING=1 ;;
        --no-settings) SKIP_SETTINGS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1  (Arch/CachyOS: sudo pacman -S $2)" >&2; exit 1; }
}
need python3 python
need kpackagetool6 kpackage

echo "==> Hook installieren: $HOOK_DST"
install -Dm755 "$HOOK_SRC" "$HOOK_DST"

echo "==> Plasmoid installieren/aktualisieren ($PLASMOID_ID)"
if [[ -d "$HOME/.local/share/plasma/plasmoids/$PLASMOID_ID" ]]; then
    kpackagetool6 --type Plasma/Applet --upgrade "$REPO_DIR/plasmoid"
    UPGRADED=1
else
    kpackagetool6 --type Plasma/Applet --install "$REPO_DIR/plasmoid"
    UPGRADED=0
fi

SETTINGS_RC=0
if [[ $SKIP_SETTINGS -eq 0 ]]; then
    echo "==> statusLine in $SETTINGS eintragen"
    mkdir -p "$CLAUDE_DIR"
    python3 - "$SETTINGS" "$HOOK_DST" "$WRAP_EXISTING" <<'PY' || SETTINGS_RC=$?
import json, os, shlex, shutil, sys, tempfile, time

path, hook, wrap = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
hook_q = shlex.quote(hook)

settings = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            settings = json.load(fh)
    except ValueError as exc:
        print(f"   {path} ist kein gültiges JSON ({exc}) – fasse ich nicht an.")
        sys.exit(4)
    if not isinstance(settings, dict):
        print(f"   {path} ist kein JSON-Objekt – fasse ich nicht an.")
        sys.exit(4)

current = settings.get("statusLine")
cmd = current.get("command", "") if isinstance(current, dict) else ""

if cmd.startswith(hook) or cmd.startswith(hook_q):
    print("   statusLine ist bereits eingerichtet.")
    sys.exit(0)

if current is None:
    settings["statusLine"] = {"type": "command", "command": hook_q}
elif wrap and cmd:
    new = dict(current)
    new["command"] = f"{hook_q} --chain {shlex.quote(cmd)}"
    settings["statusLine"] = new
    print(f"   Bestehende statusLine eingebunden: {cmd}")
else:
    print(f"   Es gibt schon eine statusLine: {cmd or current!r}")
    sys.exit(3)

if os.path.exists(path):
    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"   Backup: {backup}")

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
if os.path.exists(path):
    shutil.copymode(path, tmp)
os.replace(tmp, path)
print("   OK – Claude Code lädt die Settings automatisch neu.")
PY
fi

echo
if [[ $SETTINGS_RC -eq 3 ]]; then
    cat <<EOF
!!  statusLine NICHT geändert, weil du schon eine eigene hast. Optionen:
    a) ./install.sh --wrap-existing   (Hook läuft davor, deine Zeile bleibt)
    b) In deinem Statusline-Skript eine Zeile ergänzen, die das JSON weiterreicht:
         input=\$(cat); printf '%s' "\$input" | $HOOK_DST --quiet
EOF
elif [[ $SETTINGS_RC -ne 0 ]]; then
    echo "!!  settings.json konnte nicht angepasst werden (Code $SETTINGS_RC)."
fi

cat <<EOF

Fertig. Nächste Schritte:
  1. Rechtsklick auf die Kontrollleiste → "Widgets hinzufügen…" → "Claude Usage" reinziehen.
  2. Claude Code starten und eine Nachricht schicken (Pro/Max-Abo nötig).
  3. Kontrolle im Terminal:  $HOOK_DST --show
EOF
if [[ $UPGRADED -eq 1 ]]; then
    echo
    echo "Update: Plasma lädt geänderten Widget-Code erst nach Neustart der Shell:"
    echo "  systemctl --user restart plasma-plasmashell.service"
fi
