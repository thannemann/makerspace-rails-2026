class Admin::CheckoutApproversController < AdminController
  # Only full admins can manage who gets approver status
  before_action :find_approver, only: [:update, :destroy]

  def index
    approvers = CheckoutApprover.all
    render json: approvers, each_serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def create
    # Upsert — if approver already exists, update their shops
    approver = CheckoutApprover.find_or_initialize_by(member_id: approver_params[:member_id])
    approver.shop_ids = approver_params[:shop_ids] || []
    approver.save!
    render json: approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def update
    @approver.update_attributes!(approver_params)
    render json: @approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def destroy
    @approver.destroy
    render json: {}, status: 204
  end

  private

  def approver_params
    params.permit(:member_id, shop_ids: [])
  end

  def find_approver
    @approver = CheckoutApprover.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(CheckoutApprover, { id: params[:id] }) if @approver.nil?
  end
end
