"""Tests fuer hook/claude-usage-hook.py - laufen mit: python3 -m unittest discover tests"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parent.parent / "hook" / "claude-usage-hook.py"


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "sub" / "state.json"
        self.env = dict(os.environ, CLAUDE_USAGE_STATE=str(self.state))

    def tearDown(self):
        self.tmp.cleanup()

    def run_hook(self, payload, *args):
        data = payload if isinstance(payload, (bytes, str)) else json.dumps(payload)
        if isinstance(data, str):
            data = data.encode()
        return subprocess.run(
            [sys.executable, str(HOOK), *args],
            input=data, capture_output=True, env=self.env, timeout=10,
        )

    def read_state(self):
        return json.loads(self.state.read_text())

    def write_state(self, state):
        self.state.write_text(json.dumps(state))

    def payload(self, five=23.5, seven=41.2, offset=3600, session=None, api_ms=None):
        now = int(time.time())
        p = {
            "model": {"display_name": "Opus"},
            "version": "2.1.260",
            "rate_limits": {
                "five_hour": {"used_percentage": five, "resets_at": now + offset},
                "seven_day": {"used_percentage": seven, "resets_at": now + 5 * 86400},
            },
        }
        if session is not None:
            p["session_id"] = session
        if api_ms is not None:
            p["cost"] = {"total_api_duration_ms": api_ms}
        return p

    def age_state(self, seconds=3600):
        """Tut so, als waere der gespeicherte Stand `seconds` alt."""
        st = self.read_state()
        st["updated_at"] -= seconds
        for win in st["windows"].values():
            win["seen_at"] -= seconds
        self.write_state(st)
        return st

    def test_writes_state_and_prints_line(self):
        res = self.run_hook(self.payload())
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("[Opus] 5h 24% | 7d 41%", res.stdout.decode())
        st = self.read_state()
        self.assertEqual(st["windows"]["five_hour"]["used_percentage"], 23.5)
        self.assertEqual(st["windows"]["seven_day"]["used_percentage"], 41.2)
        self.assertEqual(st["claude_code_version"], "2.1.260")
        self.assertEqual(oct(self.state.stat().st_mode & 0o777), "0o600")

    def test_missing_rate_limits_keeps_old_state(self):
        self.run_hook(self.payload())
        before = self.read_state()
        res = self.run_hook({"model": {"display_name": "Opus"}})
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.read_state(), before)
        # Statusline zeigt trotzdem den letzten bekannten Stand
        self.assertIn("5h 24%", res.stdout.decode())

    def test_epoch_leak_bug_is_ignored(self):
        p = self.payload()
        p["rate_limits"]["five_hour"]["used_percentage"] = 1776950400
        self.run_hook(p)
        st = self.read_state()
        self.assertNotIn("five_hour", st["windows"])
        self.assertIn("seven_day", st["windows"])

    def test_iso_resets_at_is_converted(self):
        p = self.payload()
        p["rate_limits"]["five_hour"]["resets_at"] = "2030-01-01T12:00:00Z"
        self.run_hook(p)
        self.assertEqual(self.read_state()["windows"]["five_hour"]["resets_at"], 1893499200)

    def test_expired_window_not_shown_in_statusline(self):
        res = self.run_hook(self.payload(offset=-60))
        self.assertNotIn("5h", res.stdout.decode())
        self.assertIn("7d 41%", res.stdout.decode())

    def test_partial_update_merges(self):
        self.run_hook(self.payload())
        p = self.payload(five=50)
        del p["rate_limits"]["seven_day"]
        self.run_hook(p)
        st = self.read_state()
        self.assertEqual(st["windows"]["five_hour"]["used_percentage"], 50)
        self.assertEqual(st["windows"]["seven_day"]["used_percentage"], 41.2)

    def test_unchanged_data_is_throttled(self):
        self.run_hook(self.payload())
        first = self.read_state()["updated_at"]
        mtime = self.state.stat().st_mtime_ns
        self.run_hook(self.payload())
        self.assertEqual(self.read_state()["updated_at"], first)
        self.assertEqual(self.state.stat().st_mtime_ns, mtime)

    def test_chain_passes_stdin_through(self):
        payload = self.payload()
        res = self.run_hook(payload, "--chain", "cat")
        self.assertEqual(json.loads(res.stdout), payload)
        self.assertTrue(self.state.exists())

    def test_chain_returncode_is_forwarded(self):
        res = self.run_hook(self.payload(), "--chain", "echo hi; exit 3")
        self.assertEqual(res.returncode, 3)
        self.assertEqual(res.stdout.decode().strip(), "hi")

    def test_garbage_input_never_crashes(self):
        for junk in (b"", b"not json", b"[1,2,3]", b"\xff\xfe", b'{"rate_limits": 5}'):
            res = self.run_hook(junk)
            self.assertEqual(res.returncode, 0, (junk, res.stderr))
            self.assertTrue(res.stdout.strip())

    def test_quiet_prints_nothing(self):
        res = self.run_hook(self.payload(), "--quiet")
        self.assertEqual(res.stdout, b"")
        self.assertTrue(self.state.exists())

    # --- mehrere Sessions / reine Wiederholungen -------------------------

    def test_idle_session_does_not_overwrite_fresher_value(self):
        self.run_hook(self.payload(five=40, session="A", api_ms=1000))
        # Session B war laenger untaetig und rendert mit ihrem alten Stand neu
        self.run_hook(self.payload(five=20, session="B", api_ms=500))
        self.assertEqual(self.read_state()["windows"]["five_hour"]["used_percentage"], 40)

    def test_repeat_without_api_response_keeps_timestamps(self):
        p = self.payload(session="A", api_ms=1000)
        self.run_hook(p)
        before = self.age_state()
        res = self.run_hook(p)  # z. B. Prompt-Cache abgelaufen, Moduswechsel
        self.assertEqual(self.read_state(), before)
        self.assertIn("5h 24%", res.stdout.decode())

    def test_new_api_response_refreshes_timestamps(self):
        self.run_hook(self.payload(session="A", api_ms=1000))
        before = self.age_state()
        self.run_hook(self.payload(session="A", api_ms=1800))  # gleiche Werte
        st = self.read_state()
        self.assertGreater(st["updated_at"], before["updated_at"])
        self.assertGreater(
            st["windows"]["five_hour"]["seen_at"], before["windows"]["five_hour"]["seen_at"]
        )

    def test_known_session_may_report_lower_value(self):
        self.run_hook(self.payload(five=40, session="A", api_ms=1000))
        self.run_hook(self.payload(five=30, session="A", api_ms=2000))
        self.assertEqual(self.read_state()["windows"]["five_hour"]["used_percentage"], 30)

    def test_new_window_replaces_old_even_if_lower(self):
        self.run_hook(self.payload(five=40, session="A", api_ms=1000))
        self.run_hook(self.payload(five=5, offset=3600 + 5 * 3600, session="B", api_ms=10))
        self.assertEqual(self.read_state()["windows"]["five_hour"]["used_percentage"], 5)

    def test_older_window_is_ignored(self):
        self.run_hook(self.payload(five=10, offset=5 * 3600, session="A", api_ms=1000))
        self.run_hook(self.payload(five=90, offset=600, session="B", api_ms=10))
        self.assertEqual(self.read_state()["windows"]["five_hour"]["used_percentage"], 10)

    def test_dropped_window_rerender_is_not_fresh_data(self):
        p = self.payload(session="A", api_ms=1000)
        self.run_hook(p)
        before = self.age_state()
        del p["rate_limits"]["five_hour"]  # Claude Code verwirft Fenster nach Reset
        self.run_hook(p)
        st = self.read_state()
        self.assertEqual(st["updated_at"], before["updated_at"])
        self.assertEqual(st["windows"]["seven_day"], before["windows"]["seven_day"])

    def test_session_list_is_capped(self):
        spec = importlib.util.spec_from_file_location("claude_usage_hook", HOOK)
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        os.environ["CLAUDE_USAGE_STATE"] = str(self.state)
        try:
            now = int(time.time())
            for i in range(hook.MAX_SESSIONS + 8):
                hook.update_state(self.payload(session=f"s{i}", api_ms=i), now + i)
        finally:
            del os.environ["CLAUDE_USAGE_STATE"]
        sessions = self.read_state()["sessions"]
        self.assertEqual(len(sessions), hook.MAX_SESSIONS)
        self.assertIn(f"s{hook.MAX_SESSIONS + 7}", sessions)
        self.assertNotIn("s0", sessions)

    def test_show(self):
        self.assertEqual(self.run_hook(b"", "--show").returncode, 1)
        self.run_hook(self.payload())
        res = self.run_hook(b"", "--show")
        self.assertEqual(res.returncode, 0)
        self.assertIn("five_hour", res.stdout.decode())


if __name__ == "__main__":
    unittest.main()
