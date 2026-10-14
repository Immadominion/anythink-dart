import 'package:flutter/material.dart';

import '../configuration.dart';
import '../session_controller.dart';
import 'app_theme.dart';
import 'components.dart';

class SessionValidationScreen extends StatefulWidget {
  const SessionValidationScreen({super.key, required this.configuration});
  final NativeHostConfiguration configuration;

  @override
  State<SessionValidationScreen> createState() =>
      _SessionValidationScreenState();
}

class _SessionValidationScreenState extends State<SessionValidationScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final SessionController _session;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _session = SessionController(widget.configuration);
  }

  Future<void> _signIn() async {
    if (!_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await _session.signIn(_email.text, _password.text);
    } finally {
      if (mounted) _password.clear();
    }
  }

  @override
  void dispose() {
    _session.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 40).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      const SizedBox(height: 48),
                      if (_session.signedIn) _account() else _signInForm(),
                      if (_session.message case final message?) ...[
                        const SizedBox(height: 20),
                        SessionNotice(
                          message: message,
                          isError: _session.isError,
                        ),
                      ],
                      if (_session.needsSignOutRetry) ...[
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: _session.busy ? null : _session.signOut,
                          icon: const Icon(Icons.logout_rounded, size: 18),
                          label: const Text('Retry sign-out'),
                        ),
                      ],
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _header() => LayoutBuilder(
    builder: (context, constraints) => Row(
      children: [
        const Expanded(child: AppBrand()),
        if (constraints.maxWidth >= 330 &&
            MediaQuery.textScalerOf(context).scale(1) <= 1.2)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: ShapeDecoration(
              color: const Color(0xffeae9e1),
              shape: squircle(9),
            ),
            child: const Text(
              'PREVIEW',
              style: TextStyle(
                color: AppPalette.muted,
                fontSize: 10,
                letterSpacing: 1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Settings',
          onPressed: _showDetails,
          icon: const Icon(Icons.settings_outlined, size: 21),
        ),
      ],
    ),
  );

  Widget _signInForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Welcome back.', style: Theme.of(context).textTheme.headlineLarge),
      const SizedBox(height: 10),
      const Text(
        'Sign in to your workspace.',
        style: TextStyle(color: AppPalette.muted, fontSize: 16),
      ),
      const SizedBox(height: 32),
      SurfaceCard(
        child: Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('email-field'),
                  controller: _email,
                  enabled: _session.configured && !_session.busy,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.username],
                  autocorrect: false,
                  enableSuggestions: false,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter your email.'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('password-field'),
                  controller: _password,
                  enabled: _session.configured && !_session.busy,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip: _showPassword
                          ? 'Hide password'
                          : 'Show password',
                      onPressed: _session.configured && !_session.busy
                          ? () => setState(() => _showPassword = !_showPassword)
                          : null,
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                      ),
                    ),
                  ),
                  obscureText: !_showPassword,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  autocorrect: false,
                  enableSuggestions: false,
                  onFieldSubmitted: (_) {
                    if (_session.configured && !_session.busy) _signIn();
                  },
                  validator: (value) => value == null || value.isEmpty
                      ? 'Enter your password.'
                      : null,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('sign-in'),
                  onPressed: _session.configured && !_session.busy
                      ? _signIn
                      : null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(_session.busy ? 'Please wait…' : 'Sign in'),
                      ),
                      const SizedBox(width: 12),
                      if (_session.busy)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.arrow_forward_rounded, size: 20),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_session.hasSavedSession) ...[
        const SizedBox(height: 12),
        Center(
          child: TextButton.icon(
            onPressed: _session.configured && !_session.busy
                ? _session.restore
                : null,
            icon: const Icon(Icons.history_rounded, size: 18),
            label: const Text('Use saved session'),
          ),
        ),
      ],
      if (!_session.configured) ...[
        const SizedBox(height: 16),
        SessionNotice(
          message: _session.invalidConfiguration
              ? 'Check your project settings to enable sign-in.'
              : 'Connect a project to enable sign-in.',
          isError: _session.invalidConfiguration,
        ),
      ],
    ],
  );

  Widget _account() {
    final user = _session.user;
    final name = [
      user?.firstName,
      user?.lastName,
    ].whereType<String>().where((part) => part.trim().isNotEmpty).join(' ');
    final displayText = name.isNotEmpty ? name : user?.email?.trim() ?? '';
    final initial = displayText.isEmpty
        ? '?'
        : displayText.characters.first.toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Your workspace.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: AppPalette.success,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                _session.statusLabel,
                key: const Key('auth-status'),
                style: const TextStyle(color: AppPalette.success),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: AppPalette.accentSoft,
                  shape: squircle(18),
                ),
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: AppPalette.accent,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                name.isNotEmpty ? name : 'Your account',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (user?.email case final email?) ...[
                const SizedBox(height: 6),
                Text(email, style: const TextStyle(color: AppPalette.muted)),
              ],
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              ActionRow(
                icon: Icons.refresh_rounded,
                label: 'Refresh account',
                onTap: _session.busy ? null : _session.refreshAccount,
                trailing: _session.busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              ActionRow(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onTap: _showDetails,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: _session.busy ? null : _session.signOut,
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  void _showDetails() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: _session,
      builder: (context, _) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Settings', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              _detail('Session', _session.statusLabel),
              _detail(
                'Project',
                widget.configuration.projectId.isEmpty
                    ? 'Not set'
                    : widget.configuration.projectId,
              ),
              _detail(
                'API',
                _session.validApiOrigin ??
                    (_session.invalidConfiguration ? 'Invalid' : 'Not set'),
              ),
              if (_session.user case final user?)
                _detail('Account ID', '${user.id}'),
              if (!_session.configured) ...[
                const SizedBox(height: 8),
                const Text(
                  'Set ANYTHINK_API_ORIGIN and ANYTHINK_PROJECT_ID when building the app.',
                  style: TextStyle(color: AppPalette.muted),
                ),
              ],
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 20),
              const Text(
                'Native sign-in, notifications and purchases are not enabled in this preview.',
                style: TextStyle(color: AppPalette.muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppPalette.muted, fontSize: 12),
        ),
        const SizedBox(height: 4),
        SelectableText(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ),
  );
}
