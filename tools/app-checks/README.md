# App checks

Helper scripts for checking the app outside `xcodebuild test`: they run the core tests and fetch a CI run's
artifacts into one evidence folder outside the repository, and compare the UI tests' screenshots with the Mockup v2
frames in Figma. The feature notes in `features/` say how to check three behaviours a person relies on, and which
tests cover them. The test suites themselves, and what each layer can and cannot catch, are in `docs/TESTING.md`.

## Set up

Needs `bash`, `git` and `python3`; `swift` for the core tests, `gh` (signed in) for CI, and Pillow and numpy for the
screenshot compare (`pip install pillow numpy`). From the repository root, once per check:

    export RUN_ID=$(date +%Y%m%d-%H%M%S)
    T=tools/app-checks/scripts
    $T/doctor.sh local     # or: $T/doctor.sh ci

Every script writes into `$EVIDENCE_ROOT/$RUN_ID` (default `~/teleop-ios-evidence/<RUN_ID>`), so one `RUN_ID`
keeps one check's evidence together. Builds go to `$SCRATCH` (default `/tmp/teleop-app-checks-<RUN_ID>`).

## The scripts

| Script | What it does | Exit |
|---|---|---|
| `doctor.sh [local\|ci]` | Read-only. Prints `OK` or `FAIL` for the core package, `project.yml`, Pillow and numpy, and then `swift` (local) or `gh` sign-in, the repository and `.github/workflows/ios.yml` on the default branch (ci). | 1 if any line failed |
| `run-core-tests.sh` | `swift test` in `Packages/TeleopCore`; the log and a one-line result go to `core/`. | 0 pass, 1 fail, 2 no `swift` (a skip, not a pass) |
| `fetch-ci.sh [run-id]` | Waits for a run of the `ios` workflow (default: the newest on the current branch) and downloads its artifacts (`xcodebuild-log`, `screenshots`, `xcresult`) into `ci/artifacts/`, with `ci/run.json`. | the run's result |
| `figma-compare.py --figma DIR --shots DIR --out DIR [--only S1,P5] [--threshold 0.10]` | Pairs each frame `<SCREEN_ID>.png` with the screenshot whose name holds that screen id (`06-S1-connect.png`), and writes `<SCREEN_ID>-side-by-side.png` (Figma, iPhone simulator, difference), `report.json` and `report.md`. | 0 all pages under the threshold, 1 otherwise, 2 nothing paired |
| `frames.tsv` | Screen id, Figma node, frame name and route raw value (for `-startRoute`) of each Mockup v2 frame. | |
| `export-figma.md` | How to export the frames from Figma without changing the file. | |
| `check-english.sh [base-ref] [pr-number]` | Looks for Chinese, Japanese or Korean characters in commit messages since `base-ref`, in tracked files, in file names and in a pull request's title and body; results go to `english/`. | 1 if any were found |
| `cleanup.sh [--sim <udid>]` | Removes `$SCRATCH` (only a path under `/tmp/teleop-app-checks-`) and a simulator you name; never touches the evidence, and prints where it is kept. | 1 if the evidence folder is gone |

## Read the results

- A check passes only on the path it ran. `run-core-tests.sh` checks logic and nothing on screen; screens, layout
  and screenshots come from CI or a local `xcodebuild test`. A skip (no `swift`, no CI) is reported as a skip with
  its reason.
- The compare score is the share of pixels whose largest colour difference is over 32 after the screenshot is
  scaled to 402 x 874. The status bar's time and battery always differ, so a score says where to look; the
  side-by-side image says what differs. `MISSING` means there is no screenshot for that screen yet, not that it
  passed. The frames are Mockup v2; where the app has moved on from it, a difference is expected.
- `check-english.sh` uses `grep -P`, which the `grep` that ships with macOS does not have: there every search prints
  a usage message and reports `OK`, so run it where GNU grep is installed. It then lists every file with such
  characters.
  The string catalogs in `App/Resources`, the tests that check Chinese strings and `scripts/test_check_strings.py`
  hold Traditional Chinese on purpose; only other hits are findings.
- A result names the commit it ran on (`git rev-parse --short HEAD`) and, for CI, the run id.

## Changing it

- A new script sources `_common.sh` for `REPO_ROOT`, `RUN_ID`, `EVIDENCE`, `SCRATCH`, `GH_REPO` and `CORE_DIR`,
  writes only into its own folder under `$EVIDENCE`, and exits 0 for a pass, 1 for a failure and 2 for a skip.
- When a screen is added, removed or redrawn in Figma, update `frames.tsv` and the screen ids in
  `figma-compare.py`, and the feature note that describes it.
- When a behaviour in a feature note changes, change the note in the same commit as the code and its tests.

## Feature notes

| Note | Covers |
|---|---|
| `features/disconnect-reconnect.md` | Disconnect from Settings, connecting again, and a link that drops by itself |
| `features/hold-to-move-haptics.md` | Holding a control to move, one control at a time, and the cues that answer |
| `features/stop-reachability.md` | STOP on every screen, the stopped state, and the two ways out of it |
