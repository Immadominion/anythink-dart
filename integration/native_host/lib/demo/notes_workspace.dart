import 'dart:async';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import '../ui/components.dart';
import 'notes_controller.dart';

class NotesWorkspace extends StatefulWidget {
  const NotesWorkspace({
    super.key,
    required this.client,
    required this.onSignOut,
  });
  final AnythinkClient client;
  final VoidCallback? onSignOut;

  @override
  State<NotesWorkspace> createState() => _NotesWorkspaceState();
}

class _NotesWorkspaceState extends State<NotesWorkspace> {
  late final NotesController _notes;

  @override
  void initState() {
    super.initState();
    _notes = NotesController(widget.client);
    unawaited(_notes.load());
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _notes,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Your notes.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
            ),
            IconButton(
              tooltip: 'Reload notes',
              onPressed: _notes.loading || _notes.saving ? null : _notes.load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          widget.client.auth.state.user?.email ?? 'Your workspace',
          style: const TextStyle(color: AppPalette.muted),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('new-note'),
          onPressed: _notes.loading || _notes.saving ? null : _compose,
          icon: const Icon(Icons.add_rounded),
          label: const Text('New note'),
        ),
        const SizedBox(height: 24),
        if (_notes.loading) const LinearProgressIndicator(minHeight: 2),
        if (_notes.error case final message?) ...[
          SessionNotice(message: message, isError: true),
          const SizedBox(height: 16),
        ],
        if (_notes.loaded && _notes.notes.isEmpty && !_notes.loading)
          const SurfaceCard(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'A little room for your next idea.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.muted),
              ),
            ),
          ),
        for (final note in _notes.notes) ...[
          Semantics(
            button: true,
            label: 'Open ${note.title}',
            child: InkWell(
              key: ValueKey('note-${note.id}'),
              customBorder: squircle(28),
              onTap: () => _read(note),
              child: SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (note.body.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        note.body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppPalette.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (_notes.hasMore)
          TextButton(
            onPressed: _notes.loading || _notes.saving
                ? null
                : () => _notes.load(more: true),
            child: const Text('Load more'),
          ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _notes.saving ? null : widget.onSignOut,
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('Sign out'),
        ),
      ],
    ),
  );

  Future<void> _read(Note note) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(note.title, style: Theme.of(context).textTheme.headlineLarge),
            const SizedBox(height: 20),
            SelectableText(
              note.body,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _compose() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _NoteComposer(controller: _notes),
    );
  }
}

class _NoteComposer extends StatefulWidget {
  const _NoteComposer({required this.controller});
  final NotesController controller;
  @override
  State<_NoteComposer> createState() => _NoteComposerState();
}

class _NoteComposerState extends State<_NoteComposer> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _busy = true);
    final saved = await widget.controller.create(_title.text, _body.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New note', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              TextFormField(
                key: const Key('note-title'),
                controller: _title,
                enabled: !_busy,
                maxLength: 120,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Title'),
                textInputAction: TextInputAction.next,
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Give your note a title.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('note-body'),
                controller: _body,
                enabled: !_busy,
                minLines: 3,
                maxLines: 6,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Write something…',
                ),
              ),
              if (widget.controller.error case final message?) ...[
                const SizedBox(height: 12),
                SessionNotice(message: message, isError: true),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('save-note'),
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Saving…' : 'Save note'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
