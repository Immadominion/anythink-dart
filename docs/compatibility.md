# Compatibility

The workspace uses Flutter 3.44.2 / Dart 3.12.2. Individual packages have lower
minimums where their dependencies permit them.

| Package | Dart | Flutter |
| --- | --- | --- |
| `anythink_dart` | 3.8.0 | Not required |
| `anythink_flutter` | 3.10.0 | 3.38.1 |
| `anythink_flutter_auth` | 3.12.0 | 3.44.0 |
| `anythink_flutter_push` | 3.10.0 | 3.38.1 |
| `anythink_flutter_purchases` | 3.11.0 | 3.41.0 |

All five packages passed isolated analysis and tests on their minimum toolchains
with both latest-compatible and lowest-direct runtime dependencies. These checks
cover Dart and plugin APIs; configured providers and device behavior are separate.

## Reproduce package checks

```sh
python3 tool/check_package.py --package anythink_dart \
  --resolution lowest-direct --dart /path/to/dart-3.8.0/bin/dart
python3 tool/check_package.py --package anythink_flutter \
  --resolution latest --flutter /path/to/flutter-3.38.1/bin/flutter
```

Each run copies the package and its local peers into an isolated directory,
resolves dependencies, analyzes and tests them. Reports go to
`build/compatibility/`. CI runs both strategies for every package.

`lowest-direct` downgrades direct runtime dependencies while keeping compatible
development tools. It does not test every transitive combination. `--offline`
limits resolution to the local cache and cannot establish registry-wide minimums.

## Check package archives

```sh
python3 tool/package_preflight.py
```

This runs `flutter pub publish --dry-run` in a copied workspace and checks every
archive. It never uploads or changes `publish_to: none`. Reports and archive
listings go to `build/package-preflight/`; registry metadata may be read.

Package archives exclude credentials, local configuration, generated files,
lockfiles, logs and build output. Before publishing to pub.dev, verify package
name ownership, complete the [release gates](validation.md#before-a-release),
and deliberately change the publication guard.

References: [workspaces](https://dart.dev/tools/pub/workspaces),
[dependency downgrade](https://dart.dev/tools/pub/cmd/pub-downgrade),
[publish dry runs](https://dart.dev/tools/pub/cmd/pub-lish).
