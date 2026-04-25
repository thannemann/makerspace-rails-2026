class Admin::RentalsController < AdminController
  include FastQuery::MongoidQuery
  before_action :authorized?
  before_action :set_rental, only: [:update, :destroy, :approve, :deny]

  def index
    rentals = if search_params[:member_id].present?
      Rental.where(member_id: search_params[:member_id])
    elsif search_params[:status].present?
      Rental.where(status: search_params[:status])
    else
      Rental.all
    end
    render_with_total_items(
      query_resource(rentals),
      { each_serializer: RentalSerializer, adapter: :attributes }
    )
  end

  def create
    @rental = Rental.new(create_rental_params)
    @rental.status = "active"
    @rental.save!
    render json: @rental, adapter: :attributes
  end

  def update
    initial_date = @rental.get_expiration
    @rental.update_attributes!(update_rental_params)
    notify_renewal(initial_date)
    @rental.reload
    render json: @rental, adapter: :attributes
  end

  def destroy
    raise ::Error::Forbidden.new unless is_admin?
    @rental.destroy
    render json: {}, status: 204
  end

  # POST /api/admin/rentals/:id/approve
  def approve
    raise ::Error::UnprocessableEntity.new("Rental is not pending approval.") unless @rental.status == "pending"

    # Move to pending_agreement — member must sign before going active
    @rental.update_attributes!(status: "pending_agreement")

    member = @rental.member
    profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}"

    enque_message("✅ *#{member.fullname}*'s rental request for *#{@rental.number}* has been approved — awaiting agreement signature.")

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message("Your rental request for *#{@rental.number}* has been approved! Please sign your rental agreement to complete the process: #{profile_url}", slack_user.slack_id)
    end

    RentalMailer.rental_request_approved(member.id.to_s, @rental.id.to_s).deliver_later

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  # POST /api/admin/rentals/:id/deny
  def deny
    raise ::Error::UnprocessableEntity.new("Rental is not pending approval.") unless @rental.status == "pending"

    reason = params[:reason].presence || "Your rental request was not approved at this time."
    @rental.update_attributes!(
      status: "denied",
      notes:  [@rental.notes, "Denied: #{reason}"].compact.join(" | ")
    )

    member = @rental.member
    enque_message("❌ *#{member.fullname}*'s rental request for *#{@rental.number}* has been denied.")

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message("Your rental request for *#{@rental.number}* was not approved. Reason: #{reason}", slack_user.slack_id)
    end

    RentalMailer.rental_request_denied(member.id.to_s, @rental.id.to_s, reason).deliver_later

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  private

  def authorized?
    raise ::Error::Forbidden.new unless is_admin? || is_resource_manager?
  end

  def set_rental
    @rental = Rental.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Rental, { id: params[:id] }) if @rental.nil?
  end

  def create_rental_params
    params.require([:number, :member_id])
    params.permit(:number, :member_id, :expiration, :description, :contract_on_file, :notes, :rental_spot_id)
  end

  def update_rental_params
    params.permit(:number, :member_id, :expiration, :description, :renew, :contract_on_file, :notes, :status)
  end

  def search_params
    params.permit(:member_id, :status)
  end

  def notify_renewal(init)
    final = @rental.get_expiration
    if final && (init.nil? || (Time.at(final / 1000) - Time.at((init || 0) / 1000) > 1.day))
      @rental.send_renewal_slack_message(current_member)
    end
  end
end
