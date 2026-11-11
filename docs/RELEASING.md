# Releasing

How a version of the app is made: the number, the record of what changed, the checks, the tag, and how a build
gets onto a phone. All commands run from the repository root.

## The version number

Two numbers live in `project.yml`, under `settings.base`, and nowhere else:

- `MARKETING_VERSION`: the version people see, such as `1.0.0`. It is shown at the bottom of Settings in the app,
  because installs happen often and the icon never changes.
- `CURRENT_PROJECT_VERSION`: the build number, a whole number. iOS and App Store Connect use it to tell two builds
  of the same version apart.

`CHANGELOG.md` states the rule for the version number, but only for 0.x: `0.x.0` adds or changes behaviour,
`0.x.y` only fixes. No rule for versions after 1.0.0 is written down yet. Carrying the same idea over would make
`1.x.0` a version that adds or changes behaviour and `1.x.y` one that only fixes; whoever cuts the first version
after 1.0.0 should write the rule into `CHANGELOG.md` so it is decided once.

The build number is not covered by any written rule either. In practice it has gone up by one with every version
(0.9.1 was build 11, 0.10.0 build 12) and never goes back. Keep it that way: App Store Connect
refuses an upload whose build number is not higher than every build already uploaded for that version.

To change either number, edit `project.yml`, then regenerate the Xcode project, which is not committed:

    xcodegen generate

Check what the project now carries:

    xcodebuild -showBuildSettings -project Teleop.xcodeproj -scheme Teleop | grep -E ' (MARKETING_VERSION|CURRENT_PROJECT_VERSION) '

## The changelog is the record

`CHANGELOG.md` says what each version does for the person using the app, newest first. Every build that goes onto
a phone gets a new version and an entry here first.

- While work goes on, changes collect under `## Unreleased`.
- When the version is cut, that heading becomes `## X.Y.Z (YYYY-MM-DD)` with a one-line summary under it, and a new
  empty `## Unreleased` goes above it.
- An entry says what changed for the operator and why, not which files changed.

## The checks to run first

All of these must pass on the commit that will carry the version. The first five need no simulator.

    git status --porcelain
    (cd Packages/TeleopCore && swift test)
    .cursor/skills/verify-session-safety/scripts/check.sh
    python3 scripts/check-strings.py
    python3 scripts/check-dead-buttons.py

`git status --porcelain` must print nothing. The safety checker must exit 0; `docs/ARCHITECTURE.md` says what it
proves.

Every string a person sees or hears must exist in English and in Traditional Chinese. The default test plan checks
this for the spoken strings only (`SpeechTextTests.testEveryPhraseResolvesInBothLanguages`); nothing checks the
other three catalogs (`Localizable`, `Buttons`, `InfoPlist`). This command checks all four: it lists any key without
a Traditional Chinese entry and fails if there is one.

    python3 -c "
    import json, pathlib, sys
    bad = 0
    for path in sorted(pathlib.Path('App/Resources').glob('*.xcstrings')):
        strings = json.loads(path.read_text())['strings']
        missing = [key for key, entry in strings.items() if 'zh-Hant' not in entry.get('localizations', {})]
        print(path.name, len(strings), 'keys,', len(missing), 'without Traditional Chinese', missing)
        bad += len(missing)
    sys.exit(1 if bad else 0)
    "

Then the full default test plan, about ten minutes, as in `docs/TESTING.md`:

    xcodegen generate
    SIM=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9] Pro( Max)?|iPhone 1[0-9]' | head -n 1)
    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO

Do not set `TEST_RUNNER_TELEOP_MOTION` for a release check. The live tests move the shared simulator and are a
separate, deliberate step.

## Commit and tag

The version bump in `project.yml` and the changelog entry go in one commit. Regenerating the project leaves
nothing else to commit: the Xcode project is not in the repository, and `App/Info.plist` reads both numbers from the
build settings (`$(MARKETING_VERSION)`, `$(CURRENT_PROJECT_VERSION)`). Then put an annotated tag on that commit,
named `v` and the version, with the version and the one-line summary as its message:

    git tag -a v1.0.0 -m "1.0.0: <one-line summary>"

Check it:

    git show v1.0.0 --no-patch

An annotated tag records who tagged and when; `git tag -n` lists every version with its summary. Push the tag
together with the branch it is on, in one push (not run for this document; `<branch>` is the branch that carries the
version commit):

    git push --atomic origin <branch> v1.0.0

`--atomic` makes the push all or nothing, so the branch never arrives without its tag or the other way round.

## Putting a build on a phone

This needs an iPhone connected to the Mac (by cable, or paired over the network), in Developer Mode, and an Apple
developer team the phone is registered with. The project carries no signing settings, and `xcodegen generate`
drops a team picked in Xcode's window, so the team goes on the command line.

Find the phone's UDID (unique device identifier). `xcodebuild` matches a destination on the UDID and nothing
else, so take it from `xcodebuild` itself: the connected phone is the `platform:iOS` line with a real `id`, not the
`Any iOS Device` placeholder.

    xcodebuild -showdestinations -project Teleop.xcodeproj -scheme Teleop

`xcrun devicectl list devices` lists the phone too, but what its Identifier column shows depends on the Xcode
version: recent versions show the UDID and mark it `(UDID)`, older ones show a CoreDevice identifier (in the form
8-4-4-4-12 hex digits; a phone's UDID is 8-16) that `devicectl` accepts and `xcodebuild` does not.

Build for it. `<TEAM_ID>` is the ten-character team identifier, `<DEVICE_UDID>` the phone's UDID:

    xcodebuild -project Teleop.xcodeproj -scheme Teleop -configuration Debug \
      -destination 'id=<DEVICE_UDID>' -derivedDataPath build/device \
      DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates build

`-allowProvisioningUpdates` lets Xcode create or renew the signing certificate and profile with the Apple account
signed in to Xcode. Install it and start it (`devicectl` takes the same UDID; `<BUNDLE_ID>` is
`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`):

    xcrun devicectl device install app --device <DEVICE_UDID> build/device/Build/Products/Debug-iphoneos/Teleop.app
    xcrun devicectl device process launch --device <DEVICE_UDID> <BUNDLE_ID>

The first launch on a phone may need the developer to be trusted on the phone itself (Settings, General, VPN &
Device Management). With a free team, the profile expires after seven days and the app stops opening until it is
installed again.

## What a TestFlight release would additionally need

TestFlight is Apple's way to hand a build to testers through App Store Connect. None of this is set up in the
repository today, and the two commands below need the paid team and the App Store Connect record, so they have not
been run here. A release through it would additionally need:

- a paid Apple Developer Program membership for the team, and an app record in App Store Connect for the bundle
  identifier (`PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`), with a privacy policy address (required for every
  app);
- a build number higher than any build already uploaded for that version;
- a Release archive for a generic device, signed for distribution:

      xcodebuild archive -project Teleop.xcodeproj -scheme Teleop -configuration Release \
        -destination 'generic/platform=iOS' -archivePath build/Teleop.xcarchive \
        DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates

- an export options file (not in the repository) with `method` set to `app-store-connect` and `destination` set to
  `upload`, and the upload itself:

      xcodebuild -exportArchive -archivePath build/Teleop.xcarchive \
        -exportOptionsPlist <export-options.plist> -exportPath build/export -allowProvisioningUpdates

- an answer to the export compliance question about encryption for each build, or the key
  `ITSAppUsesNonExemptEncryption` in the app's `Info.plist` so it is answered once;
- testers: people in the App Store Connect team can test as soon as the build is processed; outside testers need
  a test description, a feedback address, and Apple's beta review of the first build. A reviewer may ask why the app
  allows plain `ws://` connections (`NSAllowsArbitraryLoads` in `project.yml`): the server speaks unencrypted
  WebSocket on a local or private network.

After the upload, the tag and the changelog entry are the same as for any other version.
