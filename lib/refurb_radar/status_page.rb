# frozen_string_literal: true

require "cgi"
require "erb"

module RefurbRadar
  # The watcher's page, structured around the moments its one user actually
  # opens it: a drop in progress (triage and buy), "did I miss something?"
  # (the story log), "is it even working?" (verdict + proof-of-life chain,
  # with a live test), "what is it hunting?" (the contract line), and
  # "pause the calls" (mute strip). Anything that maps to none of those
  # moments stays off the page.
  class StatusPage
    STORY_LIMIT = 8
    CONTACT_BURST_SECONDS = 3600
    CONTACT_DELTA_SECONDS = 3600

    DEFAULT_TARGETS_PATH = File.expand_path("../../config/targets.json", __dir__)

    MUTE_CHOICES = [["twilio_call", "calls"], ["twilio_sms", "texts"], ["both", "both"]].freeze

    # The slower store-wide catalog refresh is the only surface that sees
    # products outside the rules, so "listed now" means last seen by it within
    # a few refresh cycles.
    STORE_FRESH_SECONDS = 2 * 3600
    MISS_ROW_LIMIT = 3

    def initialize(state_path:, catalog_path:, control_store: nil, event_log: NullEventLog.new,
                   targets_path: DEFAULT_TARGETS_PATH, test_receipt_path: nil,
                   public_url: nil, base_path: "", env: ENV, now: -> { Time.now.utc })
      @state_path = state_path
      @catalog_path = catalog_path
      @control_store = control_store
      @event_log = event_log
      @targets_path = targets_path
      @test_receipt_path = test_receipt_path
      @public_url = public_url
      @base_path = base_path.to_s.sub(%r{/+\z}, "")
      @env = env
      @now = now
    end

    def render
      snapshot = snapshot()
      ERB.new(template, trim_mode: "-").result(binding)
    end

    private

    def snapshot
      inventory = InventorySnapshot.new(
        state_path: @state_path,
        catalog_path: @catalog_path,
        control_store: @control_store,
        event_log: @event_log,
        targets_path: @targets_path,
        test_receipt_path: @test_receipt_path,
        public_url: @public_url,
        base_path: @base_path,
        env: @env,
        now: @now
      ).to_h
      seen = inventory.fetch(:seen)
      history = inventory.fetch(:history)
      active_products = inventory.fetch(:active_products)
      products = inventory.fetch(:products)
      products_by_part = inventory.fetch(:products_by_part)
      drop = inventory.fetch(:drop)
      events = inventory.fetch(:events)
      scoped_seen = inventory.fetch(:scoped_seen)
      scoped_history = inventory.fetch(:scoped_history)
      scoped_events = inventory.fetch(:scoped_events)
      story_rows = stories(scoped_seen, scoped_history, products_by_part, drop, scoped_events)
      rules, rules_fault = begin
        [rule_groups(active_products, products_by_part, seen, history, events), nil]
      rescue StandardError => error
        [[], "#{@targets_path}: #{error.message}"]
      end

      inventory.merge(
        last_contact: last_contact(story_rows),
        stories: story_rows,
        rules: rules,
        addable: addable_models(active_products, rules),
        log_began: events.filter_map { |event| parse_time(event["checked_at"]) }.min,
        faults: inventory.fetch(:faults) + [rules_fault].compact
      )
    end

    def mute_phrase(muted)
      muted.map { |channel| channel[:label] }.join(" & ")
    end

    def clause_parts(min_memory, max_memory, cores, capacity, price, screen_size = nil, chip_family = nil)
      parts = []
      parts << "#{format_screen_size(screen_size)}" if screen_size
      parts << "#{format_chip_family(chip_family)} chip" if chip_family
      parts << memory_clause(min_memory, max_memory) if min_memory || max_memory
      parts << "#{cores}-core+ CPU" if cores
      parts << "up to #{format_gb(capacity)} SSD" if capacity
      parts << "under #{format_price(price)}" if price
      parts
    end

    def memory_clause(min_memory, max_memory)
      if min_memory && max_memory
        min_memory == max_memory ? "#{min_memory}GB RAM" : "#{min_memory}-#{max_memory}GB RAM"
      elsif min_memory
        "#{min_memory}GB+ RAM"
      else
        "up to #{max_memory}GB RAM"
      end
    end

    def last_contact(stories)
      story = stories.find { |entry| entry[:last_alert_at] || entry[:available_at] }
      return nil unless story

      {
        title: story[:title],
        gone_day: day(story[:last_alert_at] || story[:available_at]),
        held: story[:held]
      }
    end

    # One story per product run, stitched from the event log (the worker's
    # not_buyable transition erases ladder keys from state, so events are the
    # only complete record of what happened and how fast).
    def stories(seen, history, products_by_part, drop, events)
      drop_parts = drop.map { |row| row[:part_number] }
      ended_by_part = history.group_by { |record| record["part_number"] }
      parts = (events.map { |event| event["part_number"] } + ended_by_part.keys).compact.uniq - drop_parts

      parts.filter_map do |part|
        story(
          part,
          events.select { |event| event["part_number"] == part },
          ended_by_part[part]&.last,
          seen[part],
          products_by_part[part]
        )
      end.sort_by { |story| story[:at] }.reverse.first(STORY_LIMIT)
    rescue StandardError
      []
    end

    def story(part, events, ended, current, product)
      listed_at = event_time(events, "listing_event") || parse_time((ended || current || {})["first_detected_at"])
      flip_at = event_time(events, "buyability_flip")
      contacts = contact_attempts(events)
      first_contact_at = contacts.first && contacts.first[:at]
      last_contact = contacts.last
      gone_at = parse_time(ended&.fetch("disappeared_at", nil))
      # A part number can recur across days; a disappearance older than this
      # episode's events belongs to a previous episode, not this one.
      gone_at = nil if gone_at && [listed_at, flip_at, first_contact_at].compact.any? { |time| gone_at < time }
      return nil unless flip_at || first_contact_at

      beats = []
      beats << "became buyable #{day_clock(flip_at)}" if flip_at
      contacts.each { |contact| beats << alert_beat(contact, flip_at) }
      beats << "alerts muted" if events.any? { |event| event["type"] == "alert_suppressed" }
      beats << ending_beat(flip_at, gone_at, current, first_contact_at)
      at = [last_contact && last_contact[:at], flip_at].compact.max
      title = clean_title((product || ended || current || {})["title"])
      held = duration_between(flip_at, gone_at)

      {
        at: at,
        ended_at: gone_at,
        day: day(at),
        available_at: flip_at,
        last_alert_at: last_contact && last_contact[:at],
        spec: product ? spec_line(product, ended || current || {}) : title,
        title: title,
        price: format_price(product && product["price"]),
        held: held,
        beats: beats.compact
      }
    end

    def event_time(events, type)
      event = events.find { |entry| entry["type"] == type }
      event && parse_time(event["checked_at"])
    end

    def contact_attempts(events)
      attempts = events.select { |entry| entry["type"] == "alert_attempt" && entry["success"] }
                       .filter_map { |event| contact_attempt(event) }
                       .sort_by { |attempt| attempt[:at] }
      latest_contact_burst(attempts).each_with_object([]) do |attempt, burst|
        burst << attempt unless burst.any? { |existing| existing[:channel] == attempt[:channel] }
      end
    end

    def contact_attempt(event)
      at = parse_time(event["checked_at"])
      at && { channel: event["channel"], label: contact_label(event["channel"]), at: at }
    end

    def contact_label(channel)
      {
        "twilio_sms" => "texted you",
        "twilio_call" => "called you",
        "browser" => "opened page",
        "command" => "ran alert command"
      }.fetch(channel.to_s, channel.to_s)
    end

    def latest_contact_burst(attempts)
      return [] if attempts.empty?

      latest = attempts.last[:at]
      attempts.reverse.take_while { |attempt| latest - attempt[:at] <= CONTACT_BURST_SECONDS }.reverse
    end

    def alert_beat(contact, since)
      at = contact[:at]
      verb = contact[:label]
      if since && at >= since && at - since <= CONTACT_DELTA_SECONDS
        "#{verb} in #{(at - since).round}s"
      else
        "#{verb} #{day_clock(at)}"
      end
    end

    def ending_beat(flip_at, gone_at, current, first_contact_at)
      if gone_at && flip_at
        "gone #{day_clock(gone_at)} · buyable for #{duration(gone_at - flip_at)}"
      elsif gone_at && first_contact_at
        "no longer tracked #{day_clock(gone_at)}"
      elsif current && current["last_buyable_at"].nil?
        "no longer buyable"
      end
    end

    # The watch list is the editor: one group per rule, the configs it
    # matches nested beneath it, plus the rule's own evidence — what it would
    # have done, replayed from the event log, and what it excludes by one
    # constraint. A product belongs to the first rule that matches it.
    def rule_groups(products, products_by_part, seen, history, events)
      return [] unless File.exist?(@targets_path)

      matcher = Matcher.new(rules: Matcher.rules_from_file(@targets_path))
      last_buyable_by_part = last_buyable_index(seen, history)
      assigned = products.group_by do |product|
        candidate = Config.candidate_from_product(product)
        matcher.rules.find_index { |rule| matcher.shortfalls(candidate, rule).empty? }
      end
      episodes = flip_episodes(events, products_by_part)

      matcher.rules.each_with_index.map do |rule, index|
        matched = assigned[index] || []
        prices = matched.filter_map { |product| product["price"] }
        configs = config_rows(matched, seen, last_buyable_by_part)
        {
          index: index,
          models: rule.models,
          label: rule.models.map { |model| model_label(model) }.join(" & "),
          clauses: clause_parts(
            rule.min_memory_gb,
            rule.max_memory_gb,
            rule.min_cpu_cores,
            rule.max_capacity_gb,
            rule.max_price,
            rule.screen_size_inches,
            rule.chip_family
          ),
          configs: configs,
          summary: config_summary(configs),
          sku_count: matched.length,
          min_price: format_price(prices.min_by(&:to_f)),
          tune: tune_options(rule, matcher, products),
          proof: proof(rule, matcher, episodes, products, seen)
        }
      end
    end

    # Rows live inside a per-product card, so the spec is just memory · SSD.
    # A buyable config carries its own link to the product page — seeing
    # "buyable" and buying it are the same moment.
    def config_rows(matched, seen, last_buyable_by_part)
      matched.group_by { |product| [product_screen_size(product), product_chip_family(product), product["memory"], product["capacity"]] }
             .map do |(screen_size, chip_family, memory, capacity), group|
               parts = group.map { |product| product["part_number"] }
               buyable = group.select { |product| seen[product["part_number"]]&.fetch("last_buyable_at", nil) }
               buyable_parts = buyable.map { |product| product["part_number"] }
               listed_parts = parts.select { |part| seen[part]&.fetch("listed_present", nil) && !buyable_parts.include?(part) }
               checked_parts = parts.select { |part| seen.key?(part) }
               checked_not_buyable_parts = checked_parts - buyable_parts - listed_parts
               catalog_only_parts = parts - checked_parts
               cheapest_buyable = buyable.min_by { |product| product["price"].to_f }
               prices = group.filter_map { |product| product["price"] }.uniq
               last_catalog_seen = group.filter_map { |product| parse_time(product["last_seen_at"]) }.max
               {
                 spec: [format_screen_size(screen_size), format_chip_family(chip_family), format_memory(memory), format_capacity(capacity)].compact.join(" · "),
                 price: format_price(prices.min_by(&:to_f)),
                 price_from: prices.length > 1,
                 sku_count: parts.length,
                 available: buyable.length,
                 buyable: buyable.length,
                 buy_url: cheapest_buyable && (cheapest_buyable["url"] || RefurbRadar.short_product_url(cheapest_buyable["part_number"])),
                 listed: listed_parts.length,
                 checked: checked_parts.length,
                 checked_not_buyable: checked_not_buyable_parts.length,
                 catalog_only: catalog_only_parts.length,
                 last_catalog_seen: last_catalog_seen,
                 last_available: parts.filter_map { |part| last_buyable_by_part[part] }.max
               }
             end
             .sort_by { |row| [row[:available].positive? ? 0 : (row[:listed].positive? ? 1 : 2), row[:spec]] }
    end

    def config_summary(configs)
      {
        configs: configs.length,
        skus: configs.sum { |row| row[:sku_count] },
        buyable: configs.sum { |row| row[:buyable] },
        listed: configs.sum { |row| row[:listed] },
        checked_not_buyable: configs.sum { |row| row[:checked_not_buyable] },
        catalog_only: configs.sum { |row| row[:catalog_only] }
      }
    end

    # Dropdown choices mostly come from the store itself, with a small
    # model-aware set for known thresholds that might not be listed today.
    def tune_options(rule, matcher, products)
      pool = products.select { |product| rule.models.include?(product["model"]) }
      tuned_pool = if rule.chip_family
        pool.select { |product| Matcher.normalize_chip_family(product_chip_family(product)) == rule.chip_family }
      else
        pool
      end
      matrix = ProductMatrix.default.choices(models: rule.models, chip_family: rule.chip_family)
      all_chips = ProductMatrix.default.choices(models: rule.models)[:chip]
      memory_values = choice_values(
        tuned_pool.map { |product| matcher.memory_gb(product["memory"]) } + matrix[:memory],
        rule.min_memory_gb,
        rule.max_memory_gb
      )
      {
        memory: memory_values,
        max_memory: memory_values,
        cores: choice_values(tuned_pool.map { |product| matcher.candidate_cpu_cores(Config.candidate_from_product(product)) } + matrix[:cores], rule.min_cpu_cores),
        capacity: choice_values(tuned_pool.map { |product| matcher.capacity_gb(product["capacity"]) } + matrix[:capacity], rule.max_capacity_gb),
        screen_size: choice_values(tuned_pool.map { |product| product_screen_size(product) }, rule.screen_size_inches),
        chip: choice_values(pool.map { |product| product_chip_family(product) } + all_chips, rule.chip_family),
        current: {
          memory: rule.min_memory_gb,
          max_memory: rule.max_memory_gb,
          cores: rule.min_cpu_cores,
          capacity: rule.max_capacity_gb,
          price: rule.max_price,
          screen_size: rule.screen_size_inches,
          chip: rule.chip_family
        }
      }
    end

    def choice_values(values, *current)
      (values + current).compact.uniq.sort
    end

    # A part number can flip buyable many times during one drop; a proof
    # episode is one part on one day. Parts the catalog no longer knows are
    # skipped — without specs there is nothing to judge.
    def flip_episodes(events, products_by_part)
      events.select { |event| event["type"] == "buyability_flip" }
            .group_by { |event| [event["part_number"], day(parse_time(event["checked_at"]))] }
            .filter_map do |(part, _day), group|
              product = products_by_part[part]
              next unless product

              {
                at: group.filter_map { |event| parse_time(event["checked_at"]) }.min,
                product: product,
                candidate: Config.candidate_from_product(product)
              }
            end
    end

    # The rule's evidence: replayed drops it would have caught, and near
    # misses from those drops and the recent catalog that it excludes by a
    # single constraint, each with a one-click loosen.
    def proof(rule, matcher, episodes, products, seen)
      relevant = episodes.select { |episode| rule.models.include?(episode[:candidate].model) }
      hits = relevant.select { |episode| matcher.shortfalls(episode[:candidate], rule).empty? }
                     .sort_by { |episode| episode[:at] }
      drop_misses = relevant.filter_map do |episode|
        near_miss(episode[:candidate], episode[:product], rule, matcher, source: "drop", at: episode[:at])
      end
      flip_parts = relevant.map { |episode| episode[:product]["part_number"] }
      store_misses = products.filter_map do |product|
        next unless rule.models.include?(product["model"])
        next if flip_parts.include?(product["part_number"])
        next unless on_store_now?(product, seen)

        candidate = Config.candidate_from_product(product)
        next if matcher.eligible?(candidate)

        near_miss(candidate, product, rule, matcher, source: "store")
      end

      {
        fired: hits.length,
        latest_hit: hits.last && hit_row(hits.last),
        misses: collapse_misses(drop_misses + store_misses)
      }
    end

    def hit_row(episode)
      product = episode[:product]
      {
        day: day(episode[:at]),
        spec: [
          format_screen_size(product_screen_size(product)),
          format_chip_family(product_chip_family(product)),
          format_memory(product["memory"]),
          format_capacity(product["capacity"])
        ].compact.join(" · "),
        price: format_price(product["price"])
      }
    end

    def near_miss(candidate, product, rule, matcher, source:, at: nil)
      fails = matcher.shortfalls(candidate, rule) - [:model]
      if fails.empty?
        nil
      else
        {
          spec: miss_spec(product, matcher),
          price: product["price"],
          fails: fails,
          source: source,
          day: at && day(at),
          loosen: fails.length == 1 ? loosen_for(fails.first, candidate, rule, matcher) : nil
        }
      end
    end

    def miss_spec(product, matcher)
      cores = matcher.candidate_cpu_cores(Config.candidate_from_product(product))
      [
        format_screen_size(product_screen_size(product)),
        format_chip_family(product_chip_family(product)),
        format_memory(product["memory"]),
        format_capacity(product["capacity"]),
        cores && "#{cores}-core"
      ]
        .compact.join(" · ")
    end

    def collapse_misses(misses)
      rows = misses.group_by { |miss| [miss[:spec], miss[:fails], miss[:source]] }
                   .map do |_, group|
                     group.first.merge(
                       count: group.length,
                       price: format_price(group.filter_map { |miss| miss[:price] }.min_by(&:to_f))
                     )
                   end
                   .sort_by { |miss| [miss[:loosen] ? 0 : 1, miss[:source] == "drop" ? 0 : 1, miss[:spec]] }
      shown = rows.first(MISS_ROW_LIMIT)
      rest = rows.drop(MISS_ROW_LIMIT)
      { rows: shown, more: rest.sum { |miss| miss[:count] } }
    end

    def loosen_for(field, candidate, rule, matcher)
      current = {
        memory: rule.min_memory_gb, max_memory: rule.max_memory_gb, cores: rule.min_cpu_cores,
        capacity: rule.max_capacity_gb, price: rule.max_price,
        screen_size: rule.screen_size_inches, chip: rule.chip_family
      }
      case field
      when :memory
        value = matcher.memory_gb(candidate.memory)
        if rule.max_memory_gb && value && value > rule.max_memory_gb
          { label: "allow up to #{value}GB", params: current.merge(max_memory: value) }
        else
          { label: value ? "allow #{value}GB+" : "allow any RAM", params: current.merge(memory: value) }
        end
      when :cores
        value = matcher.candidate_cpu_cores(candidate)
        { label: value ? "allow #{value}-core+" : "allow any CPU", params: current.merge(cores: value) }
      when :capacity
        value = matcher.capacity_gb(candidate.capacity)
        { label: value ? "allow up to #{format_gb(value)}" : "allow any SSD", params: current.merge(capacity: value) }
      when :price
        value = matcher.price_dollars(candidate.price)&.ceil
        { label: value ? "allow up to #{format_price(value)}" : "drop the price cap", params: current.merge(price: value) }
      when :screen_size
        value = candidate.screen_size_inches
        { label: value ? "allow #{format_screen_size(value)}" : "allow any size", params: current.merge(screen_size: value) }
      when :chip
        value = candidate.chip_family
        { label: value ? "allow #{format_chip_family(value)}" : "allow any chip", params: current.merge(chip: value) }
      end
    end

    # "Still on the store" for products outside the rules can only come from
    # the catalog's last_seen_at — the fast loop never checks them.
    def on_store_now?(product, seen)
      return true if seen.key?(product["part_number"])

      last_seen = parse_time(product["last_seen_at"])
      last_seen && @now.call - last_seen < STORE_FRESH_SECONDS
    end

    def addable_models(products, groups)
      watched = groups.flat_map { |group| group[:models] }
      products.reject { |product| watched.include?(product["model"]) }
              .group_by { |product| product["model"] }
              .map do |model, list|
                prices = list.filter_map { |product| product["price"] }
                {
                  model: model,
                  label: model_label(model),
                  configs: list.group_by { |product| [product_screen_size(product), product_chip_family(product), product["memory"], product["capacity"]] }.length,
                  skus: list.length,
                  price_range: price_range(prices)
                }
              end
              .sort_by { |row| row[:label] }
    end

    def price_range(prices)
      sorted = prices.sort_by(&:to_f)
      low = format_price(sorted.first)
      high = format_price(sorted.last)
      low == high ? low : "#{low}–#{high}"
    end

    def last_buyable_index(seen, history)
      (seen.values + history).each_with_object({}) do |record, index|
        at = parse_time(record["last_buyable_at"] || record["buyable_alerted_at"])
        next unless at

        part = record["part_number"]
        index[part] = [index[part], at].compact.max
      end
    end

    def parse_time(value)
      Time.parse(value.to_s).utc unless value.to_s.empty?
    rescue ArgumentError
      nil
    end

    def clean_title(title)
      title.to_s.sub(/\ARefurbished\s+/i, "").strip
    end

    def spec_line(product, record)
      parts = [
        product["model"] && model_label(product["model"]),
        format_screen_size(product_screen_size(product)),
        format_chip_family(product_chip_family(product)),
        format_memory(product["memory"]),
        format_capacity(product["capacity"])
      ].compact
      parts.empty? ? clean_title(product["title"] || record["title"]) : parts.join(" · ")
    end

    def product_screen_size(product)
      product["screen_size_inches"] || Config.screen_size_inches(product["title"])
    end

    def product_chip_family(product)
      product["chip_family"] || Config.chip_family_key(product["title"])
    end

    def model_label(model)
      {
        "macmini" => "Mac mini",
        "macstudio" => "Mac Studio",
        "macbookpro" => "MacBook Pro",
        "macbookair" => "MacBook Air",
        "imac" => "iMac",
        "macpro" => "Mac Pro",
        "visionpro" => "Apple Vision Pro"
      }.fetch(model.to_s, model.to_s)
    end

    def format_memory(memory)
      memory.to_s =~ /\A(\d+)gb\z/ ? "#{$1}GB" : memory
    end

    def format_capacity(capacity)
      case capacity.to_s
      when /\A(\d+)gb\z/ then "#{$1}GB"
      when /\A(\d+)tb\z/ then "#{$1}TB"
      when /\A(\d+)point(\d+)tb\z/ then "#{$1}.#{$2}TB"
      else capacity
      end
    end

    def format_screen_size(size)
      return nil if size.to_s.empty?

      number = size.to_f
      label = number == number.to_i ? number.to_i.to_s : number.to_s
      "#{label}-inch"
    end

    def format_chip_family(chip)
      normalized = Matcher.normalize_chip_family(chip)
      return nil unless normalized

      normalized.sub(/\Am(\d)/i, 'M\1')
                .sub(/pro\z/i, " Pro")
                .sub(/max\z/i, " Max")
                .sub(/ultra\z/i, " Ultra")
    end

    def format_gb(gigabytes)
      gigabytes.to_i >= 1024 ? "#{gigabytes.to_i / 1024}TB" : "#{gigabytes}GB"
    end

    def format_price(price)
      return nil if price.to_s.empty?

      whole, cents = price.to_s.split(".")
      grouped = whole.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
      cents = cents.to_s.ljust(2, "0")[0, 2]
      cents == "00" ? "$#{grouped}" : "$#{grouped}.#{cents}"
    end

    def count_noun(count, noun)
      count == 1 ? noun : "#{noun}s"
    end

    def rule_summary(rule)
      summary = rule[:summary]
      parts = [
        "#{summary[:configs]} #{count_noun(summary[:configs], "Mac")} watched"
      ]
      parts << "from #{rule[:min_price]}" if rule[:min_price]
      parts << "#{summary[:skus]} #{count_noun(summary[:skus], "variant")} checked" if summary[:skus] > 1
      parts << if summary[:buyable].positive?
        "#{summary[:buyable]} buyable now"
      else
        "none buyable"
      end
      parts << "#{summary[:listed]} showing" if summary[:listed].positive?
      parts << "#{summary[:catalog_only]} not checked yet" if summary[:catalog_only].positive?
      parts.join(" · ")
    end

    def config_note(row)
      parts = []
      parts << "#{row[:sku_count]} #{count_noun(row[:sku_count], "variant")}" if row[:sku_count] > 1
      parts << "#{row[:listed]} showing now" if row[:listed].positive?

      if row[:available].zero? && row[:checked_not_buyable].positive?
        parts << if row[:checked_not_buyable] == 1
          "checked, not buyable"
        else
          "#{row[:checked_not_buyable]} checked, none buyable"
        end
      elsif row[:checked_not_buyable].positive?
        parts << "#{row[:checked_not_buyable]} checked, not buyable"
      end

      parts << "#{row[:catalog_only]} not checked yet" if row[:catalog_only].positive?
      parts << "seen #{day(row[:last_catalog_seen])}" if row[:checked].zero? && row[:last_catalog_seen]
      parts << "last buyable #{day(row[:last_available])}" if row[:last_available]
      parts.join(" · ")
    end

    def duration_between(start_time, end_time)
      return nil unless start_time && end_time

      duration(end_time - start_time)
    end

    def duration(seconds)
      seconds = seconds.to_i
      return "#{seconds}s" if seconds < 60

      minutes = seconds / 60
      return "#{minutes} min" if minutes < 60

      hours = minutes / 60
      minutes = minutes % 60
      return minutes.zero? ? "#{hours}h" : "#{hours}h #{minutes}m" if hours < 48

      "#{hours / 24} days"
    end

    def clock(time)
      time ? time.localtime.strftime("%H:%M:%S") : "?"
    end

    def clock_minute(time)
      time ? time.localtime.strftime("%H:%M") : "?"
    end

    def day_clock(time)
      time ? time.localtime.strftime("%b %-d %H:%M:%S") : "?"
    end

    def day(time)
      time ? time.localtime.strftime("%b %-d") : "?"
    end

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def template
      <<~'ERB'
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="refresh" content="20">
          <link rel="icon" href="data:,">
          <title>Refurb Radar</title>
          <style>
            :root {
              color-scheme: dark;
              --bg: #0c0e0d;
              --ink: #d9e3dc;
              --dim: #828f86;
              --faint: #4d5751;
              --rule: #242a26;
              --ok: #51d88a;
              --warn: #e8b339;
              --down: #f07567;
              --buy-ink: #07150c;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              background: var(--bg);
              color: var(--ink);
              font: 15px/1.55 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
            }
            main { width: min(760px, calc(100vw - 32px)); margin: 0 auto; padding: 26px 0 56px; }
            a { color: var(--ink); }
            p { margin: 0; }

            .zone { padding: 20px 0; border-top: 1px solid var(--rule); }
            .zone:first-child { border-top: 0; padding-top: 0; }
            .zone__label {
              font-size: 11px; letter-spacing: .22em; color: var(--faint);
              text-transform: uppercase; margin: 0 0 12px;
            }

            .verdict { display: flex; justify-content: space-between; gap: 12px 24px; flex-wrap: wrap; align-items: baseline; }
            .verdict h1 { margin: 0; font-size: clamp(22px, 5.4vw, 30px); line-height: 1.25; font-weight: 700; letter-spacing: -.01em; }
            .verdict--ok h1, .verdict--drop h1 { color: var(--ok); }
            .verdict--muted h1 { color: var(--warn); }
            .verdict--down h1 { color: var(--down); }
            .verdict--dim h1 { color: var(--dim); }
            .verdict__detail { color: var(--dim); margin-top: 4px; }
            .pulse { display: inline-block; inline-size: 9px; block-size: 9px; border-radius: 50%; background: var(--ok); margin-inline-start: 6px; vertical-align: 2px; animation: pulse 2.4s ease-in-out infinite; }
            .verdict--muted .pulse { background: var(--warn); animation: none; }
            .verdict--down .pulse, .verdict--dim .pulse { background: var(--faint); animation: none; }

            .mutes { display: flex; gap: 6px 14px; flex-wrap: wrap; font-size: 13px; color: var(--dim); align-items: baseline; }
            .mutes form { display: inline; margin: 0; }
            .mutes .is-muted { color: var(--warn); }
            details.mutes__menu { display: inline-flex; gap: 6px 14px; align-items: baseline; flex-wrap: wrap; }
            details.mutes__menu summary {
              list-style: none; cursor: pointer; color: var(--dim);
              text-decoration: underline; text-underline-offset: 3px; text-decoration-color: var(--rule);
            }
            details.mutes__menu summary::-webkit-details-marker { display: none; }
            details.mutes__menu summary:hover, details.mutes__menu[open] summary { color: var(--ink); text-decoration-color: var(--dim); }
            .mutes .unmute { color: var(--warn); font-weight: 700; text-decoration-color: color-mix(in oklab, var(--warn) 40%, transparent); }
            select, button {
              font: 12px ui-monospace, Menlo, monospace;
              background: transparent; color: var(--dim);
              border: 1px solid var(--rule); padding: 5px 9px; border-radius: 5px;
            }
            button { cursor: pointer; }
            button:hover, select:hover { color: var(--ink); border-color: var(--dim); }
            button.unmute { color: var(--warn); border-color: var(--warn); font-weight: 700; }

            .contract { color: var(--dim); margin-top: 14px; max-inline-size: 60ch; }
            .contract b { color: var(--ink); font-weight: 700; }

            .chain { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 6px 28px; margin-top: 16px; font-size: 13px; }
            .chain div { display: flex; gap: 10px; align-items: baseline; }
            .chain .k { color: var(--faint); min-inline-size: 88px; }
            .chain .ok { color: var(--ok); }
            .chain .warn, .chain .muted { color: var(--warn); }
            .chain .dead { color: var(--down); }
            .chain .unknown, .chain .off { color: var(--dim); }
            .chain .note { color: var(--dim); }

            details.test { margin-top: 14px; font-size: 13px; color: var(--dim); }
            details.test summary { cursor: pointer; inline-size: fit-content; }
            details.test summary:hover { color: var(--ink); }
            details.test form { margin: 8px 0 0; }
            .test__last { margin-top: 8px; }
            .test__fail { color: var(--down); }

            .drop-row { display: grid; grid-template-columns: 1fr auto; gap: 4px 18px; align-items: center; padding: 14px 0; border-top: 1px dashed var(--rule); }
            .drop-row:first-of-type { border-top: 0; }
            .drop-row .spec { font-size: 19px; font-weight: 700; }
            .drop-row .meta { grid-column: 1; color: var(--dim); font-size: 13px; }
            .buy {
              grid-row: 1 / span 2; grid-column: 2; align-self: center;
              background: var(--ok); color: var(--buy-ink);
              font-weight: 700; font-size: 16px; text-decoration: none; text-align: center;
              padding: 14px 22px; border-radius: 7px; white-space: nowrap;
            }
            .buy:hover { filter: brightness(1.12); }
            @media (max-width: 560px) {
              .drop-row { grid-template-columns: 1fr; }
              .buy { grid-row: auto; grid-column: 1; margin-top: 8px; padding-block: 15px; }
            }
            .nothing { color: var(--dim); max-inline-size: 64ch; }
            .nothing b { color: var(--ink); font-weight: 700; }

            .story { padding: 12px 0; border-top: 1px dashed var(--rule); }
            .story:first-of-type { border-top: 0; }
            .story__head { display: flex; gap: 14px; flex-wrap: wrap; align-items: baseline; }
            .story__day { color: var(--faint); font-size: 12px; min-inline-size: 52px; }
            .story__spec { font-weight: 700; }
            .story__price { color: var(--dim); font-size: 13px; }
            .story__beats { color: var(--dim); font-size: 13px; margin: 3px 0 0 66px; max-inline-size: 60ch; }
            @media (max-width: 560px) { .story__beats { margin-inline-start: 0; } }

            .rule { padding: 18px 0; border-top: 1px dashed var(--rule); }
            .rule:first-of-type { border-top: 0; padding-top: 4px; }
            .rule__head { display: flex; justify-content: space-between; gap: 8px 18px; flex-wrap: wrap; align-items: baseline; }
            .rule__sentence { font-weight: 700; font-size: 16px; }
            .rule__sentence .clauses { color: var(--dim); font-weight: 400; font-size: 14px; }
            .rule__result { color: var(--dim); font-size: 13px; margin-top: 2px; }
            .rule__result b { color: var(--ok); }

            /* Quiet text actions: the resting page is content, not chrome. */
            .act {
              background: none; border: 0; padding: 0; cursor: pointer;
              font: 13px ui-monospace, Menlo, monospace; color: var(--faint);
              text-decoration: underline; text-underline-offset: 3px; text-decoration-color: var(--rule);
            }
            .act:hover { color: var(--ink); border: 0; text-decoration-color: var(--dim); }

            .cfgs { margin-top: 10px; }
            /* Fixed spec and price columns so the eye scans down; whatever a
               row has to say sits right after the price, not at the margin. */
            .cfg { display: grid; grid-template-columns: minmax(13ch, auto) minmax(9ch, auto) 1fr; gap: 2px 14px; padding: 4px 0; font-size: 14px; align-items: baseline; }
            .cfg .spec { font-weight: 700; }
            .cfg .price { color: var(--dim); }
            .cfg .note { color: var(--faint); font-size: 13px; }
            .cfg .go { color: var(--ok); font-weight: 700; text-decoration: none; }
            .cfg .go:hover { text-decoration: underline; text-underline-offset: 3px; }

            details.edit { font-size: 13px; }
            /* Open: the editor drops to its own full-width row under the header. */
            details.edit[open] { flex-basis: 100%; order: 10; }
            details.edit summary { list-style: none; cursor: pointer; inline-size: fit-content; font: 13px ui-monospace, Menlo, monospace; color: var(--faint); text-decoration: underline; text-underline-offset: 3px; text-decoration-color: var(--rule); }
            details.edit summary::-webkit-details-marker { display: none; }
            details.edit summary:hover, details.edit[open] summary { color: var(--ink); }
            .editor { margin-top: 10px; border: 1px solid var(--rule); border-radius: 8px; padding: 14px 16px; }
            .editor__row { display: flex; gap: 10px 16px; flex-wrap: wrap; align-items: center; margin: 0; }
            .editor__row label { display: inline-flex; gap: 6px; align-items: center; font-size: 13px; color: var(--dim); }
            .editor input[type="number"] {
              font: 12px ui-monospace, Menlo, monospace; background: transparent; color: var(--dim);
              border: 1px solid var(--rule); padding: 5px 9px; border-radius: 5px; inline-size: 90px;
            }
            .editor button.apply { color: var(--ok); border-color: var(--ok); font-weight: 700; }
            .editor__exit { margin-top: 12px; padding-top: 10px; border-top: 1px dotted var(--rule); display: flex; justify-content: space-between; gap: 8px 18px; flex-wrap: wrap; align-items: baseline; font-size: 12px; color: var(--faint); }
            .editor__exit form { margin: 0; }
            .editor__exit .act { color: var(--down); text-decoration-color: color-mix(in oklab, var(--down) 40%, transparent); }

            .proof { margin-top: 12px; font-size: 13px; color: var(--faint); max-inline-size: 64ch; }
            .proof > * { padding: 1px 0; margin: 0; }
            .proof b { color: var(--dim); }
            .proof .ok { color: var(--ok); }
            .proof form { display: inline; margin: 0; }
            .proof .act { color: var(--warn); text-decoration-color: color-mix(in oklab, var(--warn) 40%, transparent); }
            .proof .act:hover { color: var(--ink); }

            details.add { margin-top: 20px; font-size: 14px; }
            details.add summary {
              list-style: none; cursor: pointer; inline-size: fit-content;
              color: var(--dim); border: 1px solid var(--rule); border-radius: 7px; padding: 10px 16px;
            }
            details.add summary::-webkit-details-marker { display: none; }
            details.add summary:hover, details.add[open] summary { color: var(--ink); border-color: var(--dim); }
            .add-row { display: grid; grid-template-columns: 1fr auto auto; gap: 4px 18px; padding: 8px 0; border-top: 1px dashed var(--rule); align-items: baseline; }
            .add-row:first-of-type { border-top: 0; margin-top: 12px; }
            .add-row .product { font-weight: 700; }
            .add-row .meta { color: var(--dim); font-size: 13px; text-align: end; }
            .add-row form { margin: 0; }
            .add-hint { color: var(--faint); font-size: 12px; margin-top: 10px; max-inline-size: 58ch; }

            .fault { color: var(--down); font-size: 13px; margin-top: 10px; }
            footer { color: var(--faint); font-size: 12px; margin-top: 26px; }
            footer a { color: var(--faint); }

            @keyframes pulse { 50% { opacity: .25; } }
            @media (prefers-reduced-motion: reduce) { .pulse { animation: none; } }
          </style>
        </head>
        <body>
          <main>
            <section class="zone verdict-zone">
              <div class="verdict verdict--<%= snapshot[:verdict][:tone] %>">
                <div>
                  <h1><%= h(snapshot[:verdict][:headline]) %><span class="pulse"></span></h1>
                  <% if snapshot[:verdict][:detail] -%>
                    <p class="verdict__detail"><%= h(snapshot[:verdict][:detail]) %></p>
                  <% end -%>
                </div>
                <div class="mutes">
                  <% muted = snapshot[:controls].select { |channel| channel[:paused] } -%>
                  <% if muted.any? -%>
                    <span class="is-muted"><%= h(muted.length == snapshot[:controls].length ? "notifications" : mute_phrase(muted)) %> muted<% if muted.length == 1 && muted.first[:paused_until] && !muted.first[:indefinite] %> until <%= h(clock_minute(muted.first[:paused_until])) %><% end %></span>
                    <form method="post" action="<%= h(snapshot[:base_path]) %>/controls/resume">
                      <input type="hidden" name="channel" value="both">
                      <button class="act unmute" type="submit">unmute</button>
                    </form>
                  <% else -%>
                    <% mute_choices = MUTE_CHOICES.select do |value, _label|
                         if value == "both"
                           snapshot[:controls].select { |channel| %w[twilio_call twilio_sms].include?(channel[:key]) }.all? { |channel| channel[:configured] }
                         else
                           channel = snapshot[:controls].find { |item| item[:key] == value }
                           channel.nil? || channel[:configured]
                         end
                       end -%>
                    <details class="mutes__menu">
                      <summary>mute notifications…</summary>
                      <% mute_choices.each do |value, label| -%>
                        <form method="post" action="<%= h(snapshot[:base_path]) %>/controls/pause">
                          <input type="hidden" name="channel" value="<%= h(value) %>">
                          <input type="hidden" name="duration" value="indefinite">
                          <button class="act" type="submit"><%= h(label) %></button>
                        </form>
                      <% end -%>
                    </details>
                  <% end -%>
                </div>
              </div>

              <% if snapshot[:hunting] -%>
                <% summary = snapshot[:watch_summary] -%>
                <p class="contract">
                  Hunting <b><%= h(snapshot[:hunting]) %></b> —
                  checking <%= summary[:checked] %> matching known config<%= summary[:checked] == 1 ? "" : "s" %> every ~10 seconds.
                  <%= summary[:listed] %> showing on Apple’s refurb page; <%= summary[:available] %> buyable now.
                </p>
              <% else -%>
                <p class="contract">Not watching anything yet — pick a product under What you're watching below.</p>
              <% end -%>

              <div class="chain">
                <% snapshot[:chain].each do |link| -%>
                  <div>
                    <span class="k"><%= h(link[:label]) %></span>
                    <span class="<%= link[:state] %>"><%=
                      case link[:state]
                      when "ok" then "✓"
                      when "muted" then "◌"
                      when "warn" then "!"
                      when "dead" then "✗"
                      when "off" then "—"
                      else "—"
                      end
                    %></span>
                    <span class="note"><% if link[:epoch] %><span data-epoch="<%= link[:epoch] %>">just now</span> ago<% else %><%= h(link[:note]) %><% end %></span>
                  </div>
                <% end -%>
              </div>

              <details class="test">
                <summary>Send a test alert</summary>
                <% calls_configured = snapshot[:controls].find { |channel| channel[:key] == "twilio_call" }&.fetch(:configured, true) -%>
                <% sms_configured = snapshot[:controls].find { |channel| channel[:key] == "twilio_sms" }&.fetch(:configured, true) -%>
                <% if calls_configured && sms_configured -%>
                  <p>Sends a real SMS and rings your phone, right now, to prove the path works.</p>
                <% elsif sms_configured -%>
                  <p>Sends a real SMS right now to prove the text path works. Phone calls are off by config; checking and texts stay on.</p>
                <% elsif calls_configured -%>
                  <p>Rings your phone right now to prove the call path works. Texts are off by config; checking stays on.</p>
                <% else -%>
                  <p>No Twilio alert channels are configured here. Checking and browser-open stay separate.</p>
                <% end -%>
                <% if calls_configured || sms_configured -%>
                  <form method="post" action="<%= h(snapshot[:base_path]) %>/controls/test">
                    <button type="submit"><%= calls_configured ? "Send test — ring my phone" : "Send test — text me" %></button>
                  </form>
                <% end -%>
                <% if snapshot[:test] && snapshot[:test][:tested_at] -%>
                  <p class="test__last">
                    Last test <%= h(day(snapshot[:test][:tested_at])) %> <%= h(clock(snapshot[:test][:tested_at])) %> —
                    <% if snapshot[:test][:receipts].empty? -%>
                      no Twilio channels configured here.
                    <% else -%>
                      <% snapshot[:test][:receipts].each do |receipt| -%>
                        <span class="<%= receipt[:success] ? "" : "test__fail" %>"><%= h(receipt[:channel] == "twilio_call" ? "call" : "text") %> <%= receipt[:success] ? "sent ✓" : "failed: #{h(receipt[:error])}" %></span>
                      <% end -%>
                    <% end -%>
                  </p>
                <% end -%>
              </details>

              <% snapshot[:faults].each do |fault| -%>
                <p class="fault">Data problem: <%= h(fault) %></p>
              <% end -%>
            </section>

            <section class="zone">
              <% if snapshot[:drop].any? -%>
                <% snapshot[:drop].each do |row| -%>
                  <div class="drop-row">
                    <span class="spec"><%= h(row[:spec]) %><%= row[:price] ? " — #{row[:price]}" : "" %></span>
                    <a class="buy" href="<%= h(row[:url]) %>">Buy →</a>
                    <span class="meta">
                      buyable <% if row[:buyable_since] %><span data-epoch="<%= row[:buyable_since].to_i %>">now</span><% end %>
                      <% row[:actions].each do |action| %> · <%= h(action) %><% end %>
                      · <%= h(row[:part_number]) %>
                    </span>
                  </div>
                <% end -%>
              <% else -%>
                <p class="nothing">
                  <b>Nothing buyable right now.</b>
                  <% if snapshot[:last_contact] -%>
                    Last alert <%= h(snapshot[:last_contact][:gone_day]) %>:
                    <%= h(snapshot[:last_contact][:title]) %><% if snapshot[:last_contact][:held] %>, buyable for <%= h(snapshot[:last_contact][:held]) %><% end %>.
                  <% end -%>
                </p>
              <% end -%>
            </section>

            <% if snapshot[:stories].any? -%>
              <section class="zone">
                <p class="zone__label">Alerts</p>
                <% snapshot[:stories].each do |story| -%>
                  <div class="story">
                    <div class="story__head">
                      <span class="story__day"><%= h(story[:day]) %></span>
                      <span class="story__spec"><%= h(story[:spec]) %></span>
                      <% if story[:price] -%><span class="story__price"><%= h(story[:price]) %></span><% end -%>
                    </div>
                    <p class="story__beats"><%= h(story[:beats].join(" → ")) %></p>
                  </div>
                <% end -%>
              </section>
            <% end -%>

            <section class="zone">
              <p class="zone__label">What you're watching</p>
              <% if snapshot[:rules].empty? -%>
                <p class="nothing"><b>Not watching anything.</b> Pick a product below — nothing is matched until you do.</p>
              <% end -%>
              <% snapshot[:rules].each do |rule| -%>
                <div class="rule">
                  <div class="rule__head">
                    <span class="rule__sentence"><%= h(rule[:label]) %> <span class="clauses">· <%= rule[:clauses].any? ? h(rule[:clauses].join(" · ")) : "any configuration" %></span></span>
                    <details class="edit">
                      <summary>edit</summary>
                      <div class="editor">
                        <form class="editor__row" method="post" action="<%= h(snapshot[:base_path]) %>/rules/update">
                          <input type="hidden" name="index" value="<%= rule[:index] %>">
                          <% if rule[:tune][:screen_size].any? -%>
                            <label>Size
                              <select name="screen_size">
                                <option value="">any</option>
                                <% rule[:tune][:screen_size].each do |value| -%>
                                  <option value="<%= value %>"<%= rule[:tune][:current][:screen_size] == value ? " selected" : "" %>><%= h(format_screen_size(value)) %></option>
                                <% end -%>
                              </select>
                            </label>
                          <% end -%>
                          <% if rule[:tune][:chip].any? -%>
                            <label>Chip
                              <select name="chip">
                                <option value="">any</option>
                                <% rule[:tune][:chip].each do |value| -%>
                                  <option value="<%= h(value) %>"<%= rule[:tune][:current][:chip] == value ? " selected" : "" %>><%= h(format_chip_family(value)) %></option>
                                <% end -%>
                              </select>
                            </label>
                          <% end -%>
                          <label>RAM
                            <select name="memory">
                              <option value="">any</option>
                              <% rule[:tune][:memory].each do |value| -%>
                                <option value="<%= value %>"<%= rule[:tune][:current][:memory] == value ? " selected" : "" %>><%= value %>GB or more</option>
                              <% end -%>
                            </select>
                          </label>
                          <label>Max RAM
                            <select name="max_memory">
                              <option value="">any</option>
                              <% rule[:tune][:max_memory].each do |value| -%>
                                <option value="<%= value %>"<%= rule[:tune][:current][:max_memory] == value ? " selected" : "" %>>up to <%= value %>GB</option>
                              <% end -%>
                            </select>
                          </label>
                          <% if rule[:tune][:cores].any? -%>
                            <label>CPU
                              <select name="cores">
                                <option value="">any</option>
                                <% rule[:tune][:cores].each do |value| -%>
                                  <option value="<%= value %>"<%= rule[:tune][:current][:cores] == value ? " selected" : "" %>><%= value %>-core or better</option>
                                <% end -%>
                              </select>
                            </label>
                          <% end -%>
                          <label>SSD
                            <select name="capacity">
                              <option value="">any</option>
                              <% rule[:tune][:capacity].each do |value| -%>
                                <option value="<%= value %>"<%= rule[:tune][:current][:capacity] == value ? " selected" : "" %>>up to <%= h(format_gb(value)) %></option>
                              <% end -%>
                            </select>
                          </label>
                          <label>under $
                            <input type="number" name="price" min="1" placeholder="no cap" value="<%= rule[:tune][:current][:price] %>">
                          </label>
                          <button class="apply" type="submit">Apply — live in ~10s</button>
                        </form>
                        <div class="editor__exit">
                          <span>choices come from known Apple configurations</span>
                          <form method="post" action="<%= h(snapshot[:base_path]) %>/rules/remove">
                            <input type="hidden" name="index" value="<%= rule[:index] %>">
                            <button class="act" type="submit">stop watching <%= h(rule[:label]) %></button>
                          </form>
                        </div>
                      </div>
                    </details>
                  </div>
                  <p class="rule__result">
                    <% if rule[:configs].any? -%>
                      <%= h(rule_summary(rule)) %>
                    <% else -%>
                      matches no known configs — new stock that fits will still be caught
                    <% end -%>
                  </p>
                  <% if rule[:configs].any? -%>
                    <div class="cfgs">
                      <% rule[:configs].each do |row| -%>
                        <div class="cfg">
                          <span class="spec"><%= h(row[:spec]) %></span>
                          <span class="price"><%= row[:price_from] ? "from " : "" %><%= h(row[:price]) %></span>
                          <span>
                            <% if row[:available].positive? -%>
                              <a class="go" href="<%= h(row[:buy_url]) %>"><%= row[:available] > 1 ? "#{row[:available]} buyable now" : "Buyable now" %> — Buy ↗</a>
                              <% note = config_note(row) -%>
                              <% if note && !note.empty? -%><span class="note"> · <%= h(note) %></span><% end -%>
                            <% elsif row[:listed].positive? -%>
                              <span class="note"><%= h(config_note(row)) %></span>
                            <% elsif row[:checked].positive? -%>
                              <span class="note"><%= h(config_note(row)) %></span>
                            <% elsif row[:last_catalog_seen] -%>
                              <span class="note"><%= h(config_note(row)) %></span>
                            <% elsif row[:sku_count] > 1 -%>
                              <span class="note"><%= h(config_note(row)) %></span>
                            <% end -%>
                          </span>
                        </div>
                      <% end -%>
                    </div>
                  <% end -%>
                  <% proof = rule[:proof] -%>
                  <% if proof[:fired].positive? || proof[:misses][:rows].any? -%>
                    <div class="proof">
                      <% if proof[:fired].positive? && proof[:latest_hit] -%>
                        <p><span class="ok">✓</span> caught the <%= h(proof[:latest_hit][:day]) %> drop — would have alerted <%= proof[:fired] == 1 ? "once" : "#{proof[:fired]} times" %> (<b><%= h(proof[:latest_hit][:spec]) %></b><% if proof[:latest_hit][:price] %>, <%= h(proof[:latest_hit][:price]) %><% end %>)</p>
                      <% end -%>
                      <% if proof[:misses][:rows].any? -%>
                        <div>
                          <%= proof[:fired].positive? ? "excludes:" : "no drop caught yet · excludes:" %>
                          <% proof[:misses][:rows].each_with_index do |miss, position| -%>
                            <%= position.zero? ? "" : " · " %><b><%= h(miss[:spec]) %></b><% if miss[:price] %> at <%= h(miss[:price]) %><% end %><% if miss[:count] > 1 %> (×<%= miss[:count] %>)<% end %>
                            <%= miss[:source] == "drop" ? "in the#{miss[:day] ? " #{h(miss[:day])}" : ""} drop" : "recently listed" %>
                            — <%= h(miss[:fails].map { |fail| { memory: "RAM range", cores: "CPU floor", capacity: "SSD cap", price: "price cap", screen_size: "screen size", chip: "chip" }.fetch(fail, fail.to_s) }.join(" + ")) %>
                            <% if miss[:loosen] -%>
                              <form method="post" action="<%= h(snapshot[:base_path]) %>/rules/update"><input type="hidden" name="index" value="<%= rule[:index] %>"><input type="hidden" name="memory" value="<%= miss[:loosen][:params][:memory] %>"><input type="hidden" name="max_memory" value="<%= miss[:loosen][:params][:max_memory] %>"><input type="hidden" name="cores" value="<%= miss[:loosen][:params][:cores] %>"><input type="hidden" name="capacity" value="<%= miss[:loosen][:params][:capacity] %>"><input type="hidden" name="price" value="<%= miss[:loosen][:params][:price] %>"><input type="hidden" name="screen_size" value="<%= miss[:loosen][:params][:screen_size] %>"><input type="hidden" name="chip" value="<%= h(miss[:loosen][:params][:chip]) %>"><button class="act" type="submit"><%= h(miss[:loosen][:label]) %></button></form>
                            <% end -%>
                          <% end -%>
                          <% if proof[:misses][:more].positive? %> · +<%= proof[:misses][:more] %> more<% end %>
                        </div>
                      <% end -%>
                    </div>
                  <% end -%>
                </div>
              <% end -%>

              <details class="add">
                <summary>＋ Watch another product</summary>
                <% if !snapshot[:catalog_known] -%>
                  <p class="add-hint">No store data yet — run bin/refresh-catalog once, or wait for the next store check.</p>
                <% elsif snapshot[:addable].empty? -%>
                  <p class="add-hint">You’re already watching every product in the known catalog.</p>
                <% else -%>
                  <% snapshot[:addable].each do |row| -%>
                    <div class="add-row">
                      <span class="product"><%= h(row[:label]) %></span>
                      <span class="meta"><%= row[:configs] %> config<%= row[:configs] == 1 ? "" : "s" %><% if row[:price_range] %> · <%= h(row[:price_range]) %><% end %></span>
                      <form method="post" action="<%= h(snapshot[:base_path]) %>/rules/add">
                        <input type="hidden" name="model" value="<%= h(row[:model]) %>">
                        <button type="submit">watch</button>
                      </form>
                    </div>
                  <% end -%>
                  <p class="add-hint">Watching starts wide — every known configuration of that product — then tighten it with “edit”. New stock that fits is caught automatically.</p>
                <% end -%>
              </details>
            </section>

            <footer>
              Page refreshes every 20s · store checked every ~10s
              <% if snapshot[:catalog_updated_at] %> · catalog refreshed <%= h(day(snapshot[:catalog_updated_at])) %> <%= h(clock_minute(snapshot[:catalog_updated_at])) %><% end %>
              · everything stays in local files
              <% if snapshot[:public_url] %> · <a href="<%= h(snapshot[:public_url]) %>">public link</a><% end %>
            </footer>
          </main>
          <script>
            // Live "Ns ago" so the heartbeat reads true between refreshes.
            const tick = () => {
              document.querySelectorAll("[data-epoch]").forEach((el) => {
                const epoch = Number(el.dataset.epoch)
                if (!epoch) return
                const s = Math.max(0, Math.floor(Date.now() / 1000 - epoch))
                el.textContent = s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)} min` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
              })
            }
            tick()
            setInterval(tick, 1000)
          </script>
        </body>
        </html>
      ERB
    end
  end
end
