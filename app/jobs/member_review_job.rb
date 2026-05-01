class MemberReviewJob < ApplicationJob
  queue_as :default

  def perform
    begin
      Rake::Task["member_review"].reenable
      Rake::Task["member_review"].invoke
      SystemConfig.record_run("member_review", success: true)
    rescue => e
      SystemConfig.record_run("member_review", success: false)
      Honeybadger.notify("MemberReviewJob failed", context: { error: e.message })
      raise e
    end
  end
end
