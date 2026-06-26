# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "refurb_radar"

class RefurbWatcherTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  BASE_URL = "https://www.apple.com/ca/shop/refurbished/mac"

  def test_cloudflare_access_allows_requests_when_unconfigured
    access = RefurbRadar::CloudflareAccess.new(env: {})

    assert access.valid_request?({})
  end

  def test_cloudflare_access_verifies_signed_access_jwt
    key = OpenSSL::PKey::RSA.new(2048)
    kid = "test-key"
    with_access_cert_cache(kid => access_certificate(key).to_pem) do
      env = {
        "CLOUDFLARE_ACCESS_TEAM_DOMAIN" => "team.cloudflareaccess.com",
        "CLOUDFLARE_ACCESS_AUD" => "test-audience"
      }
      access = RefurbRadar::CloudflareAccess.new(env: env)

      assert access.valid_request?(
        "cf-access-jwt-assertion" => [access_token(key: key, kid: kid, audience: "test-audience")]
      )
      refute access.valid_request?(
        "cf-access-jwt-assertion" => [access_token(key: key, kid: kid, audience: "wrong-audience")]
      )
    end
  end

  def test_cloudflare_access_denies_cleanly_when_cert_fetch_fails
    key = OpenSSL::PKey::RSA.new(2048)
    kid = "test-key"
    env = {
      "CLOUDFLARE_ACCESS_TEAM_DOMAIN" => "team.cloudflareaccess.com",
      "CLOUDFLARE_ACCESS_AUD" => "test-audience"
    }
    access = RefurbRadar::CloudflareAccess.new(env: env)
    access.define_singleton_method(:fetch_certs) { raise SocketError, "offline" }

    refute access.valid_request?(
      "cf-access-jwt-assertion" => [access_token(key: key, kid: kid, audience: "test-audience")]
    )
  end

  def test_cloudflare_access_does_not_cache_empty_cert_fetches
    key = OpenSSL::PKey::RSA.new(2048)
    kid = "test-key"
    env = {
      "CLOUDFLARE_ACCESS_TEAM_DOMAIN" => "team.cloudflareaccess.com",
      "CLOUDFLARE_ACCESS_AUD" => "test-audience"
    }
    access = RefurbRadar::CloudflareAccess.new(env: env)
    fetches = 0
    access.define_singleton_method(:fetch_certs) do
      fetches += 1
      {}
    end

    2.times do
      refute access.valid_request?(
        "cf-access-jwt-assertion" => [access_token(key: key, kid: kid, audience: "test-audience")]
      )
    end

    assert_equal 2, fetches
  end

  def test_extracts_grid_bootstrap_and_candidates
    parser = RefurbRadar::Parser.new
    grid = parser.grid_from_html(fixture("refurb_grid.html"))
    candidates = parser.candidates_from_grid(grid, BASE_URL)

    assert_equal 6, candidates.length
    assert_equal "GMINI48/A", candidates.first.part_number
    assert_equal "https://www.apple.com/ca/shop/product/gmini48/a/Refurbished-Mac-mini-M4-Pro", candidates.first.url
    assert_equal "2499.00", candidates.first.price
  end

  def test_extracts_grid_bootstrap_with_multibyte_content_quickly
    title = "Refurbished Mac mini Apple M4 Pro Chip with 14‑Core CPU and 20‑Core GPU"
    filler = "<p>Apple Studio Display 27‑inch 5K Retina</p>" * 2_000
    html = <<~HTML
      <html><head><title>Apple — Certified Refurbished</title></head><body>
      #{filler}
      <script>
      window.REFURB_GRID_BOOTSTRAP = {"tiles":[{"partNumber":"G1JV8LL/A","title":#{title.to_json},"productDetailsUrl":"/shop/product/g1jv8ll/a","filters":{"dimensions":{"refurbClearModel":"macmini","tsMemorySize":"48gb","dimensionCapacity":"1tb"}},"price":{"currentPrice":{"raw_amount":"2489.00"}}}]};
      </script>
      #{filler}
      </body></html>
    HTML

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    grid = RefurbRadar::Parser.new.grid_from_html(html)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal title, grid.fetch("tiles").first.fetch("title")
    assert_operator elapsed, :<, 1.0, "grid extraction should scan bytes, not multibyte chars (took #{elapsed.round(2)}s)"
  end

  def test_matches_target_model_memory_and_capacity
    candidates = parsed_candidates
    matcher = mac_desktop_matcher

    target_candidates = candidates.select { |candidate| matcher.target_model?(candidate) }
    eligible_candidates = candidates.select { |candidate| matcher.eligible?(candidate) }

    assert_equal %w[GMINI48/A GSTUDIO96/A GLOWMEM/A GBIGSSD/A GWEIRDMEM/A], target_candidates.map(&:part_number)
    assert_equal %w[GMINI48/A GSTUDIO96/A], eligible_candidates.map(&:part_number)
    assert_nil matcher.memory_gb("1_5tb")
    assert_equal 1536, matcher.capacity_gb("1point5tb")
  end

  def test_extra_models_can_temporarily_include_mac_pro
    candidate = RefurbRadar::Candidate.new(
      part_number: "GPRO64/A",
      title: "Refurbished Mac Pro Rack Apple M2 Ultra",
      url: "https://www.apple.com/ca/shop/product/GPRO64/A",
      model: "macpro",
      memory: "64gb",
      capacity: "1tb",
      price: "8159.00"
    )

    refute mac_desktop_matcher.target_model?(candidate)
    refute mac_desktop_matcher.eligible?(candidate)

    matcher = RefurbRadar::Matcher.new(
      rules: mac_desktop_matcher_rules,
      extra_models: "macpro"
    )

    assert matcher.target_model?(candidate)
    assert matcher.eligible?(candidate)
  end

def test_matcher_enforces_min_cpu_cores_including_nonbreaking_hyphen_titles
  matcher = RefurbRadar::Matcher.new(
    rules: [RefurbRadar::Matcher::Rule.new(models: %w[macmini], min_memory_gb: 64, max_capacity_gb: 2048, min_cpu_cores: 14)]
  )
  fourteen = candidate(part_number: "G14/A", model: "macmini", memory: "64gb", capacity: "1tb")
  fourteen.title = "Refurbished Mac mini Apple M4 Pro Chip with 14‑Core CPU and 20‑Core GPU"
  twelve = candidate(part_number: "G12/A", model: "macmini", memory: "64gb", capacity: "1tb")
  twelve.title = "Refurbished Mac mini Apple M4 Pro Chip with 12-Core CPU and 16-Core GPU"
  unstated = candidate(part_number: "G00/A", model: "macmini", memory: "64gb", capacity: "1tb")
  unstated.title = "Refurbished Mac mini"

  assert matcher.eligible?(fourteen), "non-breaking hyphen titles must parse"
  refute matcher.eligible?(twelve)
  refute matcher.eligible?(unstated), "a cores floor must not pass titles that hide the core count"
end

def test_matcher_uses_chip_family_when_high_end_title_hides_cpu_cores
  matcher = RefurbRadar::Matcher.new(
    rules: [RefurbRadar::Matcher::Rule.new(models: %w[macstudio], min_memory_gb: 64, max_capacity_gb: 4096, min_cpu_cores: 14)]
  )
  m3_ultra = candidate(part_number: "GSTUDIO96/A", model: "macstudio", memory: "96gb", capacity: "2tb")
  m3_ultra.title = "Refurbished Mac Studio Apple M3 Ultra chip with 96GB unified memory and 2TB SSD"
  m3_ultra.chip_family = "m3ultra"

  assert_equal 28, matcher.candidate_cpu_cores(m3_ultra)
  assert matcher.eligible?(m3_ultra)
  assert_empty matcher.shortfalls(m3_ultra, matcher.rules.first)
end

def test_rules_from_file_parses_min_cpu_cores
  Dir.mktmpdir do |dir|
    path = File.join(dir, "targets.json")
    File.write(path, JSON.generate(
      "rules" => [{ "models" => %w[macmini], "min_memory_gb" => 64, "max_memory_gb" => 128, "max_capacity_gb" => 2048, "min_cpu_cores" => 14 }]
    ))

    rules = RefurbRadar::Matcher.rules_from_file(path)

    assert_equal 14, rules.first.min_cpu_cores
    assert_equal 128, rules.first.max_memory_gb
  end
end

  def test_matcher_rule_without_memory_floor_matches_any_memory
    matcher = RefurbRadar::Matcher.new(
      rules: [RefurbRadar::Matcher::Rule.new(models: %w[macmini])]
    )

    assert matcher.eligible?(candidate(part_number: "G16/A", model: "macmini", memory: "16gb", capacity: "256gb"))
    refute matcher.eligible?(candidate(part_number: "GAIR/A", model: "macbookair", memory: "16gb", capacity: "256gb"))
  end

  def test_matcher_can_cap_memory_for_exact_ram_hunts
    matcher = RefurbRadar::Matcher.new(
      rules: [RefurbRadar::Matcher::Rule.new(models: %w[macbookpro], min_memory_gb: 24, max_memory_gb: 24)]
    )

    assert matcher.eligible?(candidate(part_number: "G24/A", model: "macbookpro", memory: "24gb", capacity: "512gb"))
    refute matcher.eligible?(candidate(part_number: "G16/A", model: "macbookpro", memory: "16gb", capacity: "512gb"))
    refute matcher.eligible?(candidate(part_number: "G32/A", model: "macbookpro", memory: "32gb", capacity: "512gb"))
  end

  def test_matcher_max_price_fails_closed_without_a_price
    matcher = RefurbRadar::Matcher.new(
      rules: [RefurbRadar::Matcher::Rule.new(models: %w[macmini], max_price: 2500)]
    )
    cheap = candidate(part_number: "G1/A", model: "macmini", memory: "16gb", capacity: "512gb")
    cheap.price = "2379.00"
    dear = candidate(part_number: "G2/A", model: "macmini", memory: "16gb", capacity: "512gb")
    dear.price = "2589.00"
    unpriced = candidate(part_number: "G3/A", model: "macmini", memory: "16gb", capacity: "512gb")

    assert matcher.eligible?(cheap)
    refute matcher.eligible?(dear)
    refute matcher.eligible?(unpriced), "a price cap must not pass candidates whose price is unknown"
  end

  def test_matcher_shortfalls_name_every_failed_constraint
    rule = RefurbRadar::Matcher::Rule.new(
      models: %w[macmini], min_memory_gb: 64, min_cpu_cores: 14, max_capacity_gb: 2048, max_price: 2000
    )
    matcher = RefurbRadar::Matcher.new(rules: [rule])
    miss = candidate(part_number: "G4/A", model: "macmini", memory: "48gb", capacity: "4tb")
    miss.title = "Refurbished Mac mini Apple M4 Pro Chip with 12-Core CPU"
    miss.price = "2799.00"
    near = candidate(part_number: "G5/A", model: "macmini", memory: "64gb", capacity: "1tb")
    near.title = "Refurbished Mac mini Apple M4 Pro Chip with 12-Core CPU"
    near.price = "1949.00"

    assert_equal %i[memory cores capacity price], matcher.shortfalls(miss, rule)
    assert_equal %i[cores], matcher.shortfalls(near, rule)
    assert_equal %i[model], matcher.shortfalls(candidate(part_number: "G6/A", model: "imac", memory: "64gb", capacity: "1tb"), rule)
  end

  def test_multi_model_rules_split_into_one_rule_per_model
    Dir.mktmpdir do |dir|
      path = File.join(dir, "targets.json")
      File.write(path, JSON.generate(
        "rules" => [{ "models" => %w[macmini macstudio], "min_memory_gb" => 64 }]
      ))

      rules = RefurbRadar::Matcher.rules_from_file(path)
      assert_equal [["macmini"], ["macstudio"]], rules.map(&:models)
      assert_equal [64, 64], rules.map(&:min_memory_gb)

      store = RefurbRadar::TargetsStore.new(path)
      assert_equal rules.map(&:models), store.rules.map { |rule| rule["models"] },
                   "the store and the matcher must agree on rule indexes"
      store.remove(0)
      assert_equal [{ "models" => ["macstudio"], "min_memory_gb" => 64 }], store.rules
    end
  end

  def test_matcher_matching_rule_returns_the_first_match_in_file_order
    loose = RefurbRadar::Matcher::Rule.new(models: %w[macmini])
    tight = RefurbRadar::Matcher::Rule.new(models: %w[macmini], min_memory_gb: 64)
    matcher = RefurbRadar::Matcher.new(rules: [tight, loose])
    small = candidate(part_number: "G7/A", model: "macmini", memory: "16gb", capacity: "256gb")
    big = candidate(part_number: "G8/A", model: "macmini", memory: "64gb", capacity: "1tb")

    assert_equal loose, matcher.matching_rule(small)
    assert_equal tight, matcher.matching_rule(big)
  end

  def test_confirms_buyable_pdp
    verdict = RefurbRadar::Buyability.new.confirm(fixture("live_pdp.html"))

    assert verdict.buyable?
    assert_includes verdict.positive_signals, "schema_in_stock"
    assert_includes verdict.positive_signals, "is_buyable_true"
    assert_includes verdict.positive_signals, "buy_button_enabled"
    assert_empty verdict.negative_signals
  end

  def test_rejects_out_of_stock_pdp
    verdict = RefurbRadar::Buyability.new.confirm(fixture("out_of_stock_pdp.html"))

    refute verdict.buyable?
    assert_includes verdict.negative_signals, "schema_out_of_stock"
    assert_includes verdict.negative_signals, "is_buyable_false"
    assert_includes verdict.negative_signals, "buy_button_disabled"
    assert_includes verdict.negative_signals, "commit_out_of_stock"
  end

  def test_detects_availability_signal_when_schema_conflicts_with_checkout_controls
    verdict = RefurbRadar::Buyability.new.confirm(availability_signal_pdp)

    refute verdict.buyable?
    assert verdict.availability_signal?
    refute verdict.ambiguous?
    assert_includes verdict.positive_signals, "schema_in_stock"
    assert_includes verdict.negative_signals, "is_buyable_false"
    assert_includes verdict.negative_signals, "buy_button_disabled"
    assert_includes verdict.negative_signals, "add_to_cart_disabled"
  end

  def test_parses_buyability_message_fixtures
    parser = RefurbRadar::BuyabilityMessages.new

    assert_equal(
      { "G1JV8LL/A" => false, "G1CD5LL/A" => false },
      parser.parse(fixture("buyability_all_false.json"))
    )
    assert_equal(
      { "G1JV8LL/A" => false, "G1CD5LL/A" => true },
      parser.parse(fixture("buyability_mixed.json"))
    )
    assert_equal(
      { "G1JV8LL/A" => true, "G1CD5LL/A" => true },
      parser.parse(fixture("buyability_all_true.json"))
    )
    assert_raises(RefurbRadar::ParseError) { parser.parse(fixture("buyability_malformed.json")) }
    refute parser.parse(fixture("buyability_mixed.json")).key?("G1MISSING/A")
  end

  def test_fast_check_uses_one_buyability_call_for_watch_candidates
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ "G1CD5LL/A" => true }])
    alerter = RecordingAlerter.new

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          fetcher: ExplodingFetcher.new,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: [candidate],
          include_grid: false,
          now: -> { Time.utc(2026, 6, 10, 10, 0, 0) }
        )

        result = check.run

        assert_equal [["G1CD5LL/A"]], buyability.calls
        assert_equal ["G1CD5LL/A"], result.confirmed_buyable.map(&:part_number)
        assert_equal ["buyable"], result.alerts.map { |alert| alert.alert_kind || "buyable" }
        assert_equal [%w[browser command twilio_sms]], alerter.calls.map { |call| call.fetch(:channels) }
      end
    end
  end

  def test_grid_listing_detection_alerts_once_and_merges_universe
    fetcher = SequencedFetcher.new(
      BASE_URL => [empty_grid_html, fixture("refurb_grid.html")]
    )
    watch_candidates = parsed_candidates.select { |item| mac_desktop_matcher.eligible?(item) }
    buyability = FakeBuyabilityClient.new([
      { "GMINI48/A" => false, "GSTUDIO96/A" => false },
      { "GMINI48/A" => false, "GSTUDIO96/A" => false }
    ])
    alerter = RecordingAlerter.new

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          grid_url: BASE_URL,
          fetcher: fetcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: watch_candidates,
          now: -> { now }
        )

        assert_empty check.run.alerts
        now += 10
        result = check.run

        assert_equal %w[GMINI48/A GSTUDIO96/A], result.alerts.map(&:part_number).sort
        assert_equal ["listing", "listing"], result.alerts.map(&:alert_kind).sort
        assert_equal [%w[twilio_sms], %w[twilio_sms]], alerter.calls.map { |call| call.fetch(:channels) }
        assert_equal %w[GMINI48/A GSTUDIO96/A], catalog_store.products.map { |product| product.fetch("part_number") }.sort
      end
    end
  end

  def test_listing_signal_does_not_realert_after_transient_grid_absence
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 10, 10, 0, 0)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )
      store.mark_alerted(state, first_alerts.first, alerted_at: now)
      state = save_and_reload(store, state)
      now += 10
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [],
        buyable_candidates: [],
        checked_at: now
      )
      state = save_and_reload(store, state)
      now += 10
      relisted_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )

      assert_equal ["listing"], first_alerts.map(&:alert_kind)
      assert_empty relisted_alerts
    end
  end

  def test_listing_signal_rearms_after_stable_grid_absence
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 10, 10, 0, 0)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )
      store.mark_alerted(state, first_alerts.first, alerted_at: now)
      state = save_and_reload(store, state)

      RefurbRadar::StateStore::LISTING_STABLE_ABSENT_PASSES.times do
        now += 10
        store.alertable_candidates(
          state: state,
          visible_candidates: [candidate],
          listed_candidates: [],
          buyable_candidates: [],
          checked_at: now
        )
        state = save_and_reload(store, state)
      end

      now += 10
      relisted_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )

      record = state.fetch("currently_seen").fetch(candidate.part_number)
      assert_equal ["listing"], first_alerts.map(&:alert_kind)
      assert_equal ["listing"], relisted_alerts.map(&:alert_kind)
      assert_equal "2026-06-10T10:03:30Z", record.fetch("first_positive_at")
      assert_equal "2026-06-10T10:03:30Z", record.fetch("first_grid_present_at")
      assert_equal "2026-06-10T10:03:20Z", record.fetch("last_not_listed_at")
    end
  end

  def test_first_surface_fields_record_grid_before_buyability
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 10, 10, 0, 0)

      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )
      state = save_and_reload(store, state)
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 10
      )

      record = state.fetch("currently_seen").fetch(candidate.part_number)
      assert_equal "grid", record.fetch("first_positive_source")
      assert_equal "2026-06-10T10:00:00Z", record.fetch("first_positive_at")
      assert_equal "2026-06-10T10:00:00Z", record.fetch("first_grid_present_at")
      assert_equal "2026-06-10T10:00:10Z", record.fetch("first_buyability_true_at")
    end
  end

  def test_first_surface_recomputes_when_grid_source_clears
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 10, 10, 0, 0)

      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )
      state = save_and_reload(store, state)
      now += 10
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      state = save_and_reload(store, state)

      RefurbRadar::StateStore::LISTING_STABLE_ABSENT_PASSES.times do
        now += 10
        store.alertable_candidates(
          state: state,
          visible_candidates: [candidate],
          listed_candidates: [],
          buyable_candidates: [candidate],
          checked_at: now
        )
        state = save_and_reload(store, state)
      end

      record = state.fetch("currently_seen").fetch(candidate.part_number)
      assert_equal "buyability", record.fetch("first_positive_source")
      assert_equal "2026-06-10T10:00:10Z", record.fetch("first_positive_at")
      assert_equal "2026-06-10T10:00:10Z", record.fetch("first_buyability_true_at")
      refute record.key?("first_grid_present_at")
    end
  end

  def test_first_surface_fields_record_buyability_without_delaying_sms
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 10, 10, 0, 0)

      alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )

      record = state.fetch("currently_seen").fetch(candidate.part_number)
      assert_equal [candidate], alerts
      assert_equal "buyability", record.fetch("first_positive_source")
      assert_equal "2026-06-10T10:00:00Z", record.fetch("first_positive_at")
      assert_equal "2026-06-10T10:00:00Z", record.fetch("first_buyability_true_at")
    end
  end

  def test_first_surface_recomputes_when_buyability_source_clears
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 10, 10, 0, 0)

      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      state = save_and_reload(store, state)
      now += 10
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        listed_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      state = save_and_reload(store, state)

      RefurbRadar::StateStore::AVAILABILITY_STABLE_PASSES.times do
        now += 10
        store.alertable_candidates(
          state: state,
          visible_candidates: [candidate],
          listed_candidates: [candidate],
          buyable_candidates: [],
          not_buyable_candidates: [candidate],
          checked_at: now
        )
        state = save_and_reload(store, state)
      end

      record = state.fetch("currently_seen").fetch(candidate.part_number)
      assert_equal "grid", record.fetch("first_positive_source")
      assert_equal "2026-06-10T10:00:10Z", record.fetch("first_positive_at")
      assert_equal "2026-06-10T10:00:10Z", record.fetch("first_grid_present_at")
      refute record.key?("first_buyability_true_at")
    end
  end

  def test_grid_catalog_merge_skips_seen_at_only_rewrites
    watch_candidates = parsed_candidates.select { |item| mac_desktop_matcher.eligible?(item) }
    fetcher = SequencedFetcher.new(
      BASE_URL => [fixture("refurb_grid.html"), fixture("refurb_grid.html")]
    )
    buyability = FakeBuyabilityClient.new([
      { "GMINI48/A" => false, "GSTUDIO96/A" => false },
      { "GMINI48/A" => false, "GSTUDIO96/A" => false }
    ])

    with_state_store do |store|
      Dir.mktmpdir do |dir|
        catalog_store = CountingCatalogStore.new(File.join(dir, "catalog.json"))
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          grid_url: BASE_URL,
          fetcher: fetcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: RecordingAlerter.new,
          watch_candidates: watch_candidates,
          now: -> { now }
        )

        check.run
        first_catalog = catalog_store.load
        now += 10
        check.run

        assert_equal 1, catalog_store.save_count
        assert_equal first_catalog, catalog_store.load
      end
    end
  end

  def test_grid_failure_preserves_listing_presence
    watch_candidates = parsed_candidates.select { |item| mac_desktop_matcher.eligible?(item) }
    fetcher = SequencedFetcher.new(
      BASE_URL => [
        fixture("refurb_grid.html"),
        RefurbRadar::FetchError.new("grid rejected"),
        fixture("refurb_grid.html")
      ]
    )
    buyability = FakeBuyabilityClient.new([
      { "GMINI48/A" => false, "GSTUDIO96/A" => false },
      { "GMINI48/A" => false, "GSTUDIO96/A" => false },
      { "GMINI48/A" => false, "GSTUDIO96/A" => false }
    ])
    alerter = RecordingAlerter.new

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          grid_url: BASE_URL,
          fetcher: fetcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: watch_candidates,
          now: -> { now }
        )

        assert_equal ["listing", "listing"], check.run.alerts.map(&:alert_kind).sort
        now += 10
        assert_empty check.run.alerts
        assert store.load.fetch("currently_seen").values.all? { |record| record["listed_present"] }
        now += 10
        assert_empty check.run.alerts
      end
    end
  end

  def test_buyability_confirmation_call_and_reminder_ladder
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([
      { "G1CD5LL/A" => true },
      { "G1CD5LL/A" => true },
      { "G1CD5LL/A" => true },
      { "G1CD5LL/A" => false },
      { "G1CD5LL/A" => true }
    ])
    alerter = RecordingAlerter.new

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: [candidate],
          include_grid: false,
          reminder_interval_seconds: 300,
          now: -> { now }
        )

        assert_equal ["buyable"], check.run.alerts.map { |alert| alert.alert_kind || "buyable" }
        now += 10
        assert_equal ["confirmed_buyable_call"], check.run.alerts.map(&:alert_kind)
        now += 300
        assert_equal ["reminder"], check.run.alerts.map(&:alert_kind)
        now += 10
        assert_empty check.run.alerts
        now += 10
        assert_empty check.run.alerts

        assert_equal [
          %w[browser command twilio_sms],
          %w[twilio_call],
          %w[twilio_sms]
        ], alerter.calls.map { |call| call.fetch(:channels) }
      end
    end
  end

  def test_buyability_confirmation_call_is_skipped_when_call_channel_is_unavailable
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([
      { "G1CD5LL/A" => true },
      { "G1CD5LL/A" => true }
    ])
    alerter = ChannelRecordingAlerter.new(%w[twilio_sms])

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: [candidate],
          include_grid: false,
          reminder_interval_seconds: 100_000,
          now: -> { now }
        )

        assert_equal ["buyable"], check.run.alerts.map { |alert| alert.alert_kind || "buyable" }
        now += 10
        assert_empty check.run.alerts
      end
    end
  end

  def test_no_matching_channel_does_not_block_later_browser_alert
    watch_candidates = parsed_candidates.select { |item| item.part_number == "GMINI48/A" }
    fetcher = SequencedFetcher.new(BASE_URL => [fixture("refurb_grid.html"), fixture("refurb_grid.html")])
    buyability = FakeBuyabilityClient.new([
      { "GMINI48/A" => false },
      { "GMINI48/A" => true }
    ])
    alerter = RefurbRadar::Alerter.new(
      channels: [RefurbRadar::BrowserAlert.new(open_command: "/usr/bin/true", err: StringIO.new)],
      err: StringIO.new
    )

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          grid_url: BASE_URL,
          fetcher: fetcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: watch_candidates,
          now: -> { now }
        )

        listing_result = check.run
        assert_includes listing_result.alerts.map(&:part_number), "GMINI48/A"
        assert listing_result.alerts.all? { |alert| alert.alert_kind == "listing" }
        record = store.load.fetch("currently_seen").fetch("GMINI48/A")
        refute record.key?("next_alert_attempt_at")

        now += 10
        result = check.run
        record = store.load.fetch("currently_seen").fetch("GMINI48/A")

        assert_equal ["GMINI48/A"], result.alerts.map(&:part_number)
        assert record["buyable_alerted_at"]
        refute record.key?("next_alert_attempt_at")
      end
    end
  end

  # The local Mac agent's browser tab is persistent, unlike a phone ring:
  # one open per buyable episode. Confirming passes and call re-rings must
  # never reopen the page under the buyer's hands.
  def test_browser_opens_once_per_buyable_episode
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ "G1CD5LL/A" => true }])
    alerter = RefurbRadar::Alerter.new(
      channels: [RefurbRadar::BrowserAlert.new(open_command: "/usr/bin/true", err: StringIO.new)],
      err: StringIO.new
    )

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: [candidate],
          include_grid: false,
          reminder_interval_seconds: 100_000,
          call_interval_seconds: 120,
          now: -> { now }
        )

        assert_equal ["buyable"], check.run.alerts.map { |alert| alert.alert_kind || "buyable" }
        now += 10
        check.run
        now += 130
        check.run

        record = store.load.fetch("currently_seen").fetch("G1CD5LL/A")
        assert record["buyable_alerted_at"]
        assert_equal ["browser"], record.fetch("alert_attempts").map { |attempt| attempt.fetch("channel") },
                     "confirm and re-ring passes must not reopen the browser"
      end
    end
  end

  def test_buyable_call_rerings_on_cadence_while_still_buyable
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ "G1CD5LL/A" => true }])
    alerter = RecordingAlerter.new

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: [candidate],
          include_grid: false,
          reminder_interval_seconds: 100_000,
          call_interval_seconds: 120,
          now: -> { now }
        )

        assert_equal ["buyable"], check.run.alerts.map { |alert| alert.alert_kind || "buyable" }
        now += 10
        assert_equal ["confirmed_buyable_call"], check.run.alerts.map(&:alert_kind)
        now += 60
        assert_empty check.run.alerts
        now += 70
        assert_equal ["confirmed_buyable_call"], check.run.alerts.map(&:alert_kind)
      end
    end
  end

  def test_control_store_pause_and_resume_round_trip
    with_control_store do |controls|
      assert_empty controls.muted_channels
      controls.pause("twilio_call", paused_until: :indefinite)
      assert_equal ["twilio_call"], controls.muted_channels
      controls.resume("twilio_call")
      assert_empty controls.muted_channels
    end
  end

  def test_control_store_auto_resumes_after_paused_until
    now = Time.utc(2026, 6, 10, 12, 0, 0)
    with_control_store(now: -> { now }) do |controls|
      controls.pause("twilio_sms", paused_until: now + 60)
      assert_equal ["twilio_sms"], controls.muted_channels
      now += 61
      assert_empty controls.muted_channels, "pause must auto-resume once paused_until passes"
    end
  end

  def test_control_store_fails_open_on_missing_and_corrupt_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "controls.json")
      store = RefurbRadar::ControlStore.new(path)
      assert_empty store.muted_channels
      File.write(path, "{ not valid json")
      assert_empty store.muted_channels, "a corrupt control file must never silently mute alerts"
    end
  end

  def test_control_store_rejects_unknown_channel
    with_control_store do |controls|
      assert_raises(ArgumentError) { controls.pause("email", paused_until: :indefinite) }
    end
  end

  def test_targets_store_add_update_remove_round_trip
    Dir.mktmpdir do |dir|
      store = RefurbRadar::TargetsStore.new(File.join(dir, "targets.json"))

      store.add("macbookpro")
      assert_equal [{ "models" => ["macbookpro"] }], store.rules

      store.update(0, "min_memory_gb" => "64", "max_memory_gb" => "128", "min_cpu_cores" => nil, "max_capacity_gb" => "2048", "max_price" => "4000")
      assert_equal(
        [{ "models" => ["macbookpro"], "min_memory_gb" => 64, "max_memory_gb" => 128, "max_capacity_gb" => 2048, "max_price" => 4000 }],
        store.rules
      )

      store.update(0, "min_memory_gb" => "64", "max_memory_gb" => nil, "min_cpu_cores" => nil, "max_capacity_gb" => nil, "max_price" => nil)
      assert_equal [{ "models" => ["macbookpro"], "min_memory_gb" => 64 }], store.rules,
                   "blank constraints must clear, not linger"

      store.add("imac")
      store.remove(0)
      assert_equal [{ "models" => ["imac"] }], store.rules
    end
  end

  def test_targets_store_rejects_bad_input_without_corrupting_the_file
    Dir.mktmpdir do |dir|
      store = RefurbRadar::TargetsStore.new(File.join(dir, "targets.json"))
      store.add("macmini")

      assert_raises(ArgumentError) { store.add("") }
      assert_raises(ArgumentError) { store.remove(5) }
      assert_raises(ArgumentError) { store.remove(-1) }
      assert_raises(ArgumentError) { store.update(0, "min_memory_gb" => "lots") }
      assert_equal [{ "models" => ["macmini"] }], store.rules
    end
  end

  # The load-bearing pause guarantee: muting SMS must not mute the phone call.
  # In production the buyable alert's only live channel is SMS, and the call
  # gates on the buyable alert being marked sent, so a paused-SMS buyable alert
  # must still advance the ladder via a synthetic paused receipt.
  def test_pausing_sms_still_fires_the_confirmed_call
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ "G1CD5LL/A" => true }])
    alerter = ChannelRecordingAlerter.new(%w[twilio_sms twilio_call])

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        with_control_store do |controls|
          controls.pause("twilio_sms", paused_until: :indefinite)
          now = Time.utc(2026, 6, 10, 10, 0, 0)
          check = RefurbRadar::Check.new(
            matcher: mac_desktop_matcher,
            buyability_client: buyability,
            state_store: store,
            catalog_store: catalog_store,
            control_store: controls,
            event_log: RefurbRadar::NullEventLog.new,
            alerter: alerter,
            watch_candidates: [candidate],
            include_grid: false,
            reminder_interval_seconds: 100_000,
            call_interval_seconds: 120,
            now: -> { now }
          )

          check.run
          assert_empty alerter.calls, "SMS is paused so nothing dispatches on the buyable pass"
          record = store.load.fetch("currently_seen").fetch("G1CD5LL/A")
          assert record["buyable_alerted_at"], "buyable ladder must advance even when SMS is paused"
          assert_equal ["paused"], record.fetch("alert_attempts").map { |attempt| attempt.fetch("channel") }

          now += 10
          check.run
          assert_equal [%w[twilio_call]], alerter.calls.map { |call| call[:channels] }
          assert store.load.fetch("currently_seen").fetch("G1CD5LL/A")["confirmed_buyable_call_alerted_at"]
        end
      end
    end
  end

  def test_failed_buyable_sms_still_fires_the_confirmed_call
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ "G1CD5LL/A" => true }])
    alerter = FailingSmsRecordingAlerter.new

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        now = Time.utc(2026, 6, 10, 10, 0, 0)
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: alerter,
          watch_candidates: [candidate],
          include_grid: false,
          reminder_interval_seconds: 100_000,
          call_interval_seconds: 120,
          now: -> { now }
        )

        assert_equal ["buyable"], check.run.alerts.map { |alert| alert.alert_kind || "buyable" }
        record = store.load.fetch("currently_seen").fetch("G1CD5LL/A")
        assert record["buyable_alerted_at"], "failed SMS must not block call escalation"
        refute record.key?("alerted_at")
        refute record.key?("next_alert_attempt_at")
        assert_equal [false], record.fetch("alert_attempts").map { |attempt| attempt.fetch("success") }

        now += 10
        assert_equal ["confirmed_buyable_call"], check.run.alerts.map(&:alert_kind)
        assert_equal [%w[twilio_sms], %w[twilio_call]], alerter.calls.map { |call| call.fetch(:channels) }
      end
    end
  end

  def test_paused_call_refires_on_resume_while_still_buyable
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ "G1CD5LL/A" => true }])
    alerter = ChannelRecordingAlerter.new(%w[twilio_sms twilio_call])

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        with_control_store do |controls|
          now = Time.utc(2026, 6, 10, 10, 0, 0)
          check = RefurbRadar::Check.new(
            matcher: mac_desktop_matcher,
            buyability_client: buyability,
            state_store: store,
            catalog_store: catalog_store,
            control_store: controls,
            event_log: RefurbRadar::NullEventLog.new,
            alerter: alerter,
            watch_candidates: [candidate],
            include_grid: false,
            reminder_interval_seconds: 100_000,
            call_interval_seconds: 120,
            now: -> { now }
          )

          check.run
          assert_equal [%w[twilio_sms]], alerter.calls.map { |call| call[:channels] }

          controls.pause("twilio_call", paused_until: :indefinite)
          now += 10
          check.run
          record = store.load.fetch("currently_seen").fetch("G1CD5LL/A")
          refute record["confirmed_buyable_call_alerted_at"], "a paused call must not be marked sent"
          assert_equal [%w[twilio_sms]], alerter.calls.map { |call| call[:channels] }, "no call dispatched while paused"

          controls.resume("twilio_call")
          now += 10
          check.run
          assert_includes alerter.calls.map { |call| call[:channels] }, %w[twilio_call]
          assert store.load.fetch("currently_seen").fetch("G1CD5LL/A")["confirmed_buyable_call_alerted_at"]
        end
      end
    end
  end

  def test_parses_candidate_from_direct_pdp
    candidate = RefurbRadar::Parser.new.candidate_from_pdp(
      fixture("direct_live_pdp.html"),
      "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    )

    assert_equal "G1CD5LL/A", candidate.part_number
    assert_equal "macstudio", candidate.model
    assert_equal "64gb", candidate.memory
    assert_equal "1tb", candidate.capacity
    assert_equal "2499.00", candidate.price
  end

  def test_parses_mac_pro_from_direct_pdp
    candidate = RefurbRadar::Parser.new.candidate_from_pdp(
      <<~HTML,
        <script type="application/ld+json">
          {
            "@type": "Product",
            "sku": "GPRO64/A",
            "name": "Refurbished Mac Pro Rack Apple M2 Ultra with 24-core CPU and 60-core GPU",
            "description": "64GB unified memory and 1TB SSD",
            "offers": { "price": "8159.00" }
          }
        </script>
      HTML
      "https://www.apple.com/ca/shop/product/GPRO64/A"
    )

    assert_equal "GPRO64/A", candidate.part_number
    assert_equal "macpro", candidate.model
    assert_equal "64gb", candidate.memory
    assert_equal "1tb", candidate.capacity
  end

  def test_parses_vision_pro_from_direct_pdp_without_memory
    candidate = RefurbRadar::Parser.new.candidate_from_pdp(
      <<~HTML,
        <script type="application/ld+json">
          {
            "@type": "Product",
            "sku": "FVISION256/A",
            "name": "Refurbished Apple Vision Pro",
            "description": "256GB storage",
            "offers": { "price": "4249.00" }
          }
        </script>
      HTML
      "https://www.apple.com/ca/shop/product/FVISION256/A"
    )

    assert_equal "FVISION256/A", candidate.part_number
    assert_equal "visionpro", candidate.model
    assert_nil candidate.memory
    assert_equal "256gb", candidate.capacity
    assert_equal "4249.00", candidate.price
  end

  def test_parses_vision_pro_grid_tile_without_memory
    grid = {
      "tiles" => [
        {
          "partNumber" => "FVISION512/A",
          "title" => "Refurbished Apple Vision Pro 512GB",
          "productDetailsUrl" => "/ca/shop/product/FVISION512/A/refurbished-apple-vision-pro-512gb",
          "filters" => { "dimensions" => { "dimensionCapacity" => "512gb" } },
          "price" => { "currentPrice" => { "raw_amount" => "4599.00" } }
        }
      ]
    }

    candidate = RefurbRadar::Parser.new.candidates_from_grid(grid, BASE_URL).first

    assert_equal "FVISION512/A", candidate.part_number
    assert_equal "visionpro", candidate.model
    assert_nil candidate.memory
    assert_equal "512gb", candidate.capacity
  end

  def test_parses_catalog_candidates_from_pdp_variants
    candidates = RefurbRadar::Parser.new.catalog_candidates_from_pdp(
      fixture("direct_catalog_pdp.html"),
      "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    )
    by_part = candidates.to_h { |candidate| [candidate.part_number, candidate] }

    assert_equal %w[G1CD4LL/A G1CD5LL/A G1CD9LL/A G1CDELL/A G1LOWLL/A], by_part.keys.sort
    assert_equal "48gb", by_part.fetch("G1CD4LL/A").memory
    assert_equal "1tb", by_part.fetch("G1CD4LL/A").capacity
    assert_equal "3179.00", by_part.fetch("G1CD4LL/A").price
    assert_equal "4tb", by_part.fetch("G1CDELL/A").capacity
  end

  def test_loads_direct_watch_urls_from_file_and_environment
    Dir.mktmpdir do |dir|
      path = File.join(dir, "watch_urls.txt")
      File.write(path, "# comment\nhttps://example.com/file\n")
      catalog_path = File.join(dir, "catalog.json")
      RefurbRadar::CatalogStore.new(catalog_path).save(
        "updated_at" => "2026-06-09T16:48:05Z",
        "products" => [
          {
            "part_number" => "G1CD5LL/A",
            "url" => "https://www.apple.com/ca/shop/product/G1CD5LL/A",
            "model" => "macstudio",
            "memory" => "64gb",
            "capacity" => "1tb"
          }
        ]
      )

      urls = RefurbRadar::Config.watch_urls(
        env: { "REFURB_RADAR_WATCH_URLS" => "https://example.com/env, https://example.com/file" },
        matcher: mac_desktop_matcher,
        path: path,
        catalog_path: catalog_path,
        seed_path: File.join(dir, "missing-seed.json")
      )

      assert_equal [
        "https://example.com/env",
        "https://example.com/file",
        "https://www.apple.com/ca/shop/product/G1CD5LL/A"
      ], urls
    end
  end

  def test_catalog_watch_urls_replace_seed_url_for_same_part_number
    Dir.mktmpdir do |dir|
      path = File.join(dir, "watch_urls.txt")
      seed_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
      catalog_url = "https://www.apple.com/ca/shop/product/G1CD5LL/A"
      File.write(path, "#{seed_url}\n")
      catalog_path = File.join(dir, "catalog.json")
      RefurbRadar::CatalogStore.new(catalog_path).save(
        "updated_at" => "2026-06-09T16:48:05Z",
        "products" => [
          {
            "part_number" => "G1CD5LL/A",
            "url" => catalog_url,
            "model" => "macstudio",
            "memory" => "64gb",
            "capacity" => "1tb"
          }
        ]
      )

      urls = RefurbRadar::Config.watch_urls(
        env: {},
        matcher: mac_desktop_matcher,
        path: path,
        catalog_path: catalog_path,
        seed_path: File.join(dir, "missing-seed.json")
      )

      assert_equal [catalog_url], urls
    end
  end

  def test_retired_catalog_products_are_not_active_watch_candidates
    Dir.mktmpdir do |dir|
      catalog_path = File.join(dir, "catalog.json")
      RefurbRadar::CatalogStore.new(catalog_path).save(
        "updated_at" => "2026-06-16T14:00:00Z",
        "products" => [
          {
            "part_number" => "GACTIVE/A",
            "url" => "https://www.apple.com/ca/shop/product/GACTIVE/A",
            "model" => "macstudio",
            "memory" => "64gb",
            "capacity" => "1tb"
          },
          {
            "part_number" => "GRETIRED/A",
            "url" => "https://www.apple.com/ca/shop/product/GRETIRED/A",
            "model" => "macstudio",
            "memory" => "64gb",
            "capacity" => "1tb",
            "retired_at" => "2026-06-16T14:00:00Z",
            "retired_reason" => "missing_buyability_flag"
          }
        ]
      )

      candidates = RefurbRadar::Config.watch_candidates(
        matcher: mac_desktop_matcher,
        catalog_path: catalog_path,
        seed_path: File.join(dir, "missing-seed.json")
      )

      assert_equal ["GACTIVE/A"], candidates.map(&:part_number)
    end
  end

  def test_seed_catalog_replaces_manual_seed_url_for_same_part_number
    Dir.mktmpdir do |dir|
      path = File.join(dir, "watch_urls.txt")
      seed_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
      File.write(path, "#{seed_url}\n")

      urls = RefurbRadar::Config.watch_urls(
        env: {},
        matcher: mac_desktop_matcher,
        path: path,
        catalog_path: File.join(dir, "missing-catalog.json")
      )

      assert_equal 1, urls.count { |url| url.include?("G1CD5LL/A") || url.include?("g1cd5ll/a") }
      assert_includes urls, "https://www.apple.com/ca/shop/product/G1CD5LL/A"
      refute_includes urls, seed_url
    end
  end

  def test_seed_universe_feeds_watch_urls_from_cold_start
    Dir.mktmpdir do |dir|
      urls = RefurbRadar::Config.watch_urls(
        env: {},
        matcher: mac_desktop_matcher,
        path: File.join(dir, "missing-watch-urls.txt"),
        catalog_path: File.join(dir, "missing-catalog.json")
      )

      assert_includes urls, "https://www.apple.com/ca/shop/product/G1CD5LL/A"
      assert_includes urls, "https://www.apple.com/ca/shop/product/G1JV3LL/A"
      refute_includes urls, "https://www.apple.com/ca/shop/product/G1CDELL/A"
    end
  end

  def test_watch_urls_filter_stale_catalog_entries_by_current_targets
    Dir.mktmpdir do |dir|
      catalog_path = File.join(dir, "catalog.json")
      RefurbRadar::CatalogStore.new(catalog_path).save(
        "updated_at" => "2026-06-09T16:48:05Z",
        "products" => [
          {
            "part_number" => "G1720LL/A",
            "url" => "https://www.apple.com/ca/shop/product/G1720LL/A",
            "model" => "macpro",
            "memory" => "64gb",
            "capacity" => "1tb"
          }
        ]
      )

      urls = RefurbRadar::Config.watch_urls(
        env: {},
        matcher: mac_desktop_matcher,
        path: File.join(dir, "missing-watch-urls.txt"),
        catalog_path: catalog_path,
        seed_path: File.join(dir, "missing-seed.json")
      )

      assert_empty urls
    end
  end

  def test_target_rules_load_from_config_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "targets.json")
      File.write(
        path,
        JSON.generate(
          "rules" => [
            { "models" => ["macmini"], "min_memory_gb" => 64, "max_capacity_gb" => 1024 }
          ]
        )
      )
      matcher = RefurbRadar::Matcher.from_env(env: {}, path: path)

      assert matcher.eligible?(candidate(part_number: "A", model: "macmini", memory: "64gb", capacity: "1tb"))
      refute matcher.eligible?(candidate(part_number: "B", model: "macmini", memory: "48gb", capacity: "1tb"))
      refute matcher.eligible?(candidate(part_number: "C", model: "macstudio", memory: "64gb", capacity: "1tb"))
    end
  end

  def test_target_rules_can_filter_screen_size_and_chip_family
    Dir.mktmpdir do |dir|
      path = File.join(dir, "targets.json")
      File.write(
        path,
        JSON.generate(
          "rules" => [
            { "models" => ["macbookair"], "screen_size_inches" => "13", "chip_family" => "M4", "min_memory_gb" => 24 }
          ]
        )
      )
      matcher = RefurbRadar::Matcher.from_env(env: {}, path: path)
      thirteen = candidate(part_number: "AIR13/A", model: "macbookair", memory: "24gb", capacity: "512gb")
      thirteen.screen_size_inches = "13"
      thirteen.chip_family = "m4"
      fifteen = candidate(part_number: "AIR15/A", model: "macbookair", memory: "24gb", capacity: "512gb")
      fifteen.screen_size_inches = 15
      fifteen.chip_family = "m4"
      old_chip = candidate(part_number: "AIR13M3/A", model: "macbookair", memory: "24gb", capacity: "512gb")
      old_chip.screen_size_inches = 13
      old_chip.chip_family = "m3"

      assert matcher.eligible?(thirteen)
      refute matcher.eligible?(fifteen)
      refute matcher.eligible?(old_chip)
      assert_equal %i[screen_size], matcher.shortfalls(fifteen, matcher.rules.first)
      assert_equal %i[chip], matcher.shortfalls(old_chip, matcher.rules.first)
    end
  end

  def test_product_matrix_keeps_historical_choices_separate_by_chip
    matrix = RefurbRadar::ProductMatrix.default
    studio = matrix.choices(models: ["macstudio"])
    m4_max = matrix.choices(models: ["macstudio"], chip_family: "m4max")
    m3_ultra = matrix.choices(models: ["macstudio"], chip_family: "m3ultra")

    assert_includes studio[:memory], 96
    assert_includes studio[:memory], 512
    assert_includes studio[:chip], "m3ultra"
    assert_includes m4_max[:memory], 128
    refute_includes m4_max[:memory], 96
    assert_equal [96, 256, 512], m3_ultra[:memory]
    assert_equal [28, 32], m3_ultra[:cores]
  end

  def test_refresh_catalog_discovers_eligible_variant_urls
    seed_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    fetcher = FakeFetcher.new(
      BASE_URL => fixture("refurb_grid.html"),
      seed_url => fixture("direct_catalog_pdp.html")
    )

    with_catalog_store do |store|
      refresh = RefurbRadar::CatalogRefresh.new(
        grid_url: BASE_URL,
        seed_urls: [seed_url],
        fetcher: fetcher,
        store: store,
        now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
      )

      result = refresh.run
      products = store.load.fetch("products")
      by_part = products.to_h { |product| [product.fetch("part_number"), product] }

      assert_equal 11, result.discovered_candidates.length
      assert_includes by_part.keys, "G1CD4LL/A"
      assert_includes by_part.keys, "G1CD5LL/A"
      assert_includes by_part.keys, "G1CD9LL/A"
      assert_includes by_part.keys, "G1CDELL/A"
      assert_includes by_part.keys, "G1LOWLL/A"
      assert_equal "https://www.apple.com/ca/shop/product/G1CD5LL/A", by_part.fetch("G1CD5LL/A").fetch("url")
      assert_equal "2026-06-09T16:48:05Z", by_part.fetch("G1CD5LL/A").fetch("first_discovered_at")
      assert_empty result.warnings
    end
  end

  def test_state_dedupes_continuously_buyable_sku
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, candidate, alerted_at: now)
      second_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 30
      )

      assert_equal [candidate], first_alerts
      assert_empty second_alerts
    end
  end

  def test_state_realerts_when_visible_sku_becomes_buyable
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now
      )
      second_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 30
      )

      assert_empty first_alerts
      assert_equal [candidate], second_alerts
    end
  end

  def test_state_realerts_after_disappearance_and_return
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, candidate, alerted_at: now)
      store.alertable_candidates(
        state: state,
        visible_candidates: [],
        buyable_candidates: [],
        checked_at: now + 30
      )
      second_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 60
      )

      assert_equal [candidate], first_alerts
      assert_equal [candidate], second_alerts
      assert_equal 1, state.fetch("history").length
    end
  end

  def test_state_does_not_mark_alerted_until_alert_succeeds
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      second_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 30
      )

      assert_equal [candidate], first_alerts
      assert_equal [candidate], second_alerts
    end
  end

  def test_state_records_check_and_alert_stats
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now,
        check_summary: {
          "total_tiles" => 6,
          "target_tiles" => 5,
          "eligible_target_tiles" => 2,
          "confirmed_buyable" => 1,
          "warnings" => 0
        }
      )
      store.mark_alerted(state, candidate, alerted_at: now)

      assert_equal 1, state.fetch("stats").fetch("successful_checks")
      assert_equal 1, state.fetch("stats").fetch("total_alerts")
      assert_equal 6, state.fetch("stats").fetch("last_check").fetch("total_tiles")
      assert_equal "2026-06-09T16:48:05Z", state.fetch("stats").fetch("last_alerted_at")
    end
  end

  def test_state_preserves_alerted_window_after_transient_unconfirmed_check
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, candidate, alerted_at: now)
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        checked_at: now + 30
      )
      second_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 60
      )

      assert_equal [candidate], first_alerts
      assert_empty second_alerts
    end
  end

  def test_state_keeps_alerted_window_until_verified_not_buyable_is_stable
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, candidate, alerted_at: now)
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        not_buyable_candidates: [candidate],
        checked_at: now + 30
      )
      assert_equal "2026-06-09T16:48:35Z", state.fetch("currently_seen").fetch(candidate.part_number).fetch("last_not_buyable_at")

      transient_return_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now + 60
      )
      now = build_not_buyable_streak(store, state, candidate, from: now + 90)
      stable_return_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )

      assert_equal [candidate], first_alerts
      assert_empty transient_return_alerts
      assert_equal [candidate], stable_return_alerts
      refute state.fetch("currently_seen").fetch(candidate.part_number).key?("last_not_buyable_at")
    end
  end

  def test_availability_signal_alerts_only_after_stable_not_buyable_baseline
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      cold_start_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        availability_signal_candidates: [candidate],
        checked_at: now
      )
      now = build_not_buyable_streak(store, state, candidate, from: now)
      edge_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        availability_signal_candidates: [candidate],
        checked_at: now
      )

      assert_empty cold_start_alerts
      assert_equal ["availability_signal"], edge_alerts.map(&:alert_kind)
      assert_equal ["GMINI48/A"], edge_alerts.map(&:part_number)
    end
  end

  def test_availability_signal_flapping_never_rebuilds_stable_baseline
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)
      alerts = []

      # schema_in_stock flapping every few passes, as observed in production:
      # short not-buyable streaks must never count as a stable baseline.
      12.times do
        5.times do
          alerts.concat(store.alertable_candidates(
            state: state,
            visible_candidates: [candidate],
            buyable_candidates: [],
            not_buyable_candidates: [candidate],
            checked_at: now
          ))
          now += 30
        end
        alerts.concat(store.alertable_candidates(
          state: state,
          visible_candidates: [candidate],
          buyable_candidates: [],
          availability_signal_candidates: [candidate],
          checked_at: now
        ))
        now += 30
      end

      assert_empty alerts
    end
  end

  def test_availability_signal_cooldown_blocks_repeat_then_allows_after_expiry
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      now = build_not_buyable_streak(store, state, candidate, from: now)
      first_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        availability_signal_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, first_alerts.first, alerted_at: now)

      now = build_not_buyable_streak(store, state, candidate, from: now + 30)
      within_cooldown_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        availability_signal_candidates: [candidate],
        checked_at: now
      )

      now += RefurbRadar::StateStore::AVAILABILITY_COOLDOWN_SECONDS
      now = build_not_buyable_streak(store, state, candidate, from: now)
      after_cooldown_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        availability_signal_candidates: [candidate],
        checked_at: now
      )

      assert_equal ["availability_signal"], first_alerts.map(&:alert_kind)
      assert_empty within_cooldown_alerts
      assert_equal ["availability_signal"], after_cooldown_alerts.map(&:alert_kind)
    end
  end

  def test_buyable_alert_fires_immediately_and_escalates_past_availability_sms
    with_state_store do |store|
      state = store.load
      candidate = parsed_candidates.first
      now = Time.utc(2026, 6, 9, 16, 48, 5)

      now = build_not_buyable_streak(store, state, candidate, from: now)
      signal_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        availability_signal_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, signal_alerts.first, alerted_at: now)
      buyable_alerts = store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        availability_signal_candidates: [],
        checked_at: now + 30
      )

      assert_equal ["availability_signal"], signal_alerts.map(&:alert_kind)
      assert_equal ["GMINI48/A"], buyable_alerts.map(&:part_number)
      assert_nil buyable_alerts.first.alert_kind
    end
  end

  def test_check_summary_with_fake_fetcher
    fetcher = FakeFetcher.new(
      BASE_URL => fixture("refurb_grid.html"),
      "https://www.apple.com/ca/shop/product/gmini48/a/Refurbished-Mac-mini-M4-Pro" => fixture("live_pdp.html"),
      "https://www.apple.com/ca/shop/product/gstudio96/a/Refurbished-Mac-Studio" => fixture("out_of_stock_pdp.html")
    )
    alerter = FakeAlerter.new

    with_state_store do |store|
      check = RefurbRadar::Check.new(
        grid_url: BASE_URL,
        fetcher: fetcher,
        matcher: mac_desktop_matcher,
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: alerter,
        now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
      )

      result = check.run

      assert_equal 6, result.total_tiles
      assert_equal 5, result.target_tiles
      assert_equal 2, result.eligible_target_tiles
      assert_equal ["GMINI48/A"], result.confirmed_buyable.map(&:part_number)
      assert_equal ["GMINI48/A"], result.alerts.map(&:part_number)
      assert_equal ["GMINI48/A"], alerter.alerted.map(&:part_number)
      assert_equal 0, result.unconfirmed_candidates.length
    end
  end

  def test_alerter_succeeds_when_any_channel_succeeds
    err = StringIO.new
    candidate = parsed_candidates.first
    alerter = RefurbRadar::Alerter.new(
      channels: [FakeAlertChannel.new(false), FakeAlertChannel.new(true)],
      err: err
    )

    assert alerter.alert(candidate)
    assert_empty err.string
  end

  def test_alerter_reports_no_configured_channels
    err = StringIO.new
    candidate = parsed_candidates.first
    alerter = RefurbRadar::Alerter.new(channels: [], err: err)

    refute alerter.alert(candidate)
    assert_includes err.string, "warning=no_alert_channels_configured"
  end

  def test_alerter_reports_configured_channel_keys
    env = {
      "TWILIO_ACCOUNT_SID" => "AC123",
      "TWILIO_AUTH_TOKEN" => "secret",
      "TWILIO_FROM_NUMBER" => "+15555550100",
      "REFURB_RADAR_ALERT_TO" => "+15555550123",
      "REFURB_RADAR_TWILIO_SMS" => "1",
      "REFURB_RADAR_TWILIO_CALL" => "0"
    }
    alerter = RefurbRadar::Alerter.from_env(env: env, err: StringIO.new)

    assert alerter.alerts_channel?("twilio_sms")
    refute alerter.alerts_channel?("twilio_call")
  end

  def test_twilio_sms_alert_sends_single_segment_message_with_canonical_url
    client = FakeTwilioClient.new
    err = StringIO.new
    candidate = parsed_candidates.first
    candidate.title = "Refurbished Mac mini Apple M4 Pro Chip with 14‑Core CPU and 20‑Core GPU, 10Gb Ethernet"
    alert = RefurbRadar::TwilioSmsAlert.new(client: client, to: "+15555550123", err: err)

    assert alert.alert(candidate)
    body = client.sms_requests.first.fetch(:body)
    assert_equal "+15555550123", client.sms_requests.first.fetch(:to)
    assert_includes body, candidate.part_number
    assert_includes body, "https://www.apple.com/ca/shop/product/#{candidate.part_number}"
    assert body.ascii_only?, "SMS body must stay GSM-7 friendly, got #{body.inspect}"
    assert_operator body.length, :<=, 140, "SMS body must fit one segment with trial watermark headroom"
    assert_includes err.string, "twilio_sms_sent sid=SM123"
  end

  def test_twilio_sms_alert_labels_availability_signal
    client = FakeTwilioClient.new
    candidate = parsed_candidates.first
    candidate.alert_kind = "availability_signal"
    alert = RefurbRadar::TwilioSmsAlert.new(client: client, to: "+15555550123", err: StringIO.new)

    assert alert.alert(candidate)
    assert_includes client.sms_requests.first.fetch(:body), "Apple refurb availability signal:"
  end

  def test_twilio_call_alert_sends_inline_twiml
    client = FakeTwilioClient.new
    err = StringIO.new
    candidate = parsed_candidates.first
    alert = RefurbRadar::TwilioCallAlert.new(client: client, to: "+15555550123", err: err)

    assert alert.alert(candidate)
    assert_equal "+15555550123", client.call_requests.first.fetch(:to)
    assert_includes client.call_requests.first.fetch(:twiml), "Apple refurbished alert"
    assert_includes err.string, "twilio_call_started sid=CA123"
  end

  def test_twilio_call_alert_ignores_old_call_threshold
    client = FakeTwilioClient.new
    candidate = RefurbRadar::Candidate.new(
      part_number: "G1JV8LL/A",
      title: "Refurbished Mac mini Apple M4 Pro Chip with 12-Core CPU and 16-Core GPU",
      url: "https://www.apple.com/ca/shop/product/G1JV8LL/A",
      model: "macmini",
      memory: "64gb",
      capacity: "1tb"
    )
    criteria = RefurbRadar::TwilioCallCriteria.new(
      models: "macmini,macstudio",
      min_memory_gb: 64,
      min_cpu_cores: 14,
      max_capacity_gb: 2048
    )
    alert = RefurbRadar::TwilioCallAlert.new(client: client, to: "+15555550123", criteria: criteria, err: StringIO.new)

    receipt = alert.alert_with_receipt(candidate)

    assert receipt.success?
    assert_nil receipt.error
    assert_equal 1, client.call_requests.length
  end

  def test_twilio_call_alert_no_longer_checks_alert_kind
    client = FakeTwilioClient.new
    candidate = RefurbRadar::Candidate.new(
      part_number: "G1KZELL/A",
      title: "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU and 20-Core GPU",
      url: "https://www.apple.com/ca/shop/product/G1KZELL/A",
      model: "macmini",
      memory: "64gb",
      capacity: "512gb",
      alert_kind: "availability_signal"
    )
    criteria = RefurbRadar::TwilioCallCriteria.new(
      models: "macmini,macstudio",
      min_memory_gb: 64,
      min_cpu_cores: 14,
      max_capacity_gb: 2048
    )
    alert = RefurbRadar::TwilioCallAlert.new(client: client, to: "+15555550123", criteria: criteria, err: StringIO.new)

    receipt = alert.alert_with_receipt(candidate)

    assert receipt.success?
    assert_nil receipt.error
    assert_equal 1, client.call_requests.length
  end

  def test_sms_and_call_both_send_without_threshold_gate
    client = FakeTwilioClient.new
    candidate = RefurbRadar::Candidate.new(
      part_number: "G1JV8LL/A",
      title: "Refurbished Mac mini Apple M4 Pro Chip with 12-Core CPU and 16-Core GPU",
      url: "https://www.apple.com/ca/shop/product/G1JV8LL/A",
      model: "macmini",
      memory: "64gb",
      capacity: "1tb"
    )
    criteria = RefurbRadar::TwilioCallCriteria.new(
      models: "macmini,macstudio",
      min_memory_gb: 64,
      min_cpu_cores: 14,
      max_capacity_gb: 2048
    )
    alerter = RefurbRadar::Alerter.new(
      channels: [
        RefurbRadar::TwilioSmsAlert.new(client: client, to: "+15555550123", err: StringIO.new),
        RefurbRadar::TwilioCallAlert.new(client: client, to: "+15555550123", criteria: criteria, err: StringIO.new)
      ]
    )

    result = alerter.alert_with_receipts(candidate)

    assert result.success?
    assert_equal 1, client.sms_requests.length
    assert_equal 1, client.call_requests.length
    assert_equal ["twilio_sms", "twilio_call"], result.receipts.map(&:channel)
    assert_nil result.receipts.last.error
  end

  def test_twilio_call_alert_sends_candidates_meeting_call_threshold
    client = FakeTwilioClient.new
    candidate = RefurbRadar::Candidate.new(
      part_number: "G1KZELL/A",
      title: "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU and 20-Core GPU",
      url: "https://www.apple.com/ca/shop/product/G1KZELL/A",
      model: "macmini",
      memory: "64gb",
      capacity: "512gb"
    )
    criteria = RefurbRadar::TwilioCallCriteria.new(
      models: "macmini,macstudio",
      min_memory_gb: 64,
      min_cpu_cores: 14,
      max_capacity_gb: 2048
    )
    alert = RefurbRadar::TwilioCallAlert.new(client: client, to: "+15555550123", criteria: criteria, err: StringIO.new)

    assert alert.alert(candidate)
    assert_equal 1, client.call_requests.length
  end

  def test_twilio_call_criteria_uses_chip_family_when_title_hides_cpu_cores
    candidate = RefurbRadar::Candidate.new(
      part_number: "GSTUDIO96/A",
      title: "Refurbished Mac Studio Apple M3 Ultra chip with 96GB unified memory and 2TB SSD",
      url: "https://www.apple.com/ca/shop/product/GSTUDIO96/A",
      model: "macstudio",
      memory: "96gb",
      capacity: "2tb",
      chip_family: "m3ultra"
    )
    criteria = RefurbRadar::TwilioCallCriteria.new(
      models: "macmini,macstudio",
      min_memory_gb: 64,
      min_cpu_cores: 14,
      max_capacity_gb: 4096
    )

    assert criteria.matches?(candidate)
  end

  def test_check_alerts_for_direct_watch_url
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    fetcher = FakeFetcher.new(
      BASE_URL => fixture("refurb_grid.html"),
      "https://www.apple.com/ca/shop/product/gmini48/a/Refurbished-Mac-mini-M4-Pro" => fixture("out_of_stock_pdp.html"),
      "https://www.apple.com/ca/shop/product/gstudio96/a/Refurbished-Mac-Studio" => fixture("out_of_stock_pdp.html"),
      direct_url => fixture("direct_live_pdp.html")
    )
    alerter = FakeAlerter.new

    with_state_store do |store|
      check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        grid_url: BASE_URL,
        fetcher: fetcher,
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: alerter,
        watch_urls: [direct_url],
        now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
      )

      result = check.run

      assert_equal 1, result.direct_watch_candidates
      assert_includes result.confirmed_buyable.map(&:part_number), "G1CD5LL/A"
      assert_includes result.alerts.map(&:part_number), "G1CD5LL/A"
      assert_empty result.warnings
    end
  end

  def test_check_alerts_availability_signal_only_after_stable_not_buyable_run
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    pages = { direct_url => not_buyable_pdp }
    fetcher = FakeFetcher.new(pages)
    alerter = FakeAlerter.new
    now = Time.utc(2026, 6, 9, 16, 48, 5)

    with_state_store do |store|
      with_event_log do |event_log|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          fetcher: fetcher,
          state_store: store,
          event_log: event_log,
          alerter: alerter,
          watch_urls: [direct_url],
          include_grid: false,
          now: -> { now }
        )

        RefurbRadar::StateStore::AVAILABILITY_STABLE_PASSES.times do
          check.run
          now += 30
        end
        pages[direct_url] = availability_signal_pdp
        result = check.run
        record = store.load.fetch("currently_seen").fetch("G1CD5LL/A")
        verdict = event_log.read.reverse.find { |event| event["type"] == "buyability_verdict" && event["part_number"] == "G1CD5LL/A" }

        assert_empty result.confirmed_buyable
        assert_equal ["G1CD5LL/A"], result.availability_signals.map(&:part_number)
        assert_equal ["availability_signal"], result.alerts.map(&:alert_kind)
        assert_equal ["availability_signal"], alerter.alerted.map(&:alert_kind)
        assert_equal now.iso8601, record.fetch("last_availability_signal_at")
        refute record.key?("last_buyable_at")
        assert_equal "availability_signal", verdict.fetch("verdict")
      end
    end
  end

  def test_check_does_not_alert_availability_signal_on_cold_start
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    fetcher = FakeFetcher.new(direct_url => availability_signal_pdp)
    alerter = FakeAlerter.new

    with_state_store do |store|
      check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        fetcher: fetcher,
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: alerter,
        watch_urls: [direct_url],
        include_grid: false,
        now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
      )

      result = check.run

      assert_equal ["G1CD5LL/A"], result.availability_signals.map(&:part_number)
      assert_empty result.alerts
      assert_empty alerter.alerted
    end
  end

  def test_fetches_direct_watch_urls_concurrently
    urls = [
      "https://www.apple.com/ca/shop/product/g1cd5ll/a/one",
      "https://www.apple.com/ca/shop/product/g1cd6ll/a/two"
    ]
    fetcher = SlowFetcher.new(urls.to_h { |url| [url, fixture("direct_live_pdp.html")] })

    with_state_store do |store|
      check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        fetcher: fetcher,
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: FakeAlerter.new,
        watch_urls: urls,
        include_grid: false,
        fetch_threads: 2,
        open_matches: false,
        now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
      )

      check.run

      assert_operator fetcher.max_active, :>=, 2
    end
  end

  def test_mass_failure_alarm_counts_fetch_stage_watch_url_failures
    urls = [
      "https://www.apple.com/ca/shop/product/G1CD5LL/A",
      "https://www.apple.com/ca/shop/product/G1CD6LL/A"
    ]
    fetcher = FakeFetcher.new({})

    with_state_store do |store|
      with_event_log do |event_log|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          fetcher: fetcher,
          state_store: store,
          event_log: event_log,
          alerter: FakeAlerter.new,
          watch_urls: urls,
          include_grid: false,
          open_matches: false,
          now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
        )

        result = check.run
        alarm = event_log.read.find { |event| event["type"] == "mass_failure_alarm" }

        assert_equal 2, result.warnings.length
        refute_nil alarm
        assert_equal 2, alarm.fetch("direct_watch_failures")
        assert_equal 2, alarm.fetch("direct_watch_urls")
      end
    end
  end

  def test_fetch_stage_failure_preserves_previous_alerted_window
    direct_url = "https://www.apple.com/ca/shop/product/G1CD5LL/A"
    now = Time.utc(2026, 6, 9, 16, 48, 5)

    with_state_store do |store|
      state = store.load
      candidate = RefurbRadar::Candidate.new(
        part_number: "G1CD5LL/A",
        title: "Refurbished Mac Studio",
        url: direct_url,
        model: "macstudio",
        memory: "64gb",
        capacity: "1tb"
      )
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [candidate],
        checked_at: now
      )
      store.mark_alerted(state, candidate, alerted_at: now)
      store.save(state)

      failing_check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        fetcher: FakeFetcher.new({}),
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: FakeAlerter.new,
        watch_urls: [direct_url],
        include_grid: false,
        open_matches: false,
        now: -> { now + 30 }
      )
      failing_check.run

      restored_check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        fetcher: FakeFetcher.new(direct_url => fixture("direct_live_pdp.html")),
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: FakeAlerter.new,
        watch_urls: [direct_url],
        include_grid: false,
        open_matches: false,
        now: -> { now + 60 }
      )
      result = restored_check.run

      assert_empty result.alerts
      assert_empty store.load.fetch("history")
    end
  end

  def test_grid_failure_does_not_block_direct_watch_alert
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    fetcher = FakeFetcher.new(
      direct_url => fixture("direct_live_pdp.html")
    )
    alerter = FakeAlerter.new

    with_state_store do |store|
      with_event_log do |event_log|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          grid_url: BASE_URL,
          fetcher: fetcher,
          state_store: store,
          event_log: event_log,
          alerter: alerter,
          watch_urls: [direct_url],
          now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
        )

        result = check.run

        assert_equal 1, result.direct_watch_candidates
        assert_includes result.warnings.join(" "), "grid_unconfirmed"
        assert_includes result.alerts.map(&:part_number), "G1CD5LL/A"
        assert_includes event_log.read.map { |event| event.fetch("type") }, "check_pass"
      end
    end
  end

  def test_event_log_records_buyability_and_alert_receipts
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    fetcher = FakeFetcher.new(
      BASE_URL => fixture("refurb_grid.html"),
      "https://www.apple.com/ca/shop/product/gmini48/a/Refurbished-Mac-mini-M4-Pro" => fixture("out_of_stock_pdp.html"),
      "https://www.apple.com/ca/shop/product/gstudio96/a/Refurbished-Mac-Studio" => fixture("out_of_stock_pdp.html"),
      direct_url => fixture("direct_live_pdp.html")
    )
    alerter = RefurbRadar::Alerter.new(
      channels: [FakeAlertChannel.new(false, channel: "sms"), FakeAlertChannel.new(true, channel: "call")],
      err: StringIO.new
    )

    with_state_store do |store|
      with_event_log do |event_log|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          grid_url: BASE_URL,
          fetcher: fetcher,
          state_store: store,
          event_log: event_log,
          alerter: alerter,
          watch_urls: [direct_url],
          now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
        )

        check.run
        events = event_log.read
        attempts = events.select { |event| event["type"] == "alert_attempt" }
        verdict = events.find { |event| event["type"] == "buyability_verdict" && event["part_number"] == "G1CD5LL/A" }

        assert_equal ["sms", "call"], attempts.map { |event| event.fetch("channel") }
        assert_equal [false, true], attempts.map { |event| event.fetch("success") }
        assert_equal "buyable", verdict.fetch("verdict")
        assert_includes verdict.fetch("positive_signals"), "schema_in_stock"
      end
    end
  end

  def test_event_log_retains_only_latest_events
    Dir.mktmpdir do |dir|
      event_log = RefurbRadar::EventLog.new(File.join(dir, "events.jsonl"), max_events: 3)

      event_log.append_many([
        { "type" => "one" },
        { "type" => "two" }
      ])
      event_log.append_many([
        { "type" => "three" },
        { "type" => "four" }
      ])

      assert_equal %w[two three four], event_log.read.map { |event| event.fetch("type") }
    end
  end

  def test_event_log_appends_without_renaming_below_retention_limit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events.jsonl")
      event_log = RefurbRadar::EventLog.new(path, max_events: 10)

      event_log.append_many([{ "type" => "one" }])
      inode = File.stat(path).ino
      event_log.append_many([{ "type" => "two" }])

      assert_equal inode, File.stat(path).ino
      assert_equal %w[one two], event_log.read.map { |event| event.fetch("type") }
    end
  end

  def test_event_log_survives_unicode_titles_under_ascii_default_encoding
    Dir.mktmpdir do |dir|
      event_log = RefurbRadar::EventLog.new(File.join(dir, "events.jsonl"))
      title = "Refurbished Mac mini Apple M4 Pro Chip with 14‑Core CPU and 20‑Core GPU"

      with_default_external(Encoding::US_ASCII) do
        event_log.append_many([{ "type" => "alert_attempt", "title" => title }])
        event_log.append_many([{ "type" => "check_pass" }])

        assert_equal title, event_log.read.first.fetch("title")
      end
      assert_empty Dir.glob(File.join(dir, "events.jsonl.tmp-*"))
    end
  end

  def test_missing_buyability_flag_falls_back_to_pdp_before_alerting
    candidate = candidate(part_number: "G1CD5LL/A", model: "macstudio", memory: "64gb", capacity: "1tb")
    buyability = FakeBuyabilityClient.new([{ }])
    fetcher = FakeFetcher.new(candidate.url => fixture("direct_live_pdp.html"))

    with_state_store do |store|
      with_catalog_store do |catalog_store|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          fetcher: fetcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: FakeAlerter.new,
          watch_candidates: [candidate],
          include_grid: false,
          open_matches: false,
          now: -> { Time.utc(2026, 6, 16, 14, 0, 0) }
        )

        result = check.run

        assert_equal ["G1CD5LL/A"], result.confirmed_buyable.map(&:part_number)
        assert_equal ["G1CD5LL/A"], result.alerts.map(&:part_number)
        assert_empty result.warnings
      end
    end
  end

  def test_stale_catalog_candidate_missing_buyability_flag_is_retired
    Dir.mktmpdir do |dir|
      catalog_path = File.join(dir, "catalog.json")
      missing_seed_path = File.join(dir, "missing-seed.json")
      catalog_store = RefurbRadar::CatalogStore.new(catalog_path)
      catalog_store.save(
        "updated_at" => "2026-06-09T16:48:05Z",
        "products" => [
          {
            "part_number" => "GSTALE/A",
            "title" => "Refurbished Mac Studio",
            "url" => "https://www.apple.com/ca/shop/product/GSTALE/A",
            "model" => "macstudio",
            "memory" => "64gb",
            "capacity" => "1tb",
            "last_seen_at" => "2026-06-09T16:48:05Z"
          }
        ]
      )
      buyability = FakeBuyabilityClient.new([{ }, { }])
      fetcher = FakeFetcher.new("https://www.apple.com/ca/shop/product/GSTALE/A" => "<html><body>retired</body></html>")

      with_state_store do |store|
        check = RefurbRadar::Check.new(
          matcher: mac_desktop_matcher,
          fetcher: fetcher,
          buyability_client: buyability,
          state_store: store,
          catalog_store: catalog_store,
          event_log: RefurbRadar::NullEventLog.new,
          alerter: FakeAlerter.new,
          watch_candidates: -> {
            RefurbRadar::Config.watch_candidates(
              matcher: mac_desktop_matcher,
              catalog_path: catalog_path,
              seed_path: missing_seed_path
            )
          },
          include_grid: false,
          open_matches: false,
          now: -> { Time.utc(2026, 6, 16, 14, 0, 0) }
        )

        first = check.run
        retired = catalog_store.products.first
        second = check.run

        assert_empty first.warnings
        assert_equal "2026-06-16T14:00:00Z", retired.fetch("retired_at")
        assert_equal "missing_buyability_flag", retired.fetch("retired_reason")
        assert_equal 0, second.direct_watch_candidates
      end
    end
  end

  def test_alert_state_survives_event_log_failure_and_does_not_realert
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    fetcher = FakeFetcher.new(direct_url => fixture("direct_live_pdp.html"))
    alerter = FakeAlerter.new
    now = Time.utc(2026, 6, 9, 16, 48, 5)

    with_state_store do |store|
      check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        fetcher: fetcher,
        state_store: store,
        event_log: ExplodingEventLog.new,
        alerter: alerter,
        watch_urls: [direct_url],
        include_grid: false,
        now: -> { now }
      )

      first = check.run
      now += 30
      second = check.run
      record = store.load.fetch("currently_seen").fetch("G1CD5LL/A")

      assert_equal 1, alerter.alerted.length
      assert_equal ["G1CD5LL/A"], first.alerts.map(&:part_number)
      assert_empty second.alerts
      assert_equal "2026-06-09T16:48:05Z", record.fetch("alerted_at")
      assert(first.warnings.any? { |warning| warning.include?("event_log_unconfirmed") })
    end
  end

  def test_check_reloads_dynamic_direct_watch_urls_each_run
    direct_url = "https://www.apple.com/ca/shop/product/g1cd5ll/a/Refurbished-Mac-Studio"
    watch_sets = [[], [direct_url]]
    fetcher = FakeFetcher.new(
      BASE_URL => fixture("refurb_grid.html"),
      "https://www.apple.com/ca/shop/product/gmini48/a/Refurbished-Mac-mini-M4-Pro" => fixture("out_of_stock_pdp.html"),
      "https://www.apple.com/ca/shop/product/gstudio96/a/Refurbished-Mac-Studio" => fixture("out_of_stock_pdp.html"),
      direct_url => fixture("direct_live_pdp.html")
    )
    alerter = FakeAlerter.new

    with_state_store do |store|
      check = RefurbRadar::Check.new(
        matcher: mac_desktop_matcher,
        grid_url: BASE_URL,
        fetcher: fetcher,
        state_store: store,
        event_log: RefurbRadar::NullEventLog.new,
        alerter: alerter,
        watch_urls: -> { watch_sets.shift || [] },
        now: -> { Time.utc(2026, 6, 9, 16, 48, 5) }
      )

      first_result = check.run
      second_result = check.run

      assert_equal 0, first_result.direct_watch_candidates
      assert_equal 1, second_result.direct_watch_candidates
      assert_includes second_result.alerts.map(&:part_number), "G1CD5LL/A"
    end
  end

  def test_watch_exits_after_max_checks
    check = FakeCheck.new([
      RefurbRadar::Result.new(
        checked_at: Time.utc(2026, 6, 9, 16, 48, 5),
        total_tiles: 1,
        direct_watch_candidates: 0,
        target_tiles: 1,
        eligible_target_tiles: 1,
        confirmed_buyable: [],
        unconfirmed_candidates: [],
        alerts: [],
        warnings: []
      )
    ])
    output = StringIO.new

    RefurbRadar::Watch.new(check: check, output: output, sleeper: FakeSleeper, max_checks: 1).run

    assert_equal 1, check.runs
    assert_includes output.string, "tiles=1"
  end

  def test_watch_refreshes_catalog_after_first_check
    refresh = FakeCatalogRefresh.new
    check = FakeCheck.new([
      RefurbRadar::Result.new(
        checked_at: Time.utc(2026, 6, 9, 16, 48, 5),
        total_tiles: 1,
        direct_watch_candidates: 1,
        target_tiles: 1,
        eligible_target_tiles: 1,
        confirmed_buyable: [],
        unconfirmed_candidates: [],
        alerts: [],
        warnings: [],
        duration_seconds: 0.1
      )
    ], before_run: -> { assert_equal 0, refresh.runs })
    output = StringIO.new

    RefurbRadar::Watch.new(
      check: check,
      output: output,
      sleeper: FakeSleeper,
      max_checks: 1,
      catalog_refresh: refresh
    ).run

    assert_equal 1, refresh.runs
    assert_includes output.string, "catalog_refreshed_at=2026-06-09T16:48:05Z"
    assert_includes output.string, "direct_watch_candidates=1"
  end

  def test_inventory_snapshot_projects_top_level_status_facts
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      test_receipt_path = File.join(dir, "test-alert.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-09T16:48:05Z",
          "stats" => {
            "last_check" => {
              "checked_at" => "2026-06-09T16:48:05Z",
              "eligible_target_tiles" => 3,
              "verified_not_buyable" => 2,
              "duration_seconds" => 0.42
            }
          },
          "currently_seen" => {
            "G1CD5LL/A" => {
              "part_number" => "G1CD5LL/A",
              "title" => "Refurbished Mac Studio",
              "url" => "https://www.apple.com/ca/shop/product/G1CD5LL/A",
              "listed_present" => true,
              "last_listed_at" => "2026-06-09T16:47:05Z",
              "last_buyable_at" => "2026-06-09T16:48:05Z",
              "alert_attempts" => [
                { "attempted_at" => "2026-06-09T16:48:10Z", "channel" => "twilio_sms", "success" => true }
              ]
            }
          },
          "history" => []
        )
      )
      File.write(
        catalog_path,
        JSON.pretty_generate(
          "updated_at" => "2026-06-09T16:48:05Z",
          "products" => [
            {
              "part_number" => "G1CD5LL/A",
              "model" => "macstudio",
              "memory" => "64gb",
              "capacity" => "1tb",
              "price" => "3439.00"
            }
          ]
        )
      )
      File.write(
        test_receipt_path,
        JSON.pretty_generate(
          "tested_at" => "2026-06-09T16:40:05Z",
          "receipts" => [{ "channel" => "twilio_call", "success" => true }]
        )
      )
      controls = RefurbRadar::ControlStore.new(File.join(dir, "controls.json"))
      controls.pause("twilio_call", paused_until: :indefinite)

      snapshot = RefurbRadar::InventorySnapshot.new(
        state_path: state_path,
        catalog_path: catalog_path,
        control_store: controls,
        targets_path: write_mac_desktop_targets(dir),
        test_receipt_path: test_receipt_path,
        base_path: "/refurb-radar",
        env: {
          "REFURB_RADAR_TWILIO_SMS" => "1",
          "REFURB_RADAR_TWILIO_CALL" => "1"
        },
        now: -> { Time.utc(2026, 6, 9, 16, 48, 35) }
      ).to_h

      assert_equal "Drop in progress — and calls muted.", snapshot.fetch(:verdict).fetch(:headline)
      assert_equal({ checked: 3, listed: 1, available: 1 }, snapshot.fetch(:watch_summary))
      assert_equal 0.42, snapshot.fetch(:pass_seconds)
      assert_equal "/refurb-radar", snapshot.fetch(:base_path)
      assert_equal ["texts", "calls", "browser"], snapshot.fetch(:chain).last(3).map { |link| link[:label] }
      assert_equal "muted", snapshot.fetch(:chain).find { |link| link[:label] == "calls" }.fetch(:state)
      assert_equal "G1CD5LL/A", snapshot.fetch(:drop).first.fetch(:part_number)
      assert_equal "Mac Studio · 64GB · 1TB", snapshot.fetch(:drop).first.fetch(:spec)
      assert_equal "$3,439", snapshot.fetch(:drop).first.fetch(:price)
      assert_equal "Mac mini & Mac Studio · 48GB+ RAM · up to 2TB SSD", snapshot.fetch(:hunting)
      assert_empty snapshot.fetch(:faults)
      assert_equal 1, snapshot.fetch(:products).length
      assert_equal 1, snapshot.fetch(:active_products).length
    end
  end

  def test_inventory_snapshot_scopes_channel_chain_to_watched_models
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-12T16:54:14Z",
          "stats" => { "last_check" => { "checked_at" => "2026-06-12T16:54:14Z" } },
          "currently_seen" => {},
          "history" => [
            {
              "part_number" => "GMINI/A",
              "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU",
              "first_detected_at" => "2026-06-12T12:00:00Z",
              "listed_present" => false
            },
            {
              "part_number" => "GBOOK/A",
              "title" => "Refurbished 16-inch MacBook Pro Apple M4 Max Chip with 16-Core CPU",
              "alert_attempts" => [
                { "attempted_at" => "2026-06-12T14:00:00Z", "channel" => "twilio_sms", "success" => true }
              ]
            }
          ]
        )
      )
      File.write(
        catalog_path,
        JSON.pretty_generate(
          "products" => [
            { "part_number" => "GMINI/A", "model" => "macmini", "memory" => "64gb", "capacity" => "1tb" },
            { "part_number" => "GBOOK/A", "model" => "macbookpro", "memory" => "48gb", "capacity" => "1tb" }
          ]
        )
      )
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macmini], "min_memory_gb" => 64 }]))

      snapshot = RefurbRadar::InventorySnapshot.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        env: { "REFURB_RADAR_TWILIO_SMS" => "1" },
        now: -> { Time.utc(2026, 6, 12, 16, 55, 0) }
      ).to_h

      text_link = snapshot.fetch(:chain).find { |link| link[:label] == "texts" }
      assert_equal "unknown", text_link.fetch(:state)
      assert_equal "never proven — run a test", text_link.fetch(:note)
      assert_equal ["GMINI/A"], snapshot.fetch(:scoped_history).map { |record| record["part_number"] }
    end
  end

  def test_inventory_snapshot_surfaces_missing_and_corrupt_inputs_as_faults
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(state_path, "{ nope")

      snapshot = RefurbRadar::InventorySnapshot.new(
        state_path: state_path,
        catalog_path: catalog_path,
        now: -> { Time.utc(2026, 6, 9, 16, 48, 35) }
      ).to_h

      assert_equal "Standing by.", snapshot.fetch(:verdict).fetch(:headline)
      assert_equal({ checked: 0, listed: 0, available: 0 }, snapshot.fetch(:watch_summary))
      assert_empty snapshot.fetch(:drop)
      assert_empty snapshot.fetch(:products)
      assert_equal 2, snapshot.fetch(:faults).length
      assert_match(/seen\.json:/, snapshot.fetch(:faults).first)
      assert_match(/catalog\.json missing/, snapshot.fetch(:faults).last)
    end
  end

  def test_status_page_renders_stats_and_listing_durations
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-09T16:48:05Z",
          "stats" => {
            "successful_checks" => 42,
            "total_alerts" => 1,
            "last_check" => {
              "checked_at" => "2026-06-09T16:48:05Z",
              "total_tiles" => 151,
              "direct_watch_candidates" => 9,
              "target_tiles" => 9,
              "confirmed_buyable" => 1,
              "warnings" => 0
            }
          },
          "currently_seen" => {
            "G1CD5LL/A" => {
              "part_number" => "G1CD5LL/A",
              "title" => "Refurbished Mac Studio",
              "url" => "https://www.apple.com/ca/shop/product/G1CD5LL/A",
              "first_seen_at" => "2026-06-09T15:48:05Z",
              "last_seen_at" => "2026-06-09T16:48:05Z",
              "last_not_buyable_at" => "2026-06-09T16:48:05Z"
            }
          },
          "history" => [
            {
              "part_number" => "GSTUDIO_OLD/A",
              "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU",
              "url" => "https://www.apple.com/ca/shop/product/GSTUDIO_OLD/A",
              "first_seen_at" => "2026-06-09T14:00:00Z",
              "first_detected_at" => "2026-06-09T14:00:00Z",
              "last_seen_at" => "2026-06-09T14:10:00Z",
              "disappeared_at" => "2026-06-09T14:15:00Z"
            },
            {
              "part_number" => "G1720LL/A",
              "title" => "Refurbished Mac Pro Rack",
              "url" => "https://www.apple.com/ca/shop/product/G1720LL/A",
              "first_seen_at" => "2026-06-09T14:00:00Z",
              "last_seen_at" => "2026-06-09T14:10:00Z",
              "disappeared_at" => "2026-06-09T14:15:00Z"
            }
          ]
        )
      )
      File.write(
        catalog_path,
        JSON.pretty_generate(
          "updated_at" => "2026-06-09T16:48:05Z",
          "products" => [
            {
              "part_number" => "G1CD5LL/A",
              "model" => "macstudio",
              "memory" => "64gb",
              "capacity" => "1tb",
              "price" => "3439.00"
            }
          ]
        )
      )

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: write_mac_desktop_targets(dir),
        env: {
          "REFURB_RADAR_TWILIO_SMS" => "1",
          "REFURB_RADAR_TWILIO_CALL" => "1"
        },
        now: -> { Time.utc(2026, 6, 9, 16, 49, 5) }
      ).render

      assert_includes html, "On watch."
      assert_includes html, "Hunting"
      assert_includes html, "Nothing buyable right now."
      assert_includes html, "Mac Studio"
      assert_includes html, "64GB · 1TB"
      assert_includes html, "$3,439"
      assert_includes html, "calls"
      assert_includes html, "texts"
      assert_includes html, "mute notifications…"
      assert_includes html, "/controls/pause"
      refute_includes html, "Mac Pro Rack"
      assert_includes html, "Send a test alert"
      assert_includes html, "never proven — run a test"
      assert_includes html, "0 showing on Apple’s refurb page; 0 buyable now"
      assert_includes html, "1 Mac watched"
      assert_includes html, "not buyable"
      refute_includes html, "today’s store"
      refute_includes html, "Last sighting"
    end
  end

  def test_status_page_omits_recent_listings_table_without_calling_listed_items_buyable
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-12T12:00:00Z",
          "stats" => {
            "last_check" => {
              "checked_at" => "2026-06-12T12:00:00Z",
              "eligible_target_tiles" => 2,
              "verified_not_buyable" => 1
            }
          },
          "currently_seen" => {
            "GMINI-LISTED/A" => {
              "part_number" => "GMINI-LISTED/A",
              "title" => "Refurbished Mac mini Apple M4 Chip",
              "listed_present" => true,
              "first_grid_present_at" => "2026-06-12T11:15:00Z",
              "last_listed_at" => "2026-06-12T11:55:00Z",
              "last_not_buyable_at" => "2026-06-12T11:55:00Z"
            }
          },
          "history" => [
            {
              "part_number" => "GSTUDIO-SOLD/A",
              "title" => "Refurbished Mac Studio Apple M4 Max Chip",
              "first_grid_present_at" => "2026-06-12T09:00:00Z",
              "disappeared_at" => "2026-06-12T10:00:00Z",
              "first_buyability_true_at" => "2026-06-12T09:10:00Z",
              "last_not_buyable_at" => "2026-06-12T09:35:00Z"
            }
          ]
        )
      )
      File.write(
        catalog_path,
        JSON.pretty_generate(
          "products" => [
            { "part_number" => "GMINI-LISTED/A", "model" => "macmini", "memory" => "64gb", "capacity" => "512gb", "price" => "2379.00" },
            { "part_number" => "GSTUDIO-SOLD/A", "model" => "macstudio", "memory" => "64gb", "capacity" => "1tb", "price" => "3439.00" }
          ]
        )
      )

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: write_mac_desktop_targets(dir),
        now: -> { Time.utc(2026, 6, 12, 12, 0, 0) }
      ).render

      assert_includes html, "Nothing buyable right now."
      assert_includes html, "What you're watching"
      assert_includes html, "Mac mini"
      assert_includes html, "Mac Studio"
      assert_includes html, "1 showing now"
      removed_heading = ["Recent refurb", "listings"].join(" ")
      internal_term = "epi" + "sode"
      refute_includes html, removed_heading
      refute_includes html, "market"
      refute_includes html, "GMINI-LISTED/A available"
      refute_includes html, "GMINI-LISTED/A buyable"
      refute_includes html, "Buy →"
      refute_includes html, internal_term
    end
  end

  def test_status_page_shows_calls_off_by_config
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-09T16:48:05Z",
          "stats" => { "last_check" => { "checked_at" => "2026-06-09T16:48:05Z" } },
          "currently_seen" => {},
          "history" => []
        )
      )
      File.write(catalog_path, JSON.pretty_generate("products" => []))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: write_mac_desktop_targets(dir),
        env: {
          "REFURB_RADAR_BROWSER_ALERT" => "0",
          "REFURB_RADAR_TWILIO_SMS" => "1",
          "REFURB_RADAR_TWILIO_CALL" => "0"
        },
        now: -> { Time.utc(2026, 6, 9, 16, 49, 5) }
      ).render

      assert_includes html, "calls"
      assert_includes html, "texts"
      assert_includes html, "browser"
      assert_includes html, "off by config"
      assert_includes html, "Phone calls are off by config; checking and texts stay on."
      assert_includes html, "Send test — text me"
      refute_includes html, "Send test — ring my phone"
      refute_includes html, ">calls</button>"
      refute_includes html, ">both</button>"
    end
  end

  def test_status_page_treats_unset_twilio_channels_as_off_by_config
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-09T16:48:05Z",
          "stats" => { "last_check" => { "checked_at" => "2026-06-09T16:48:05Z" } },
          "currently_seen" => {},
          "history" => []
        )
      )
      File.write(catalog_path, JSON.pretty_generate("products" => []))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: write_mac_desktop_targets(dir),
        env: {},
        now: -> { Time.utc(2026, 6, 9, 16, 49, 5) }
      ).render

      assert_includes html, "calls"
      assert_includes html, "texts"
      assert_includes html, "off by config"
      assert_includes html, "No Twilio alert channels are configured here."
      refute_includes html, "Send test — ring my phone"
      refute_includes html, "Send test — text me"
      refute_includes html, ">calls</button>"
      refute_includes html, ">texts</button>"
      refute_includes html, ">both</button>"
    end
  end

  def test_status_page_shows_local_browser_open_as_separate_channel
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-09T16:48:05Z",
          "stats" => { "last_check" => { "checked_at" => "2026-06-09T16:48:05Z" } },
          "currently_seen" => {
            "GLOCAL/A" => {
              "part_number" => "GLOCAL/A",
              "title" => "Refurbished Mac Studio",
              "alert_attempts" => [
                { "attempted_at" => "2026-06-09T16:48:10Z", "channel" => "browser", "success" => true }
              ]
            }
          },
          "history" => []
        )
      )
      File.write(
        catalog_path,
        JSON.pretty_generate(
          "products" => [
            { "part_number" => "GLOCAL/A", "model" => "macstudio", "memory" => "64gb", "capacity" => "1tb" }
          ]
        )
      )

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: write_mac_desktop_targets(dir),
        env: {
          "REFURB_RADAR_BROWSER_ALERT" => "1",
          "REFURB_RADAR_TWILIO_SMS" => "0",
          "REFURB_RADAR_TWILIO_CALL" => "0"
        },
        now: -> { Time.utc(2026, 6, 9, 16, 49, 5) }
      ).render

      assert_includes html, "browser"
      assert_includes html, "sent Jun 9"
      assert_includes html, "texts"
      assert_includes html, "calls"
      assert_includes html, "off by config"
    end
  end

  def test_status_page_shows_buyable_hero_and_paused_controls
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-09T16:48:05Z",
          "stats" => { "successful_checks" => 7, "total_alerts" => 2, "last_check" => { "confirmed_buyable" => 1 } },
          "currently_seen" => {
            "G1CD5LL/A" => {
              "part_number" => "G1CD5LL/A",
              "title" => "Refurbished Mac Studio",
              "url" => "https://www.apple.com/ca/shop/product/G1CD5LL/A",
              "first_seen_at" => "2026-06-09T16:30:05Z",
              "last_seen_at" => "2026-06-09T16:48:05Z",
              "last_buyable_at" => "2026-06-09T16:48:05Z"
            }
          },
          "history" => []
        )
      )
      File.write(
        catalog_path,
        JSON.pretty_generate(
          "updated_at" => "2026-06-09T16:48:05Z",
          "products" => [
            { "part_number" => "G1CD5LL/A", "model" => "macstudio", "memory" => "64gb", "capacity" => "1tb", "price" => "3439.00" }
          ]
        )
      )

      controls = RefurbRadar::ControlStore.new(File.join(dir, "controls.json"))
      controls.pause("twilio_call", paused_until: :indefinite)

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: write_mac_desktop_targets(dir),
        control_store: controls,
        base_path: "/refurb-radar",
        env: {
          "REFURB_RADAR_TWILIO_SMS" => "1",
          "REFURB_RADAR_TWILIO_CALL" => "1"
        },
        now: -> { Time.utc(2026, 6, 9, 16, 48, 35) }
      ).render

      assert_includes html, "Drop in progress — and calls muted."
      assert_includes html, "Buy →"
      assert_includes html, "Buyable now — Buy ↗", "a buyable config row must link straight to the product"
      assert_includes html, "calls muted"
      assert_includes html, "unmute"
      assert_includes html, "/refurb-radar/controls/resume"
      assert_includes html, "/refurb-radar/controls/test"
      refute_includes html, "mute notifications…", "while muted, the only mute action is unmute"
    end
  end

  def test_watch_criteria_card_groups_skus_and_preserves_buy_link_semantics
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      products = %w[GBUYLL/A GLISTLL/A GCHECKLL/A GCATALOGLL/A].each_with_index.map do |part, index|
        {
          "part_number" => part,
          "model" => "macstudio",
          "memory" => "64gb",
          "capacity" => "1tb",
          "price" => (3_439 + (index * 100)).to_s,
          "url" => "https://www.apple.com/ca/shop/product/#{part}",
          "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU",
          "last_seen_at" => "2026-06-19T18:00:00Z"
        }
      end
      File.write(
        state_path,
        JSON.pretty_generate(
          "last_checked_at" => "2026-06-19T18:10:00Z",
          "stats" => {
            "last_check" => {
              "checked_at" => "2026-06-19T18:10:00Z",
              "eligible_target_tiles" => 4,
              "verified_not_buyable" => 2,
              "confirmed_buyable" => 1
            }
          },
          "currently_seen" => {
            "GBUYLL/A" => {
              "part_number" => "GBUYLL/A",
              "title" => "Refurbished Mac Studio",
              "url" => "https://www.apple.com/ca/shop/product/GBUYLL/A",
              "listed_present" => true,
              "last_buyable_at" => "2026-06-19T18:10:00Z"
            },
            "GLISTLL/A" => {
              "part_number" => "GLISTLL/A",
              "title" => "Refurbished Mac Studio",
              "url" => "https://www.apple.com/ca/shop/product/GLISTLL/A",
              "listed_present" => true,
              "last_not_buyable_at" => "2026-06-19T18:10:00Z"
            },
            "GCHECKLL/A" => {
              "part_number" => "GCHECKLL/A",
              "title" => "Refurbished Mac Studio",
              "url" => "https://www.apple.com/ca/shop/product/GCHECKLL/A",
              "listed_present" => false,
              "last_not_buyable_at" => "2026-06-19T18:10:00Z"
            }
          },
          "history" => []
        )
      )
      File.write(catalog_path, JSON.pretty_generate("updated_at" => "2026-06-19T18:00:00Z", "products" => products))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macstudio] }]))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        now: -> { Time.utc(2026, 6, 19, 18, 10, 30) }
      ).render

      assert_includes html, "Mac Studio"
      assert_includes html, "any configuration"
      assert_includes html, "1 Mac watched · from $3,439 · 4 variants checked · 1 buyable now · 1 showing · 1 not checked yet"
      assert_includes html, "4 variants · 1 showing now · 1 checked, not buyable · 1 not checked yet"
      refute_includes html, "SKU"
      refute_includes html, "catalog-only"
      refute_includes html, "checked not buyable"
      assert_includes html, %(href="https://www.apple.com/ca/shop/product/GBUYLL/A")
      assert_equal 1, html.scan("Buy ↗").length
      refute_includes html, %(href="https://www.apple.com/ca/shop/product/GLISTLL/A")
      refute_includes html, %(href="https://www.apple.com/ca/shop/product/GCHECKLL/A")
      refute_includes html, %(href="https://www.apple.com/ca/shop/product/GCATALOGLL/A")
    end
  end

  def test_event_log_tail_reads_newest_events_and_skips_torn_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events.jsonl")
      lines = (1..30).map { |index| JSON.generate("type" => "check_pass", "index" => index) }
      lines[27] = "{ torn json"
      File.write(path, lines.join("\n") + "\n")

      tail = RefurbRadar::EventLog.new(path).tail(5)

      assert_equal [26, 27, 29, 30], tail.map { |event| event["index"] }.sort
    end
  end

  # The proof panel replays the full retention window; a tail that trusts a
  # bytes-per-line estimate forgets a drop once verdict events grow past it.
  def test_event_log_tail_grows_its_chunk_until_it_has_enough_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events.jsonl")
      lines = (1..40).map { |index| JSON.generate("type" => "check_pass", "index" => index, "padding" => "x" * 1200) }
      File.write(path, lines.join("\n") + "\n")

      tail = RefurbRadar::EventLog.new(path).tail(30)

      assert_equal (11..40).to_a, tail.map { |event| event["index"] }
    end
  end

  def test_event_log_compaction_keeps_story_events_past_verdict_retention
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events.jsonl")
      event_log = RefurbRadar::EventLog.new(path, max_events: 3)

      event_log.append_many([
        { "type" => "alert_attempt", "part_number" => "G1JV9LL/A", "checked_at" => "2026-06-12T04:55:42Z" }
      ])
      event_log.append_many([
        { "type" => "buyability_verdict", "index" => 1, "checked_at" => "2026-06-12T10:04:41Z" },
        { "type" => "buyability_verdict", "index" => 2, "checked_at" => "2026-06-12T10:04:55Z" },
        { "type" => "check_pass", "index" => 3, "checked_at" => "2026-06-12T10:05:12Z" }
      ])

      events = event_log.read
      tailed = event_log.tail(3)

      assert_equal ["alert_attempt", "buyability_verdict", "check_pass"], events.map { |event| event["type"] }
      assert_equal "G1JV9LL/A", events.first.fetch("part_number")
      assert_equal events, tailed
      assert_equal 3, File.readlines(path).length
    end
  end

  def test_event_log_compaction_regains_append_headroom_after_many_story_events
    Dir.mktmpdir do |dir|
      path = File.join(dir, "events.jsonl")
      event_log = RefurbRadar::EventLog.new(path, max_events: 2_000)

      event_log.append_many(
        3_000.times.map do |index|
          { "type" => "alert_attempt", "index" => index, "checked_at" => "2026-06-12T04:55:42Z" }
        end
      )
      event_log.append_many([{ "type" => "buyability_verdict", "index" => 3_001, "checked_at" => "2026-06-12T10:04:41Z" }])
      compacted_inode = File.stat(path).ino

      event_log.append_many([{ "type" => "buyability_verdict", "index" => 3_002, "checked_at" => "2026-06-12T10:04:55Z" }])

      assert_equal compacted_inode, File.stat(path).ino
      assert_equal 2_001, File.readlines(path).length
    end
  end

  def test_status_page_watch_list_is_the_rule_editor
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate("last_checked_at" => "2026-06-11T16:48:05Z", "currently_seen" => {}, "history" => []))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-11T16:48:05Z",
        "products" => [
          { "part_number" => "GBIG/A", "model" => "macmini", "memory" => "64gb", "capacity" => "1tb",
            "price" => "2589.00", "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU" },
          { "part_number" => "GSMALL/A", "model" => "macmini", "memory" => "16gb", "capacity" => "256gb",
            "price" => "889.00", "title" => "Refurbished Mac mini Apple M4 Chip with 10-Core CPU" },
          { "part_number" => "GAIR/A", "model" => "macbookair", "memory" => "16gb", "capacity" => "256gb",
            "price" => "1249.00", "title" => "Refurbished MacBook Air 13-inch Apple M4 Chip with 10-Core CPU" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macmini], "min_memory_gb" => 64 }]))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        base_path: "/refurb-radar",
        now: -> { Time.utc(2026, 6, 11, 16, 49, 5) }
      ).render

      assert_includes html, "64GB+ RAM"
      assert_includes html, ">M4 Pro · 64GB · 1TB<"
      refute_includes html, "16GB · 256GB", "configs outside the rule must not render as watched"
      assert_includes html, "/refurb-radar/rules/remove"
      assert_includes html, "stop watching Mac mini"
      assert_includes html, "/refurb-radar/rules/update"
      assert_includes html, "/refurb-radar/rules/add"
      assert_includes html, "MacBook Air", "unwatched products must be offered with one-click watch"
      assert_includes html, "$1,249"
      # Edit choices include source-backed model options, but do not borrow
      # impossible memory tiers from other products.
      assert_includes html, %(<option value="16">16GB or more</option>)
      refute_includes html, %(<option value="96">96GB or more</option>)
    end
  end

  def test_status_page_offers_mac_studio_memory_thresholds_even_when_not_listed_today
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate("last_checked_at" => "2026-06-11T16:48:05Z", "currently_seen" => {}, "history" => []))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-11T16:48:05Z",
        "products" => [
          { "part_number" => "G64/A", "model" => "macstudio", "memory" => "64gb", "capacity" => "1tb",
            "price" => "3439.00", "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU" },
          { "part_number" => "G128/A", "model" => "macstudio", "memory" => "128gb", "capacity" => "1tb",
            "price" => "4459.00", "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macstudio], "min_memory_gb" => 64 }]))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        base_path: "/refurb-radar",
        now: -> { Time.utc(2026, 6, 11, 16, 49, 5) }
      ).render

      assert_includes html, %(<option value="96">96GB or more</option>)
      assert_includes html, %(<option value="512">512GB or more</option>)
      assert_includes html, %(<option value="m3ultra">M3 Ultra</option>)
      assert_includes html, %(<option value="8192">up to 8TB</option>)
      assert_includes html, %(<option value="16384">up to 16TB</option>)
    end
  end

  def test_status_page_filters_historical_memory_choices_by_chip_family
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate("last_checked_at" => "2026-06-11T16:48:05Z", "currently_seen" => {}, "history" => []))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-11T16:48:05Z",
        "products" => [
          { "part_number" => "G64/A", "model" => "macstudio", "chip_family" => "m4max", "memory" => "64gb", "capacity" => "1tb",
            "price" => "3439.00", "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU" },
          { "part_number" => "GU96/A", "model" => "macstudio", "chip_family" => "m3ultra", "memory" => "96gb", "capacity" => "2tb",
            "price" => "5179.00", "title" => "Refurbished Mac Studio Apple M3 Ultra chip with 96GB unified memory and 2TB SSD" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate(
        "rules" => [{ "models" => %w[macstudio], "chip_family" => "m4max", "min_memory_gb" => 64 }]
      ))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        base_path: "/refurb-radar",
        now: -> { Time.utc(2026, 6, 11, 16, 49, 5) }
      ).render

      assert_includes html, %(<option value="128">128GB or more</option>)
      refute_includes html, %(<option value="96">96GB or more</option>)
      refute_includes html, %(<option value="256">256GB or more</option>)
      assert_includes html, %(<option value="m3ultra">M3 Ultra</option>)
    end
  end

  def test_status_page_proof_replays_recorded_drops_with_one_click_loosen
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      events_path = File.join(dir, "events.jsonl")
      File.write(state_path, JSON.pretty_generate("last_checked_at" => "2026-06-11T18:00:00Z", "currently_seen" => {}, "history" => []))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-11T18:00:00Z",
        "products" => [
          { "part_number" => "GHIT/A", "model" => "macmini", "memory" => "64gb", "capacity" => "1tb",
            "price" => "2589.00", "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU" },
          { "part_number" => "GMISS/A", "model" => "macmini", "memory" => "48gb", "capacity" => "1tb",
            "price" => "2379.00", "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macmini], "min_memory_gb" => 64 }]))
      File.write(events_path, [
        JSON.generate("type" => "buyability_flip", "part_number" => "GHIT/A", "checked_at" => "2026-06-11T17:39:25Z"),
        JSON.generate("type" => "buyability_flip", "part_number" => "GMISS/A", "checked_at" => "2026-06-11T17:39:25Z")
      ].join("\n") + "\n")

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        event_log: RefurbRadar::EventLog.new(events_path),
        now: -> { Time.utc(2026, 6, 11, 18, 0, 30) }
      ).render

      assert_includes html, "would have alerted once"
      assert_includes html, "RAM range"
      assert_includes html, "allow 48GB+", "a single-constraint miss must offer a one-click loosen"
      assert_includes html, %(name="memory" value="48"), "the loosen form must carry the loosened floor"
    end
  end

  def test_status_page_reconstructs_story_alerts_from_state_when_event_log_rolled_over
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate(
        "last_checked_at" => "2026-06-12T16:54:14Z",
        "stats" => { "successful_checks" => 100, "last_check" => { "checked_at" => "2026-06-12T16:54:14Z" } },
        "currently_seen" => {
          "G1JV9LL/A" => {
            "part_number" => "G1JV9LL/A",
            "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU and 20-Core GPU, Gigabit Ethernet ",
            "url" => "https://www.apple.com/ca/shop/product/G1JV9LL/A",
            "first_detected_at" => "2026-06-11T00:47:08Z",
            "last_seen_at" => "2026-06-12T16:54:14Z",
            "last_not_buyable_at" => "2026-06-12T16:54:14Z",
            "alert_attempts" => [
              { "attempted_at" => "2026-06-11T17:40:37Z", "channel" => "twilio_sms", "success" => true },
              { "attempted_at" => "2026-06-11T17:40:45Z", "channel" => "twilio_call", "success" => true },
              { "attempted_at" => "2026-06-12T04:55:42Z", "channel" => "twilio_sms", "success" => true },
              { "attempted_at" => "2026-06-12T04:55:56Z", "channel" => "twilio_call", "success" => true },
              { "attempted_at" => "2026-06-12T05:27:20Z", "channel" => "twilio_sms", "success" => true }
            ]
          }
        },
        "history" => [
          {
            "part_number" => "G1JV9LL/A",
            "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU and 20-Core GPU, Gigabit Ethernet ",
            "url" => "https://www.apple.com/ca/shop/product/G1JV9LL/A",
            "first_seen_at" => "2026-06-10T16:11:12Z",
            "last_seen_at" => "2026-06-10T16:17:46Z",
            "disappeared_at" => "2026-06-10T16:19:13Z"
          }
        ]
      ))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-12T16:54:14Z",
        "products" => [
          { "part_number" => "G1JV9LL/A", "model" => "macmini", "memory" => "64gb", "capacity" => "1tb",
            "price" => "2589.00", "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macmini], "min_memory_gb" => 64 }]))

      with_timezone("UTC") do
        html = RefurbRadar::StatusPage.new(
          state_path: state_path,
          catalog_path: catalog_path,
          targets_path: targets_path,
          event_log: RefurbRadar::NullEventLog.new,
          now: -> { Time.utc(2026, 6, 12, 16, 55, 0) }
        ).render

        assert_includes html, "64GB · 1TB"
        assert_includes html, "Last alert Jun 12"
        assert_includes html, %(<span class="story__day">Jun 12</span>)
        assert_includes html, "texted you Jun 12 04:55:42 → called you Jun 12 04:55:56"
        assert_includes html, "no longer buyable"
        refute_includes html, "buyable for", "alert-only reconstructed history must not invent a buyability duration"
        refute_match(/called you in \d+s/, html)
        refute_includes html, "texted you 05:27:20"
        refute_includes html, "Last alert Jun 10"
        refute_includes html, "Gigabit Ethernet ."
        refute_includes html, "pulled 16:19:13"
      end
    end
  end

  def test_status_page_scopes_last_sighting_to_watched_models
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate(
        "last_checked_at" => "2026-06-12T16:54:14Z",
        "stats" => { "successful_checks" => 100, "last_check" => { "checked_at" => "2026-06-12T16:54:14Z" } },
        "currently_seen" => {},
        "history" => [
          {
            "part_number" => "GMINI/A",
            "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU and 20-Core GPU, Gigabit Ethernet",
            "url" => "https://www.apple.com/ca/shop/product/GMINI/A",
            "first_seen_at" => "2026-06-12T04:55:42Z",
            "first_detected_at" => "2026-06-12T04:55:42Z",
            "last_seen_at" => "2026-06-12T12:19:13Z",
            "disappeared_at" => "2026-06-12T12:19:13Z"
          },
          {
            "part_number" => "GBOOK/A",
            "title" => "Refurbished 16-inch MacBook Pro Apple M4 Max Chip with 16-Core CPU and 40-Core GPU",
            "url" => "https://www.apple.com/ca/shop/product/GBOOK/A",
            "first_seen_at" => "2026-06-12T14:00:00Z",
            "first_detected_at" => "2026-06-12T14:00:00Z",
            "last_seen_at" => "2026-06-12T14:00:05Z",
            "last_buyable_at" => "2026-06-12T14:00:00Z",
            "buyable_alerted_at" => "2026-06-12T14:00:00Z",
            "alert_attempts" => [
              { "attempted_at" => "2026-06-12T14:00:00Z", "channel" => "twilio_sms", "success" => true }
            ],
            "disappeared_at" => "2026-06-12T14:00:05Z"
          }
        ]
      ))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-12T16:54:14Z",
        "products" => [
          { "part_number" => "GMINI/A", "model" => "macmini", "memory" => "64gb", "capacity" => "1tb",
            "price" => "2589.00", "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU" },
          { "part_number" => "GBOOK/A", "model" => "macbookpro", "memory" => "48gb", "capacity" => "1tb",
            "price" => "3999.00", "title" => "Refurbished 16-inch MacBook Pro Apple M4 Max Chip with 16-Core CPU" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macmini], "min_memory_gb" => 64 }]))

      with_timezone("UTC") do
        html = RefurbRadar::StatusPage.new(
          state_path: state_path,
          catalog_path: catalog_path,
          targets_path: targets_path,
          now: -> { Time.utc(2026, 6, 12, 16, 55, 0) }
        ).render

        assert_includes html, "64GB · 1TB"
        refute_includes html, "Last sighting"
        refute_includes html[/<p class="nothing">.*?<\/p>/m], "MacBook Pro"
        refute_includes html[/<p class="zone__label">Alerts<\/p>.*?<\/section>/m].to_s, "MacBook Pro"
        refute_includes html, "sent Jun 12", "unwatched alert attempts must not prove the current watch channels"
      end
    end
  end

  def test_status_page_does_not_turn_rule_churn_into_a_sighting
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      mac_studio_128 = %w[G1CD2LL/A G1CD6LL/A G1CDALL/A G1CDELL/A]
      products = mac_studio_128.each_with_index.map do |part, index|
        {
          "part_number" => part,
          "model" => "macstudio",
          "memory" => "128gb",
          "capacity" => %w[512gb 1tb 2tb 4tb][index],
          "price" => %w[4199.00 4459.00 4969.00 5729.00][index],
          "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU",
          "last_seen_at" => "2026-06-11T01:02:56Z"
        }
      end
      File.write(state_path, JSON.pretty_generate(
        "last_checked_at" => "2026-06-15T17:13:10Z",
        "stats" => {
          "last_check" => {
            "checked_at" => "2026-06-15T17:13:10Z",
            "eligible_target_tiles" => 4,
            "verified_not_buyable" => 4,
            "confirmed_buyable" => 0,
            "grid_failed" => false
          }
        },
        "currently_seen" => mac_studio_128.to_h do |part|
          [
            part,
            {
              "part_number" => part,
              "title" => "Refurbished Mac Studio Apple M4 Max chip with 16-Core CPU and 40-Core GPU",
              "url" => "https://www.apple.com/ca/shop/product/#{part}",
              "first_seen_at" => "2026-06-11T01:13:10Z",
              "last_seen_at" => "2026-06-15T17:13:10Z",
              "listed_present" => false,
              "last_not_buyable_at" => "2026-06-15T17:13:10Z"
            }
          ]
        end,
        "history" => [
          {
            "part_number" => "G1JV9LL/A",
            "title" => "Refurbished Mac mini Apple M4 Pro Chip with 14-Core CPU and 20-Core GPU",
            "url" => "https://www.apple.com/ca/shop/product/G1JV9LL/A",
            "first_seen_at" => "2026-06-10T16:13:03Z",
            "first_detected_at" => "2026-06-11T01:13:10Z",
            "last_seen_at" => "2026-06-15T16:17:03Z",
            "last_not_buyable_at" => "2026-06-15T16:17:03Z",
            "disappeared_at" => "2026-06-15T16:17:12Z"
          }
        ]
      ))
      File.write(catalog_path, JSON.pretty_generate("updated_at" => "2026-06-12T05:26:00Z", "products" => products))
      File.write(targets_path, JSON.pretty_generate(
        "rules" => [{ "models" => %w[macstudio], "min_memory_gb" => 96, "min_cpu_cores" => 14, "max_capacity_gb" => 4096 }]
      ))

      with_timezone("America/Toronto") do
        html = RefurbRadar::StatusPage.new(
          state_path: state_path,
          catalog_path: catalog_path,
          targets_path: targets_path,
          now: -> { Time.utc(2026, 6, 15, 17, 13, 20) }
        ).render

        assert_includes html, "checking 4 matching known configs"
        assert_includes html, "0 showing on Apple’s refurb page; 0 buyable now"
        assert_includes html, "4 Macs watched"
        assert_includes html, "4 variants checked"
        assert_includes html, "none buyable"
        refute_includes html, "Last sighting"
        refute_includes html, "today’s store"
        refute_includes html, "gone after"
        refute_includes html, "G1JV9LL/A"
      end
    end
  end

  def test_status_page_surfaces_store_near_misses_for_fresh_catalog_products
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate("last_checked_at" => "2026-06-11T18:00:00Z", "currently_seen" => {}, "history" => []))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-11T18:00:00Z",
        "products" => [
          { "part_number" => "G4TB/A", "model" => "macstudio", "memory" => "64gb", "capacity" => "4tb",
            "price" => "4709.00", "title" => "Refurbished Mac Studio Apple M4 Max Chip with 16-Core CPU",
            "last_seen_at" => "2026-06-11T17:45:00Z" },
          { "part_number" => "GOLD/A", "model" => "macstudio", "memory" => "64gb", "capacity" => "8tb",
            "price" => "6239.00", "title" => "Refurbished Mac Studio Apple M4 Max Chip with 16-Core CPU",
            "last_seen_at" => "2026-06-01T00:00:00Z" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => [{ "models" => %w[macstudio], "min_memory_gb" => 64, "max_capacity_gb" => 2048 }]))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        now: -> { Time.utc(2026, 6, 11, 18, 0, 30) }
      ).render

      assert_includes html, "SSD cap"
      assert_includes html, "allow up to 4TB"
      assert_includes html, "recently listed"
      refute_includes html, "allow up to 8TB", "products gone from the store must not show as near misses"
      refute_includes html, "$6,239"
    end
  end

  def test_status_page_with_no_rules_prompts_for_a_model
    Dir.mktmpdir do |dir|
      state_path = File.join(dir, "seen.json")
      catalog_path = File.join(dir, "catalog.json")
      targets_path = File.join(dir, "targets.json")
      File.write(state_path, JSON.pretty_generate("last_checked_at" => "2026-06-11T18:00:00Z", "currently_seen" => {}, "history" => []))
      File.write(catalog_path, JSON.pretty_generate(
        "updated_at" => "2026-06-11T18:00:00Z",
        "products" => [
          { "part_number" => "GAIR/A", "model" => "macbookair", "memory" => "16gb", "capacity" => "256gb", "price" => "1249.00",
            "title" => "Refurbished MacBook Air 13-inch Apple M4 Chip with 10-Core CPU" }
        ]
      ))
      File.write(targets_path, JSON.pretty_generate("rules" => []))

      html = RefurbRadar::StatusPage.new(
        state_path: state_path,
        catalog_path: catalog_path,
        targets_path: targets_path,
        now: -> { Time.utc(2026, 6, 11, 18, 0, 30) }
      ).render

      assert_includes html, "Not watching anything."
      assert_includes html, "Watch another product"
      assert_includes html, "MacBook Air"
    end
  end

  def test_fetcher_resets_backoff_after_success
    responses = [
      fake_response(Net::HTTPForbidden, "403", "Forbidden"),
      fake_response(Net::HTTPOK, "200", "OK", body: "ok"),
      fake_response(Net::HTTPForbidden, "403", "Forbidden"),
      fake_response(Net::HTTPOK, "200", "OK", body: "ok")
    ]
    http = FakeHTTP.new(responses)
    now = Time.utc(2026, 6, 9, 16, 48, 5)
    sleeper = AdvancingSleeper.new { |seconds| now += seconds }
    fetcher = RefurbRadar::Fetcher.new(http: http, sleeper: sleeper, now: -> { now })

    assert_raises(RefurbRadar::FetchError) { fetcher.get("https://example.com/one") }
    assert_equal "ok", fetcher.get("https://example.com/two")
    assert_raises(RefurbRadar::FetchError) { fetcher.get("https://example.com/three") }
    assert_equal "ok", fetcher.get("https://example.com/four")

    assert_equal [2, 2], sleeper.delays
    assert_equal 1, http.starts
  end

  def test_store_session_refreshes_once_after_fetch_error
    fetcher = RejectingSessionFetcher.new(
      grid_url: BASE_URL,
      target_url: "https://www.apple.com/ca/shop/buyability-message?parts.0=G1JV8LL%2FA"
    )
    session = RefurbRadar::StoreSession.new(grid_url: BASE_URL, fetcher: fetcher)

    response = session.get_with_metadata("https://www.apple.com/ca/shop/buyability-message?parts.0=G1JV8LL%2FA")

    assert_equal "ok", response.body
    assert_equal [
      [BASE_URL, nil],
      ["https://www.apple.com/ca/shop/buyability-message?parts.0=G1JV8LL%2FA", "aos=1"],
      [BASE_URL, "aos=1"],
      ["https://www.apple.com/ca/shop/buyability-message?parts.0=G1JV8LL%2FA", "aos=2"]
    ], fetcher.calls
  end

  private

  def with_access_cert_cache(certs)
    RefurbRadar::CloudflareAccess.instance_variable_set(
      :@cert_cache,
      { certs: certs, expires_at: Time.now + 60 }
    )
    yield
  ensure
    if RefurbRadar::CloudflareAccess.instance_variable_defined?(:@cert_cache)
      RefurbRadar::CloudflareAccess.remove_instance_variable(:@cert_cache)
    end
  end

  def access_certificate(key)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=refurb-radar-test")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    cert
  end

  def access_token(key:, kid:, audience:)
    header = { "alg" => "RS256", "kid" => kid, "typ" => "JWT" }
    payload = {
      "iss" => "https://team.cloudflareaccess.com",
      "aud" => [audience],
      "email" => "test-user",
      "exp" => Time.now.to_i + 300,
      "nbf" => Time.now.to_i - 60
    }
    encoded_header = urlsafe_encode(JSON.generate(header))
    encoded_payload = urlsafe_encode(JSON.generate(payload))
    signature = key.sign(OpenSSL::Digest::SHA256.new, "#{encoded_header}.#{encoded_payload}")
    "#{encoded_header}.#{encoded_payload}.#{urlsafe_encode(signature)}"
  end

  def urlsafe_encode(value)
    [value].pack("m0").tr("+/", "-_").delete("=")
  end

  def fixture(name)
    File.read(File.join(FIXTURES, name))
  end

  def parsed_candidates
    parser = RefurbRadar::Parser.new
    parser.candidates_from_grid(parser.grid_from_html(fixture("refurb_grid.html")), BASE_URL)
  end

  def availability_signal_pdp
    fixture("direct_live_pdp.html")
      .sub('data-autom="add-to-cart"', 'data-autom="add-to-cart" disabled="disabled"')
      .gsub('"disabled": false', '"disabled": true')
      .gsub('"buyable": true', '"buyable": false')
      .gsub('"isBuyable": true', '"isBuyable": false')
  end

  def not_buyable_pdp
    availability_signal_pdp.gsub("schema.org/InStock", "schema.org/OutOfStock")
  end

  def empty_grid_html
    <<~HTML
      <script>
        window.REFURB_GRID_BOOTSTRAP = {"tiles":[]}
      </script>
    HTML
  end

  # Tests must not depend on the deployable config/targets.json, which
  # changes whenever live watch criteria change.
  def mac_desktop_matcher_rules
    [RefurbRadar::Matcher::Rule.new(models: %w[macmini macstudio], min_memory_gb: 48, max_capacity_gb: 2048)]
  end

  def mac_desktop_matcher
    RefurbRadar::Matcher.new(rules: mac_desktop_matcher_rules)
  end

  def write_mac_desktop_targets(dir)
    File.join(dir, "targets.json").tap do |path|
      File.write(path, JSON.pretty_generate(
        "rules" => [{ "models" => %w[macmini macstudio], "min_memory_gb" => 48, "max_capacity_gb" => 2048 }]
      ))
    end
  end

  def with_state_store
    Dir.mktmpdir do |dir|
      yield RefurbRadar::StateStore.new(File.join(dir, "seen.json"))
    end
  end

  def save_and_reload(store, state)
    store.save(state)
    store.load
  end

  def with_catalog_store
    Dir.mktmpdir do |dir|
      yield RefurbRadar::CatalogStore.new(File.join(dir, "catalog.json"))
    end
  end

  def with_control_store(now: -> { Time.now.utc })
    Dir.mktmpdir do |dir|
      yield RefurbRadar::ControlStore.new(File.join(dir, "controls.json"), now: now)
    end
  end

  def with_event_log
    Dir.mktmpdir do |dir|
      yield RefurbRadar::EventLog.new(File.join(dir, "events.jsonl"))
    end
  end

  def with_default_external(encoding)
    previous = Encoding.default_external
    silence_warnings { Encoding.default_external = encoding }
    yield
  ensure
    silence_warnings { Encoding.default_external = previous }
  end

  def with_timezone(timezone)
    previous = ENV["TZ"]
    ENV["TZ"] = timezone
    yield
  ensure
    previous ? ENV["TZ"] = previous : ENV.delete("TZ")
  end

  def silence_warnings
    previous = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = previous
  end

  def build_not_buyable_streak(store, state, candidate, from:, passes: RefurbRadar::StateStore::AVAILABILITY_STABLE_PASSES)
    now = from
    passes.times do
      store.alertable_candidates(
        state: state,
        visible_candidates: [candidate],
        buyable_candidates: [],
        not_buyable_candidates: [candidate],
        checked_at: now
      )
      now += 30
    end
    now
  end

  def candidate(part_number:, model:, memory:, capacity:)
    RefurbRadar::Candidate.new(
      part_number: part_number,
      title: part_number,
      url: "https://www.apple.com/ca/shop/product/#{part_number}",
      model: model,
      memory: memory,
      capacity: capacity
    )
  end

  class ExplodingEventLog
    def append_many(_events)
      raise Encoding::InvalidByteSequenceError, "\"\\xE2\" on US-ASCII"
    end

    def read
      []
    end
  end

  class FakeFetcher
    def initialize(responses)
      @responses = responses
    end

    def get(url)
      @responses.fetch(url)
    rescue KeyError
      raise RefurbRadar::FetchError, "unexpected URL #{url}"
    end
  end

  class SequencedFetcher
    def initialize(responses)
      @responses = responses.transform_values(&:dup)
    end

    def get(url)
      values = @responses.fetch(url)
      value = values.length > 1 ? values.shift : values.first
      raise value if value.is_a?(StandardError)

      value
    rescue KeyError
      raise RefurbRadar::FetchError, "unexpected URL #{url}"
    end

    def get_with_metadata(url)
      RefurbRadar::FetchResult.new(
        body: get(url),
        headers: {},
        code: "200",
        duration_seconds: 0.01,
        url: url
      )
    end
  end

  class ExplodingFetcher
    def get(url)
      raise RefurbRadar::FetchError, "unexpected fetch #{url}"
    end

    def get_with_metadata(url)
      raise RefurbRadar::FetchError, "unexpected fetch #{url}"
    end
  end

  class FakeBuyabilityClient
    attr_reader :calls

    def initialize(responses)
      @responses = responses.dup
      @calls = []
    end

    def fetch(part_numbers)
      @calls << part_numbers.sort
      flags = @responses.length > 1 ? @responses.shift : @responses.first
      RefurbRadar::BuyabilityClient::Result.new(
        flags: flags,
        metadata: {
          "server_timing" => "app;dur=0.010",
          "cache_control" => "no-store"
        }
      )
    end
  end

  class CountingCatalogStore < RefurbRadar::CatalogStore
    attr_reader :save_count

    def initialize(path)
      super
      @save_count = 0
    end

    def save(catalog)
      @save_count += 1
      super
    end
  end

  class RecordingAlerter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def alert_with_receipts(candidate, channels: nil, muted: [])
      @calls << {
        candidate: candidate,
        channels: channels
      }
      delivered = Array(channels || "fake") - muted
      RefurbRadar::AlertResult.new(
        receipts: delivered.map do |channel|
          RefurbRadar::AlertReceipt.new(channel: channel, success: true, provider_id: "fake")
        end,
        suppressed_channels: Array(channels || []) & muted
      )
    end
  end

  # Models the production alerter: only the listed channel keys are live, so
  # nominal channels the alerter is not configured for never deliver. This is
  # what makes a paused-SMS buyable alert fully suppress in tests.
  class ChannelRecordingAlerter
    attr_reader :calls

    def initialize(channel_keys)
      @channel_keys = channel_keys
      @calls = []
    end

    def alerts_channel?(key)
      @channel_keys.include?(key)
    end

    def alert_with_receipts(candidate, channels: nil, muted: [])
      requested = channels ? channels & @channel_keys : @channel_keys
      delivered = requested - muted
      @calls << { kind: candidate.alert_kind, channels: delivered } unless delivered.empty?
      RefurbRadar::AlertResult.new(
        receipts: delivered.map do |channel|
          RefurbRadar::AlertReceipt.new(channel: channel, success: true, provider_id: "fake")
        end,
        suppressed_channels: requested & muted
      )
    end
  end

  class FailingSmsRecordingAlerter
    attr_reader :calls

    def initialize
      @channel_keys = %w[twilio_sms twilio_call]
      @calls = []
    end

    def alert_with_receipts(_candidate, channels: nil, muted: [])
      delivered = (Array(channels) & @channel_keys) - muted
      @calls << { channels: delivered } unless delivered.empty?
      RefurbRadar::AlertResult.new(
        receipts: delivered.map do |channel|
          RefurbRadar::AlertReceipt.new(
            channel: channel,
            success: channel != "twilio_sms",
            provider_id: channel == "twilio_sms" ? nil : "fake",
            error: channel == "twilio_sms" ? "sms quota exceeded" : nil
          )
        end,
        suppressed_channels: Array(channels) & muted
      )
    end
  end

  class SlowFetcher
    attr_reader :max_active

    def initialize(responses)
      @responses = responses
      @active = 0
      @max_active = 0
      @mutex = Mutex.new
    end

    def get(url)
      @mutex.synchronize do
        @active += 1
        @max_active = [@max_active, @active].max
      end
      sleep 0.02
      @responses.fetch(url)
    rescue KeyError
      raise RefurbRadar::FetchError, "unexpected URL #{url}"
    ensure
      @mutex.synchronize { @active -= 1 }
    end
  end

  class FakeHTTP
    attr_reader :starts

    def initialize(responses)
      @responses = responses
      @starts = 0
    end

    def start(_host, _port, **_options)
      @starts += 1
      if block_given?
        yield self
      else
        self
      end
    end

    def started?
      true
    end

    def request(_request)
      @responses.shift || raise("no fake response")
    end
  end

  class RejectingSessionFetcher
    attr_reader :calls

    def initialize(grid_url:, target_url:)
      @grid_url = grid_url
      @target_url = target_url
      @target_attempts = 0
      @cookie_version = 0
      @calls = []
    end

    def get_with_metadata(url, headers: {})
      @calls << [url, headers["Cookie"]]
      if url == @grid_url
        @cookie_version += 1
        RefurbRadar::FetchResult.new(body: "grid", headers: { "set-cookie" => "aos=#{@cookie_version}; Path=/" }, code: "200")
      elsif url == @target_url
        @target_attempts += 1
        raise RefurbRadar::FetchError, "GET #{url} failed with HTTP 403" if @target_attempts == 1

        RefurbRadar::FetchResult.new(body: "ok", headers: {}, code: "200")
      else
        raise RefurbRadar::FetchError, "unexpected URL #{url}"
      end
    end
  end

  class AdvancingSleeper
    attr_reader :delays

    def initialize(&advance)
      @advance = advance
      @delays = []
    end

    def sleep(seconds)
      @delays << seconds
      @advance.call(seconds)
    end
  end

  def fake_response(klass, code, message, body: "")
    klass.new("1.1", code, message).tap do |response|
      response.define_singleton_method(:body) { body }
    end
  end

  class FakeAlerter
    attr_reader :alerted

    def initialize
      @alerted = []
    end

    def alert(candidate)
      @alerted << candidate
      true
    end
  end

  class FakeAlertChannel
    def initialize(result, channel: "fake")
      @result = result
      @channel = channel
    end

    def alert(_candidate)
      @result
    end

    def alert_with_receipt(_candidate)
      RefurbRadar::AlertReceipt.new(channel: @channel, success: @result, error: @result ? nil : "fake failure")
    end
  end

  class FakeTwilioClient
    attr_reader :sms_requests, :call_requests, :from, :messaging_service_sid

    def initialize(from: "+15555550000", messaging_service_sid: nil)
      @from = from
      @messaging_service_sid = messaging_service_sid
      @sms_requests = []
      @call_requests = []
    end

    def send_sms(to:, body:)
      @sms_requests << { to: to, body: body }
      FakeTwilioResponse.new(true, "SM123")
    end

    def place_call(to:, twiml:)
      @call_requests << { to: to, twiml: twiml }
      FakeTwilioResponse.new(true, "CA123")
    end
  end

  class FakeTwilioResponse
    attr_reader :sid

    def initialize(success, sid)
      @success = success
      @sid = sid
    end

    def success?
      @success
    end

    def error_message
      "fake error"
    end
  end

  class FakeCheck
    attr_reader :runs

    def initialize(results, before_run: nil)
      @results = results
      @before_run = before_run
      @runs = 0
    end

    def run
      @before_run&.call
      @runs += 1
      @results.fetch(@runs - 1)
    end
  end

  class FakeCatalogRefresh
    attr_reader :runs

    def initialize
      @runs = 0
    end

    def run
      @runs += 1
      RefurbRadar::CatalogRefresh::Result.new(
        checked_at: Time.utc(2026, 6, 9, 16, 48, 5),
        catalog: {
          "updated_at" => "2026-06-09T16:48:05Z",
          "products" => [
            { "part_number" => "G1CD5LL/A", "url" => "https://www.apple.com/ca/shop/product/G1CD5LL/A" }
          ]
        },
        discovered_candidates: [
          RefurbRadar::Candidate.new(part_number: "G1CD5LL/A")
        ],
        warnings: []
      )
    end
  end

  module FakeSleeper
    def self.sleep(_seconds)
      raise "sleep should not be called"
    end
  end
end
