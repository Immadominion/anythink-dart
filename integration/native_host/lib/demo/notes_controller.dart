import 'package:anythink_dart/anythink_dart.dart';
import 'package:flutter/foundation.dart';

import '../session_controller.dart';

final class Note {
  const Note({required this.id, required this.title, required this.body});
  factory Note.fromJson(JsonObject json) {
    final id = json['id'];
    final title = json['title'];
    final body = json['body'];
    if (id is! int || title is! String || (body != null && body is! String)) {
      throw const FormatException('Unexpected note fields');
    }
    return Note(id: id, title: title, body: body as String? ?? '');
  }
  final int id;
  final String title;
  final String body;
}

/// Records remain server-owned. Never substitute sample data after a failure.
class NotesController extends ChangeNotifier {
  NotesController(AnythinkClient client)
    : _records = client.collection('notes', decode: Note.fromJson);

  final RecordService<Note> _records;
  List<Note> notes = const [];
  bool loading = false;
  bool saving = false;
  bool loaded = false;
  bool hasMore = false;
  String? error;
  int _page = 0;
  bool _disposed = false;

  Future<void> load({bool more = false}) async {
    if (_disposed || loading || saving || (more && !hasMore)) return;
    loading = true;
    error = null;
    _notify();
    try {
      final next = more ? _page + 1 : 1;
      final page = await _records.list(
        query: RecordQuery(
          page: next,
          pageSize: 20,
          sortBy: 'id',
          sortDirection: SortDirection.descending,
        ),
      );
      if (_disposed) return;
      final combined = [if (more) ...notes, ...page.items];
      notes = List.unmodifiable(
        {for (final note in combined) note.id: note}.values,
      );
      _page = next;
      hasMore = page.hasNextPage;
      loaded = true;
    } catch (failure) {
      if (!_disposed) error = safeFailure(failure);
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<bool> create(String title, String body) async {
    if (_disposed || saving || loading || title.trim().isEmpty) return false;
    saving = true;
    error = null;
    _notify();
    var created = false;
    try {
      final note = await _records.create({
        'title': title.trim(),
        'body': body.trim(),
      });
      if (_disposed) return false;
      notes = List.unmodifiable([
        note,
        ...notes.where((item) => item.id != note.id),
      ]);
      created = true;
    } catch (failure) {
      if (!_disposed) error = safeFailure(failure);
    } finally {
      saving = false;
      _notify();
    }
    // Read again so the visible list comes from the same API used after restart.
    if (created) await load();
    return created;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
