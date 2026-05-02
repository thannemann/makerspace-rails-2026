# Service::SlackUserSync
#
# Shared service for syncing Slack users to Member records.
#
# Two entry points:
#   Service::SlackUserSync.sync_single(slack_id)
#     — Fetches one user from the Slack API by slack_id, matches by email
#       to a Member record, creates or updates the SlackUser record.
#       Returns the Member if found, nil if no matching member exists.
#       Called reactively when a Slack command fails with "user not linked".
#
#   Service::SlackUserSync.sync_all
#     — Bulk syncs all non-bot, non-deleted Slack workspace users.
#       Called by the "Run Now" button in System Settings and the rake task.
#       Controlled by SystemConfig 'slack_sync_enabled' flag.
#
module Service
  module SlackUserSync

    # Sync a single Slack user by slack_id.
    # Returns the linked Member if found and matched, nil otherwise.
    # Posts to logs_channel if the user has no matching Member record.
    def self.sync_single(slack_id)
      unless ENV['SLACK_ADMIN_TOKEN'].present?
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack single-user sync failed: SLACK_ADMIN_TOKEN not set.",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])

      begin
        response = client.users_info(user: slack_id)
      rescue Slack::Web::Api::Errors::SlackError => e
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack single-user sync failed for #{slack_id}: #{e.message}",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      slack_user_data = response['user']
      return nil unless slack_user_data

      slack_email = slack_user_data.dig('profile', 'email').to_s.strip.downcase
      name        = slack_user_data['name'].to_s.strip
      real_name   = slack_user_data.dig('profile', 'real_name').to_s.strip

      member = slack_email.present? ? Member.find_by(email: slack_email) : nil

      unless member
        # Notify admins that someone tried a command with no linked account
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack user *#{real_name.presence || name}* (`#{slack_id}`)" \
          " attempted a command but has no linked Member account." \
          "#{slack_email.present? ? " Email on file: #{slack_email}" : ' No email on Slack profile.'}",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      existing = SlackUser.find_by(slack_id: slack_id)
      if existing
        existing.set(slack_email: slack_email, name: name, real_name: real_name)
      else
        SlackUser.create!(
          slack_id:    slack_id,
          slack_email: slack_email,
          name:        name,
          real_name:   real_name,
          member:      member
        )
      end

      member
    end

    # Bulk sync all Slack workspace users.
    # Respects the slack_sync_enabled SystemConfig flag.
    # Returns a result hash with counts for logging.
    def self.sync_all
      unless SystemConfig.enabled?(SystemConfig::SLACK_SYNC_ENABLED)
        puts '[Slack Sync] Skipping — slack_sync_enabled is not set to true in SystemConfig'
        return { skipped: true }
      end

      unless ENV['SLACK_ADMIN_TOKEN'].present?
        msg = '[Slack Sync] ERROR: SLACK_ADMIN_TOKEN is not set — cannot connect to Slack API'
        puts msg
        Honeybadger.notify('Slack user sync failed', context: { reason: 'SLACK_ADMIN_TOKEN not set' }) if defined?(Honeybadger)
        raise msg
      end

      client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])

      created_count = 0
      updated_count = 0
      skipped_count = 0
      unmatched     = []

      puts '[Slack Sync] Starting Slack user sync...'

      begin
        cursor      = nil
        slack_users = []

        loop do
          response = client.users_list(limit: 200, cursor: cursor)

          unless response['ok']
            raise 'Slack API returned ok=false'
          end

          slack_users.concat(response['members'])
          cursor = response.dig('response_metadata', 'next_cursor')
          break if cursor.blank?
        end

        puts "[Slack Sync] Fetched #{slack_users.size} users from Slack workspace"

        slack_users.each do |slack_user|
          next if slack_user['is_bot']
          next if slack_user['deleted']
          next if slack_user['id'] == 'USLACKBOT'

          slack_id    = slack_user['id']
          slack_email = slack_user.dig('profile', 'email').to_s.strip.downcase
          name        = slack_user['name'].to_s.strip
          real_name   = slack_user.dig('profile', 'real_name').to_s.strip

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
            existing.set(slack_email: slack_email, name: name, real_name: real_name)
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
        Honeybadger.notify('Slack user sync failed', context: { error: e.message, reason: 'Slack API error' }) if defined?(Honeybadger)
        raise e
      rescue => e
        puts "[Slack Sync] ERROR: Unexpected error — #{e.message}"
        Honeybadger.notify('Slack user sync failed', context: { error: e.message, reason: 'Unexpected error' }) if defined?(Honeybadger)
        raise e
      end

      puts ''
      puts '[Slack Sync] ✅ Sync complete'
      puts "[Slack Sync]   Created:               #{created_count}"
      puts "[Slack Sync]   Updated:               #{updated_count}"
      puts "[Slack Sync]   Skipped (no email):    #{skipped_count}"
      puts "[Slack Sync]   Unmatched (no member): #{unmatched.size}"

      if unmatched.any?
        puts ''
        puts '[Slack Sync] Unmatched Slack users (no Member record with matching email):'
        unmatched.each do |u|
          puts "[Slack Sync]   #{u[:name]} (#{u[:slack_id]}) — #{u[:email]}"
        end
      end

      { created: created_count, updated: updated_count, skipped: skipped_count, unmatched: unmatched.size }
    end
  end
end
