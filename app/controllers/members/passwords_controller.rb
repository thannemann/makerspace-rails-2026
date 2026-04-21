class Members::PasswordsController < AuthenticationController
  # PUT /api/members/password
  # Authenticated member changes their own password directly (no reset token required).
  def update
    password = password_params[:password]
    raise ::Error::UnprocessableEntity.new("Password cannot be blank") if password.blank?
    raise ::Error::UnprocessableEntity.new("Password is too short (minimum 8 characters)") if password.length < 8

    current_member.password = password
    current_member.save!
    render json: {}, status: 204 and return
  end

  private
  def password_params
    params.require(:password)
    params.permit(:password)
  end
end
