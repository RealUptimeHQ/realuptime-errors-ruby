# realuptime-errors (Ruby)

Zero-dependency error tracking SDK for Ruby, with Rails, Rack and Sidekiq
integrations: part of [RealUptime Errors](https://realuptime.io/error-tracking).

This is a **mirror**. It is published from `packages/errors-ruby` in the
[realuptime monorepo](https://github.com/RealUptimeHQ/realuptime) by
`scripts/publish-sdk-mirrors.mjs` and is not edited directly; open issues
and PRs against this repo, but expect source changes to land here after
they merge upstream.

## Install

Installable from the package registry (primary) or straight from this mirror's git history (e.g. to pin an exact commit).

```ruby
# Gemfile
gem "realuptime-errors"
```

```ruby
# or, straight from this mirror
gem "realuptime-errors", git: "https://github.com/RealUptimeHQ/realuptime-errors-ruby"
```

## Usage

```ruby
require "realuptime/errors"

Realuptime::Errors.init(
  dsn: "https://realuptime.io/api/errors/v1/ingest/rue_...",  # from your project's dashboard
  release: "v2.4.1",
  environment: "production"
)

Realuptime::Errors.capture_exception(some_error)
```

Rails: `gem "realuptime-errors", git: "...", require: "realuptime/errors/rails"`,
then set `Rails.application.config.realuptime_errors.dsn` (or
`ENV["REALUPTIME_ERRORS_DSN"]`); the Railtie installs the Rack middleware
and the ActiveJob hook.
Rack: `use Realuptime::Errors::RackMiddleware`
Sidekiq: `require "realuptime/errors/sidekiq"; Realuptime::Errors::Sidekiq.install`

## What this SDK actually does

- **Never raises out of a public method.** Every entry point catches
  everything; a broken SDK logs once to stderr (prefixed
  `[realuptime-errors]`) and goes quiet. An error tracker that crashes the
  app it watches is worse than none.
- **Scrubs PII by default, client-side**, before anything serializes:
  `Authorization`/`Proxy-Authorization`/`Cookie`/`Set-Cookie` headers are
  replaced whole; card-shaped digit runs (Luhn-checked), JWTs, prefixed API
  keys, and long hex/base64 runs are pattern-scrubbed anywhere they appear
  in the message, request context, breadcrumbs, tags and context values.
  `user.email` and `user.username` are removed unless opted back in by
  name with `allow_fields: ["user.email"]`; there is no global "disable
  scrubbing" switch, by design. The vectors in `scrub-vectors.json` are
  the same file the JS and Python SDKs and the server are tested against.
- **Never silently drops.** The in-memory buffer (200 events) evicts the
  oldest event when full, counts every eviction, and reports the count on
  the next successful batch, so drops show up on your dashboard instead of
  disappearing.
- **Standard library only** (`json`, `net/http`, `uri`, `time`,
  `rbconfig`), checked by `test/wire_contract_test.rb`'s require
  allow-list scan; the gemspec declares zero runtime dependencies.
- **Background delivery** on one thread per process (re-spawned after a
  fork), exponential backoff 5s to 300s, over-quota pause until the window
  resets, revoked key disables for the process. `Realuptime::Errors.flush`
  is synchronous and runs at exit.

## API

| Method | Notes |
| --- | --- |
| `init(dsn:, release: nil, environment: nil, allow_fields: nil, capture_unhandled: true, send_device_info: true, background: true)` | Installs an `at_exit` reporter unless `capture_unhandled: false`. Safe to call twice; a missing DSN logs once and stays inert. |
| `capture_exception(exc, request: nil, fingerprint: nil, release: nil, environment: nil, user: nil, tags: nil, context: nil)` | Reports an exception. |
| `capture_message(message, ...)` | Reports a plain message. |
| `set_user(id:, email:, username:)` / `set_tag(k, v)` / `set_tags(h)` / `set_context(k, v)` | Sticky identity, tags and context for every later event. |
| `add_breadcrumb(message, category: nil, data: nil)` | Bounded trail (last 20), rides the next event. |
| `flush` | Delivers anything buffered, synchronously. |
| `RackMiddleware` / `Rails::RailsMiddleware` / `Sidekiq::ServerMiddleware` | Capture unhandled exceptions with minimal request or job context, then re-raise. |

## Tests

```bash
ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].each { |f| require "./#{f}" }'
```

## Version

This mirror tracks SDK_VERSION `0.1.0` in `lib/realuptime/errors/version.rb`,
the string every event actually carries on the wire.

## License

MIT, see [LICENSE](./LICENSE).
