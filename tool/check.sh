#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get --offline
dart format --output=none --set-exit-if-changed packages tool integration/native_host/lib integration/native_host/test integration/native_host/integration_test integration/native_host/tool
flutter analyze --no-pub
(cd packages/anythink_dart && dart test --reporter expanded)
for package in anythink_flutter anythink_flutter_auth anythink_flutter_push anythink_flutter_purchases; do
  (cd "packages/$package" && flutter test --no-pub --reporter expanded)
done
(cd integration/native_host && flutter test --no-pub --reporter expanded)
dart test --reporter expanded tool/test
python3 -m py_compile integration/native_host/tool/*.py tool/*.py
python3 tool/check_package.py --help >/dev/null
python3 tool/package_preflight.py --help >/dev/null
python3 -m unittest discover -s integration/native_host/tool -p 'test_*.py'
python3 integration/native_host/tool/run_android_session_validation.py --help >/dev/null
python3 integration/native_host/tool/run_ios_session_validation.py --help >/dev/null
dart run tool/live_contract.dart --help >/dev/null
