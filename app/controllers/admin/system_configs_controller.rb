class Admin::SystemConfigsController < AdminController

  # GET /api/admin/system_configs
  # Returns all feature flags and job statuses
  def index
    flags = {
      slack_sync_enabled: SystemConfig.enabled?(SystemConfig::SLACK_SYNC_ENABLED)
    }

    jobs = SystemConfig::JOB_KEYS.map do |job_key, task_name|
      status = SystemConfig.job_status(job_key)
      {
        key:             job_key,
        task:            task_name,
        last_run_at:     status&.dig(:last_run_at),
        last_run_status: status&.dig(:last_run_status)
      }
    end

    render json: { flags: flags, jobs: jobs }, status: :ok
  end

  # PUT /api/admin/system_configs/flags/:key
  # Toggle a feature flag
  def update_flag
    key   = params[:key]
    value = params[:value]

    allowed_keys = [SystemConfig::SLACK_SYNC_ENABLED]
    unless allowed_keys.include?(key)
      render json: { error: "Unknown config key: #{key}" }, status: :unprocessable_entity and return
    end

    SystemConfig.set(key, value)
    render json: { key: key, value: value }, status: :ok
  end

  # POST /api/admin/system_configs/jobs/:key/run
  # Enqueue a job to run now
  def run_job
    job_key = params[:key]

    unless SystemConfig::JOB_KEYS.key?(job_key)
      render json: { error: "Unknown job: #{job_key}" }, status: :unprocessable_entity and return
    end

    case job_key
    when "slack_sync"
      SlackSyncJob.perform_later
    when "member_review"
      MemberReviewJob.perform_later
    when "invoice_review"
      InvoiceReviewJob.perform_later
    when "garbage_collect"
      GarbageCollectJob.perform_later
    when "db_backup"
      DatabaseBackupJob.perform_later
    end

    render json: { message: "#{job_key} enqueued successfully" }, status: :ok
  end
end
