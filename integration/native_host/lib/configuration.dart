/// Public configuration only. Passwords are entered in the foreground UI.
final class NativeHostConfiguration {
  const NativeHostConfiguration({
    required this.apiOrigin,
    required this.projectId,
  });
  static const environment = NativeHostConfiguration(
    apiOrigin: String.fromEnvironment('ANYTHINK_API_ORIGIN'),
    projectId: String.fromEnvironment('ANYTHINK_PROJECT_ID'),
  );
  final String apiOrigin;
  final String projectId;
  bool get isMissing => apiOrigin.isEmpty || projectId.isEmpty;
}
