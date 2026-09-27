#!/usr/bin/env bash
# Einzeiler-Installation:
#   curl -fsSL https://raw.githubusercontent.com/BxnnyG/claude-usage-monitor/HEAD/get.sh | bash
# Optionen werden an install.sh durchgereicht:
#   curl -fsSL .../get.sh | bash -s -- --wrap-existing
# Bestimmte Version statt aktuellem Stand: CLAUDE_USAGE_REF=<tag|branch|commit>
set -euo pipefail

REPO="BxnnyG/claude-usage-monitor"
REF="${CLAUDE_USAGE_REF:-HEAD}"

# Alles in einer Funktion: bei "curl | bash" läuft erst etwas, wenn das
# Skript komplett übertragen ist (kein halb ausgeführtes Skript bei Abbruch).
main() {
    command -v curl >/dev/null 2>&1 || { echo "Fehlt: curl" >&2; exit 1; }
    command -v tar >/dev/null 2>&1 || { echo "Fehlt: tar" >&2; exit 1; }

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf -- "$TMP_DIR"' EXIT

    echo "==> Lade $REPO ($REF)"
    curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xz -C "$TMP_DIR" --strip-components=1

    bash "$TMP_DIR/install.sh" "$@"
}

main "$@"
