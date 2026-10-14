## 0.1.0-dev.1

- Invalidate verified access and stop purchase operations when refresh requires
  a new sign-in, even if the account generation has not changed.
- Add optional StoreKit 2 purchase/restore coordination with explicit Anythink verification and native completion, account binding, generation guards and deterministic tests.
- Normalize native purchase-operation failures without exposing raw platform
  payloads; retain typed Anythink API failures and explicit completion retries.
