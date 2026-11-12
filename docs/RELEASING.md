# Releasing

How a version of the app is made: the number, the record of what changed, the checks, the tag, and how a build
gets onto a phone. All commands run from the repository root.

## The version number

Two numbers live in `project.yml`, under `settings.base`, and nowhere else:

- `MARKETING_VERSION`: the version people see, such as `1.0.0`. Settings shows it under About, because installs
  happen often and the icon never changes.
- `CURRENT_PROJECT_VERSION`: the build number, a whole number. iOS and App Store Connect use it to tell two builds
  of the same version apart. It goes up by one with every version and never goes back: App Store Connect refuses
  an upload whose build number is not higher than every build already uploaded for that version.

`CHANGELOG.md` states the rule for the version number in 0.x: `0.x.0` adds or changes behaviour, `0.x.y` only
fixes. It has no rule yet for versions after 1.0.0; the first version after it is the moment to write one there.

`App/Info.plist` reads both numbers from the build settings (`$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`).
After changing either, regenerate the Xcode project, which is not committed, and check what it carries:

    xcodegen generate
    xcodebuild -showBuildSettings -project Teleop.xcodeproj -scheme Teleop | grep -E ' (MARKETING_VERSION|CURRENT_PROJECT_VERSION) '

## The changelog is the record

`CHANGELOG.md` says what each version does for the person using the app, newest first. Every build that goes onto
a phone gets a new version and an entry there first.

- While work goes on, changes collect under `## Unreleased`.
- When the version is cut, that heading becomes `## X.Y.Z (YYYY-MM-DD)` with a one-line summary under it, and a new
  empty `## Unreleased` goes above it.
- An entry says what changed for the person using the app first, then what a maintainer needs to know; not which
  files changed.

## The checks to run first

All of these must pass on the commit that will carry the version. The first group needs no iPhone simulator:

    git status --porcelain
    (cd Packages/TeleopCore && swift test)
    tools/session-safety/scripts/check.sh
    python3 scripts/check-strings.py
    python3 scripts/check-dead-buttons.py
    python3 -B -m unittest scripts/test_check_strings.py scripts/test_analyze_holds.py

`git status --porcelain` must print nothing. `-B` keeps Python from writing `scripts/__pycache__/`; `.gitignore`
leaves such folders out of `git status` too. The safety checker must
exit 0; `docs/ARCHITECTURE.md` says what it proves. `check-strings.py` fails on any string, in any of the four
catalogs, that lacks English or Traditional Chinese.

Then the full default test plan, about twenty minutes, on an iPhone simulator nothing else uses and a Mac that
stays awake (`docs/TESTING.md` explains both):

    xcodegen generate
    SIM=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9] Pro( Max)?|iPhone 1[0-9]' | head -n 1)
    caffeinate -i xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO

Do not set `TEST_RUNNER_TELEOP_MOTION` for a release check. The live tests move the shared arm in Isaac Sim and
are a separate, deliberate step.

## Commit and tag

Versions are cut on the release branch, `release-1.0`, which carries every version tag; `main` carries none. The
version bump in `project.yml` and the changelog entry go in one commit on that branch; regenerating the project
leaves nothing else to commit. Put an annotated tag on that commit, named `v` and the version, with the version
and the one-line summary as its message, and check it:

    git tag -a v1.0.0 -m "1.0.0: <one-line summary>"
    git show v1.0.0 --no-patch

An annotated tag records who tagged and when; `git tag -n` lists every version with its summary. Push the tag
together with the branch that carries the version commit, in one push, so neither arrives without the other:

    git push --atomic origin release-1.0 v1.0.0

## Putting a build on a phone

This needs an iPhone connected to the Mac (by cable, or paired over the network), in Developer Mode, and an Apple
developer team the phone is registered with. The project carries no signing settings, and `xcodegen generate`
drops a team picked in Xcode's window, so the team goes on the command line.

Find the phone's UDID (unique device identifier), and use it in both the build and the install below so that
they name the same phone. Take it from `xcodebuild` itself: the connected phone is the `platform:iOS` line with a
real `id`, not the `Any iOS Device` placeholder.

    xcodebuild -showdestinations -project Teleop.xcodeproj -scheme Teleop

Build, install and start it. `<TEAM_ID>` is the ten-character team identifier, `<DEVICE_UDID>` the phone's UDID,
and `<BUNDLE_ID>` is `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`:

    xcodebuild -project Teleop.xcodeproj -scheme Teleop -configuration Debug \
      -destination 'id=<DEVICE_UDID>' -derivedDataPath build/device \
      DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates build
    xcrun devicectl device install app --device <DEVICE_UDID> build/device/Build/Products/Debug-iphoneos/Teleop.app
    xcrun devicectl device process launch --device <DEVICE_UDID> <BUNDLE_ID>

`-allowProvisioningUpdates` lets Xcode create or renew the signing certificate and profile with the Apple account
signed in to Xcode. The first launch on a phone may need the developer to be trusted on the phone itself
(Settings, General, VPN & Device Management). With a free team, the profile expires after seven days and the app
stops opening until it is installed again.

## TestFlight

TestFlight is Apple's way to hand a build to testers through App Store Connect. It is not set up for this app yet:
the repository has no archive or upload step. Before a first upload, the holder of the Apple developer account has
to provide:

- a paid Apple Developer Program membership for the team that signs the app;
- an app record in App Store Connect for the bundle identifier (`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`), and
  any agreements App Store Connect asks to be accepted;
- the testers: people in the App Store Connect team, or outside testers, for whom Apple first reviews the build;
- an answer to the export compliance question about encryption for each build.
