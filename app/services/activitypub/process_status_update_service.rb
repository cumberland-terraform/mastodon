# frozen_string_literal: true

class ActivityPub::ProcessStatusUpdateService < BaseService
  include JsonLdHelper
  include Redisable
  include Lockable

  def call(status, activity_json, object_json, request_id: nil)
    raise ArgumentError, 'Status has unsaved changes' if status.changed?

    @activity_json             = activity_json
    @json                      = object_json
    @status_parser             = ActivityPub::Parser::StatusParser.new(@json, followers_collection: status.account.followers_url, actor_uri: ActivityPub::TagManager.instance.uri_for(status.account))
    @uri                       = @status_parser.uri
    @status                    = status
    @account                   = status.account
    @media_attachments_changed = false
    @poll_changed              = false
    @quote_changed             = false
    @request_id                = request_id

    # Only native types can be updated at the moment
    return @status if !expected_type? || already_updated_more_recently?

    if @status_parser.edited_at.present? && (@status.edited_at.nil? || @status_parser.edited_at > @status.edited_at)
      handle_explicit_update!
    else
      handle_implicit_update!
    end

    @status
  end

  private

  def handle_explicit_update!
    last_edit_date = @status.edited_at.presence || @status.created_at

    # Only allow processing one create/update per status at a time
    with_redis_lock("create:#{@uri}") do
      Status.transaction do
        record_previous_edit!
        update_media_attachments!
        update_interaction_policies!
        update_poll!
        update_immediate_attributes!
        update_metadata!
        update_counts!
        create_edits!
      end

      download_media_files!
      queue_poll_notifications!

      next unless significant_changes?

      reset_preview_card!
      broadcast_updates!
    end

    forward_activity! if significant_changes? && @status_parser.edited_at > last_edit_date
  end

  def handle_implicit_update!
    with_redis_lock("create:#{@uri}") do
      update_interaction_policies!
      update_poll!(allow_significant_changes: false)
      queue_poll_notifications!
      update_quote_approval!
      update_counts!
    end
  end

  def update_interaction_policies!
    @status.quote_approval_policy = @status_parser.quote_policy
  end

  def update_media_attachments!
    previous_media_attachments     = @status.media_attachments.to_a
    previous_media_attachments_ids = @status.ordered_media_attachment_ids || previous_media_attachments.map(&:id)
    @next_media_attachments        = []

    as_array(@json['attachment']).each do |attachment|
      media_attachment_parser = ActivityPub::Parser::MediaAttachmentParser.new(attachment)

      next if media_attachment_parser.remote_url.blank? || @next_media_attachments.size > Status::MEDIA_ATTACHMENTS_LIMIT

      begin
        media_attachment   = previous_media_attachments.find { |previous_media_attachment| previous_media_attachment.remote_url == media_attachment_parser.remote_url }
        media_attachment ||= MediaAttachment.new(account: @account, remote_url: media_attachment_parser.remote_url)

        # If a previously existing media attachment was significantly updated, mark
        # media attachments as changed even if none were added or removed
        @media_attachments_changed = true if media_attachment_parser.significantly_changes?(media_attachment)

        media_attachment.description          = media_attachment_parser.description
        media_attachment.focus                = media_attachment_parser.focus
        media_attachment.thumbnail_remote_url = media_attachment_parser.thumbnail_remote_url
        media_attachment.blurhash             = media_attachment_parser.blurhash
        media_attachment.status_id            = @status.id
        media_attachment.skip_download        = unsupported_media_type?(media_attachment_parser.file_content_type) || skip_download?
        media_attachment.save!

        @next_media_attachments << media_attachment
      rescue Addressable::URI::InvalidURIError => e
        Rails.logger.debug { "Invalid URL in attachment: #{e}" }
      end
    end

    @status.ordered_media_attachment_ids = @next_media_attachments.map(&:id)

    @media_attachments_changed = true if @status.ordered_media_attachment_ids != previous_media_attachments_ids
  end

  def download_media_files!
    @next_media_attachments.each do |media_attachment|
      next if media_attachment.skip_download

      media_attachment.download_file! if media_attachment.remote_url_previously_changed?
      media_attachment.download_thumbnail! if media_attachment.thumbnail_remote_url_previously_changed?
      media_attachment.save
    rescue Mastodon::UnexpectedResponseError, *Mastodon::HTTP_CONNECTION_ERRORS
      RedownloadMediaWorker.perform_in(rand(30..600).seconds, media_attachment.id)
    rescue Seahorse::Client::NetworkingError => e
      Rails.logger.warn "Error storing media attachment: #{e}"
    end

    @status.media_attachments.reload
  end

  def update_poll!(allow_significant_changes: true)
    previous_poll        = @status.preloadable_poll
    @previous_expires_at = previous_poll&.expires_at
    poll_parser          = ActivityPub::Parser::PollParser.new(@json)

    if poll_parser.valid?
      poll = previous_poll || @account.polls.new(status: @status)

      # If for some reasons the options were changed, it invalidates all previous
      # votes, so we need to remove them
      @poll_changed = true if poll_parser.significantly_changes?(poll)
      return if @poll_changed && !allow_significant_changes

      poll.last_fetched_at = Time.now.utc
      poll.options         = poll_parser.options
      poll.multiple        = poll_parser.multiple
      poll.expires_at      = poll_parser.expires_at
      poll.voters_count    = poll_parser.voters_count
      poll.cached_tallies  = poll_parser.cached_tallies
      poll.reset_votes! if @poll_changed
      poll.save!

      @status.poll_id = poll.id
    elsif previous_poll.present?
      return unless allow_significant_changes

      previous_poll.destroy!
      @poll_changed = true
      @status.poll_id = nil
    end
  end

  def update_immediate_attributes!
    @status.text         = @status_parser.text || ''
    @status.spoiler_text = @status_parser.spoiler_text || ''
    @status.sensitive    = @account.sensitized? || @status_parser.sensitive || false
    @status.language     = @status_parser.language

    @significant_changes = text_significantly_changed? || @status.spoiler_text_changed? || @media_attachments_changed || @poll_changed || @quote_changed

    @status.edited_at = @status_parser.edited_at if significant_changes?

    @status.save!
  end

  def update_metadata!
    @raw_tags     = []
    @raw_mentions = []
    @raw_emojis   = []

    as_array(@json['tag']).each do |tag|
      if equals_or_includes?(tag['type'], 'Hashtag')
        @raw_tags << tag['name'] if tag['name'].present?
      elsif equals_or_includes?(tag['type'], 'Mention')
        @raw_mentions << tag['href'] if tag['href'].present?
      elsif equals_or_includes?(tag['type'], 'Emoji')
        @raw_emojis << tag
      end
    end

    update_tags!
    update_mentions!
    update_emojis!
    update_quote!
  end

  def update_tags!
    previous_tags = @status.tags.to_a
    current_tags = @status.tags = Tag.find_or_create_by_names(@raw_tags)

    return unless @status.distributable?

    added_tags = current_tags - previous_tags

    unless added_tags.empty?
      @account.featured_tags.where(tag_id: added_tags.pluck(:id)).find_each do |featured_tag|
        featured_tag.increment(@status.created_at)
      end
    end

    removed_tags = previous_tags - current_tags

    unless removed_tags.empty?
      @account.featured_tags.where(tag_id: removed_tags.pluck(:id)).find_each do |featured_tag|
        featured_tag.decrement(@status)
      end
    end
  end

  def update_mentions!
    unresolved_mentions = []

    currently_mentioned_account_ids = @raw_mentions.filter_map do |href|
      next if href.blank?

      account   = ActivityPub::TagManager.instance.uri_to_resource(href, Account)
      account ||= ActivityPub::FetchRemoteAccountService.new.call(href, request_id: @request_id)

      account&.id
    rescue Mastodon::UnexpectedResponseError, *Mastodon::HTTP_CONNECTION_ERRORS
      # Since previous mentions are about already-known accounts,
      # they don't try to resolve again and won't fall into this case.
      # In other words, this failure case is only for new mentions and won't
      # affect `removed_mentions` so they can safely be retried asynchronously
      unresolved_mentions << href
      nil
    end

    @status.mentions.upsert_all(currently_mentioned_account_ids.uniq.map { |id| { account_id: id, silent: false } }, unique_by: %w(status_id account_id))

    # If previous mentions are no longer contained in the text, convert them
    # to silent mentions, since withdrawing access from someone who already
    # received a notification might be more confusing
    @status.mentions.where.not(account_id: currently_mentioned_account_ids).update_all(silent: true)

    # Queue unresolved mentions for later
    unresolved_mentions.uniq.each do |uri|
      MentionResolveWorker.perform_in(rand(30...600).seconds, @status.id, uri, { 'request_id' => @request_id })
    end
  end

  def update_emojis!
    return if skip_download?

    @raw_emojis.each do |raw_emoji|
      custom_emoji_parser = ActivityPub::Parser::CustomEmojiParser.new(raw_emoji)

      next if custom_emoji_parser.shortcode.blank? || custom_emoji_parser.image_remote_url.blank?

      emoji = CustomEmoji.find_by(shortcode: custom_emoji_parser.shortcode, domain: @account.domain)

      next unless emoji.nil? || custom_emoji_parser.image_remote_url != emoji.image_remote_url || (custom_emoji_parser.updated_at && custom_emoji_parser.updated_at >= emoji.updated_at)

      begin
        emoji ||= CustomEmoji.new(domain: @account.domain, shortcode: custom_emoji_parser.shortcode, uri: custom_emoji_parser.uri)
        emoji.image_remote_url = custom_emoji_parser.image_remote_url
        emoji.save
      rescue Seahorse::Client::NetworkingError => e
        Rails.logger.warn "Error storing emoji: #{e}"
      end
    end
  end

  # This method is only concerned with approval and skips other meaningful changes,
  # as it is used instead of `update_quote!` in implicit updates
  def update_quote_approval!
    quote_uri = @status_parser.quote_uri
    return unless quote_uri.present? && @status.quote.present?

    quote = @status.quote
    return if quote.quoted_status.present? && ActivityPub::TagManager.instance.uri_for(quote.quoted_status) != quote_uri

    approval_uri = @status_parser.quote_approval_uri
    approval_uri = nil if unsupported_uri_scheme?(approval_uri)

    quote.update(approval_uri: approval_uri, state: :pending, legacy: @status_parser.legacy_quote?) if quote.approval_uri != @status_parser.quote_approval_uri

    fetch_and_verify_quote!(quote, quote_uri)
  end

  def update_quote!
    quote_uri = @status_parser.quote_uri

    if quote_uri.present?
      approval_uri = @status_parser.quote_approval_uri
      approval_uri = nil if unsupported_uri_scheme?(approval_uri)

      if @status.quote.present?
        # If the quoted post has changed, discard the old object and create a new one
        if @status.quote.quoted_status.present? && ActivityPub::TagManager.instance.uri_for(@status.quote.quoted_status) != quote_uri
          # Revoke the quote while we get a chance… maybe this should be a `before_destroy` hook?
          RevokeQuoteService.new.call(@status.quote) if @status.quote.quoted_account&.local? && @status.quote.accepted?
          @status.quote.destroy
          quote = Quote.create(status: @status, approval_uri: approval_uri, legacy: @status_parser.legacy_quote?)
          @quote_changed = true
        else
          quote = @status.quote
          quote.update(approval_uri: approval_uri, state: :pending, legacy: @status_parser.legacy_quote?) if quote.approval_uri != @status_parser.quote_approval_uri
        end
      else
        quote = Quote.create(status: @status, approval_uri: approval_uri, legacy: @status_parser.legacy_quote?)
        @quote_changed = true
      end

      quote.save

      fetch_and_verify_quote!(quote, quote_uri)
    elsif @status.quote.present?
      @status.quote.destroy!
      @quote_changed = true
    end
  end

  def fetch_and_verify_quote!(quote, quote_uri)
    embedded_quote = safe_prefetched_embed(@account, @status_parser.quoted_object, @activity_json['context'])
    ActivityPub::VerifyQuoteService.new.call(quote, fetchable_quoted_uri: quote_uri, prefetched_quoted_object: embedded_quote, request_id: @request_id)
  rescue Mastodon::UnexpectedResponseError, *Mastodon::HTTP_CONNECTION_ERRORS
    ActivityPub::RefetchAndVerifyQuoteWorker.perform_in(rand(30..600).seconds, quote.id, quote_uri, { 'request_id' => @request_id })
  end

  def update_counts!
    likes = @status_parser.favourites_count
    shares =  @status_parser.reblogs_count
    return if likes.nil? && shares.nil?

    @status.status_stat.tap do |status_stat|
      status_stat.untrusted_reblogs_count = shares unless shares.nil?
      status_stat.untrusted_favourites_count = likes unless likes.nil?

      status_stat.save if status_stat.changed?
    end
  end

  def expected_type?
    equals_or_includes_any?(@json['type'], %w(Note Question))
  end

  def record_previous_edit!
    @previous_edit = @status.build_snapshot(at_time: @status.created_at, rate_limit: false) if @status.edits.empty?
  end

  def create_edits!
    return unless significant_changes?

    @previous_edit&.save!
    @status.snapshot!(account_id: @account.id, rate_limit: false)
  end

  def skip_download?
    return @skip_download if defined?(@skip_download)

    @skip_download ||= DomainBlock.reject_media?(@account.domain)
  end

  def unsupported_media_type?(mime_type)
    mime_type.present? && !MediaAttachment.supported_mime_types.include?(mime_type)
  end

  def significant_changes?
    @significant_changes
  end

  def text_significantly_changed?
    return false unless @status.text_changed?

    old, new = @status.text_change
    HtmlAwareFormatter.new(old, false).to_s != HtmlAwareFormatter.new(new, false).to_s
  end

  def already_updated_more_recently?
    @status.edited_at.present? && @status_parser.edited_at.present? && @status.edited_at > @status_parser.edited_at
  end

  def reset_preview_card!
    @status.reset_preview_card!
    LinkCrawlWorker.perform_in(rand(1..59).seconds, @status.id)
  end

  def broadcast_updates!
    ::DistributionWorker.perform_async(@status.id, { 'update' => true })
  end

  def queue_poll_notifications!
    poll = @status.preloadable_poll

    # If the poll had no expiration date set but now has, or now has a sooner
    # expiration date, and people have voted, schedule a notification

    return unless poll.present? && poll.expires_at.present? && poll.votes.exists?

    PollExpirationNotifyWorker.remove_from_scheduled(poll.id) if @previous_expires_at.present? && @previous_expires_at > poll.expires_at
    PollExpirationNotifyWorker.perform_at(poll.expires_at + 5.minutes, poll.id)
  end

  def forward_activity!
    forwarder.forward! if forwarder.forwardable?
  end

  def forwarder
    @forwarder ||= ActivityPub::Forwarder.new(@account, @activity_json, @status)
  end
end
