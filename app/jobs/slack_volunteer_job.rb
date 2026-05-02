# SlackVolunteerJob
#
# Handles inbound /volunteer Slack slash commands asynchronously.
# All processing is deferred here to satisfy Slack's 3-second response window.
#
# If the invoker's Slack account is not linked to a Member record,
# Service::SlackUserSync.sync_single is called once to attempt a live sync
# before giving up.
#
# Supported commands:
#   /volunteer status [@member]              — check credit count
#   /volunteer tasks                         — list available bounty tasks
#   /volunteer claim <task-id>               — claim an available bounty task
#   /volunteer done <task-id>                — mark claimed task as pending verification
#   /volunteer award @member <reason>        — admin/RM: award a one-off credit (always 1 credit)
#   /volunteer verify <task-id>              — admin/RM: verify a completed task
#   /volunteer release <task-id> <reason>    — admin/RM: release a stale claimed task
#   /volunteer reject <task-id> <reason>     — admin/RM: reject a pending task
#
class SlackVolunteerJob < ApplicationJob
  queue_as :default

  def perform(params)
    response_url     = params['response_url']
    invoker_slack_id = params['user_id']
    text             = params['text'].to_s.strip

    parts   = text.split(/\s+/)
    command = parts[0].to_s.downcase

    # Find invoker — attempt sync_single once if not linked
    invoker = find_member_by_slack_id(invoker_slack_id)
    if invoker.nil?
      Service::SlackUserSync.sync_single(invoker_slack_id)
      invoker = find_member_by_slack_id(invoker_slack_id)
    end

    unless invoker
      post_response(response_url, :ephemeral, '❌ Your Slack account is not linked to a Member Portal account. An admin has been notified.')
      return
    end

    case command
    when 'status'
      handle_status(response_url, invoker, parts[1])
    when 'tasks'
      handle_tasks(response_url)
    when 'claim'
      handle_claim(response_url, invoker, parts[1])
    when 'done'
      handle_done(response_url, invoker, parts[1])
    when 'award'
      handle_award(response_url, invoker, parts)
    when 'verify'
      handle_verify(response_url, invoker, parts[1])
    when 'release'
      handle_release(response_url, invoker, parts[1], parts[2..].join(' '))
    when 'reject'
      handle_reject(response_url, invoker, parts[1], parts[2..].join(' '))
    else
      post_response(response_url, :ephemeral, usage_text)
    end
  end

  private

  # ── Command Handlers ─────────────────────────────────────────────────────

  def handle_status(response_url, invoker, target_token)
    member = target_token.present? ? find_member_from_token(target_token) : invoker

    unless member
      post_response(response_url, :ephemeral, "❌ Member not found: #{target_token}")
      return
    end

    if member.id != invoker.id && !privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ You can only check your own status.')
      return
    end

    year_count     = VolunteerCredit.year_count_for(member.id)
    discounts_used = VolunteerCredit.discounts_applied_this_year_for(member.id)
    threshold      = VolunteerCredit.credits_per_discount
    max_discounts  = VolunteerCredit.max_discounts_per_year
    pending_count  = VolunteerCredit.pending.where(member_id: member.id).count
    is_earned      = EarnedMembership.where(member_id: member.id).exists?

    lines = ["📊 *Volunteer Status for #{member.fullname}*"]
    lines << "Credits this year: *#{year_count}*"
    lines << "Discounts applied: *#{discounts_used}* / #{max_discounts}"
    lines << "Pending approval: #{pending_count}" if pending_count > 0

    if is_earned
      lines << '_Earned membership — credits logged for recognition only._'
    elsif discounts_used >= max_discounts
      lines << '🏆 Maximum discounts reached for this year. Resets January 1st.'
    else
      credits_until_next = [(threshold * (discounts_used + 1)) - year_count, 0.0].max
      lines << "#{credits_until_next} credit#{'s' if credits_until_next != 1.0} until next discount."
    end

    post_response(response_url, :ephemeral, lines.join("\n"))
  end

  def handle_tasks(response_url)
    tasks = VolunteerTask.available.order_by(created_at: :desc).limit(10)

    if tasks.empty?
      post_response(response_url, :ephemeral, '📋 No bounty tasks are currently available.')
      return
    end

    lines = ['📋 *Available Bounty Tasks*']
    tasks.each do |t|
      credit_label = t.credit_value == 1.0 ? '1 credit' : "#{t.credit_value} credits"
      lines << "• *#{t.title}* (#{credit_label}) — ID: `#{t.id}`\n  #{t.description}"
    end
    lines << "\nUse `/volunteer claim <task-id>` to claim one."

    post_response(response_url, :ephemeral, lines.join("\n"))
  end

  def handle_claim(response_url, invoker, task_id_str)
    unless task_id_str.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer claim <task-id>`')
      return
    end

    task = VolunteerTask.find(task_id_str) rescue nil
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_id_str}")
      return
    end

    unless task.status == 'available'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not available (status: #{task.status}).")
      return
    end

    task.claim!(invoker)
    post_response(response_url, :ephemeral,
      "🙌 You've claimed *#{task.title}*. When you're done, use `/volunteer done #{task.id}`")
  end

  def handle_done(response_url, invoker, task_id_str)
    unless task_id_str.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer done <task-id>`')
      return
    end

    task = VolunteerTask.find(task_id_str) rescue nil
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_id_str}")
      return
    end

    unless task.claimed_by_id == invoker.id
      post_response(response_url, :ephemeral, "❌ You haven't claimed this task.")
      return
    end

    task.mark_pending!(invoker)

    ::Service::SlackConnector.send_slack_message(
      "✅ *#{invoker.fullname}* completed task *#{task.title}* and is awaiting verification.\nTask ID: `#{task.id}`",
      VolunteerCredit.pending_slack_channel
    )

    post_response(response_url, :ephemeral,
      "✅ Task *#{task.title}* marked as complete. An admin or RM will verify shortly.")
  end

  def handle_award(response_url, invoker, parts)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can award credits.')
      return
    end

    if parts.length < 3
      post_response(response_url, :ephemeral, 'Usage: `/volunteer award @member <reason>`')
      return
    end

    member = find_member_from_token(parts[1])
    unless member
      post_response(response_url, :ephemeral, "❌ Member not found: #{parts[1]}")
      return
    end

    if member.id == invoker.id
      post_response(response_url, :ephemeral, '❌ You cannot award a credit to yourself.')
      return
    end

    description = parts[2..].join(' ')

    credit = VolunteerCredit.create!(
      member_id:    member.id,
      issued_by_id: invoker.id,
      description:  description,
      credit_value: 1.0,
      status:       'approved'
    )
    credit.send(:notify_member_credit_awarded)
    credit.send(:check_discount_threshold!)

    post_response(response_url, :in_channel,
      "🌟 *#{invoker.fullname}* awarded a volunteer credit to *#{member.fullname}*: _#{description}_")
  end

  def handle_verify(response_url, invoker, task_id_str)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can verify tasks.')
      return
    end

    unless task_id_str.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer verify <task-id>`')
      return
    end

    task = VolunteerTask.find(task_id_str) rescue nil
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_id_str}")
      return
    end

    unless task.status == 'pending'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not pending verification (status: #{task.status}).")
      return
    end

    if task.claimed_by_id == invoker.id
      post_response(response_url, :ephemeral, '❌ You cannot verify your own task.')
      return
    end

    task.complete!(invoker)
    claimant = Member.find(task.claimed_by_id) rescue nil

    post_response(response_url, :in_channel,
      "✅ *#{invoker.fullname}* verified task *#{task.title}* complete for *#{claimant&.fullname || 'member'}*. Credit issued!")
  end

  def handle_release(response_url, invoker, task_id_str, reason)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can release tasks.')
      return
    end

    unless task_id_str.present? && reason.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer release <task-id> <reason>`')
      return
    end

    task = VolunteerTask.find(task_id_str) rescue nil
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_id_str}")
      return
    end

    unless task.status == 'claimed'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not currently claimed (status: #{task.status}).")
      return
    end

    task.release!(invoker, reason)
    post_response(response_url, :in_channel,
      "🔓 Task *#{task.title}* has been released back to available. Reason: #{reason}")
  rescue Error::Forbidden
    post_response(response_url, :ephemeral, '❌ You cannot release your own claimed task.')
  end

  def handle_reject(response_url, invoker, task_id_str, reason)
    unless privileged?(invoker)
      post_response(response_url, :ephemeral, '❌ Only admins and resource managers can reject tasks.')
      return
    end

    unless task_id_str.present? && reason.present?
      post_response(response_url, :ephemeral, 'Usage: `/volunteer reject <task-id> <reason>`')
      return
    end

    task = VolunteerTask.find(task_id_str) rescue nil
    unless task
      post_response(response_url, :ephemeral, "❌ Task not found: #{task_id_str}")
      return
    end

    unless task.status == 'pending'
      post_response(response_url, :ephemeral, "❌ Task *#{task.title}* is not pending verification (status: #{task.status}).")
      return
    end

    task.reject_pending!(invoker, reason)
    post_response(response_url, :in_channel,
      "❌ Task *#{task.title}* completion was rejected. Reason: #{reason}. Task is available for reclaiming.")
  rescue Error::Forbidden
    post_response(response_url, :ephemeral, '❌ You cannot reject your own task.')
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  def usage_text
    <<~TEXT
      *Volunteer Commands:*
      `/volunteer status [@member]` — Check credit status
      `/volunteer tasks` — List available bounty tasks
      `/volunteer claim <task-id>` — Claim a bounty task
      `/volunteer done <task-id>` — Mark your claimed task as complete
      `/volunteer award @member <reason>` — _(admin/RM)_ Award a one-off credit (1 credit)
      `/volunteer verify <task-id>` — _(admin/RM)_ Verify a completed task
      `/volunteer release <task-id> <reason>` — _(admin/RM)_ Release a stale claimed task
      `/volunteer reject <task-id> <reason>` — _(admin/RM)_ Reject a pending task
    TEXT
  end

  def privileged?(member)
    member.role.in?(%w[admin resource_manager])
  end

  def find_member_by_slack_id(slack_id)
    slack_user = SlackUser.find_by(slack_id: slack_id)
    return nil unless slack_user
    Member.find(slack_user.member_id) rescue nil
  end

  def find_member_from_token(token)
    if token.start_with?('<@')
      slack_id   = token.match(/<@([^|>]+)/i)&.captures&.first
      slack_user = SlackUser.find_by(slack_id: slack_id)
      slack_user ? (Member.find(slack_user.member_id) rescue nil) : nil
    elsif token.start_with?('@')
      username   = token.sub(/\A@/, '')
      slack_user = SlackUser.where(name: /\A#{Regexp.escape(username)}\z/i).first
      slack_user ? (Member.find(slack_user.member_id) rescue nil) : nil
    else
      Member.find_by(email: token.downcase)
    end
  end

  def post_response(response_url, response_type, text)
    uri  = URI.parse(response_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    req  = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = { response_type: response_type, text: text }.to_json
    http.request(req)
  rescue => err
    Honeybadger.notify('SlackVolunteerJob: failed to post response', context: {
      error: err.message, response_url: response_url
    }) if defined?(Honeybadger)
  end
end
