#!/usr/bin/env python3
"""
gps_logger.py - read a NEO-6M GPS module over UART on a Raspberry Pi and
append position fixes to a CSV file. A log file is kept next to the CSV.

Usage:
    python3 gps_logger.py /home/pi/gps/track.csv
    python3 gps_logger.py /home/pi/gps/track.csv --port /dev/serial0 --baud 9600 --interval 5

Output:
    /home/pi/gps/track.csv   - one row per fix (UTC time from the satellites)
    /home/pi/gps/track.log   - diagnostics (rotated at 1 MB, 3 backups kept)

Only dependency: pyserial  (sudo apt install python3-serial)
"""

import argparse
import csv
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler

try:
    import serial  # pyserial
except ImportError:
    sys.stderr.write("pyserial is missing. Install it with: sudo apt install python3-serial\n")
    sys.exit(1)

CSV_HEADER = [
    "utc_time", "latitude", "longitude", "altitude_m",
    "speed_kmh", "course_deg", "fix_quality", "satellites", "hdop",
]

KNOTS_TO_KMH = 1.852
NO_DATA_WARN_SECONDS = 10
STATUS_EVERY_SECONDS = 60
RECONNECT_DELAY_SECONDS = 5

log = logging.getLogger("gps_logger")
running = True


# --------------------------------------------------------------------------- #
# NMEA parsing (NMEA 0183 = the plain-text sentence format GPS modules speak)
# --------------------------------------------------------------------------- #

def checksum_ok(sentence: str) -> bool:
    """'$GPRMC,...*6A' -> XOR of every char between '$' and '*' must equal 0x6A."""
    if not sentence.startswith("$") or "*" not in sentence:
        return False
    body, _, given = sentence[1:].partition("*")
    calc = 0
    for ch in body:
        calc ^= ord(ch)
    try:
        return calc == int(given[:2], 16)
    except ValueError:
        return False


def to_decimal_degrees(value: str, hemisphere: str):
    """NMEA 'ddmm.mmmm' / 'dddmm.mmmm' + N/S/E/W -> signed decimal degrees."""
    if not value or not hemisphere:
        return None
    dot = value.find(".")
    if dot == -1:
        dot = len(value)
    try:
        degrees = float(value[:dot - 2])
        minutes = float(value[dot - 2:])
    except ValueError:
        return None
    result = degrees + minutes / 60.0
    if hemisphere in ("S", "W"):
        result = -result
    return round(result, 7)


def to_float(value: str):
    try:
        return float(value) if value else None
    except ValueError:
        return None


def to_int(value: str):
    try:
        return int(value) if value else None
    except ValueError:
        return None


def parse_rmc(f):
    """RMC = Recommended Minimum data: time, date, validity, position, speed, course."""
    if len(f) < 10:
        return None
    return {
        "time": f[1],
        "valid": f[2] == "A",          # A = active (fix), V = void (no fix)
        "lat": to_decimal_degrees(f[3], f[4]),
        "lon": to_decimal_degrees(f[5], f[6]),
        "speed_knots": to_float(f[7]),
        "course": to_float(f[8]),
        "date": f[9],
    }


def parse_gga(f):
    """GGA = Global positioning system fix data: fix quality, satellites, HDOP, altitude."""
    if len(f) < 10:
        return None
    return {
        "time": f[1],
        "fix_quality": to_int(f[6]),   # 0 = none, 1 = GPS fix, 2 = DGPS fix
        "satellites": to_int(f[7]),
        "hdop": to_float(f[8]),
        "altitude": to_float(f[9]),
    }


def utc_iso(date_str: str, time_str: str):
    """'091026' + '122233.00' -> '2026-10-09T12:22:33+00:00'."""
    try:
        day, month, year = int(date_str[0:2]), int(date_str[2:4]), 2000 + int(date_str[4:6])
        hh, mm = int(time_str[0:2]), int(time_str[2:4])
        seconds = float(time_str[4:])
        sec = int(seconds)
        micro = int(round((seconds - sec) * 1_000_000))
        return datetime(year, month, day, hh, mm, sec, micro, tzinfo=timezone.utc).isoformat()
    except (ValueError, IndexError):
        return None


def build_row(rmc, gga):
    speed = rmc["speed_knots"]
    return [
        utc_iso(rmc["date"], rmc["time"]),
        rmc["lat"],
        rmc["lon"],
        gga["altitude"] if gga else None,
        round(speed * KNOTS_TO_KMH, 2) if speed is not None else None,
        rmc["course"],
        gga["fix_quality"] if gga else None,
        gga["satellites"] if gga else None,
        gga["hdop"] if gga else None,
    ]


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

class CsvWriter:
    """Appends rows; writes the header only when the file is new or empty.
    Every row is flushed and fsync'ed so a sudden power cut loses at most one row."""

    def __init__(self, path: str):
        new_file = not os.path.exists(path) or os.path.getsize(path) == 0
        self._fh = open(path, "a", newline="", encoding="utf-8")
        self._writer = csv.writer(self._fh)
        if new_file:
            self._writer.writerow(CSV_HEADER)
            self._sync()
        self.rows = 0

    def write(self, row):
        self._writer.writerow(["" if v is None else v for v in row])
        self._sync()
        self.rows += 1

    def _sync(self):
        self._fh.flush()
        os.fsync(self._fh.fileno())

    def close(self):
        self._fh.close()


def setup_logging(csv_path: str) -> str:
    base, _ = os.path.splitext(csv_path)
    log_path = base + ".log"
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s")

    file_handler = RotatingFileHandler(log_path, maxBytes=1_000_000, backupCount=3, encoding="utf-8")
    file_handler.setFormatter(fmt)
    console = logging.StreamHandler()  # ends up in journalctl when run by systemd
    console.setFormatter(fmt)

    log.setLevel(logging.INFO)
    log.addHandler(file_handler)
    log.addHandler(console)
    return log_path


# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #

def stop(signum, _frame):
    global running
    log.info("Received signal %s, stopping", signum)
    running = False


def seconds_of_day(time_str: str):
    """'081037.00' -> 29437.0 (seconds since UTC midnight)."""
    try:
        return int(time_str[0:2]) * 3600 + int(time_str[2:4]) * 60 + float(time_str[4:])
    except (ValueError, IndexError):
        return None


def run(args, out: CsvWriter):
    # One "epoch" = all sentences the module sends for one fix (same UTC timestamp).
    # Modules differ in sentence ORDER (some send GGA before RMC), so we collect both
    # by timestamp and write a row once both are in, or when the next epoch starts.
    epoch = {"time": None, "rmc": None, "gga": None}
    had_fix = None
    last_written_sod = None     # GPS seconds-of-day of the last written row
    last_data = time.monotonic()
    last_status = time.monotonic()
    last_sats = None

    def emit(rmc, gga):
        nonlocal last_written_sod
        sod = seconds_of_day(rmc["time"])
        if sod is not None and last_written_sod is not None:
            gap = (sod - last_written_sod) % 86400       # handles midnight wrap
            if gap < args.interval - 0.05:               # 50 ms tolerance for rounding
                return
        out.write(build_row(rmc, gga))
        last_written_sod = sod

    def flush_epoch():
        if epoch["rmc"] and epoch["rmc"]["valid"]:
            emit(epoch["rmc"], epoch["gga"])
        epoch.update(time=None, rmc=None, gga=None)

    def add_to_epoch(key, data):
        if epoch["time"] is not None and data["time"] != epoch["time"]:
            flush_epoch()                                # new second started
        epoch["time"] = data["time"]
        epoch[key] = data
        if epoch["rmc"] and epoch["gga"]:
            flush_epoch()                                # complete: write now

    while running:
        try:
            log.info("Opening %s at %d baud", args.port, args.baud)
            with serial.Serial(args.port, args.baud, timeout=2) as port:
                while running:
                    raw = port.readline()
                    now = time.monotonic()

                    if not raw:
                        if now - last_data > NO_DATA_WARN_SECONDS:
                            log.warning("No data from %s for %ds - check wiring, baud rate and UART setup",
                                        args.port, NO_DATA_WARN_SECONDS)
                            last_data = now
                        continue
                    last_data = now

                    line = raw.decode("ascii", errors="replace").strip()
                    if not checksum_ok(line):
                        continue
                    fields = line.split("*")[0].split(",")
                    kind = fields[0][-3:]   # works for GP/GN/GL talker prefixes

                    if kind == "RMC":
                        rmc = parse_rmc(fields)
                        if rmc is None:
                            continue
                        if rmc["valid"] != had_fix:
                            log.info("GPS fix %s", "acquired" if rmc["valid"] else "lost / waiting for fix")
                            had_fix = rmc["valid"]
                        add_to_epoch("rmc", rmc)

                    elif kind == "GGA":
                        gga = parse_gga(fields)
                        if gga is None:
                            continue
                        last_sats = gga["satellites"]
                        add_to_epoch("gga", gga)

                    if now - last_status >= STATUS_EVERY_SECONDS:
                        log.info("Status: fix=%s satellites=%s rows_written=%d",
                                 bool(had_fix), last_sats, out.rows)
                        last_status = now

        except serial.SerialException as exc:
            log.error("Serial error: %s - retrying in %ds", exc, RECONNECT_DELAY_SECONDS)
            for _ in range(RECONNECT_DELAY_SECONDS * 10):
                if not running:
                    break
                time.sleep(0.1)


def main():
    parser = argparse.ArgumentParser(description="Log NEO-6M GPS fixes to CSV.")
    parser.add_argument("output", help="CSV file path, e.g. /home/pi/gps/track.csv "
                                       "(log goes next to it as track.log)")
    parser.add_argument("--port", default="/dev/ttyAMA0", help="serial device (default: /dev/ttyAMA0)")
    parser.add_argument("--baud", type=int, default=9600, help="baud rate (NEO-6M default: 9600)")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="minimum seconds between CSV rows (default: 1)")
    args = parser.parse_args()

    csv_path = os.path.abspath(os.path.expanduser(args.output))
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    log_path = setup_logging(csv_path)

    signal.signal(signal.SIGTERM, stop)   # systemctl stop
    signal.signal(signal.SIGINT, stop)    # Ctrl+C

    log.info("Starting. CSV: %s  Log: %s", csv_path, log_path)
    out = CsvWriter(csv_path)
    try:
        run(args, out)
    finally:
        out.close()
        log.info("Stopped. Rows written this session: %d", out.rows)


if __name__ == "__main__":
    main()
