# Live search validation and upstream limitations

Observed on 14 October 2026 in a disposable project with two ordinary App User
accounts. The `notes` entity has row-level
security. Four newly created records contained synthetic text only: two owned by
each account. `title` and `body` were searchable; neither was initially publicly
searchable. No other users' records or projects were queried.

## Verified behavior

Both signed-in users received their own two records and no other-owner hits.
Private body search, highlighting, field-scoped text, exact-ID filtering and
similarity all returned and decoded real indexed data. Similarity excluded the
source and returned the one visible peer. Anonymous full-text search initially
returned no matching records. Fifteen checks passed, with separate session
revocation checks.

After temporarily marking only `title` publicly searchable, ordinary anonymous
full-text search returned all four public titles and omitted `body`. The SDK
sends neither a bearer token nor cookies on public routes. These observations
validate the ordinary projection in this fixture, not every access-policy path.

## Measured upstream defects

1. **Anonymous highlights included the private body.** With `hl=true`, the
   top-level hit omitted `body`, but `_formatted.body` contained the synthetic
   private value. `_formatted` also included other nonpublic metadata.
2. **Anonymous similarity included the private body.** Its bare-array response
   contained `body`, `__name`, `tenant_id` and other fields. After removing the
   public flag from `title`, the same anonymous request still returned three
   records with the private body, while ordinary anonymous full-text search
   returned no results.
3. **Authenticated metadata preceded owner filtering.** User A received two hits,
   but `total_items` was four and title facets included all four values, including
   user B's synthetic titles. Owner-filtered hits therefore do not establish
   confidential counts or facet values.

These are observations of this deployment and configuration, not assumptions
about every Anythink deployment. The request/response shapes were valid; the
privacy failures are not a Dart decoder error. No real private content was used.

## SDK decisions and cleanup

`queryPublic` rejects `SearchQuery(highlight: true)` with `UnsupportedError`
before authentication, refresh or network access. It does not silently discard
the option. Authenticated highlighting remains available. Anonymous similarity
is not exposed in this unreleased package; no placeholder method was retained.
Server counts and facets are preserved, with their visibility limitation
documented. Filtering an already returned response is not an authorization fix.

**These measures cannot secure the backend against other HTTP clients.** Until
the upstream behavior is corrected, private searchable fields and facets must
not be treated as a confidentiality boundary. The four exact fixture IDs were
deleted through their owners and absence confirmed by record reads. The public
title flag was restored to off; body remains private. Sessions were revoked.

These limitations should be checked again after an upstream fix.
