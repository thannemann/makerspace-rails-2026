require 'timeout'

namespace :db do
  desc "Clears the db for testing."
  task :db_reset, [:options] => :environment do |t, args|
    if Rails.env.test?
      require 'factory_bot'
      require 'database_cleaner'

      puts "Cleaning db..."

      Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }
      DatabaseCleaner.strategy = :truncation
      DatabaseCleaner.clean
      FactoryBot.rewind_sequences

      # Collect extra arguments
      braintree_options = (args[:options] || "").split(",").map(&:to_sym)
      puts "Braintree options: #{braintree_options.inspect}"

      if braintree_options.length > 0
        puts "Connecting to Braintree gateway..."
        gateway = ::Service::BraintreeGateway.connect_gateway
        cancel_subscriptions(gateway) if braintree_options.include?(:subscriptions)
        delete_payment_methods(gateway) if braintree_options.include?(:payment_methods)
      else
        puts "No Braintree options provided, skipping Braintree cleanup."
      end
      puts "DB cleaned, seeding.."

      SeedData.new.call
      puts "Seeding complete, done."
    end
  end

  task :reject_card, [:number] => :environment do |t, args|
    require 'factory_bot'
    Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

    if args[:number].nil? then
      last_card = RejectionCard.all.last
      new_uid = last_card.nil? ? "0001" : ("%04d" % (last_card.uid.to_i + 1))
    else
      new_uid = args[:number]
    end
    rejection_card = FactoryBot.create(:rejection_card, uid: "#{new_uid}")
  end

  task :braintree_webhook, [:member_email] => :environment do |t, args|
    if args[:member_email]
      Timeout::timeout(30) do
        member = Member.find_by(email: args[:member_email])
        invoice = Invoice.active_invoice_for_resource(member.id)
        sample_notification = ::Service::BraintreeGateway.connect_gateway.webhook_testing.sample_notification(
          Braintree::WebhookNotification::Kind::SubscriptionCanceled,
          invoice.subscription_id
        )
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post "/billing/braintree_listener", { params: sample_notification }
      end
    end
  end

  task :paypal_webhook, [:member_email] => :environment do |t, args|
    if args[:member_email]
      Timeout::timeout(30) do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.post "/ipnlistener", { params: { 
          "payer_email" => args[:member_email],
          "txn_type": "subscr_cancel"
        } }
      end
    end
  end
end

def cancel_subscriptions(gateway)
  puts "Fetching subscriptions to cancel..."
  begin
    subscriptions = ::BraintreeService::Subscription.get_subscriptions(gateway, Proc.new do |search|
      search.status.in(
        Braintree::Subscription::Status::Active,
        Braintree::Subscription::Status::PastDue,
        Braintree::Subscription::Status::Pending
      )
    end)
    puts "Found #{subscriptions.length} subscription(s) to cancel."
    subscriptions.each do |subscription|
      begin
        gateway.subscription.cancel(subscription.id)
        puts "Cancelled subscription #{subscription.id}"
      rescue => e
        STDERR.puts "Failed to cancel subscription #{subscription.id}: #{e.message}"
      end
    end
    puts "Subscription cancellation complete."
  rescue => e
    STDERR.puts "Failed to fetch subscriptions from Braintree: #{e.message}"
    STDERR.puts e.backtrace.first(5).join("\n")
  end
end

def delete_payment_methods(gateway)
  puts "Fetching payment methods to delete..."
  customers = Member.where(:customer_id.nin => ["", nil])
  puts "Found #{customers.length} customer(s) with payment methods."
  results = []

  customers.each do |customer|
    payment_methods = ::BraintreeService::PaymentMethod.get_payment_methods_for_customer(gateway, customer.customer_id)
    puts "Customer #{customer.customer_id} has #{payment_methods.length} payment method(s)."
    payment_methods.each do |payment_method|
      result = ::BraintreeService::PaymentMethod.delete_payment_method(gateway, payment_method.token)
      puts "Deleted payment method #{payment_method.token}: #{result.success? ? 'success' : 'failed'}"
      results.push(result)
    end
  end

  evaluate_results(results)
  puts "Payment method deletion complete."
end

def evaluate_results(results)
  failures = results.select { |r| !r.success? }
  if failures.length > 0
    STDERR.puts "#{failures.length} payment method deletion(s) failed:"
    failures.each do |failure|
      failure.errors.each do |error|
        STDERR.puts "  Attribute: #{error.attribute}"
        STDERR.puts "  Code: #{error.code}"
        STDERR.puts "  Message: #{error.message}"
      end
    end
  end
end
