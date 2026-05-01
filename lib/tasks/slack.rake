namespace :slack do
  desc "Sync Slack workspace users to SlackUser records, matching by email to Member accounts.
        Controlled via SystemConfig key 'slack_sync_enabled' — toggle from the admin settings UI."
  task sync_users: :environment do
    unless SystemConfig.enabled?(SystemConfig::SLACK_SYNC_ENABLED)
      puts "[Slack Sync] Skipping — slack_sync_enabled is not set to true in SystemConfig"
      puts "[Slack Sync] Enable via the admin settings page or:"
      puts "[Slack Sync]   SystemConfig.set('slack_sync_enabled', 'true')"
      next
    end

    unless ENV['SLACK_ADMIN_TOKEN'].present?
      puts "[Slack Sync] ERROR: SLACK_ADMIN_TOKEN is not set — cannot connect to Slack API"
      Honeybadger.notify("Slack user sync failed", context: { reason: "SLACK_ADMIN_TOKEN not set" })
      next
    end

    client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])

    created_count  = 0
    updated_count  = 0
    skipped_count  = 0
    unmatched      = []

    puts "[Slack Sync] Starting Slack user sync..."

    begin
      cursor      = nil
      slack_users = []

      loop do
        response = client.users_list(limit: 200, cursor: cursor)

        unless response["ok"]
          puts "[Slack Sync] ERROR: Slack API returned not-ok response"
          Honeybadger.notify("Slack user sync failed", context: { reason: "Slack API returned ok=false" })
          next
        end

        slack_users.concat(response["members"])
        cursor = response.dig("response_metadata", "next_cursor")
        break if cursor.blank?
      end

      puts "[Slack Sync] Fetched #{slack_users.size} users from Slack workspace"

      slack_users.each do |slack_user|
        next if slack_user["is_bot"]
        next if slack_user["deleted"]
        next if slack_user["id"] == "USLACKBOT"

        slack_id    = slack_user["id"]
        slack_email = slack_user.dig("profile", "email").to_s.strip.downcase
        name        = slack_user["name"].to_s.strip
        real_name   = slack_user.dig("profile", "real_name").to_s.strip

        if slack_email.blank?
          puts "[Slack Sync] SKIP #{name} (#{slack_id}) — no email on profile"
          skipped_count += 1
          next
        end

        member = Member.find_by(email: slack_email)

        unless member
          unmatched << { slack_id: slack_id, name: name, email: slack_email }
          next
        end

        existing = SlackUser.find_by(slack_id: slack_id)

        if existing
          existing.set(
            slack_email: slack_email,
            name:        name,
            real_name:   real_name
          )
          puts "[Slack Sync] UPDATED #{real_name} (#{slack_id}) -> Member #{member.fullname}"
          updated_count += 1
        else
          SlackUser.create!(
            slack_id:    slack_id,
            slack_email: slack_email,
            name:        name,
            real_name:   real_name,
            member:      member
          )
          puts "[Slack Sync] CREATED #{real_name} (#{slack_id}) -> Member #{member.fullname}"
          created_count += 1
        end
      end

    rescue Slack::Web::Api::Errors::SlackError => e
      puts "[Slack Sync] ERROR: Slack API error — #{e.message}"
      Honeybadger.notify("Slack user sync failed", context: { error: e.message, reason: "Slack API error" })
      next
    rescue => e
      puts "[Slack Sync] ERROR: Unexpected error — #{e.message}"
      Honeybadger.notify("Slack user sync failed", context: { error: e.message, reason: "Unexpected error" })
      next
    end

    puts ""
    puts "[Slack Sync] ✅ Sync complete"
    puts "[Slack Sync]   Created:               #{created_count}"
    puts "[Slack Sync]   Updated:               #{updated_count}"
    puts "[Slack Sync]   Skipped (no email):    #{skipped_count}"
    puts "[Slack Sync]   Unmatched (no member): #{unmatched.size}"

    if unmatched.any?
      puts ""
      puts "[Slack Sync] Unmatched Slack users (no Member record with matching email):"
      unmatched.each do |u|
        puts "[Slack Sync]   #{u[:name]} (#{u[:slack_id]}) — #{u[:email]}"
      end
    end
  end
end
