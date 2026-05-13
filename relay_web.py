#!/usr/bin/env python3
"""
Waveshare RPi Relay Board (B) - Web Controller v1.0.0
REST API + live HTML dashboard for 8-channel relay board on Raspberry Pi 5.

Usage:
    python3 relay_web.py            # listens on 0.0.0.0:8080
    PORT=9090 python3 relay_web.py  # custom port

Requires: flask  (sudo apt install python3-flask)
"""

import os
import subprocess
from flask import Flask, jsonify, render_template, request

# ── Config ────────────────────────────────────────────────────────
RELAY_SCRIPT = os.environ.get("RELAY_SCRIPT", "/usr/local/bin/relay_control.sh")
STATE_DIR    = "/tmp/relay_board_b"
HOST         = "0.0.0.0"
PORT         = int(os.environ.get("PORT", 8080))

# BCM pin for each channel (source: RPi_Relay_Board_(B)_User_Manual_EN.pdf)
BCM_PINS: dict[int, int] = {
    1: 5, 2: 6, 3: 13, 4: 16,
    5: 19, 6: 20, 7: 21, 8: 26,
}
CHANNELS = list(BCM_PINS)

app = Flask(__name__)

# ── Helpers ───────────────────────────────────────────────────────

def _run(args: list[str], timeout: int = 10) -> tuple[bool, str]:
    """Run relay_control.sh; return (success, combined output)."""
    try:
        r = subprocess.run(
            [RELAY_SCRIPT] + args,
            capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as exc:
        return False, str(exc)


def _read_state(ch: int) -> str:
    """Read /tmp/relay_board_b/chN.state."""
    try:
        with open(os.path.join(STATE_DIR, f"ch{ch}.state")) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return "unknown"


def _all_states() -> dict:
    return {
        str(ch): {"state": _read_state(ch), "bcm": BCM_PINS[ch]}
        for ch in CHANNELS
    }


def _ch_json(ch: int, ok: bool, msg: str) -> dict:
    return {
        "channel": ch,
        "bcm":     BCM_PINS[ch],
        "state":   _read_state(ch),
        "success": ok,
        "message": msg,
    }

# ── Routes ────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    """Return current state of all 8 relays."""
    return jsonify({"relays": _all_states()})


@app.route("/api/relay/<int:ch>/on", methods=["POST"])
def relay_on(ch: int):
    if ch not in CHANNELS:
        return jsonify({"error": f"Invalid channel {ch}. Valid: 1-8"}), 400
    ok, msg = _run(["on", str(ch)])
    return jsonify(_ch_json(ch, ok, msg)), 200 if ok else 500


@app.route("/api/relay/<int:ch>/off", methods=["POST"])
def relay_off(ch: int):
    if ch not in CHANNELS:
        return jsonify({"error": f"Invalid channel {ch}. Valid: 1-8"}), 400
    ok, msg = _run(["off", str(ch)])
    return jsonify(_ch_json(ch, ok, msg)), 200 if ok else 500


@app.route("/api/relay/<int:ch>/toggle", methods=["POST"])
def relay_toggle(ch: int):
    if ch not in CHANNELS:
        return jsonify({"error": f"Invalid channel {ch}. Valid: 1-8"}), 400
    ok, msg = _run(["toggle", str(ch)])
    return jsonify(_ch_json(ch, ok, msg)), 200 if ok else 500


@app.route("/api/relay/<int:ch>/pulse", methods=["POST"])
def relay_pulse(ch: int):
    if ch not in CHANNELS:
        return jsonify({"error": f"Invalid channel {ch}. Valid: 1-8"}), 400
    ms = request.args.get("ms", "1000")
    if not ms.isdigit() or int(ms) < 1:
        return jsonify({"error": "ms must be a positive integer"}), 400
    ok, msg = _run(["pulse", str(ch), ms], timeout=int(ms) // 1000 + 5)
    return jsonify(_ch_json(ch, ok, msg)), 200 if ok else 500


@app.route("/api/all/on", methods=["POST"])
def all_on():
    ok, msg = _run(["on", "all"])
    return jsonify({"success": ok, "message": msg, "relays": _all_states()})


@app.route("/api/all/off", methods=["POST"])
def all_off():
    ok, msg = _run(["reset"])
    return jsonify({"success": ok, "message": msg, "relays": _all_states()})


if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
