# Changelog

## 0.1.2 (2026-11-13)


### Bug Fixes

* **errors:** scrub credential values in name=value text and query strings (REA-1260)

## 0.1.1 (2026-09-25)

### Features

* Scrubbing: a case-insensitive key-name denylist (password, secret, token, api key, authorization, credential, private key, access key, session) is applied before the pattern scrub, matching whole camelCase or snake_case segments.
* Scrubbing: new pattern rules for AWS access key ids, Stripe webhook signing secrets and credentials in URL userinfo.
* Documentation and examples name the dedicated intake host, `ingest.realuptime.io`. DSNs already issued keep working.

## 0.1.0 (2026-08-24)

First published release.

### Features

* Error capture for Rails, Rack and Sidekiq, standard library only.
* Scrub-by-default for sensitive values before an event leaves the process.
* Bounded buffering with honest drop counters.
