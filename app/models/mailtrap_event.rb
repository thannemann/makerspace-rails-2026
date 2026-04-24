class MailtrapEvent
  include Mongoid::Document
  include Mongoid::Attributes::Dynamic
  include Mongoid::Timestamps::Created

  store_in collection: "mailtrap"

  field :member_id, type: BSON::ObjectId
  field :email, type: String
  field :status, type: String
  field :occurred_at, type: Time
end
