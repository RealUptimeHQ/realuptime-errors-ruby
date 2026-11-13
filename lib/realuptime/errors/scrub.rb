# frozen_string_literal: true

module Realuptime
  module Errors
    # PII scrub-by-default, client-side (the internal-docs repo's errors-plan.md, "PII
    # scrub-by-default, specified"). A byte-for-byte port of
    # errors-js/scrub.ts and errors-py/realuptime_errors.py's
    # scrub half; the shared vectors (scrub-vectors.json, vendored into this
    # gem and asserted byte-identical to errors-js/scrub-vectors.json
    # by test/vendored_vectors_test.rb) pin all four implementations -- JS,
    # Python, this one, and the server's second net -- to identical output.
    #
    # The five pattern rules, in the shared order:
    #   1. JWT three-dot shape
    #   2. prefixed keys (sk_/pk_/rk_/ghp_/gho_/ghs_/xox?_/rua_/rue_/ru_live_)
    #   3. card-shaped digit runs, 13-19 digits, Luhn-checked
    #   4. long hex runs (32+)
    #   5. long base64-ish runs (40+)
    #
    # REMOVAL (value replaced whole) unless allow-listed by name:
    #   - headers authorization / proxy-authorization / cookie / set-cookie
    #   - identity (wire v2): user.email and user.username. user.id is NOT
    #     removed; an opaque id in the customer's own key space is not
    #     contact data, and it is what makes "how many users hit this"
    #     answerable.
    module Scrub
      SCRUBBED = "[scrubbed]"

      REMOVED_HEADERS = %w[authorization proxy-authorization cookie set-cookie].freeze
      REMOVED_USER_FIELDS = %w[user.email user.username].freeze

      JWT_RE = /\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b/.freeze
      PREFIXED_KEY_RE = /\b(?:sk|pk|rk|ghp|gho|ghs|xox[a-z]|rua|rue|ru_live|whsec)_[A-Za-z0-9_-]{8,}/.freeze
      AWS_KEY_RE = /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/.freeze
      CARD_RE = /(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/.freeze
      HEX_RE = /\b[0-9a-fA-F]{32,}\b/.freeze
      BASE64_RE = /(?<![A-Za-z0-9+_=-])[A-Za-z0-9+_-]{40,}={0,2}/.freeze
      URL_CREDS_RE = %r{\b([a-zA-Z][a-zA-Z0-9+.-]{0,31})://[^\s/@:]+:[^\s/@]+@}.freeze

      # Key-name denylist (REA-474): see errors-js/scrub.ts's module
      # doc for the full rationale. Matched against whole camelCase/
      # snake_case segments (and contiguous joins of them) so "tokenizer"
      # and "authentic" never match "token" / "auth".
      KEY_DENYLIST = %w[
        password passwd secret token apikey auth authorization
        credential credentials privatekey accesskey session
        pw pwd passphrase sig signature sid otp
      ].freeze

      # name=value pairs (REA-1260): the value is scrubbed when the name hits
      # KEY_DENYLIST. The value class spells out JavaScript's \s.
      KEY_VALUE_RE = /([A-Za-z0-9_.\[\]-]{1,64})=([^&#;,"'<>\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+)/.freeze

      module_function

      def key_segments(key)
        spaced = key.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2')
        spaced.split(/[^a-zA-Z0-9]+/).reject(&:empty?).map(&:downcase)
      end

      def key_denylisted?(key)
        segments = key_segments(key)
        segments.each_index do |i|
          joined = +""
          (i...segments.length).each do |j|
            joined << segments[j]
            return true if KEY_DENYLIST.include?(joined)
          end
        end
        false
      end

      def luhn_valid?(digits)
        total = 0
        double = false
        digits.reverse.each_char do |ch|
          d = ch.ord - 48
          if double
            d *= 2
            d -= 9 if d > 9
          end
          total += d
          double = !double
        end
        (total % 10).zero?
      end

      # The pattern rules over one string, in the shared order. Pure.
      def scrub_string(value)
        out = value.gsub(URL_CREDS_RE) { "#{Regexp.last_match(1)}://#{SCRUBBED}@" }
        out = out.gsub(JWT_RE, SCRUBBED)
        out = out.gsub(PREFIXED_KEY_RE, SCRUBBED)
        out = out.gsub(AWS_KEY_RE, SCRUBBED)
        out = out.gsub(CARD_RE) do |run|
          digits = run.delete(" -")
          digits.length >= 13 && digits.length <= 19 && luhn_valid?(digits) ? SCRUBBED : run
        end
        out = out.gsub(HEX_RE, SCRUBBED)
        out = out.gsub(BASE64_RE, SCRUBBED)
        out.gsub(KEY_VALUE_RE) do |pair|
          key = Regexp.last_match(1)
          key_denylisted?(key) ? "#{key}=#{SCRUBBED}" : pair
        end
      end

      # A flat string map (tags, custom context, device, frame locals): a
      # key denylisted by name (REA-474) replaces the value whole,
      # regardless of shape; otherwise the value passes the pattern rules.
      # Keys themselves are always left alone.
      def scrub_string_map(value)
        return value unless value.is_a?(Hash)

        value.each_with_object({}) do |(name, entry), out|
          out[name] = if !entry.is_a?(String)
                        entry
                      elsif key_denylisted?(name)
                        SCRUBBED
                      else
                        scrub_string(entry)
                      end
        end
      end

      def scrub_breadcrumb(crumb)
        return crumb unless crumb.is_a?(Hash)

        out = crumb.dup
        out["message"] = scrub_string(out["message"]) if out["message"].is_a?(String)
        out["data"] = scrub_string_map(out["data"]) if out["data"].is_a?(Hash)
        out
      end

      def scrub_user(user, allowed)
        return user unless user.is_a?(Hash)

        out = user.dup
        out["id"] = scrub_string(out["id"]) if out["id"].is_a?(String)
        REMOVED_USER_FIELDS.each do |field|
          key = field.sub("user.", "")
          value = out[key]
          next unless value.is_a?(String)

          out[key] = allowed.include?(field) ? scrub_string(value) : SCRUBBED
        end
        out
      end

      def scrub_frame(frame)
        return frame unless frame.is_a?(Hash)
        return frame unless frame["contextLine"] || frame["preContext"] || frame["postContext"] || frame["vars"]

        out = frame.dup
        out["contextLine"] = scrub_string(out["contextLine"]) if out["contextLine"].is_a?(String)
        %w[preContext postContext].each do |key|
          lines = out[key]
          out[key] = lines.map { |line| line.is_a?(String) ? scrub_string(line) : line } if lines.is_a?(Array)
        end
        out["vars"] = scrub_string_map(out["vars"]) if out["vars"].is_a?(Hash)
        out
      end

      # Scrubs one wire event (string-keyed Hash). Returns a new Hash; never
      # mutates the input.
      def scrub_event(event, allow_fields = nil)
        allowed = (allow_fields || []).map { |f| f.to_s.downcase }
        out = event.dup
        out["message"] = scrub_string(out["message"]) if out["message"].is_a?(String)
        out["breadcrumbs"] = out["breadcrumbs"].map { |c| scrub_breadcrumb(c) } if out["breadcrumbs"].is_a?(Array)
        out["frames"] = out["frames"].map { |f| scrub_frame(f) } if out["frames"].is_a?(Array)
        %w[tags context device].each do |key|
          out[key] = scrub_string_map(out[key]) if out[key].is_a?(Hash)
        end
        out["user"] = scrub_user(out["user"], allowed) if out["user"].is_a?(Hash)
        request = out["request"]
        if request.is_a?(Hash)
          request = request.dup
          request["path"] = scrub_string(request["path"]) if request["path"].is_a?(String)
          request["route"] = scrub_string(request["route"]) if request["route"].is_a?(String)
          headers = request["headers"]
          if headers.is_a?(Hash)
            request["headers"] = headers.each_with_object({}) do |(name, value), scrubbed|
              lower = name.to_s.downcase
              scrubbed[name] = if (REMOVED_HEADERS.include?(lower) || key_denylisted?(lower)) && !allowed.include?(lower)
                                 SCRUBBED
                               else
                                 value.is_a?(String) ? scrub_string(value) : value
                               end
            end
          end
          out["request"] = request
        end
        out
      end
    end
  end
end
