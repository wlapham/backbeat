FactoryGirl.define do
  factory :v2_node, class: V2::Node do
    mode :blocking
    current_server_status :pending
    current_client_status :ready
    name :test_node
    fires_at Time.now
  end
end
