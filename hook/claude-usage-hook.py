#!/usr/bin/env python3
"""claude-usage-hook - statusLine-Befehl fuer Claude Code.

Ablauf:
  1. Claude Code ruft dieses Skript bei jedem Statusline-Update auf und schickt
     Sitzungsdaten als JSON auf stdin (offiziell dokumentiert:
     https://code.claude.com/docs/en/statusline).
  2. Wir lesen daraus NUR `rate_limits` (five_hour / seven_day / ggf. spend_limit)
     und schreiben sie atomar nach ~/.cache/claude-usage/state.json.
  3. Wir geben eine Statuszeile fuer Claude Code aus - die eigene oder, mit
     --chain, die eines bestehenden Statusline-Skripts.

Was dieses Skript NICHT tut: kein Netzwerk, keine Tokens/Cookies/Credentials
lesen, keine Abhaengigkeiten ausser der Python-Standardbibliothek.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime

STATE_VERSION = 1

# spend_limit darf laut Doku ueber 100 gehen. Alles weit darueber ist Muell -
# z. B. der bekannte Bug, bei dem ein Epoch-Timestamp in used_percentage landete
# (anthropics/claude-code#52326).
MAX_PERCENT = 1000.0

# Nur fuer Payloads ohne session_id: hat sich inhaltlich nichts geaendert, nur
# alle N Sekunden neu schreiben (um updated_at aufzufrischen).
MIN_REWRITE_SECONDS = 30

# Wie weit resets_at desselben Fensters zwischen zwei Meldungen abweichen darf.
# Ein neues 5h-/7d-Fenster beginnt erst nach dem Reset des alten, sein resets_at
# liegt also Stunden bis Tage spaeter.
SAME_WINDOW_TOLERANCE = 3600

# Pro Claude-Code-Session merken wir uns den zuletzt gemeldeten Stand, um reine
# Wiederholungen ohne neue API-Antwort zu erkennen (siehe update_state).
MAX_SESSIONS = 32
SESSION_TTL = 8 * 86400

WARN_PERCENT = 70.0
CRIT_PERCENT = 90.0


def state_path() -> str:
    # Bewusst fester Pfad (kein XDG_CACHE_HOME): Hook laeuft in der Umgebung von
    # Claude Code, das Plasmoid in der von plasmashell. Beide muessen sicher
    # dieselbe Datei meinen. CLAUDE_USAGE_STATE ist nur fuer Tests gedacht.
    return os.environ.get("CLAUDE_USAGE_STATE") or os.path.expanduser(
        "~/.cache/claude-usage/state.json"
    )


def to_epoch(value) -> int | None:
    """resets_at ist laut Doku Unix-Sekunden. ISO-Strings/ms nur defensiv."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        value = float(value)
        if value > 1e12:  # sieht nach Millisekunden aus
            value /= 1000.0
        return int(value) if value > 0 else None
    if isinstance(value, str) and value:
        try:
            return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
        except ValueError:
            return None
    return None


def parse_windows(payload: dict) -> dict:
    """Extrahiert alle plausiblen Rate-Limit-Fenster aus dem statusLine-JSON."""
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return {}
    out = {}
    for name, win in rate_limits.items():
        if not isinstance(win, dict):
            continue
        pct = win.get("used_percentage")
        if isinstance(pct, bool) or not isinstance(pct, (int, float)):
            continue
        pct = float(pct)
        if not 0.0 <= pct <= MAX_PERCENT:
            continue
        out[str(name)] = {
            "used_percentage": round(pct, 2),
            "resets_at": to_epoch(win.get("resets_at")),
        }
    return out


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def atomic_write_json(path: str, data: dict) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, separators=(",", ":"))
        os.replace(tmp, path)  # atomar: Leser sehen nie eine halbe Datei
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _comparable(windows: dict) -> dict:
    return {
        k: (w.get("used_percentage"), w.get("resets_at"))
        for k, w in windows.items()
        if isinstance(w, dict)
    }


def _num(value) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def is_newer(old, new: dict, now: int, allow_decrease: bool = False) -> bool:
    """Ist die Meldung `new` mindestens so aktuell wie der gespeicherte Stand `old`?

    Innerhalb eines Fensters steigt die Nutzung nur. Ein kleinerer Wert fuer
    dasselbe Fenster stammt deshalb fast immer aus einer anderen Session, die
    seit ihrer letzten API-Antwort untaetig ist und nur neu rendert.
    """
    if not isinstance(old, dict):
        return True
    old_reset = _num(old.get("resets_at"))
    new_reset = new.get("resets_at")
    if old_reset and old_reset <= now:
        return True  # gespeichertes Fenster ist schon abgelaufen
    if old_reset and new_reset:
        if new_reset > old_reset + SAME_WINDOW_TOLERANCE:
            return True  # neues Fenster
        if new_reset < old_reset - SAME_WINDOW_TOLERANCE:
            return False  # aelteres Fenster
    if allow_decrease:
        return True
    return new["used_percentage"] >= (_num(old.get("used_percentage")) or 0.0)


def _prune_sessions(sessions: dict, now: int) -> dict:
    alive = [
        (sid, rec)
        for sid, rec in sessions.items()
        if isinstance(rec, dict) and now - (_num(rec.get("seen")) or 0) < SESSION_TTL
    ]
    alive.sort(key=lambda item: _num(item[1].get("seen")) or 0, reverse=True)
    return dict(alive[:MAX_SESSIONS])


def update_state(payload: dict, now: int) -> dict:
    """Merged neue Fenster in die State-Datei und gibt den aktuellen Stand zurueck."""
    path = state_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    # Mehrere Claude-Code-Sessions koennen gleichzeitig schreiben.
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _update_state_locked(path, payload, now)


def _update_state_locked(path: str, payload: dict, now: int) -> dict:
    reported = parse_windows(payload)
    old = load_state(path)
    old_windows = _dict(old.get("windows"))

    if not reported:
        # Nichts Neues - z. B. vor der ersten API-Antwort einer Session, oder
        # Claude Code hat ein Fenster nach dessen Reset weggelassen.
        # Alten Stand behalten; das Widget erkennt Resets selbst.
        return old_windows

    # Claude Code ruft die statusLine nicht nur nach API-Antworten auf, sondern
    # auch bei Moduswechsel, Ablauf des Prompt-Caches, refreshInterval usw. -
    # dann mit den rate_limits der letzten Antwort DIESER Session. Laufen mehrere
    # Sessions, wuerde eine laenger untaetige Session so den frischeren Stand
    # einer anderen mit alten Werten ueberschreiben. Deshalb merken wir uns pro
    # Session, was sie zuletzt gemeldet hat, und werten reine Wiederholungen
    # nicht als neue Daten.
    old_sessions = _dict(old.get("sessions"))
    sessions = dict(old_sessions)
    sid = payload.get("session_id")
    sid = sid if isinstance(sid, str) and sid else None
    prev = sessions.get(sid) if sid else None
    prev = prev if isinstance(prev, dict) else None
    prev_windows = _dict(prev.get("windows")) if prev else {}
    cost = _dict(payload.get("cost"))
    api_ms = _num(cost.get("total_api_duration_ms"))
    record = {
        "api_ms": api_ms,
        "windows": {k: [w["used_percentage"], w["resets_at"]] for k, w in reported.items()},
    }
    if prev is not None and prev.get("api_ms") == api_ms and prev_windows == record["windows"]:
        return old_windows  # exakt dieselbe Meldung wie zuletzt: nichts zu tun
    api_changed = prev is not None and api_ms is not None and api_ms != _num(prev.get("api_ms"))

    merged = {k: v for k, v in old_windows.items() if isinstance(v, dict)}
    accepted = False
    for key, win in reported.items():
        own_changed = prev is not None and prev_windows.get(key) != [
            win["used_percentage"],
            win["resets_at"],
        ]
        if prev is not None and not (api_changed or own_changed):
            continue  # Wiederholung ohne neue API-Antwort
        # Hat die Session selbst einen anderen Wert als zuletzt, kam er aus einer
        # neuen API-Antwort - dann auch einen kleineren Wert glauben.
        if is_newer(merged.get(key), win, now, allow_decrease=own_changed):
            merged[key] = dict(win, seen_at=now)
            accepted = True

    if sid:
        sessions[sid] = dict(record, seen=now)
        sessions = _prune_sessions(sessions, now)

    last_update = _num(old.get("updated_at")) or 0
    if not accepted and sessions == old_sessions:
        return merged
    if (
        accepted
        and sid is None
        and _comparable(merged) == _comparable(old_windows)
        and now - last_update < MIN_REWRITE_SECONDS
    ):
        return merged

    version = payload.get("version")
    atomic_write_json(
        path,
        {
            "version": STATE_VERSION,
            "source": "claude-code-statusline",
            # Zeitpunkt der letzten neuen Daten, nicht des letzten Schreibens.
            "updated_at": now if accepted else (int(last_update) or None),
            "claude_code_version": version
            if accepted and isinstance(version, str)
            else old.get("claude_code_version"),
            "windows": merged,
            "sessions": sessions,
        },
    )
    return merged


def _colorize(pct: float, text: str) -> str:
    if pct >= CRIT_PERCENT:
        return f"\033[31m{text}\033[0m"
    if pct >= WARN_PERCENT:
        return f"\033[33m{text}\033[0m"
    return text


def render_line(payload: dict, windows: dict, now: int) -> str:
    model = payload.get("model")
    name = model.get("display_name") if isinstance(model, dict) else None
    head = f"[{name}]" if name else "[Claude]"
    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        win = windows.get(key)
        if not isinstance(win, dict):
            continue
        resets_at = win.get("resets_at")
        if resets_at and resets_at <= now:
            continue  # Fenster ist schon zurueckgesetzt, Wert waere falsch
        pct = float(win.get("used_percentage", 0))
        parts.append(_colorize(pct, f"{label} {pct:.0f}%"))
    return f"{head} {' | '.join(parts)}" if parts else head


def _fmt_ts(epoch) -> str:
    return datetime.fromtimestamp(epoch).strftime("%a %d.%m. %H:%M") if epoch else "?"


def _fmt_dur(seconds: float) -> str:
    seconds = int(max(0, seconds))
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d} T {h} h"
    if h:
        return f"{h} h {m} min"
    return f"{m} min"


def show_state() -> int:
    path = state_path()
    state = load_state(path)
    if not state:
        print(f"Keine Daten in {path}")
        print("Claude Code starten und eine Nachricht schicken (Pro/Max-Abo noetig).")
        return 1
    now = time.time()
    print(f"Datei:  {path}")
    updated = state.get("updated_at")
    if updated:
        print(f"Stand:  {_fmt_ts(updated)} (vor {_fmt_dur(now - updated)})")
    for key, win in (state.get("windows") or {}).items():
        resets_at = win.get("resets_at")
        if resets_at and resets_at <= now:
            status = f"zurueckgesetzt am {_fmt_ts(resets_at)}"
        elif resets_at:
            status = f"Reset {_fmt_ts(resets_at)} (in {_fmt_dur(resets_at - now)})"
        else:
            status = "Reset unbekannt"
        print(f"{key:<12} {float(win.get('used_percentage', 0)):6.1f} %   {status}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Claude-Code-statusLine-Hook: schreibt rate_limits nach "
        "~/.cache/claude-usage/state.json.",
    )
    parser.add_argument(
        "--chain",
        metavar="CMD",
        help="Danach dieses Statusline-Kommando mit demselben stdin ausfuehren "
        "und dessen Ausgabe anzeigen (um eine bestehende Statusline zu behalten).",
    )
    parser.add_argument("--quiet", action="store_true", help="Nur State schreiben, nichts ausgeben.")
    parser.add_argument("--show", action="store_true", help="Aktuellen Stand lesbar ausgeben.")
    args = parser.parse_args(argv)

    if args.show:
        return show_state()

    raw = sys.stdin.buffer.read()
    now = int(time.time())
    try:
        payload = json.loads(raw.decode("utf-8") or "{}")
    except (UnicodeDecodeError, ValueError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    windows: dict = {}
    try:
        windows = update_state(payload, now)
    except Exception as exc:  # Die Statusline darf nie wegen uns ausfallen
        print(f"claude-usage-hook: {exc}", file=sys.stderr)

    if args.chain:
        try:
            proc = subprocess.run(
                args.chain, shell=True, input=raw, stdout=subprocess.PIPE, check=False
            )
            sys.stdout.buffer.write(proc.stdout)
            sys.stdout.flush()
            return proc.returncode
        except OSError as exc:
            print(f"claude-usage-hook: --chain fehlgeschlagen: {exc}", file=sys.stderr)

    if not args.quiet:
        print(render_line(payload, windows, now))
    return 0


if __name__ == "__main__":
    sys.exit(main())
