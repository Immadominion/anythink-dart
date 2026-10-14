## 0.1.0-dev.1

- Add optional native Google (Android/iOS) and Apple (iOS) sign-in adapters.
- Validate provider token/subject presence and reject Google's email fallback.
- Preserve typed backend errors; redact provider errors and model cancellation.
- Prevent concurrent provider flows and discard credentials returned after an auth identity change.
- Add boundary tests and a source-backed integration example; live native provider verification remains a release gate.
