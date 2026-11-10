#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
status=0
printf '\n== Blousab static source check ==\n'
python3 scripts/check_static.py || status=1
printf '\n== Blousab source contracts ==\n'
python3 scripts/check_v26_contracts.py || status=1
printf '\n== Flutter SDK checks ==\n'
if command -v flutter >/dev/null 2>&1; then
  flutter pub get || status=1
  flutter analyze || status=1
  flutter test || status=1
  printf '\n== Release APK build ==\n'
  flutter build apk --release || status=1
else
  echo 'NOT RUN: Flutter SDK is not installed. Install Flutter, then rerun this script.'
  status=1
fi
printf '\n== Production security gate ==\n'
python3 scripts/check_production_security.py || status=1
if [ "$status" -eq 0 ]; then
  echo 'PREFLIGHT PASS: checks passed; device testing and independent security review are still required.'
else
  echo 'PREFLIGHT BLOCKED: do not label this build production-ready or E2E-secure.'
fi
exit "$status"
