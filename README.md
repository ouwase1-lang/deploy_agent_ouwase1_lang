# deploy_agent

`deploy_agent.sh` bootstraps, runs and archives logs for the **Student Attendance Tracker** (`attendance_checker.py`, which is never modified).

## Repository layout

```
deploy_agent_<GithubUsername>/
├── deploy_agent.sh
├── README.md
└── templates/
    ├── attendance_checker.py   (unmodified)
    ├── assets.csv              (unmodified, 10 students, 4 prior sessions each)
    └── config.json             (unmodified)
```

## How to run and select a feature

I used **both an interactive menu and command-line flags**.

```bash
chmod +x deploy_agent.sh
./deploy_agent.sh              # interactive menu (1 Deploy, 2 Run, 3 Archive, 4 Exit)
./deploy_agent.sh --deploy     # or -d
./deploy_agent.sh --run        # or -r
./deploy_agent.sh --archive    # or -a
./deploy_agent.sh --help       # or -h
```

Requires `bash`, `python3` and `zip`. The script locates `templates/` relative to its own location, so it can be launched from any directory. Projects are created next to the script.

## Feature 1: Deploy

1. **Pre-flight**: checks `python3`, `zip` and the three templates; exits with a clear message if anything is missing.
2. **Project name**: asked with `read`. The directory becomes `attendance_tracker_<name>/`. Names are restricted to letters, digits, `.`, `_`, `-`. If the directory exists, the user is asked whether to overwrite; answering no aborts with an error and leaves the existing project untouched.
3. **Structure created**:
   ```
   attendance_tracker_<name>/
   ├── attendance_checker.py
   ├── Helpers/
   │   ├── assets.csv
   │   └── config.json
   └── reports/            (empty; the app creates the logs)
   ```
4. **Roster** (`Helpers/assets.csv`):
   - **Option A**: asks how many students (1 to the number in the template), then copies the header plus that many rows from `templates/assets.csv`.
   - **Option B**: asks how many (1-100) and generates rows from name/email arrays inside the script, with both counts at `0`. Beyond 15 students the names repeat with a numeric suffix so emails stay unique.
5. **total_sessions consistency**: `config.json` is copied unmodified, then only the `total_sessions` value is aligned with the roster: **5** for Option A (4 prior sessions + today) and **1** for Option B (fresh roster = first session). The rule is `total_sessions = prior sessions in roster + 1`. No prompt is needed.
6. **Threshold update**: asks "Update thresholds? (y/N)". If yes, it reads `warning` (default 75) and `failure` (default 50) using `read`, validates them (integers 0-100, failure < warning), and edits the deployed file in place with `sed -E`, matching only the `"warning": <number>` and `"failure": <number>` entries. Layout and key order are unchanged. Pressing Enter keeps the defaults.
7. **Permissions**: `chmod +x attendance_checker.py` and `chmod 600 Helpers/config.json` (owner read/write only, since it holds grading thresholds). The resulting permissions are printed.
8. **Verification**: deploy ends by running Feature 2. A successful startup shows that structure, roster and config work together.

## Feature 2: Run

Asks for the project name, then runs `cd attendance_tracker_<name> && python3 attendance_checker.py`. The app is interactive, so the terminal is handed to the instructor. The exit status is reported.

## Feature 3: Archive logs

Asks for the project name and checks for `reports/attendance.log` and `reports/absent.log`. Each existing log is **copied** into its own directory with a shared timestamp:

```
attendance_tracker_<name>/archives/
├── attendance/attendance_YYYYMMDD_HHMMSS.log
└── absent/absent_YYYYMMDD_HHMMSS.log
```

Directories are created as needed, and the final paths are printed. A missing log (for example, nobody was absent so no `absent.log`) is reported as skipped and does not crash the script; a summary line shows how many were archived and how many were missing. Originals stay in `reports/` so the app keeps appending to them; every archive filename is unique by timestamp.

## Ctrl+C / Ctrl+Z handling

`SIGINT` and `SIGTSTP` are trapped from the moment project creation starts until deployment finishes. They are released before the app is launched, so the trap never affects `attendance_checker.py`.

On either signal the script:
1. prints that the deployment was interrupted (and by which signal),
2. zips whatever exists of `attendance_tracker_<name>/` into `attendance_tracker_<name>_archive.zip` using `zip -r`,
3. removes the half-made directory,
4. exits cleanly with status 130.

If the signal arrives before the directory exists, it reports there is nothing to archive and exits.

**How to test**: run `./deploy_agent.sh -d`, enter a name, then at the roster prompt (or any later prompt) press **Ctrl+C** or **Ctrl+Z**. Then check:

```bash
ls                                              # zip exists, project directory is gone
unzip -l attendance_tracker_<name>_archive.zip  # inspect contents
```

The zip contains the partial tree at the moment of interruption, for example `attendance_tracker_<name>/`, `attendance_checker.py`, `Helpers/config.json` and `reports/` (the roster `assets.csv` is only present if the interrupt came after it was created).

## How the deployment was tested

- **Option A** with 3 students: checked the header plus 3 rows, `total_sessions: 5`, and threshold edits (80/40) applied without altering the rest of the file.
- **Option B** with 12 students: 12 rows plus header, counts at 0, `total_sessions: 1`.
- **Existing directory**: declining the overwrite aborts and leaves the project untouched; accepting rebuilds it.
- **Permissions**: `ls -l` shows `-rwxr-xr-x` for `attendance_checker.py` and `-rw-------` for `config.json`.
- **Structure and startup**: the verification run found `Helpers/assets.csv`, `Helpers/config.json` and created `reports/`.
- **Archive**: with only `attendance.log` present, it archived one log and skipped `absent.log` gracefully.
- **Real application run**: deployed with the provided templates (Option A, all 10 students) and marked a full session. Roster counts updated, `reports/attendance.log` and `reports/absent.log` were created, and archiving produced timestamped copies of both.
- **End of input**: if input stops mid-deploy, the script cleans up like an interrupt instead of hanging.
- **Signals**: sent SIGINT and SIGTSTP mid-deploy; both produced the zip, removed the directory and exited with 130.

## Video

Run-through video: _add link here_
