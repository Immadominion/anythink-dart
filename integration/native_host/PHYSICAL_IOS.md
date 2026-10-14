# Physical iPhone session validation

The physical runner executes the same seven assertions in
`integration_test/device_session_test.dart` as the Android and simulator runners.
It uses a prebuilt, development-signed IPA and Flutter's official
`integration_test` driver. No provider, push, purchase, or locked-device result is
implied by these session checks.

See [validation](../../docs/validation.md#native-checks) for completed device checks.

## Prerequisites

- Exactly one paired physical iPhone, Developer Mode enabled and available to
  Xcode's developer disk image services.
- An existing development certificate/private key and unexpired provisioning
  profile that cover the dedicated bundle
  `dev.anythink.sdk.anythinkNativeHost` and the connected phone.
- The existing ordinary-user live-contract configuration, a nonsymlink regular
  JSON file with mode `0600`. No administrator account is accepted by the tests.
- A signed app and IPA containing that same app. The runner checks the bundle ID,
  signature, and matching executable/framework hashes before installation.

`ios/Flutter/LocalSigning.xcconfig` is an optional, gitignored local include for
device signing. Keep it at mode `0600`; no team, identity, or profile is committed.
A password-session provisioning profile does not establish Apple sign-in or
APNs readiness.

## Build and run

Compile the test entrypoint with the fixed input-directory define. The physical
iOS 27 run uses an isolated official Flutter 3.47.7 SDK (revision `abaf9c5237`,
Dart 3.13.5). Flutter 3.47.5 includes the upstream iOS 27 debugger fix. The
installed Flutter 3.44.2 had failed before any SDK gate in both the initial debug
attempt and a profile launch investigation. The global Flutter installation was
not changed. Dependency resolution for the newer SDK happened in a separate
workspace snapshot.

```sh
flutter build ios --debug --no-codesign --no-pub \
  --target=integration_test/device_session_test.dart \
  --dart-define=ANYTHINK_DEVICE_INPUT_SUBDIRECTORY=anythink-physical-session
```

Sign the resulting build with the existing local identity/profile through
`xcodebuild` using the `Debug` configuration. Set `CONFIGURATION_BUILD_DIR` to the
same `build/ios/iphoneos` output that Flutter compiled; a separate output directory
can leave generated native frameworks incomplete. The executed validation uses
direct `xcodebuild` without `-allowProvisioningUpdates` or
`-allowProvisioningDeviceRegistration`; it does not create credentials or grant
portal access. Package the signed `Runner.app` beneath `Payload/Runner.app` in an
IPA without changing its contents.

From the workspace root, pass those exact signed artifacts:

```sh
python3 integration/native_host/tool/run_physical_ios_session_validation.py \
  --config .secrets/live-contract.json \
  --app integration/native_host/build/ios/iphoneos/Runner.app \
  --ipa integration/native_host/build/ios-physical-session-347-debug.ipa \
  --mode debug
```

The runner installs only the dedicated test app. Each phase receives its input
in `Library/Caches/anythink-physical-session`, transferred with `devicectl` and
verified as a regular nonsymlink file with mode `0600`. The Dart test deletes the
input before sign-in. Credentials are not compiled into the app, passed as shell
arguments or Dart defines, or written to result reports.

The runner stops only the dedicated app process between phases. Flutter's drive
command reinstalls the same signed IPA in place; it is explicitly kept from
uninstalling the app afterward. The test checks that process IDs changed and the
cache marker survived, verifies real server identity/role and rotating refresh, and checks
Keychain persistence and durable logout. The driver must report success, exit
zero, and emit exactly the expected gate labels for every phase. Any automatic
Flutter launch retry makes the phase incomplete, even if a later launch succeeds.

Cleanup targets only that known test directory and the dedicated app process.
`devicectl` sometimes reports an error after removing an empty destination;
cleanup therefore independently verifies absence/emptiness rather than accepting
the command's status alone. A failed phase is not retried automatically, and
Keychain state is not erased to make a retry pass.

If a deliberate run is interrupted after sign-in, the test entrypoint has a
separate `cleanup_interrupted_run` phase. It restores the existing session,
checks the expected ordinary identity, signs out, and verifies an empty secure
store. This is recovery evidence only and is not one of the seven validation
gates. The normal runner never invokes it automatically, and it does not
reconstruct a lost continuity marker.

Results are written to `evidence/ios-physical-session-20261014.json`. Restore a
configured, signed `lib/main.dart` build afterward. Debugger startup failure is
recorded separately from SDK test failure and from a completed physical run.


References: [Flutter integration tests](https://docs.flutter.dev/testing/integration-tests),
[profile-mode integration driver](https://docs.flutter.dev/cookbook/testing/integration/profiling),
[Flutter 3.47.7 changelog](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/CHANGELOG.md),
[iOS 27 debugger issue](https://github.com/flutter/flutter/issues/190307).
