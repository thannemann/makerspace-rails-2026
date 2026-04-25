class RentalsController < AuthenticationController
  include FastQuery::MongoidQuery
  before_action :set_rental, only: [:show, :update, :cancel, :decline_agreement]

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

  # POST /api/rentals — member claims a rental spot
  def create
    unless current_member.status == "activeMember"
      raise ::Error::Forbidden.new("Your membership is not active. Please renew before requesting a rental.")
    end

    past_due = Invoice.where(member_id: current_member.id, settled_at: nil, transaction_id: nil)
                      .select(&:past_due)
    if past_due.any?
      raise ::Error::Forbidden.new("You have outstanding past due invoices. Please settle your balance before requesting a rental.")
    end

    spot = RentalSpot.find(params[:rental_spot_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: params[:rental_spot_id] }) if spot.nil?
    raise ::Error::UnprocessableEntity.new("This rental is not currently available.") unless spot.available?

    # All rentals start as pending_agreement or pending (approval required)
    status = spot.requires_approval? ? "pending" : "pending_agreement"

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
    end
    # No invoice generated yet — happens after agreement is signed

    render json: @rental, serializer: RentalSerializer, adapter: :attributes, status: 201
  end

  # PUT /api/rentals/:id — member signs rental agreement
  def update
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental agreement cannot be signed at this stage.") unless @rental.status == "pending_agreement"

    encoded_signature = update_params[:signature]&.split(",")&.[](1)
    if encoded_signature
      DocumentUploadJob.perform_later(encoded_signature, "rental_agreement", @rental.id.as_json)
      @rental.update_attributes!(
        contract_signed_date: Date.today,
        status: "active"
      )

      # Generate invoice NOW — after agreement is signed
      spot = @rental.rental_spot
      if spot&.invoice_option.present?
        spot.invoice_option.build_invoice(current_member.id, Time.now, @rental.id.to_s)
      end

      member = current_member
      profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}/invoices"

      slack_user = SlackUser.find_by(member_id: member.id)
      unless slack_user.nil?
        enque_message("You've signed your rental agreement for *#{@rental.number}*! ⚠ Your rental is not valid until payment is received. Please pay your invoice here: #{profile_url}", slack_user.slack_id)
      end

      RentalMailer.rental_claimed(member.id.to_s, @rental.id.to_s).deliver_later
    end

    render json: @rental, adapter: :attributes
  end

  # DELETE /api/rentals/:id/decline_agreement — member declines rental agreement
  def decline_agreement
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental is not pending agreement.") unless @rental.status == "pending_agreement"

    @rental.update_attributes!(
      status: "agreement_denied",
      notes: [@rental.notes, "Agreement declined by member on #{Date.today}"].compact.join(" | ")
    )

    member = current_member
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message("Your rental claim for *#{@rental.number}* has been cancelled because the rental agreement was not signed.", slack_user.slack_id)
    end
    enque_message("❌ #{member.fullname} declined the rental agreement for *#{@rental.number}*. Rental voided.")

    render json: @rental, serializer: RentalSerializer, adapter: :attributes
  end

  # DELETE /api/rentals/:id/cancel
  def cancel
    raise ::Error::Forbidden.new unless @rental.member_id.to_s == current_member.id.to_s
    raise ::Error::UnprocessableEntity.new("Rental is already cancelled.") if ["cancelled", "agreement_denied"].include?(@rental.status)

    vacated = params[:vacated].to_s == "true"

    if @rental.subscription_id.present?
      begin
        gateway = ::Service::BraintreeGateway.connect_gateway
        ::BraintreeService::Subscription.cancel(gateway, @rental.subscription_id)
      rescue => err
        Rails.logger.error("Error cancelling Braintree subscription for rental #{@rental.id}: #{err}")
      end
    end

    if vacated
      active_invoice = Invoice.active_invoice_for_resource(@rental.id)
      active_invoice&.destroy
      @rental.update_attributes!(status: "cancelled")
      notify_rental_ended(@rental, "Your rental of #{@rental.number} has ended.")
    else
      @rental.update_attributes!(status: "vacating")
      expiry = @rental.expiration ? Time.at(@rental.expiration / 1000).strftime("%B %-d, %Y") : "the end of your current rental period"
      notify_rental_vacating(@rental, expiry)
    end

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
    admin_message = "🔔 New rental request from *#{member.fullname}* for *#{spot.number}* (#{spot.rental_type&.display_name} — #{spot.location}). Please review in the admin portal."
    enque_message(admin_message)

    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message("Your rental request for *#{spot.number}* has been received and is pending admin approval.", slack_user.slack_id)
    end

    RentalMailer.rental_request_pending(member.id.to_s, rental.id.to_s, spot.id.to_s).deliver_later
  end

  def notify_rental_ended(rental, message)
    member = rental.member
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message("Your rental of *#{rental.number}* has ended.", slack_user.slack_id)
    end
    enque_message("🔴 #{member.fullname}'s rental of *#{rental.number}* has been cancelled.")
    RentalMailer.rental_ended(member.id.to_s, rental.id.to_s).deliver_later
  end

  def notify_rental_vacating(rental, expiry)
    member = rental.member
    slack_user = SlackUser.find_by(member_id: member.id)
    unless slack_user.nil?
      enque_message("Your rental of *#{rental.number}* will end on #{expiry}. Please ensure you have vacated by then.", slack_user.slack_id)
    end
    enque_message("🟡 #{member.fullname}'s rental of *#{rental.number}* is vacating — expires #{expiry}.")
    RentalMailer.rental_vacating(member.id.to_s, rental.id.to_s, expiry).deliver_later
  end
end
