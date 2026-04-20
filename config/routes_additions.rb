# Add these routes to config/routes.rb
# inside the `authenticate :member do` block, alongside existing rental routes

# REPLACE the existing:
#   resources :rentals, only: [:show, :index, :update]
# WITH:

resources :rentals, only: [:show, :index, :update, :create] do
  member do
    delete :cancel
  end
end

resources :rental_spots, only: [:index, :show]

# REPLACE the existing admin rentals line:
#   resources :rentals, only: [:create, :update, :destroy, :index]
# WITH (inside namespace :admin block):

resources :rentals, only: [:create, :update, :destroy, :index] do
  member do
    post :approve
    post :deny
  end
end

resources :rental_spots, only: [:index, :create, :update, :destroy]
