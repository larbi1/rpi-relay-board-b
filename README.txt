========================================================
 Waveshare RPi Relay Board (B) — Controller v1.5.1
 Raspberry Pi 5 · libgpiod · Web Dashboard
========================================================

OVERVIEW
--------
A bash relay controller + Python web server for the Waveshare
RPi Relay Board (B) on a Raspberry Pi 5.

  relay_control.sh  — CLI: on/off/toggle/pulse/status/reset/stop
  relay_web.py      — Flask REST API + live HTML dashboard (port 8080)

The sysfs GPIO interface (/sys/class/gpio) is deprecated on RPi 5.
Both tools use gpioset/gpioget from the 'gpiod' package instead.


BOARD SPECIFICATIONS
--------------------
  Product:  Waveshare RPi Relay Board (B)
  Channels: 8
  Logic:    Active-low  (GPIO LOW = relay ON)

  BCM Pin Mapping (source: RPi_Relay_Board_(B)_User_Manual_EN.pdf):
    CH1 → BCM 5    (header pin 29)
    CH2 → BCM 6    (header pin 31)
    CH3 → BCM 13   (header pin 33)
    CH4 → BCM 16   (header pin 36)
    CH5 → BCM 19   (header pin 35)
    CH6 → BCM 20   (header pin 38)
    CH7 → BCM 21   (header pin 40)
    CH8 → BCM 26   (header pin 37)


REQUIREMENTS
------------
  Hardware:
    - Raspberry Pi 5
    - Waveshare RPi Relay Board (B) connected to 40-pin header

  Software:
    - Raspberry Pi OS Bookworm (Debian 12+)
    - libgpiod:  sudo apt install gpiod bc
    - Web server: sudo apt install python3-flask  (optional)


INSTALLATION
------------
  1. Copy relay_control.sh to the RPi:
       scp relay_control.sh akaw@<rpi5-ip>:/tmp/
       ssh akaw@<rpi5-ip> "sudo cp /tmp/relay_control.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/relay_control.sh"

  2. Install GPIO tools:
       sudo apt update && sudo apt install gpiod bc

  3. Test:
       relay_control.sh status
       relay_control.sh on 1
       relay_control.sh off 1


CLI USAGE
---------
  relay_control.sh <command> [channel] [options]

  Commands:
    on     <1-8|all>       Turn relay(s) ON  (GPIO goes LOW)
    off    <1-8|all>       Turn relay(s) OFF (GPIO goes HIGH)
    toggle <1-8>           Toggle relay state
    pulse  <1-8> [ms]      Pulse ON for N milliseconds (default 1000)
    status                 Show all states and daemon health
    reset                  Turn all relays OFF cleanly
    stop                   Kill all daemons (lines float)
    help                   Show help

  Examples:
    relay_control.sh on 1
    relay_control.sh off all
    relay_control.sh toggle 2
    relay_control.sh pulse 3 500
    relay_control.sh status

  Debug:
    DEBUG=1 relay_control.sh status


WEB SERVER
----------
  Requirements:
    sudo apt install python3-flask

  Start (from project directory):
    python3 relay_web.py

  Open browser:
    http://<rpi5-ip>:8080

  Custom port:
    PORT=9090 python3 relay_web.py

  REST API endpoints:
    GET  /api/status                    — all relay states (JSON)
    POST /api/relay/{1-8}/on            — turn relay ON
    POST /api/relay/{1-8}/off           — turn relay OFF
    POST /api/relay/{1-8}/toggle        — toggle relay
    POST /api/relay/{1-8}/pulse?ms=500  — pulse ON for N ms
    POST /api/all/on                    — all relays ON
    POST /api/all/off                   — all relays OFF (reset)

  Example API calls:
    curl -s http://<rpi5-ip>:8080/api/status | python3 -m json.tool
    curl -X POST http://<rpi5-ip>:8080/api/relay/1/on
    curl -X POST http://<rpi5-ip>:8080/api/relay/2/toggle
    curl -X POST "http://<rpi5-ip>:8080/api/relay/3/pulse?ms=500"
    curl -X POST http://<rpi5-ip>:8080/api/all/off

  Run on boot (systemd — recommended):
    See SYSTEMD SERVICE section below.


SYSTEMD SERVICE
---------------
  A service file is included: relay-web.service

  Install and enable (one time):
    sudo cp relay-web.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable relay-web
    sudo systemctl start relay-web

  Daily usage:
    sudo systemctl start   relay-web   # start
    sudo systemctl stop    relay-web   # stop
    sudo systemctl restart relay-web   # restart
    sudo systemctl status  relay-web   # status + last log lines

  The service starts automatically on every boot (enabled).
  Restarts automatically if it crashes (Restart=on-failure).


HOW IT WORKS — PERSISTENT GPIO
--------------------------------
libgpiod's gpioset normally releases a GPIO line on exit.
For relays, the line must be held continuously.

This script uses a background daemon to hold the line:

  libgpiod v1.x:  gpioset --mode=signal <chip> <pin>=<value> &
                  Held until SIGTERM.

  libgpiod v2.x:  gpioset --chip <chip> --daemonize <pin>=<value>
                  Forks to background; child holds the line.

The script auto-detects the version. Daemon PIDs are tracked in:
  /tmp/relay_board_b/ch<N>.pid
  /tmp/relay_board_b/ch<N>.state


TROUBLESHOOTING
---------------
Problem: "Missing libgpiod tools"
  → sudo apt install gpiod

Problem: "Device or resource busy"
  → Another process is holding the GPIO line
  → Run: relay_control.sh stop
  → Then retry

Problem: "No suitable GPIO chip found"
  → Run: gpiodetect
  → RPi 5 header GPIO is gpiochip0 (54 lines, label pinctrl-rp1)

Problem: Relay clicks ON then immediately OFF
  → Old code used --mode=exit (wrong). This script uses --daemonize.

Problem: Web server 404 on /
  → Run from the project directory (templates/ must be present)

Problem: Web server "Permission denied" on relay_control.sh
  → Ensure relay_control.sh is executable:
      sudo chmod +x /usr/local/bin/relay_control.sh


ACTIVE-LOW LOGIC
----------------
  GPIO LOW  (0) → relay energized (ON, contact closed)
  GPIO HIGH (1) → relay released  (OFF, contact open)

  'on 1' drives BCM 5 LOW → CH1 relay energizes.


FILES
-----
  relay_control.sh      CLI relay controller (bash)
  relay_web.py          Web server / REST API (Python 3 + Flask)
  templates/index.html  Web dashboard UI
  README.txt            This file
  CLAUDE.md             AI context for this project
  CLAUDE.json           Machine-readable metadata


LICENSE
-------
  MIT License
  Copyright (c) 2025
