# CLAUDE.md — Waveshare RPi Relay Board (B) Project

## Project Summary

Bash CLI + Python web server to control a **Waveshare RPi Relay Board (B)**
on a **Raspberry Pi 5** using libgpiod.

- `relay_control.sh` — CLI (on/off/toggle/pulse/status/reset/stop)
- `relay_web.py` — Flask REST API + HTML dashboard on port 8080
- `templates/index.html` — live web UI, auto-refreshes every 3 s

## Critical Hardware Facts

| Property     | Value                                      |
|--------------|--------------------------------------------|
| Board        | Waveshare RPi Relay Board (B)              |
| Channels     | **8**                                      |
| CH1 BCM pin  | **5**                                      |
| CH2 BCM pin  | **6**                                      |
| CH3 BCM pin  | **13**                                     |
| CH4 BCM pin  | **16**                                     |
| CH5 BCM pin  | **19**                                     |
| CH6 BCM pin  | **20**                                     |
| CH7 BCM pin  | **21**                                     |
| CH8 BCM pin  | **26**                                     |
| Logic        | **Active-low** (GPIO 0 = relay ON)         |
| Platform     | Raspberry Pi 5                             |
| GPIO driver  | libgpiod (NOT sysfs, NOT RPi.GPIO)         |

## Critical Software Facts

### Why libgpiod (not sysfs)?
The `/sys/class/gpio` sysfs interface is **deprecated on RPi 5**
and may not work at all. Always use `gpioset`/`gpioget` from the
`gpiod` apt package.

### The --mode=exit Problem (DO NOT USE)
```bash
# WRONG — relay clicks and immediately releases
gpioset --mode=exit gpiochip0 26=0
```
When `gpioset --mode=exit` is used, the line is released on exit.
The relay de-energizes almost instantly. **Never use this for relay control.**

### Persistent GPIO: Correct Approach
```bash
# v1.x (RPi OS Bookworm default via apt):
gpioset --mode=signal gpiochip0 26=0 &   # held until SIGTERM

# v2.x (if installed from source):
mkfifo /tmp/gpio_fifo
gpioset --interactive gpiochip0 26=0 < /tmp/gpio_fifo &
sleep infinity > /tmp/gpio_fifo &        # keeps FIFO open → no EOF
```

### GPIO Chip on RPi 5
The RPi 5 uses an RP1 southbridge chip. The 40-pin header GPIO
may appear on `gpiochip0` or `gpiochip4` depending on firmware version.
- Detect: `gpiodetect`
- The chip with the most lines (54 on RPi 5) is the right one.
- The script auto-selects the chip with the highest line count ≥ 27.

### Exclusive Line Ownership
libgpiod enforces exclusive access to GPIO lines:
- A line held by `gpioset --mode=signal` **cannot** be read by `gpioget`
- State is tracked via files in `/tmp/relay_board_b/chN.state`
- The `status` command uses saved state, not live GPIO reads

## Script Architecture

```
relay_control.sh
├── check_deps()          — verify gpioset/gpioget/gpiodetect/gpioinfo
├── detect_gpiod_version()— parse 'gpioset --version' for major version
├── detect_gpio_chip()    — find chip with most lines (≥27 needed)
├── _gpio_set(ch, value)  — start/restart background daemon for a channel
│   ├── v1.x: gpioset --mode=signal <chip> <pin>=<value> &
│   └── v2.x: gpioset --interactive + sleep-infinity FIFO trick
├── _gpio_release(ch)     — kill daemon(s), clean up PID/FIFO files
├── relay_on/off/toggle/pulse — high-level relay operations
├── relay_status()        — display state table with daemon health
└── main()                — argument parsing and dispatch
```

## State Directory Layout

```
/tmp/relay_board_b/
├── ch1.pid      one PID per line (v2.x has two: gpioset + feeder)
├── ch1.state    "on" | "off" | "unknown"
├── ch1.fifo     named FIFO (v2.x only)
├── ch2.pid
├── ch2.state
└── ch3.pid / ch3.state
```

## Common Tasks for Claude

### Changing pin assignments
Edit `CH_PINS` in `relay_control.sh` AND `BCM_PINS` in `relay_web.py`:
```bash
# relay_control.sh
readonly -a CH_PINS=(0 5 6 13 16 19 20 21 26)   # index 0 unused, CH1-CH8
```
```python
# relay_web.py
BCM_PINS: dict[int, int] = {1:5, 2:6, 3:13, 4:16, 5:19, 6:20, 7:21, 8:26}
```

### Starting the web server
```bash
cd /path/to/waveshare-relay-b
python3 relay_web.py          # port 8080
PORT=9090 python3 relay_web.py
```

### REST API quick reference
```
GET  /api/status
POST /api/relay/{1-8}/on|off|toggle
POST /api/relay/{1-8}/pulse?ms=500
POST /api/all/on
POST /api/all/off
```

### Changing active-low to active-high
```bash
readonly GPIO_ON=1    # was 0
readonly GPIO_OFF=0   # was 1
```

### Running as a systemd service
See README.txt for daemon persistence notes.
To make relays survive a reboot, a systemd service must call
`relay_control.sh reset` on start to establish desired state.

## Testing Checklist

Before reporting changes as complete, verify on the RPi 5:
- [ ] `./relay_control.sh status` shows all channels with daemon PID
- [ ] `./relay_control.sh on 1` and relay audibly clicks ON
- [ ] `./relay_control.sh off 1` and relay clicks OFF
- [ ] `./relay_control.sh pulse 2 500` produces a 500ms click
- [ ] `./relay_control.sh toggle 3` works bidirectionally
- [ ] `./relay_control.sh off all` turns all three OFF
- [ ] `DEBUG=1 ./relay_control.sh status` shows chip/version info
- [ ] `./relay_control.sh stop` kills all daemons (verify with `ps aux | grep gpioset`)

## Do Not

- Do not use `--mode=exit` anywhere in GPIO operations
- Do not use `echo > /sys/class/gpio/...` (sysfs — deprecated on RPi 5)
- Do not add channels beyond 8 — this board has exactly 8 channels
- Do not use `gpioget` on a line held by the daemon (it will fail)
- Do not call `gpioset` without backgrounding it for relay control
