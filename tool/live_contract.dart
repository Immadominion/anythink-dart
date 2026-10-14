import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anythink_dart/anythink_dart.dart';

import 'live_delete_guard.dart';

const _help = '''
Live Anythink auth/records contract validation (creates and deletes test rows).

Usage:
  dart run tool/live_contract.dart --help
  dart run tool/live_contract.dart --config .secrets/live-contract.json --check-config
  dart run tool/live_contract.dart --config .secrets/live-contract.json --ack-disposable-project

--help and --check-config never contact Anythink or Firebase.
The config must be a Git-ignored, owner-only JSON file inside this repository's
.secrets directory. It must acknowledge a disposable project and identify two
distinct, ordinary App User accounts. Never supply credentials on the command
line. See docs/live-validation.md for the complete schema and prerequisites.

Exit codes: 0 all requested checks passed (or local help/config check succeeded),
1 live checks/cleanup incomplete, 64 invalid arguments/configuration.
''';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.write(_help);
    return;
  }
  try {
    final options = _Options.parse(arguments);
    final config = await _Config.load(options.configPath);
    if (options.checkConfig) {
      stdout.writeln(
        'LOCAL CONFIG VALID: no network calls or live checks performed.',
      );
      return;
    }
    if (!options.acknowledged) {
      throw const _ConfigError(
        'Live execution requires --ack-disposable-project.',
      );
    }
    final success = await _Run(config).execute();
    exitCode = success ? 0 : 1;
  } on _ConfigError catch (error) {
    stderr.writeln('CONFIG ERROR: ${error.message}');
    stderr.writeln('Use --help. No live validation was performed.');
    exitCode = 64;
  } catch (error) {
    stderr.writeln('INCOMPLETE: ${_safeError(error)}');
    exitCode = 1;
  }
}

final class _Options {
  const _Options(this.configPath, this.checkConfig, this.acknowledged);
  final String configPath;
  final bool checkConfig;
  final bool acknowledged;

  factory _Options.parse(List<String> arguments) {
    String? path;
    var check = false;
    var ack = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--config':
          if (path != null ||
              i + 1 >= arguments.length ||
              arguments[i + 1].startsWith('--')) {
            throw const _ConfigError('Supply exactly one --config path.');
          }
          path = arguments[++i];
        case '--check-config':
          if (check) throw const _ConfigError('Duplicate --check-config.');
          check = true;
        case '--ack-disposable-project':
          if (ack) throw const _ConfigError('Duplicate acknowledgement.');
          ack = true;
        default:
          throw const _ConfigError('Unknown or misplaced argument.');
      }
    }
    if (path == null) throw const _ConfigError('A --config path is required.');
    if (check && ack) {
      throw const _ConfigError(
        'Choose local --check-config or acknowledged live execution.',
      );
    }
    return _Options(path, check, ack);
  }
}

final class _ConfigError implements Exception {
  const _ConfigError(this.message);
  final String message;
}

final class _ContractFailure implements Exception {
  const _ContractFailure(this.reason);
  final String reason;
}

final class _UserCredentials {
  const _UserCredentials(this.email, this.password);
  final String email;
  final String password;
}

final class _Config {
  const _Config({
    required this.origin,
    required this.projectId,
    required this.entity,
    required this.role,
    required this.users,
    required this.persistence,
  });
  final Uri origin;
  final String projectId;
  final String entity;
  final String role;
  final List<_UserCredentials> users;
  final bool persistence;

  static Future<_Config> load(String path) async {
    if (!Platform.isMacOS && !Platform.isLinux) {
      throw const _ConfigError(
        'This runner requires macOS/Linux file permissions.',
      );
    }
    final root = File.fromUri(Platform.script).parent.parent;
    final secrets = Directory('${root.path}/.secrets');
    final input = File(path);
    late String resolved;
    try {
      final secretPath = await secrets.resolveSymbolicLinks();
      resolved = await input.resolveSymbolicLinks();
      if (!resolved.startsWith('$secretPath/')) {
        throw const _ConfigError(
          'The config must be inside the repository .secrets directory.',
        );
      }
      final stat = await File(resolved).stat();
      if (stat.type != FileSystemEntityType.file ||
          (stat.mode & 0x1ff) != 0x180 ||
          stat.size > 65536) {
        throw const _ConfigError(
          'The config must be a regular file with mode 0600 and at most 64 KiB.',
        );
      }
      final ignored = await Process.run('git', [
        'check-ignore',
        '--quiet',
        '--',
        resolved,
      ], workingDirectory: root.path);
      if (ignored.exitCode != 0) {
        throw const _ConfigError('Git must confirm the config is ignored.');
      }
    } on FileSystemException {
      throw const _ConfigError('Cannot read the private config path.');
    } on ProcessException {
      throw const _ConfigError('Git is required to verify config exclusion.');
    }
    late Map<String, Object?> json;
    try {
      final decoded = jsonDecode(await File(resolved).readAsString());
      if (decoded is! Map<String, Object?>) {
        throw const _ConfigError('The config must be a JSON object.');
      }
      json = decoded;
    } on FormatException {
      throw const _ConfigError('The config is not valid JSON.');
    } on FileSystemException {
      throw const _ConfigError('Cannot read the private config.');
    }
    const keys = {
      'api_origin',
      'project_id',
      'disposable_project',
      'entity',
      'required_role',
      'users',
      'verify_persistence',
    };
    if (json.keys.any((key) => !keys.contains(key))) {
      throw const _ConfigError('The config contains an unsupported property.');
    }
    String text(String key, [String? fallback]) {
      final value = json[key] ?? fallback;
      if (value is! String || value.isEmpty || value.trim() != value) {
        throw _ConfigError('A nonempty $key string is required.');
      }
      return value;
    }

    if (json['disposable_project'] != true) {
      throw const _ConfigError('disposable_project must explicitly be true.');
    }
    final origin = Uri.tryParse(text('api_origin'));
    if (origin == null ||
        origin.scheme != 'https' ||
        !origin.hasAuthority ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw const _ConfigError(
        'api_origin must be an HTTPS origin without a path, credentials or query.',
      );
    }
    final project = text('project_id');
    final entity = text('entity', 'notes');
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(project) ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(entity)) {
      throw const _ConfigError(
        'project_id or entity has an invalid identifier.',
      );
    }
    final role = text('required_role', 'App User');
    if ([
      'standard user',
      'administrator',
      'admin',
    ].contains(role.toLowerCase())) {
      throw const _ConfigError(
        'required_role must be a dedicated ordinary application role.',
      );
    }
    final rawUsers = json['users'];
    if (rawUsers is! List<Object?> || rawUsers.length != 2) {
      throw const _ConfigError('Exactly two users are required.');
    }
    final users = <_UserCredentials>[];
    for (final value in rawUsers) {
      if (value is! Map<String, Object?> ||
          value.length != 2 ||
          value['email'] is! String ||
          value['password'] is! String) {
        throw const _ConfigError(
          'Each user must contain only email and password strings.',
        );
      }
      final email = value['email']! as String;
      final password = value['password']! as String;
      if (email.trim() != email || !email.contains('@') || password.isEmpty) {
        throw const _ConfigError(
          'Each user needs a valid email and nonempty password.',
        );
      }
      users.add(_UserCredentials(email, password));
    }
    if (users[0].email.toLowerCase() == users[1].email.toLowerCase()) {
      throw const _ConfigError('The two user emails must be distinct.');
    }
    final persistence = json['verify_persistence'] ?? true;
    if (persistence is! bool) {
      throw const _ConfigError('verify_persistence must be a boolean.');
    }
    return _Config(
      origin: origin,
      projectId: project,
      entity: entity,
      role: role,
      users: users,
      persistence: persistence,
    );
  }
}

/// Private, short-lived CLI test storage, not production device secure storage.
final class _AtomicSessionStore implements SessionStore {
  _AtomicSessionStore(this.file);
  final File file;
  int _sequence = 0;

  @override
  Future<String?> read() async {
    if (!await file.exists()) return null;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        (stat.mode & 0x1ff) != 0x180 ||
        stat.size > 65536) {
      throw const _ContractFailure('Session file protection check failed.');
    }
    return file.readAsString();
  }

  @override
  Future<void> write(String value) async {
    final temp = File('${file.path}.pending-${_sequence++}');
    try {
      await temp.create(exclusive: true);
      await _chmod(temp.path, '600', 0x180);
      final writer = await temp.open(mode: FileMode.writeOnly);
      try {
        await writer.writeString(value);
        await writer.flush();
      } finally {
        await writer.close();
      }
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

Future<void> _chmod(String path, String mode, int expected) async {
  final result = await Process.run('chmod', [mode, path]);
  if (result.exitCode != 0 ||
      ((await FileStat.stat(path)).mode & 0x1ff) != expected) {
    throw const _ContractFailure(
      'Private filesystem permissions could not be established.',
    );
  }
}

final class _Run {
  _Run(this.config);
  final _Config config;
  final _clients = <AnythinkClient>[];
  final _wireClients = <AnythinkClient, DeleteStatusHttpClient>{};
  final _owned = <int, Set<int>>{0: {}, 1: {}};
  Directory? _sessionDirectory;
  String _stage = 'initialization';
  int _passed = 0;
  bool _unknownCreateOutcome = false;

  Future<bool> execute() async {
    var complete = false;
    stdout.writeln(
      'LIVE RUN: disposable project; two-user auth and records scope.',
    );
    try {
      final stores = <SessionStore?>[null, null];
      if (config.persistence) {
        final directory = await Directory.systemTemp.createTemp(
          'anythink-live-',
        );
        _sessionDirectory = directory;
        await _chmod(directory.path, '700', 0x1c0);
        stores[0] = _AtomicSessionStore(File('${directory.path}/a.json'));
        stores[1] = _AtomicSessionStore(File('${directory.path}/b.json'));
      }
      for (var i = 0; i < 2; i++) {
        _clients.add(_client(stores[i]));
      }
      final identities = <AnythinkUser>[];
      for (var i = 0; i < 2; i++) {
        final label = i == 0 ? 'A' : 'B';
        await _check(
          '$label password sign-in and ordinary-role checks',
          () async {
            final credentials = config.users[i];
            final auth = _clients[i].auth;
            await auth.signInWithPassword(
              email: credentials.email,
              password: credentials.password,
            );
            final user = await auth.getUser();
            _require(
              !await auth.isAdmin(),
              'An administrator identity cannot validate application RLS.',
            );
            _require(
              await auth.hasRole(config.role),
              'The dedicated application role is missing.',
            );
            _require(
              !await auth.hasRole('Standard User'),
              'Standard User is a team role, not an app-user fixture.',
            );
            _require(
              user.data['can_access_any_api'] == true,
              'The user lacks API access.',
            );
            identities.add(user);
          },
        );
      }
      await _check('identities are distinct', () async {
        _require(
          identities[0].id != identities[1].id &&
              identities[0].gid != identities[1].gid,
          'Both credentials resolved to the same identity.',
        );
      });
      for (var i = 0; i < 2; i++) {
        final label = i == 0 ? 'A' : 'B';
        await _check('$label refresh rotates and preserves identity', () async {
          final auth = _clients[i].auth;
          final before = auth.currentSession!;
          final after = await auth.refreshSession();
          _require(
            after.refreshToken != before.refreshToken,
            'The refresh token did not rotate.',
          );
          _require(
            after.expiresAt.isAfter(DateTime.now().toUtc()),
            'The renewed access session is already expired.',
          );
          final user = await auth.getUser();
          _require(
            user.id == identities[i].id && user.gid == identities[i].gid,
            'Refresh changed identity.',
          );
        });
      }
      if (config.persistence) {
        await _check('atomic session close and restore', () async {
          await _clients[0].close();
          _clients[0] = _client(stores[0]);
          await _clients[0].auth.restoreSession();
          final user = _clients[0].auth.state.user;
          _require(
            user?.id == identities[0].id && user?.gid == identities[0].gid,
            'Session restore failed to recover the same server identity.',
          );
        });
      } else {
        stdout.writeln(
          'SCOPE: persisted-session check was not requested; no persistence claim.',
        );
      }
      final random = Random.secure();
      final suffix = List.generate(
        12,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final marker = 'sdk-contract-$suffix';
      final a = _clients[0].records(config.entity);
      final b = _clients[1].records(config.entity);
      late int first;
      late int second;
      late int other;
      await _check('A creates and reads own records', () async {
        first = await _create(0, {
          'title': '$marker-a1',
          'body': 'original-a-body',
        });
        second = await _create(0, {
          'title': '$marker-a2',
          'body': 'second-a-body',
        });
        _require(first != second, 'Two creates returned the same record ID.');
        _matches(await a.get(first), {
          'title': '$marker-a1',
          'body': 'original-a-body',
        });
      });
      await _check('B creates and reads its own record', () async {
        other = await _create(1, {
          'title': '$marker-b',
          'body': 'original-b-body',
        });
        _require(
          other != first && other != second,
          'Different creates returned the same record ID.',
        );
        _matches(await b.get(other), {
          'title': '$marker-b',
          'body': 'original-b-body',
        });
      });
      await _check('A partial PUT preserves omitted fields', () async {
        await a.update(first, {'title': '$marker-a1-updated'});
        _matches(await a.get(first), {
          'title': '$marker-a1-updated',
          'body': 'original-a-body',
        });
      });
      await _check('B can update its own record', () async {
        await b.update(other, {'body': 'updated-b-body'});
        _matches(await b.get(other), {
          'title': '$marker-b',
          'body': 'updated-b-body',
        });
      });
      await _check('A pagination, filtering and sorting', () async {
        final filters = [RecordFilter.startsWith('title', marker)];
        final page1 = await a.list(
          query: RecordQuery(pageSize: 1, filters: filters),
        );
        final page2 = await a.list(
          query: RecordQuery(page: 2, pageSize: 1, filters: filters),
        );
        final ids = [first, second]..sort();
        _require(
          page1.page == 1 &&
              page2.page == 2 &&
              page1.pageSize == 1 &&
              page2.pageSize == 1,
          'Requested page boundaries were not honored.',
        );
        _require(
          page1.totalItems == 2 &&
              page2.totalItems == 2 &&
              page1.totalPages == 2 &&
              page2.totalPages == 2,
          'Filtered pagination totals do not match the two owned fixtures.',
        );
        _require(
          page1.hasNextPage &&
              !page1.hasPreviousPage &&
              !page2.hasNextPage &&
              page2.hasPreviousPage,
          'Pagination navigation metadata is inconsistent.',
        );
        _require(
          page1.items.length == 1 &&
              page2.items.length == 1 &&
              _id(page1.items.single) == ids[0] &&
              _id(page2.items.single) == ids[1],
          'Ascending pages did not return the expected distinct records.',
        );
        final descending = await a.list(
          query: RecordQuery(
            pageSize: 1,
            filters: filters,
            sortDirection: SortDirection.descending,
          ),
        );
        _require(
          descending.items.length == 1 &&
              _id(descending.items.single) == ids[1],
          'Descending sort was not honored.',
        );
        final exact = await a.list(
          query: RecordQuery(
            filters: [
              RecordFilter.equal(
                'title',
                FilterValue.text('$marker-a1-updated'),
              ),
            ],
          ),
        );
        _require(
          exact.totalItems == 1 &&
              exact.items.length == 1 &&
              _id(exact.items.single) == first,
          'Equality filtering was not honored.',
        );
      });
      await _check(
        'B cannot list A records, with or without filters',
        () async {
          final filtered = await b.list(
            query: RecordQuery(
              filters: [RecordFilter.startsWith('title', marker)],
            ),
          );
          _require(
            filtered.totalItems == 1 &&
                filtered.items.length == 1 &&
                _id(filtered.items.single) == other,
            'Filtered B listing leaked A or did not return its own fixture.',
          );
          final targeted = await b.list(
            query: RecordQuery(
              filters: [RecordFilter.equal('id', FilterValue.number(first))],
            ),
          );
          _require(
            targeted.totalItems == 0 && targeted.items.isEmpty,
            'A record is visible in an ID-filtered B list.',
          );
          final seen = <int>{};
          var reachedEnd = false;
          for (var page = 1; page <= 100; page++) {
            final listing = await b.list(
              query: RecordQuery(page: page, pageSize: 100),
            );
            _require(
              listing.page == page &&
                  listing.pageSize == 100 &&
                  listing.items.length <= 100,
              'Unfiltered pagination did not honor its requested boundary.',
            );
            for (final record in listing.items) {
              final id = _id(record);
              _require(
                id != first && id != second,
                'Unfiltered B listing leaked an A fixture.',
              );
              _require(seen.add(id), 'Unfiltered pages repeated a record.');
            }
            if (!listing.hasNextPage) {
              _require(
                seen.length == listing.totalItems && seen.contains(other),
                'Unfiltered listing is incomplete.',
              );
              reachedEnd = true;
              break;
            }
            _require(
              listing.items.isNotEmpty,
              'An empty page claims to have more records.',
            );
          }
          _require(
            reachedEnd,
            'Unfiltered listing exceeded the 100-page validation limit.',
          );
        },
      );
      await _check(
        'B cannot read A by ID',
        () => _denied(() async {
          await b.get(first);
        }),
      );
      await _check('B cannot update A by ID', () async {
        await _denied(() => b.update(first, {'body': 'must-not-be-written'}));
        _matches(await a.get(first), {
          'title': '$marker-a1-updated',
          'body': 'original-a-body',
        });
      });
      await _check('B cannot delete A; owner reads unchanged record', () async {
        await verifyDeleteIsolation(
          deleteAsOther: () async {
            await b.delete(first);
            return _wireClients[_clients[1]]!.lastDeleteStatus;
          },
          verifyOwnerUnchanged: () async {
            _matches(await a.get(first), {
              'title': '$marker-a1-updated',
              'body': 'original-a-body',
            });
          },
        );
      });
      await _check(
        'A deletes an owned record',
        () => _deleteAndVerify(0, second),
      );
      await _check(
        'B deletes its owned record',
        () => _deleteAndVerify(1, other),
      );
      complete = true;
    } catch (error) {
      stderr.writeln('[FAIL] $_stage: ${_safeError(error)}');
    } finally {
      if (!await _cleanup()) complete = false;
    }
    if (_unknownCreateOutcome) {
      stderr.writeln(
        'INCOMPLETE: a create response was lost or invalid; an untracked fixture may remain. No broad deletion was attempted.',
      );
      complete = false;
    }
    stdout.writeln(
      complete
          ? 'PASS: $_passed requested live checks passed; tracked fixtures and sessions cleaned.'
          : 'INCOMPLETE: live verification or cleanup failed. Do not report live parity.',
    );
    return complete;
  }

  AnythinkClient _client(SessionStore? store) {
    final wire = DeleteStatusHttpClient();
    final client = AnythinkClient(
      apiOrigin: config.origin,
      projectId: config.projectId,
      sessionStore: store,
      httpClient: wire,
      closeHttpClient: true,
      requestTimeout: const Duration(seconds: 30),
    );
    _wireClients[client] = wire;
    return client;
  }

  Future<void> _check(String label, Future<void> Function() body) async {
    _stage = label;
    await body();
    _passed++;
    stdout.writeln('[PASS] $label');
  }

  Future<int> _create(int owner, JsonObject values) async {
    JsonObject created;
    try {
      created = await _clients[owner].records(config.entity).create(values);
    } on TransportException catch (error) {
      _unknownCreateOutcome |= error.outcomeUncertain;
      rethrow;
    } on ProtocolException {
      _unknownCreateOutcome = true;
      rethrow;
    } on ApiException catch (error) {
      // A server failure can happen after a write commits. Never claim complete
      // cleanup without a returned ID, and never guess an ID to delete.
      _unknownCreateOutcome |= error.statusCode >= 500;
      rethrow;
    }
    late int id;
    try {
      id = _id(created);
    } catch (_) {
      _unknownCreateOutcome = true;
      rethrow;
    }
    _owned[owner]!.add(id);
    _matches(created, values);
    return id;
  }

  Future<void> _deleteAndVerify(int owner, int id) async {
    final records = _clients[owner].records(config.entity);
    await records.delete(id);
    try {
      await records.get(id);
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        _owned[owner]!.remove(id);
        return;
      }
      rethrow;
    }
    throw const _ContractFailure('Deleted record remains readable.');
  }

  Future<bool> _cleanup() async {
    var ok = true;
    for (var owner = 0; owner < _clients.length; owner++) {
      final client = _clients[owner];
      for (final id in _owned[owner]!.toList()) {
        try {
          try {
            await client.records(config.entity).delete(id);
          } on ApiException catch (error) {
            if (error.statusCode != 404) rethrow;
          }
          await _expectMissing(client.records(config.entity), id);
          _owned[owner]!.remove(id);
        } catch (error) {
          ok = false;
          stderr.writeln(
            '[FAIL] tracked-fixture cleanup: ${_safeError(error)}',
          );
        }
      }
      try {
        if (client.auth.currentSession != null) {
          final signedOut = await client.auth.signOut();
          _require(
            signedOut.remoteRevoked,
            'Remote session revocation was not confirmed.',
          );
        }
      } catch (error) {
        ok = false;
        stderr.writeln('[FAIL] session cleanup: ${_safeError(error)}');
      } finally {
        try {
          await client.close();
        } catch (error) {
          ok = false;
          stderr.writeln('[FAIL] client close: ${_safeError(error)}');
        }
      }
    }
    try {
      final directory = _sessionDirectory;
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      ok = false;
      stderr.writeln(
        '[FAIL] temporary private-session files could not be removed.',
      );
    }
    if (ok) {
      stdout.writeln('[PASS] cleanup of tracked fixtures and local sessions');
    }
    return ok;
  }
}

void _require(bool condition, String reason) {
  if (!condition) throw _ContractFailure(reason);
}

int _id(JsonObject record) {
  final value = record['id'];
  if (value is! int || value < 1) {
    throw const _ContractFailure(
      'A fixture response has no positive integer ID.',
    );
  }
  return value;
}

void _matches(JsonObject record, JsonObject expected) {
  _require(
    expected.entries.every((entry) => record[entry.key] == entry.value),
    'Read-back fields differ from the values written.',
  );
}

Future<void> _denied(Future<void> Function() action) async {
  try {
    await action();
  } on ApiException catch (error) {
    if (error.statusCode == 403 || error.statusCode == 404) return;
    rethrow;
  }
  throw const _ContractFailure(
    'A cross-user operation succeeded instead of returning 403/404.',
  );
}

Future<void> _expectMissing(RecordService<JsonObject> records, int id) async {
  try {
    await records.get(id);
  } on ApiException catch (error) {
    if (error.statusCode == 404) return;
    rethrow;
  }
  throw const _ContractFailure('Fixture removal was not confirmed by 404.');
}

String _safeError(Object error) => switch (error) {
  _ContractFailure() => error.reason,
  LiveDeleteIsolationFailure() =>
    'Cross-user delete returned an unexpected successful status; expected 204.',
  ApiException() => 'HTTP ${error.statusCode}',
  TransportException() =>
    'transport ${error.failure.name}; outcome uncertain: ${error.outcomeUncertain}',
  ProtocolException() => 'response protocol mismatch (content withheld)',
  SessionStorageException() => 'session persistence failed (content withheld)',
  FileSystemException() =>
    'private filesystem operation failed (path withheld)',
  _ => '${error.runtimeType} (details withheld)',
};
