class RentalSpotsController < AuthenticationController
  include FastQuery::MongoidQuery

  def index
    spots = RentalSpot.where(active: true)
    spots = spots.where(rental_type_id: params[:rental_type_id]) if params[:rental_type_id].present?

    if params[:available] == "true"
      available = spots.select(&:available?)
      return render json: available, each_serializer: RentalSpotSerializer, adapter: :attributes
    end

    render_with_total_items(
      query_resource(spots),
      { each_serializer: RentalSpotSerializer, adapter: :attributes }
    )
  end

  def show
    @spot = RentalSpot.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: params[:id] }) if @spot.nil?
    render json: @spot, serializer: RentalSpotSerializer, adapter: :attributes
  end
end
