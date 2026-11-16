#!/usr/bin/env bash
# Fails when a Swift file of the app, the core package, the tests or the safety checker is not laid out as
# .swift-format says. To lay them out: the same file list with `swift format format -i --parallel` instead.
set -euo pipefail
cd "$(dirname "$0")/.."
files=()
while IFS= read -r file; do
    files+=("$file")
done < <(git ls-files 'App/*.swift' 'Packages/TeleopCore/*.swift' 'Tests/*.swift' 'tools/session-safety/checker/*.swift')
swift format lint --strict --parallel "${files[@]}"
