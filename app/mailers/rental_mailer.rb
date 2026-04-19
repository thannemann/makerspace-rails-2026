class RentalMailer < ApplicationMailer
  ADMIN_EMAIL = "contact@manchestermakerspace.org".freeze

  def rental_request_pending(member, rental, spot)
    @member = member
    @rental = rental
    @spot   = spot
    mail(to: ADMIN_EMAIL, subject: "Rental Request Pending Approval — #{member.fullname} / #{spot.number}")
  end

  def rental_request_approved(member, rental)
    @member      = member
    @rental      = rental
    @profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}/dues"
    mail(to: member.email, subject: "Your Rental Request Has Been Approved — Manchester Makerspace")
  end

  def rental_claimed(member, rental)
    @member      = member
    @rental      = rental
    @profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{member.id}/dues"
    mail(to: member.email, subject: "Rental Spot Claimed — Payment Required — Manchester Makerspace")
  end

  def rental_request_denied(member, rental, reason)
    @member = member
    @rental = rental
    @reason = reason
    mail(to: member.email, subject: "Update on Your Rental Request — Manchester Makerspace")
  end
end
