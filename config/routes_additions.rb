# Routes additions for config/routes.rb
#
# 1. Add the Slack volunteer command route alongside the existing checkout route:
#
#   namespace :slack do
#     post '/commands/checkout',  to: 'commands#checkout'
#     post '/commands/volunteer', to: 'commands#volunteer'   # <-- ADD THIS
#   end
#
# 2. Add public bounty board routes OUTSIDE the authenticate :member block
#    (unauthenticated — token gated via SystemConfig instead):
#
#   namespace :volunteer do
#     get '/bounties', to: 'bounties#index'
#   end
#
# 3. Inside the `authenticate :member do` block, add member-facing volunteer routes:
#
#   get  '/volunteer/credits',             to: 'volunteer#credits'
#   get  '/volunteer/summary',             to: 'volunteer#summary'
#   get  '/volunteer/tasks',               to: 'volunteer#tasks'
#   post '/volunteer/tasks/:id/claim',     to: 'volunteer#claim_task'
#   post '/volunteer/tasks/:id/complete',  to: 'volunteer#complete_task'
#
# 4. Inside the `namespace :admin do` block, add admin volunteer routes:
#
#   resources :volunteer_credits, only: [:index, :create, :destroy] do
#     member do
#       post :approve
#       post :reject
#     end
#   end
#
#   resources :volunteer_tasks, only: [:index, :create, :update, :destroy] do
#     member do
#       post :complete
#       post :cancel
#       post :release
#       post :reject_pending
#     end
#   end
