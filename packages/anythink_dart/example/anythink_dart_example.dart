import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';

/// Reads a real project's notes without creating or changing records.
Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln(
      'Set ANYTHINK_API_ORIGIN, ANYTHINK_PROJECT_ID, ANYTHINK_EMAIL and '
      'ANYTHINK_PASSWORD. Run this example against an existing notes entity. '
      'It reports counts only, never credentials or record contents.',
    );
    return;
  }
  final environment = Platform.environment;
  const keys = [
    'ANYTHINK_API_ORIGIN',
    'ANYTHINK_PROJECT_ID',
    'ANYTHINK_EMAIL',
    'ANYTHINK_PASSWORD',
  ];
  if (keys.any((key) => environment[key]?.isNotEmpty != true)) {
    stderr.writeln('Missing configuration. Run with --help.');
    exitCode = 64;
    return;
  }
  final client = AnythinkClient(
    apiOrigin: Uri.parse(environment['ANYTHINK_API_ORIGIN']!),
    projectId: environment['ANYTHINK_PROJECT_ID']!,
  );
  try {
    await client.auth.signInWithPassword(
      email: environment['ANYTHINK_EMAIL']!,
      password: environment['ANYTHINK_PASSWORD']!,
    );
    await client.auth.getUser();
    final notes = client.collection<Note>('notes', decode: Note.fromJson);
    final page = await notes.list(query: RecordQuery(pageSize: 20));
    stdout.writeln(
      'Read ${page.items.length} notes on page ${page.page}. '
      'More pages: ${page.hasNextPage}.',
    );
    final logout = await client.auth.signOut();
    if (!logout.remoteRevoked) {
      stderr.writeln('Local sign-out complete; remote revocation unconfirmed.');
      exitCode = 1;
    }
  } on AnythinkException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    await client.close();
  }
}

final class Note {
  const Note(this.id, this.title, this.body);

  factory Note.fromJson(JsonObject json) {
    final id = json['id'];
    final title = json['title'];
    final body = json['body'];
    if (id is! int || title is! String || (body != null && body is! String)) {
      throw const ProtocolException('Unexpected notes schema.');
    }
    return Note(id, title, body as String?);
  }

  final int id;
  final String title;
  final String? body;
}
