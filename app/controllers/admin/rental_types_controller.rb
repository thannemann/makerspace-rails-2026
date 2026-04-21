class Admin::RentalTypesController < AdminController
  include FastQuery::MongoidQuery
  before_action :set_rental_type, only: [:update, :destroy]

  def index
    types = RentalType.all
    render_with_total_items(
      query_resource(types),
      { each_serializer: RentalTypeSerializer, adapter: :attributes }
    )
  end

  def create
    @rental_type = RentalType.new(rental_type_params)
    @rental_type.save!
    render json: @rental_type, serializer: RentalTypeSerializer, adapter: :attributes
  end

  def update
    @rental_type.update_attributes!(rental_type_params)
    render json: @rental_type, serializer: RentalTypeSerializer, adapter: :attributes
  end

  def destroy
    @rental_type.destroy
    render json: {}, status: 204
  end

  private

  def set_rental_type
    @rental_type = RentalType.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalType, { id: params[:id] }) if @rental_type.nil?
  end

  def rental_type_params
    params.require(:display_name)
    params.permit(:display_name, :active, :invoice_option_id)
  end
end
