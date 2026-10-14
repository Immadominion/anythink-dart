import 'package:flutter/material.dart';

import 'app_theme.dart';

class AppBrand extends StatelessWidget {
  const AppBrand({super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Image.asset(
      'assets/anythink-logo.png',
      width: 150,
      height: 46,
      fit: BoxFit.contain,
      semanticLabel: 'Anythink',
    ),
  );
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.padding = 24});
  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(padding),
    decoration: ShapeDecoration(
      color: Colors.white,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: AppPalette.line),
      ),
      shadows: const [
        BoxShadow(
          color: Color(0x05000000),
          blurRadius: 22,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: child,
  );
}

class SessionNotice extends StatelessWidget {
  const SessionNotice({super.key, required this.message, this.isError = false});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const Key('operation-result'),
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: isError ? const Color(0xffffeee8) : const Color(0xffeeeee7),
        shape: squircle(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.info_outline_rounded : Icons.check_circle_outline,
            size: 20,
            color: isError ? const Color(0xff9a3f2a) : AppPalette.success,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ),
  );
}

class ActionRow extends StatelessWidget {
  const ActionRow({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    minLeadingWidth: 24,
    leading: Icon(icon, size: 22),
    title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
    trailing: trailing ?? const Icon(Icons.arrow_forward_ios_rounded, size: 14),
    onTap: onTap,
    enabled: onTap != null,
    shape: squircle(16),
  );
}
