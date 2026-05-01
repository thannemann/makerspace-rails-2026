# Handles inbound Slack slash commands for tool checkouts.
#
# Slack sends a POST to /slack/commands when a slash command is used.
# The payload includes: command, text, channel_name, user_id, user_name
#
# Expected command format:
#   /checkout @member bandsaw
#   /checkout member@email.com bandsaw
#
# The shop is inferred from the channel_name via Shop.slack_channel field.
# Response must be returned within 3 seconds (Slack timeout).
#
class Slack::CommandsController < ApplicationController
  include Service::SlackConnector
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def checkout
    channel_name     = params[:channel_name]
    text             = params[:text].to_s.strip
    invoker_slack_id = params[:user_id]

    # Parse command text: first token is member identifier, rest is tool name
    parts = text.split(/\s+/, 2)
    if parts.length < 2
      Honeybadger.notify("Slack checkout failed: malformed command", context: {
        reason:           "Command text did not contain both a member identifier and a tool name",
        command_text:     text,
        invoker_slack_id: invoker_slack_id,
        invoker_token:    params[:user_id],
        member_token:     parts[0] || "(none)",
        member_slack_id:  nil
      })
      render json: { response_type: "ephemeral", text: "Usage: `/checkout @member tool-name` or `/checkout email@example.com tool-name`" } and return
    end

    member_token = parts[0]
    tool_name    = parts[1]

    # Parse member slack ID upfront so it's available in all error contexts below
    member_slack_id = if slack_mention?(member_token)
      member_token.match(/<@([^|>]+)/i)&.captures&.first
    elsif slack_username?(member_token)
      username = member_token.sub(/\A@/, "")
      SlackUser.where(name: /\A#{Regexp.escape(username)}\z/i).first&.slack_id
    end

    # Verify invoker is authorized
    invoker = find_invoker(invoker_slack_id)
    unless invoker
      Honeybadger.notify("Slack checkout failed: unauthorized invoker", context: {
        reason:           "Invoker Slack ID not linked to an admin, resource_manager, or checkout approver",
        command_text:     text,
        invoker_slack_id: invoker_slack_id,
        invoker_token:    params[:user_id],
        member_token:     member_token,
        member_slack_id:  member_slack_id
      })
      render json: { response_type: "ephemeral", text: "You are not authorized to check out members on tools." } and return
    end

    # Find the shop from the channel
    shop = Shop.find_by(slack_channel: channel_name)
    unless shop
      Honeybadger.notify("Slack checkout failed: shop not found for channel", context: {
        reason:           "No Shop record found with slack_channel matching '#{channel_name}'",
        command_text:     text,
        invoker_slack_id: invoker_slack_id,
        invoker_token:    params[:user_id],
        member_token:     member_token,
        member_slack_id:  member_slack_id,
        channel_name:     channel_name
      })
      render json: { response_type: "ephemeral", text: "No shop is configured for ##{channel_name}. Please use the portal." } and return
    end

    # Verify invoker can approve for this shop
    unless can_approve_for_shop?(invoker, shop)
      Honeybadger.notify("Slack checkout failed: invoker not approved for shop", context: {
        reason:           "Invoker does not have checkout approval rights for shop '#{shop.name}' (id: #{shop.id})",
        command_text:     text,
        invoker_slack_id: invoker_slack_id,
        invoker_token:    params[:user_id],
        member_token:     member_token,
        member_slack_id:  member_slack_id,
        shop_name:        shop.name,
        shop_id:          shop.id.to_s
      })
      render json: { response_type: "ephemeral", text: "You are not authorized to approve checkouts for #{shop.name}." } and return
    end

    # Find the tool
    tool = Tool.where(shop_id: shop.id).find_by(name: /#{Regexp.escape(tool_name)}/i)
    unless tool
      tool_list = Tool.where(shop_id: shop.id).pluck(:name).join(", ")
      Honeybadger.notify("Slack checkout failed: tool not found", context: {
        reason:             "No tool matching '#{tool_name}' found in shop '#{shop.name}'",
        command_text:       text,
        invoker_slack_id:   invoker_slack_id,
        invoker_token:      params[:user_id],
        member_token:       member_token,
        member_slack_id:    member_slack_id,
        tool_name_searched: tool_name,
        shop_name:          shop.name,
        available_tools:    tool_list
      })
      render json: { response_type: "ephemeral", text: "Tool '#{tool_name}' not found in #{shop.name}. Available: #{tool_list}" } and return
    end

    # Find the member — Slack mention or email
    member = find_member_from_token(member_token)
    unless member
      if slack_mention?(member_token)
        Honeybadger.notify("Slack checkout failed: member not found by Slack ID", context: {
          reason:           "Slack mention parsed but no SlackUser/Member record linked to this Slack ID",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          invoker_token:    params[:user_id],
          member_token:     member_token,
          member_slack_id:  member_slack_id
        })
        render json: {
          response_type: "ephemeral",
          text: "No member found linked to that Slack account. Please resubmit with their email address instead:\n`/checkout member@email.com #{tool_name}`"
        } and return
      elsif slack_username?(member_token)
        Honeybadger.notify("Slack checkout failed: member not found by Slack username", context: {
          reason:           "Plain @username not matched to any SlackUser name record",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          invoker_token:    params[:user_id],
          member_token:     member_token,
          member_slack_id:  member_slack_id
        })
        render json: {
          response_type: "ephemeral",
          text: "No member found with Slack username #{member_token}. Try using their email instead:\n`/checkout member@email.com #{tool_name}`"
        } and return
      else
        Honeybadger.notify("Slack checkout failed: member not found by email", context: {
          reason:           "No Member record found with email matching member token",
          command_text:     text,
          invoker_slack_id: invoker_slack_id,
          invoker_token:    params[:user_id],
          member_token:     member_token,
          member_slack_id:  nil
        })
        render json: { response_type: "ephemeral", text: "No member found with email #{member_token}." } and return
      end
    end

    # Check for duplicate active checkout
    if ToolCheckout.exists?(member_id: member.id, tool_id: tool.id, revoked_at: nil)
      render json: { response_type: "ephemeral", text: "#{member.fullname} is already checked out on #{tool.name}." } and return
    end

    # Create the checkout
    checkout = ToolCheckout.new(
      member_id:      member.id,
      tool_id:        tool.id,
      approved_by_id: invoker.id,
      signed_off_via: "slack",
      checked_out_at: Time.now
    )

    begin
      checkout.save!
    rescue => err
      Honeybadger.notify("Slack checkout failed: could not save ToolCheckout", context: {
        reason:           "checkout.save! raised: #{err.message}",
        command_text:     text,
        invoker_slack_id: invoker_slack_id,
        invoker_token:    params[:user_id],
        member_token:     member_token,
        member_slack_id:  member_slack_id,
        member_id:        member.id.to_s,
        tool_id:          tool.id.to_s,
        tool_name:        tool.name
      })
      render json: { response_type: "ephemeral", text: "Failed to create checkout record. Please try again or use the portal." } and return
    end

    begin
      checkout.send_checkout_slack_notification
    rescue => err
      Honeybadger.notify("Slack checkout saved but notification failed", context: {
        reason:           "send_checkout_slack_notification raised: #{err.message}",
        command_text:     text,
        invoker_slack_id: invoker_slack_id,
        invoker_token:    params[:user_id],
        member_token:     member_token,
        member_slack_id:  member_slack_id,
        member_id:        member.id.to_s,
        tool_id:          tool.id.to_s,
        tool_name:        tool.name,
        checkout_id:      checkout.id.to_s
      })
      # Don't block the response — checkout was saved successfully
    end

    # Check prerequisites — warn in channel but don't block
    unmet = unmet_prerequisites(member, tool)
    warning = unmet.any? ? "\n⚠ Warning: #{member.firstname} has not been checked out on prerequisite(s): #{unmet.map(&:name).join(', ')}" : ""

    render json: {
      response_type: "in_channel",
      text: "✅ #{member.fullname} has been checked out on *#{tool.name}* in *#{shop.name}* by #{invoker.fullname}.#{warning}"
    }
  end

  private

  def slack_mention?(token)
    token.start_with?("<@")
  end

  def slack_username?(token)
    token.start_with?("@") && !token.start_with?("<@")
  end

  def find_member_from_token(token)
    if slack_mention?(token)
      # Format: <@U12345678|username>
      slack_id = token.match(/<@([^|>]+)/i)&.captures&.first
      return nil unless slack_id
      slack_user = SlackUser.find_by(slack_id: slack_id)
      slack_user ? Member.find(slack_user.member_id) : nil
    elsif slack_username?(token)
      # Format: @plaintext username — match against SlackUser name field
      username = token.sub(/\A@/, "")
      slack_user = SlackUser.where(name: /\A#{Regexp.escape(username)}\z/i).first
      slack_user ? Member.find(slack_user.member_id) : nil
    else
      # Email fallback
      Member.find_by(email: token.downcase)
    end
  end

  def find_invoker(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    member = Member.find(slack_user.member_id)

    # Must be admin, RM, or checkout approver
    return member if member.role.in?(%w[admin resource_manager])
    return member if CheckoutApprover.is_approver?(member.id)
    nil
  end

  def can_approve_for_shop?(member, shop)
    return true if member.role.in?(%w[admin resource_manager])
    approver = CheckoutApprover.find_by(member_id: member.id)
    approver && approver.can_approve_for_shop?(shop.id)
  end

  def unmet_prerequisites(member, tool)
    return [] if tool.prerequisite_ids.blank?
    checked_out_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    tool.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_ids.include?(pid) }.map do |pid|
      Tool.find(pid) rescue nil
    end.compact
  end

  # Verify the request actually came from Slack using signing secret
  def verify_slack_signature
    slack_signing_secret = ENV['SLACK_SIGNING_SECRET']
    return if slack_signing_secret.blank? # Skip in dev if not configured

    timestamp  = request.headers['X-Slack-Request-Timestamp']
    signature  = request.headers['X-Slack-Signature']
    body       = request.raw_post

    # Reject if timestamp is >5 minutes old (replay attack prevention)
    if (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: "Request too old" }, status: 403 and return
    end

    sig_basestring = "v0:#{timestamp}:#{body}"
    my_signature   = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', slack_signing_secret, sig_basestring)}"

    unless ActiveSupport::SecurityUtils.secure_compare(my_signature, signature.to_s)
      render json: { error: "Invalid signature" }, status: 403
    end
  end
end
