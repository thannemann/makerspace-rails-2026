class RentalsController < AuthenticationController
  include FastQuery::MongoidQuery
  before_action :set_rental, only: [:show, :update, :cancel]

  def index
    @rentals = Rental.where(member_id: current_member.id)
    render_with_total_items(
      query_resource(@rentals),
      { each_serializer: RentalSerializer, adapter: :attributes }
    )
  end

  def show
    render json: @rental, adapter: :attributes
  end

  # POST /api/rentals — member requests or claims a rental spot
  def create
    # Guard: membership must be active
    unless current_member.status == "activeMember"
      raise ::Error::Forbidden.new("Your membership is not active. Please renew before requesting a rental.")
    end

    # Guard: no past due invoices
    past_due = Invoice.where(member_id: current_member.id, settled_at: nil, transaction_id: nil)
                      .select(&:past_due)
    if past_due.any?
      raise ::Error::Forbidden.new("You have outstanding past due invoices. Please settle your balance before requesting a rental.")
    end

    spot = RentalSpot.find(params[:rental_spot_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: params[:rental_spot_id] }) if spot.nil?
    raise ::Error::UnprocessableEntity.new("This spot is not currently available.") unless spot.available?

    status = spot.requires_approval? ? "pending" : "active"

    @rental = Rental.new(
      number:         spot.number,
      description:    spot.description,
      member_id:      current_member.id,
      status:         status,
      rental_spot_id: spot.id.to_s,
      notes:          params[:notes]
    )
    @rental.save!

    if spot.requires_approval?
      notify_admin_pending(@rental, spot)
    else
      create_invoice(@rental, spot)
    end

    render json: @rental, serializer: RentalSerializer, adapter: :attributes, status: 201
  end

  # PUT /api/rentals/:id — member signs rental agreement
  def update
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s

    encoded_signature = update_params[:signature]&.split(",")&.[](1)
    if encoded_signature
      DocumentUploadJob.perform_later(encoded_signature, "rental_agreement", @rental.id.as_json)
      @rental.update_attributes!(contract_signed_date: Date.today)
    end

    render json: @rental, adapter: :attributes
  end

  # DELETE /api/rentals/:id/cancel — member cancels their own rental
  def cancel
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental is already cancelled.") if @rental.status == "cancelled"

    if @rental.subscription_id.present?
      begin
        gateway = ::Service::BraintreeGateway.connect_gateway
        ::BraintreeService::Subscription.cancel(gateway, @rental.subscription_id)
      rescue => err
        Rails.logger.error("Error cancelling Braintree subscription for rental #{@rental.id}: #{err}")
      end
    end

    active_invoice = Invoice.active_invoice_for_resource(@rental.id)
    active_invoice&.destroy

    @rental.update_attributes!(status: "cancelled")
    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  private

  def set_rental
    @rental = Rental.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Rental, { id: params[:id] }) if @rental.nil?
  end

  def update_params
    params.require(:signature)
    params.permit(:signature)
  end

  def notify_admin_pending(rental, spot)
    member = current_member

    # Notify admin channel
    admin_message = "🔔 New rental request from *#{member.fullname}* for *#{spot.number}* (#{spot.rental_type&.display_name} — #{spot.location}). Please review in the admin portal."
    enque_message(admin_message)

    # DM the member directly if they have a Slack account
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      member_message = "Your rental request for *#{spot.number}* (#{spot.location}) has been received and is pending admin approval. You will be notified once it has been reviewed."
      enque_message(member_message, slack_user.slack_id)
    end

    RentalMailer.rental_request_pending(member, rental, spot).deliver_later
  end

  def create_invoice(rental, spot)
    invoice_option = spot.invoice_option
    return if invoice_option.nil?
    invoice_option.build_invoice(current_member.id, Time.now, rental.id.to_s)

    # Notify member to pay — rental is not valid until paid
    member = current_member
    profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}/dues"

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      member_message = "You've claimed *#{rental.number}*! ⚠ Your rental is not valid until payment is received. Please pay your invoice here: #{profile_url}"
      enque_message(member_message, slack_user.slack_id)
    end

    RentalMailer.rental_claimed(member, rental).deliver_later
  end
end
