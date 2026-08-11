#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "scraperwiki"
require "mechanize"
require "json"

class Scraper
  INITIAL_PAGE_URL = "https://www.joondalup.wa.gov.au/community-and-spaces/community-consultation"
  SEARCH_URL = "https://www.joondalup.wa.gov.au/search/htmlresult"

  STATE = "WA"

  def clean_whitespace(text)
    text.gsub("\r", " ").gsub("\n", " ").squeeze(" ").strip
  end

  def parse_date(date_string)
    # Parse dates like "21 January 2026" to ISO 8601 format
    Date.parse(date_string).to_s
  rescue ArgumentError
    nil
  end

  attr_accessor :pause_duration

  # Throttle block to be nice to servers we are scraping
  def throttle_block(extra_delay: 0.5)
    if @pause_duration
      puts "  Pausing #{@pause_duration}s"
      sleep(@pause_duration)
    end
    start_time = Time.now.to_f
    page = yield
    @pause_duration = (Time.now.to_f - start_time + extra_delay).round(3)
    page
  end

  # Cleanup and vacuum database of old records (planning alerts only looks at last 5 days)
  def cleanup_old_records
    cutoff_date = (Date.today - 30).to_s
    vacuum_cutoff_date = (Date.today - 35).to_s

    stats = ScraperWiki.sqliteexecute(
      "SELECT COUNT(*) as count, MIN(date_scraped) as oldest FROM data WHERE date_scraped < ?",
      [cutoff_date]
    ).first

    deleted_count = stats["count"]
    oldest_date = stats["oldest"]

    return unless deleted_count.positive? || ENV["VACUUM"]

    puts "Deleting #{deleted_count} applications scraped between #{oldest_date} and #{cutoff_date}"
    ScraperWiki.sqliteexecute("DELETE FROM data WHERE date_scraped < ?", [cutoff_date])

    # VACUUM roughly once each 33 days or if older than 35 days (first time) or if VACUUM is set
    return unless rand < 0.03 || (oldest_date && oldest_date < vacuum_cutoff_date) || ENV["VACUUM"]

    puts "  Running VACUUM to reclaim space..."
    ScraperWiki.sqliteexecute("VACUUM")
  end

  def extract_council_reference_from_details(agent, info_url)
    puts "  Fetching detail page: #{info_url}"
    detail_page = agent.get(info_url)

    # Look for "Development Application Reference:" heading
    detail_page.search("h3").each do |h3|
      text = h3.text
      next unless text =~ /Development Application Reference:\s*(.+)/

      ref = ::Regexp.last_match(1).strip
      puts "  Extracted #{ref} from detail page"
      return ref
    end

    puts "  Unable to extract reference from: #{info_url}"
    nil
  rescue StandardError => e
    puts "  Error fetching detail page #{info_url}: #{e.message}"
    nil
  end

  def build_search_payload(page_number)
    {
      "SI" => "Consultation",
      "OB" => "Status, ArticleType DESC, ArticleOpenDate DESC",
      "Q" => "",
      "PS" => 12,
      "FS" => 12,
      "PG" => page_number,
      "PR" => [
        { "key" => "widgetclassname", "values" => [{ "value" => "AWConsultationSmartSearchListing" }] },
        { "key" => "widgettemplatename", "values" => [{ "value" => "AWConsultationSmartSearchListing" }] },
        { "key" => "classname", "values" => [{ "value" => "AWPT.Consultation" }] },
        { "key" => "nodealiaspath",
          "values" => [{ "value" => "/Community-and-Spaces/Community-consultation-(Have-your-say)" }], },
        { "key" => "keyword", "values" => [{ "value" => "" }] },
        { "OR" => true, "key" => "Status", "operater" => "like", "values" => [{ "value" => "31" }] },
        { "OR" => true, "key" => "ArticleType", "operater" => "like",
          "values" => [{ "value" => "Development Applications" }], },
        { "OR" => true, "key" => "Topics", "operater" => "like", "values" => [] },
        { "OR" => true, "key" => "Suburb", "operater" => "like", "values" => [] },
      ],
      "IncludeFirst" => false,
    }
  end

  def generate_council_reference(title)
    # Sanitize: replace non-alphanumeric characters with space, strip
    sanitized = title.gsub(/[^A-Za-z0-9]+/, " ").strip

    # Truncate to 49 chars and add hyphen if truncated
    if sanitized.length > 49
      sanitized[0..48] + "-"
    else
      sanitized
    end
  end

  def run
    agent = Mechanize.new
    agent.verify_mode = OpenSSL::SSL::VERIFY_NONE

    # Visit the main page first to set cookies and play nice
    throttle_block do
      puts "Getting initial page"
      agent.get(INITIAL_PAGE_URL)
    end

    page_number = 1
    added = found = 0

    loop do
      response = throttle_block do
        puts "Getting page #{page_number}"
        response = agent.post(
          SEARCH_URL,
          build_search_payload(page_number).to_json,
          { "Content-Type" => "application/json", "X-Requested-With" => "XMLHttpRequest" }
        )
      end

      data = JSON.parse(response.body)
      html = data["htmlResult"]
      has_next = data["hasnextpage"] == "true"

      # Parse the HTML fragment
      doc = Nokogiri::HTML(html)
      articles = doc.search("article.card")

      break if articles.empty?

      articles.each do |article|
        found += 1

        link = article.at("a.hotbox")
        next unless link

        info_url = "https://www.joondalup.wa.gov.au" + link["href"]

        # Get title from h3.card-title
        title_elem = article.at("h3.card-title")
        title = title_elem ? clean_whitespace(title_elem.text) : ""

        # Always fetch the detail page to get council reference
        council_reference = extract_council_reference_from_details(agent, info_url) || generate_council_reference(title)

        unless council_reference
          puts "Warning - Unable to extract council reference for #{title} (skipped)"
          next
        end

        # Use aria-label as description, fallback to title
        full_text = link["aria-label"]&.strip&.chomp(".")&.chomp
        full_text = title if full_text.to_s.empty?

        # Extract address and description (split on dash with surrounding whitespace)
        # Match both – (en dash) and - (hyphen)
        if full_text =~ /\A(.+?)\s+[–-]\s+(.+)\z/
          address = ::Regexp.last_match(1).strip
          description = ::Regexp.last_match(2).strip
          address = "#{address}, #{STATE}" unless address.end_with?(STATE)
        else
          puts "Warning - Unable to parse address and description from: #{full_text} (skipped)"
          next
        end

        # Extract dates from the fa-ul list
        on_notice_from = nil
        on_notice_to = nil

        article.search("ul.fa-ul li").each do |li|
          text = clean_whitespace(li.text)
          if text =~ /Open date:\s*(.+)/
            on_notice_from = parse_date(::Regexp.last_match(1))
          elsif text =~ /Closing date:\s*(.+)/
            on_notice_to = parse_date(::Regexp.last_match(1))
          end
        end

        record = {
          "council_reference" => council_reference,
          "address" => address,
          "description" => description,
          "info_url" => info_url,
          "date_scraped" => Date.today.to_s,
        }
        record["on_notice_from"] = on_notice_from if on_notice_from
        record["on_notice_to"] = on_notice_to if on_notice_to

        added += 1
        puts "Saving record #{council_reference} - #{address}"
        ScraperWiki.save_sqlite(["council_reference"], record)
      end

      break unless has_next

      page_number += 1
      break if page_number > 100 # Safety limit
    end

    cleanup_old_records
    skipped = found - added
    puts "Finished! Added #{added} applications, and skipped #{skipped} unprocessable applications from #{page_number} pages."
  end
end

Scraper.new.run if __FILE__ == $PROGRAM_NAME
