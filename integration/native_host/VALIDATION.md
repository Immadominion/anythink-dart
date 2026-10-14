# Native validation

The [SDK validation summary](../../docs/validation.md#native-checks) records the
completed device checks and remaining gaps.

Session tests cover password sign-in, server identity, secure storage, process
restart, token rotation, sign-out and durable removal. Provider tests remain
separate from normal host compilation and password-session checks.

The runners under `tool/` target the maintainer's dedicated disposable test
project. Their project guards must match the reviewed private configuration;
never substitute an administrator or production account. Runtime reports are
written under the gitignored `evidence/` directory.

Use [the host guide](README.md) for manual checks,
[physical iOS](PHYSICAL_IOS.md) for signed-device runs, and
[provider setup](PROVIDER_READINESS.md) for Google, Apple, Firebase and purchases.
