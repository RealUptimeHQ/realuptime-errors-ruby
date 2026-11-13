# frozen_string_literal: true

module Realuptime
  module Errors
    SDK_NAME = "realuptime-errors-ruby"
    # The string every batch carries on the wire ("sdk" field); the gemspec
    # and the public mirror's version both read this constant.
    # REA-567: bumped from 0.1.0 (the version currently live on RubyGems)
    # so a republish carries the key-name redaction pass (REA-474) and the
    # ingest.realuptime.io host change (REA-473) that landed after 0.1.0
    # shipped. No feature was added, so this is a patch bump, not a minor
    # one.
    SDK_VERSION = "0.1.2" # x-release-please-version
  end
end
