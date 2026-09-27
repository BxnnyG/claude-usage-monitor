#!/usr/bin/env bash
# Entfernt alles, was install.sh angelegt hat. Eine per --chain eingebundene
# eigene statusLine wird wiederhergestellt.
set -euo pipefail

PLASMOID_ID="local.claudeusage"
HOOK_DST="$HOME/.local/bin/claude-usage-hook"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
CACHE_DIR="$HOME/.cache/claude-usage"

echo "Tipp: Widget vorher aus der Kontrollleiste entfernen, sonst bleibt dort ein Fehler-Platzhalter."
echo

if [[ -f "$SETTINGS" ]]; then
    echo "==> statusLine in $SETTINGS zurückbauen"
    python3 - "$SETTINGS" "$HOOK_DST" <<'PY' || echo "   (übersprungen)"
import json, os, shlex, shutil, sys, tempfile, time

path, hook = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    settings = json.load(fh)
current = settings.get("statusLine")
cmd = current.get("command", "") if isinstance(current, dict) else ""
if not (cmd.startswith(hook) or cmd.startswith(shlex.quote(hook))):
    print("   statusLine gehört nicht zu diesem Tool – bleibt unverändert.")
    sys.exit(0)

argv = shlex.split(cmd)
if "--chain" in argv and argv.index("--chain") + 1 < len(argv):
    restored = argv[argv.index("--chain") + 1]
    settings["statusLine"] = dict(current, command=restored)
    print(f"   Ursprüngliche statusLine wiederhergestellt: {restored}")
else:
    del settings["statusLine"]
    print("   statusLine entfernt.")

shutil.copy2(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
shutil.copymode(path, tmp)
os.replace(tmp, path)
PY
fi

echo "==> Plasmoid entfernen"
kpackagetool6 --type Plasma/Applet --remove "$PLASMOID_ID" 2>/dev/null || echo "   war nicht installiert"

echo "==> Auto-Refresh-Timer entfernen"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [[ -f "$UNIT_DIR/claude-usage-refresh.timer" ]]; then
    systemctl --user disable --now claude-usage-refresh.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/claude-usage-refresh.service" "$UNIT_DIR/claude-usage-refresh.timer"
    systemctl --user daemon-reload 2>/dev/null || true
else
    echo "   war nicht eingerichtet"
fi

echo "==> Hook und Cache entfernen"
rm -f "$HOOK_DST" "$HOME/.local/bin/claude-usage-refresh"
rm -rf "$CACHE_DIR"

echo "Fertig."
