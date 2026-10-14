## 0.1.0-dev.1

- Cancel pending registration and discard cached results when session refresh
  requires a new sign-in.
- Add opt-in Firebase Messaging registration for Android and iOS.
- Add explicit permission requests, token/session/lifecycle synchronization,
  cancellation, error reporting and owned-subscription cleanup.
- Expose raw message/tap streams without invented action callbacks.
- Guard terminated launch messages against native duplicates and concurrent
  consumers; preserve explicit retry after null/errors and reject late disposal.
- Document native setup and the missing consumer unregister/rebind contract.
- Snapshot nested registration metadata before asynchronous native token work.
- Correct the minimum Flutter version to 3.38.1, the first verified patch with
  stable Dart 3.10 satisfying the package constraint.
