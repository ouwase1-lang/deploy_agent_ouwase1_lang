import csv
import json
import os
import sys
from datetime import datetime

CONFIG_PATH = "Helpers/config.json"
ASSETS_PATH = "Helpers/assets.csv"
REPORTS_DIR = "reports"
ATTENDANCE_LOG_PATH = os.path.join(REPORTS_DIR, "attendance.log")
ABSENT_LOG_PATH = os.path.join(REPORTS_DIR, "absent.log")

NAME_COL = "Names"
EMAIL_COL = "Email"
ATTEND_COL = "Attendance Count"
ABSENT_COL = "Absence Count"


def load_config(path):
    if not os.path.exists(path):
        raise FileNotFoundError(f"Config file not found: {path}")
    with open(path, "r", encoding="utf-8") as f:
        try:
            config = json.load(f)
        except json.JSONDecodeError as exc:
            raise ValueError(f"Config file is not valid JSON: {exc}")

    required_top = ["thresholds", "run_mode", "total_sessions"]
    for key in required_top:
        if key not in config:
            raise ValueError(f"Config is missing required key: '{key}'")
    for key in ["warning", "failure"]:
        if key not in config["thresholds"]:
            raise ValueError(f"Config['thresholds'] is missing key: '{key}'")

    if config["total_sessions"] <= 0:
        raise ValueError("Config 'total_sessions' must be greater than 0")

    return config


def load_roster(path):
    """Read the student roster. Returns (fieldnames, rows) where rows
    are dicts with Attendance Count / Absence Count already as ints."""
    if not os.path.exists(path):
        raise FileNotFoundError(f"Roster file not found: {path}")

    with open(path, mode="r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    if not fieldnames or not rows:
        raise ValueError(f"Roster file is empty: {path}")

    required_cols = [NAME_COL, EMAIL_COL, ATTEND_COL, ABSENT_COL]
    missing = [c for c in required_cols if c not in fieldnames]
    if missing:
        raise ValueError(f"Roster is missing required column(s): {missing}")

    for row_num, row in enumerate(rows, start=2):
        try:
            row[ATTEND_COL] = int(row[ATTEND_COL])
            row[ABSENT_COL] = int(row[ABSENT_COL])
        except ValueError:
            raise ValueError(
                f"Roster row {row_num} has a non-numeric attendance/"
                f"absence count: {row}"
            )

    return fieldnames, rows


def save_roster(path, fieldnames, rows):
    """Persist updated Attendance/Absence counts back to assets.csv."""
    with open(path, mode="w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def classify(pct, thresholds):
    """Return (level, label) - level is 'URGENT', 'WARNING', or None."""
    if pct < thresholds["failure"]:
        return "URGENT", "below the failure threshold - will fail this class"
    if pct < thresholds["warning"]:
        return "WARNING", "below the warning threshold - please be careful"
    return None, ""


def prompt_present(name, email):
    """Ask the instructor to mark one student. Loops until valid input."""
    while True:
        raw = input(
            f"Mark {name} <{email}> - [P]resent or [A]bsent? "
        ).strip().lower()
        if raw in ("p", "present", "y", "yes"):
            return True
        if raw in ("a", "absent", "n", "no"):
            return False
        print("  Please enter 'P' for present or 'A' for absent.")


def mark_attendance_session(rows, total_sessions, thresholds, run_mode):
    """
    Interactively mark every student in `rows` present/absent for
    today's session, updating their running counts in place.

    Returns (attendance_lines, absent_lines, marked_count, stopped_early)
    where stopped_early is one of None, "interrupted", or "input_ran_out".
    If marking is cut short (Ctrl+C or stdin exhausted), whatever was
    completed for students already marked is still returned intact -
    the roster and logs stay consistent with each other either way.
    """
    attendance_lines = []
    absent_lines = []
    marked_count = 0
    stopped_early = None
    today = datetime.now().strftime("%Y-%m-%d")

    print(f"\nToday's session: {len(rows)} students, total_sessions={total_sessions}\n")

    for row in rows:
        name, email = row[NAME_COL], row[EMAIL_COL]
        prior_total = row[ATTEND_COL] + row[ABSENT_COL]
        expected_prior = total_sessions - 1
        if prior_total != expected_prior:
            print(
                f"  (note: {name} has {prior_total} prior sessions on "
                f"record, expected {expected_prior} - proceeding anyway)"
            )

        try:
            present = prompt_present(name, email)
        except KeyboardInterrupt:
            stopped_early = "interrupted"
            break
        except EOFError:
            stopped_early = "input_ran_out"
            break

        timestamp = datetime.now()

        if present:
            row[ATTEND_COL] += 1
            status = "PRESENT"
        else:
            row[ABSENT_COL] += 1
            status = "ABSENT"

        attended = row[ATTEND_COL]
        pct = (attended / total_sessions) * 100
        level, label = classify(pct, thresholds)

        suffix = f" | {level}: {label}" if level else ""
        line = (
            f"[{timestamp}] {name} <{email}>: {status} - "
            f"attended {attended}/{total_sessions} = {pct:.1f}%{suffix}"
        )
        attendance_lines.append(line)

        if level:
            print(f"  -> {pct:.1f}% attendance | {level}: {label}")
        else:
            print(f"  -> {pct:.1f}% attendance | on track")

        if not present:
            absent_lines.append(
                f"[{today}] {name} <{email}> - absent "
                f"(now {pct:.1f}% attendance){suffix}"
            )
            if run_mode == "live" and level:
                print(f"  Logged alert for {name}")

        marked_count += 1

    return attendance_lines, absent_lines, marked_count, stopped_early


def append_log(path, header, lines):
    if not lines:
        return
    os.makedirs(REPORTS_DIR, exist_ok=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(header + "\n")
        for line in lines:
            f.write(line + "\n")


def run_attendance_check():
    config = load_config(CONFIG_PATH)
    fieldnames, rows = load_roster(ASSETS_PATH)

    total_sessions = config["total_sessions"]
    thresholds = config["thresholds"]
    run_mode = config.get("run_mode", "dry_run")

    attendance_lines, absent_lines, marked_count, stopped_early = (
        mark_attendance_session(rows, total_sessions, thresholds, run_mode)
    )

    session_header = (
        f"=== Session recorded {datetime.now()} | "
        f"total_sessions={total_sessions} | mode={run_mode} ==="
    )
    append_log(ATTENDANCE_LOG_PATH, session_header, attendance_lines)
    append_log(ABSENT_LOG_PATH, session_header, absent_lines)
    save_roster(ASSETS_PATH, fieldnames, rows)

    if stopped_early == "interrupted":
        print(
            f"\nInterrupted - marked {marked_count}/{len(rows)} students "
            "before Ctrl+C. Their results were saved to the roster and "
            "logs; the rest of the roster is unchanged.",
            file=sys.stderr,
        )
        sys.exit(130)

    if stopped_early == "input_ran_out":
        print(
            f"\nInput ended early - marked {marked_count}/{len(rows)} "
            "students before running out of input. Their results were "
            "saved; the rest of the roster is unchanged.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(
        f"\nDone. Marked {marked_count} students, "
        f"{len(absent_lines)} absent. "
        f"Logs: {ATTENDANCE_LOG_PATH}, {ABSENT_LOG_PATH}"
    )


def main():
    try:
        run_attendance_check()
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print(f"ERROR: unexpected filesystem error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()