class Admin::RentalSpotsController < AdminController
  include FastQuery::MongoidQuery
  before_action :set_spot, only: [:update, :destroy]

  def index
    spots = RentalSpot.all
    spots = spots.where(rental_type_id: params[:rental_type_id]) if params[:rental_type_id].present?
    spots = spots.where(active: params[:active] == "true") if params[:active].present?
    render_with_total_items(
      query_resource(spots),
      { each_serializer: RentalSpotSerializer, adapter: :attributes }
    )
  end

  def create
    @spot = RentalSpot.new(spot_params)
    @spot.save!
    render json: @spot, serializer: RentalSpotSerializer, adapter: :attributes
  end

  def update
    @spot.update_attributes!(spot_params)
    render json: @spot, serializer: RentalSpotSerializer, adapter: :attributes
  end

  def destroy
    @spot.destroy
    render json: {}, status: 204
  end

  private

  def set_spot
    @spot = RentalSpot.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: params[:id] }) if @spot.nil?
  end

  def spot_params
    params.require(:number)
    params.require(:rental_type_id)
    params.require(:location)
    params.permit(:number, :location, :description, :rental_type_id,
                  :requires_approval, :active, :parent_number, :notes)
  end
end
