# Changelog

## 0.1.0-dev.1

- Initial independent Dart core and optional Flutter integrations.
- Password/native/web auth exchange, explicit rotating session ownership and
  secure-store integration.
- Typed records, file streaming, subscriptions/Apple verification and push REST.
- Full-text search, workflow invocation, payment-provider discovery and folder details.
- Typed payment checkout/intents/saved methods, plan catalogs, caller-visible
  subscriptions, renewal operations, referrals and balances.
- Refuse public highlights after a measured backend field-projection defect;
  preserve and document server search counts/facets that precede RLS filtering.
- Validate the core independently on Dart 3.8, with latest-compatible and lowest
  direct runtime dependencies and nonpublishing archive checks.
- Verified real auth/record/file contracts; cross-user DELETE isolation checks
  accept a no-op 204 only after an unchanged owner read-back.
- Loopback HTTP contract tests and native plugin boundary tests.
- Development only; see validation report before using this build in production.
