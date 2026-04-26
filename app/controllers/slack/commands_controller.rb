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
# Respons must be returned within 3 seconds (Slack timeout).
#
class Slack::CommandsController < ApplicationController
  include Service::SlackConnector
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def checkout
    channel_name = params[:channel_name]
    text         = params[:text].to_s.strip
    invoker_slack_id = params[:user_id]

    # Parse command text: first token is member identifier, rest is tool name
    parts = text.split(/\s+/, 2)
    if parts.length < 2
      render json: { response_type: "ephemeral", text: "Usage: `/checkout @member tool-name` or `/checkout email@example.com tool-name`" } and return
    end

    member_token = parts[0]
    tool_name    = parts[1]

    # Verify invoker is authorized
    invoker = find_invoker(invoker_slack_id)
    unless invoker
      render json: { response_type: "ephemeral", text: "You are not authorized to check out members on tools." } and return
    end

    # Find the shop from the channel
    shop = Shop.find_by(slack_channel: channel_name)
    unless shop
      render json: { response_type: "ephemeral", text: "No shop is configured for ##{channel_name}. Please use the portal." } and return
    end

    # Verify invoker can approve for this shop
    unless can_approve_for_shop?(invoker, shop)
      render json: { response_type: "ephemeral", text: "You are not authorized to approve checkouts for #{shop.name}." } and return
    end

    # Find the tool
    tool = Tool.where(shop_id: shop.id).find_by(name: /#{Regexp.escape(tool_name)}/i)
    unless tool
      tool_list = Tool.where(shop_id: shop.id).pluck(:name).join(", ")
      render json: { response_type: "ephemeral", text: "Tool '#{tool_name}' not found in #{shop.name}. Available: #{tool_list}" } and return
    end

    # Find the member — Slack mention or email
    member = find_member_from_token(member_token)
    unless member
      if slack_mention?(member_token)
        render json: {
          response_type: "ephemeral",
          text: "No member found linked to that Slack account. Please resubmit with their email address instead:\n`/checkout member@email.com #{tool_name}`"
        } and return
      else
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
    checkout.save!
    checkout.send_checkout_slack_notification

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

  def find_member_from_token(token)
    if slack_mention?(token)
      # Format: <@U12345678|username>
      slack_id = token.match(/<@([^|>]+)/i)&.captures&.first
      return nil unless slack_id
      slack_user = SlackUser.find_by(slack_id: slack_id)
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
