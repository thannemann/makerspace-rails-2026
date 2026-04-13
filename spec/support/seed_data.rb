require 'factory_bot'
Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

class SeedData
  include FactoryBot::Syntax::Methods

  # Number of Basic Members to create real Braintree sandbox subscriptions for.
  # These members will appear on the subscription screen with their names visible.
  SUBSCRIPTION_MEMBER_COUNT = 5

  # Braintree sandbox test nonce for a valid Visa card.
  # Nonces are single-use in production but reusable in sandbox.
  # See: https://developer.paypal.com/braintree/docs/reference/general/testing
  SANDBOX_PAYMENT_NONCE = "fake-valid-visa-nonce".freeze

  # Plan ID must match an existing plan in your Braintree sandbox account.
  SANDBOX_PLAN_ID = "membership-one-month-recurring".freeze

  def call
    create_permissions
    create_members
    create_resource_managers
    create_rentals
    create_payments
    create_group
    create_rejection_cards
    create_invoice_options
    create_subscriptions
  end

  private

  def create_members
    create_expired_members
    create_admins
    100.times do |n|
      create(:member,
        email: "basic_member#{n}@test.com",
        firstname: "Basic",
        lastname: "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
    5.times do |n|
      create(:member,
        email: "paypal_member#{n}@test.com",
        firstname: "PayPal",
        lastname: "Member#{n}",
        subscription: true,
        expirationTime: (Time.now + n.months).to_i * 1000
      )
    end
  end

  def create_expired_members
    20.times do |n|
      create(:member, :expired,
        email: "expired_member#{n}@test.com",
        firstname: "Expired",
        lastname: "Member#{n}"
      )
    end
  end

  def create_admins
    5.times do |n|
      create(:member, :admin,
        email: "admin_member#{n}@test.com",
        firstname: "Admin",
        lastname: "Member#{n}"
      )
    end
  end

  def create_resource_managers
    3.times do |n|
      create(:member, :resource_manager,
        email: "rm_member#{n}@test.com",
        firstname: "Resource",
        lastname: "Manager#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  def create_rentals
    20.times do |n|
       create(:rental,
        member: Member.skip(n).limit(1).first
      )
    end
  end

  def create_payments
    10.times { create(:payment) }
  end

  def create_group
    create(:group, member: Member.where(email: 'admin_member0@test.com').first)
  end

  def create_rejection_cards
    create(:rejection_card, uid: '0000', timeOf: Date.today)
    create(:rejection_card, uid: '0001', timeOf: Date.today)
    create(:rejection_card, uid: '0002', timeOf: Date.today)
  end

  def create_invoice_options
    create(:invoice_option, name: "One Month", amount: 65.0, id: "one-month", plan_id: "membership-one-month-recurring")
    create(:invoice_option, name: "Three Months", amount: 200.0, id: "three-months")
    create(:invoice_option, name: "One Year", amount: 800.0, id: "one-year")
  end

  def create_permissions
    DefaultPermission.create(name: :billing, enabled: true)
    DefaultPermission.create(name: :custom_billing, enabled: false)
    DefaultPermission.create(name: :earned_membership, enabled: true)
  end

  # Creates real Braintree sandbox subscriptions for the first N Basic Members.
  # Mirrors the full production flow:
  #   1. Create a Braintree customer for the member
  #   2. Add a payment method using a sandbox test nonce
  #   3. Create a subscription using that payment method token
  #   4. Store subscription_id and customer_id back on the MongoDB member
  # This ensures the subscription screen shows member names correctly after every reseed.
  def create_subscriptions
    gateway = Service::BraintreeGateway.connect_gateway
    invoice_option = InvoiceOption.find("one-month")

    SUBSCRIPTION_MEMBER_COUNT.times do |n|
      member = Member.find_by(email: "basic_member#{n}@test.com")
      next unless member

      begin
        # Step 1 — Create Braintree customer
        customer_result = gateway.customer.create(
          first_name: member.firstname,
          last_name: member.lastname,
          email: member.email,
          payment_method_nonce: SANDBOX_PAYMENT_NONCE
        )

        unless customer_result.success?
          puts "  [seed] Warning: Failed to create Braintree customer for #{member.fullname}: #{customer_result.message}"
          next
        end

        customer = customer_result.customer
        payment_method_token = customer.payment_methods.first.token

        # Store customer_id on member
        member.update!(customer_id: customer.id)

        # Step 2 — Create invoice in MongoDB (needed to generate subscription ID)
        invoice = Invoice.create!(
          member: member,
          name: invoice_option.name,
          description: invoice_option.description,
          amount: invoice_option.amount,
          quantity: invoice_option.quantity,
          plan_id: invoice_option.plan_id,
          payment_method_id: payment_method_token,
          resource_class: "member",
          resource_id: member.id,
          operation: invoice_option.operation,
          due_date: Time.now + 1.month
        )

        # Step 3 — Create Braintree subscription using generated ID
        subscription_id = invoice.generate_subscription_id
        sub_result = gateway.subscription.create(
          payment_method_token: payment_method_token,
          plan_id: SANDBOX_PLAN_ID,
          id: subscription_id
        )

        unless sub_result.success?
          puts "  [seed] Warning: Failed to create Braintree subscription for #{member.fullname}: #{sub_result.message}"
          next
        end

        # Step 4 — Store subscription_id on member and mark invoice as settled
        member.update!(subscription_id: subscription_id, subscription: true)
        invoice.update!(subscription_id: subscription_id, settled_at: Time.now)

        puts "  [seed] Created subscription for #{member.fullname}: #{subscription_id}"

      rescue => e
        puts "  [seed] Error creating subscription for basic_member#{n}: #{e.message}"
      end
    end
  end
end