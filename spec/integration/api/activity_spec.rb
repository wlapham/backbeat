require 'spec_helper'

describe Api::Workflow do
  include Goliath::TestHelper

  before do
    WorkflowServer::AsyncClient.stub(:make_decision)
  end

  context "PUT /workflows/:id/events/:event_id/change_status" do
    context "invalid status" do
      it "raises 400 if invalid new status" do
        with_api(Server) do |api|
          activity = FactoryGirl.create(:activity)
          wf = activity.workflow
          user = wf.user
          put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/change_status", head: {"CLIENT_ID" => user.client_id}, query: {status: :something_invalid}) do |c|
            c.response_header.status.should == 400
            activity.reload
            json_response = JSON.parse(c.response)
            json_response['error'].should == "Invalid status something_invalid"
          end
        end
      end
      context "activity completed" do
        it "returns 400 if the activity is not in executing state" do
          with_api(Server) do |api|
            activity = FactoryGirl.create(:activity, status: :open)
            wf = activity.workflow
            user = wf.user
            put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/change_status", head: {"CLIENT_ID" => user.client_id}, query: {status: :completed}) do |c|
              c.response_header.status.should == 400
              activity.reload
              json_response = JSON.parse(c.response)
              json_response['error'].should == "Activity #{activity.name} can't transition from open to completed"
            end
          end
        end
        it "returns 400 if the next decision is invalid" do
          with_api(Server) do |api|
            activity = FactoryGirl.create(:activity, status: :executing, parent: FactoryGirl.create(:decision))
            wf = activity.workflow
            user = wf.user
            put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/change_status", head: {"CLIENT_ID" => user.client_id}, query: {status: :completed, args: {next_decision: :test_decision}.to_json}) do |c|
              c.response_header.status.should == 400
              activity.reload
              json_response = JSON.parse(c.response)
              json_response['error'].should == "activity:#{activity.name} tried to make test_decision the next decision but is not allowed to."
              activity.status.should_not == :complete
            end
          end
        end
        it "returns 200 if the next decision is valid and the activity succeeds" do
          with_api(Server) do |api|
            activity = FactoryGirl.create(:activity, status: :executing, parent: FactoryGirl.create(:decision))
            wf = activity.workflow
            user = wf.user
            put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/change_status", head: {"CLIENT_ID" => user.client_id}, query: {status: :completed}) do |c|
              c.response_header.status.should == 200
              activity.reload
              activity.children.count.should == 1
              child = activity.children.first
              child.name.should == :make_initial_payment_succeeded
              activity.status.should == :complete
            end
          end
        end
      end
      context "activity errored" do
        it "returns 400 if the activity is not in executing state" do
          with_api(Server) do |api|
            activity = FactoryGirl.create(:activity, status: :open)
            wf = activity.workflow
            user = wf.user
            put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/change_status", head: {"CLIENT_ID" => user.client_id}, query: {status: :errored}) do |c|
              c.response_header.status.should == 400
              json_response = JSON.parse(c.response)
              json_response['error'].should == "Activity #{activity.name} can't transition from open to errored"
            end
          end
        end
        it "returns 200 and records the error message" do
          with_api(Server) do |api|
            activity = FactoryGirl.create(:activity, status: :executing, retry: 0)
            wf = activity.workflow
            user = wf.user
            put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/change_status", head: {"CLIENT_ID" => user.client_id}, query: {status: :errored, args: {error: {a: 1, b: 2}}.to_json}) do |c|
              c.response_header.status.should == 200
              activity.reload
              activity.status.should == :error
              activity.status_history.last["error"].should == {"a"=>1, "b"=>2}
            end
          end
        end
      end
    end
  end

  context "PUT /workflows/:id/events/:event_id/run_sub_activity" do
    it "raises 404 when run_sub_activity is called on something other than activity" do
      with_api(Server) do |api|
        signal = FactoryGirl.create(:signal, status: :open)
        wf = signal.workflow
        user = wf.user
        put_request(path: "/workflows/#{wf.id}/events/#{signal.id}/run_sub_activity", head: {"CLIENT_ID" => user.client_id}) do |c|
          c.response_header.status.should == 404
          json_response = JSON.parse(c.response)
          json_response['error'].should == "Event with id(#{signal.id}) not found"
        end
      end
    end
    it "returns 400 when run_sub_activity is called while activity is not in executing state" do
      with_api(Server) do |api|
        activity = FactoryGirl.create(:activity, status: :open)
        wf = activity.workflow
        user = wf.user
        put_request(path: "/workflows/#{wf.id}/events/#{activity.id}/run_sub_activity", head: {"CLIENT_ID" => user.client_id}) do |c|
          c.response_header.status.should == 400
          json_response = JSON.parse(c.response)
          json_response['error'].should == "Cannot run subactivity while in status(#{activity.status})"
        end
      end
    end
    it "runs the sub-activity" do
      with_api(Server) do |api|
        signal = FactoryGirl.create(:activity, status: :executing)
        wf = signal.workflow
        user = wf.user
        sub_activity = { name: :make_initial_payment, actor_type: "LineItem", actor_id: 100, retry: 100, retry_interval: 5, arguments: [1,2,3]}
        put_request(path: "/workflows/#{wf.id}/events/#{signal.id}/run_sub_activity", head: {"CLIENT_ID" => user.client_id}, query: {sub_activity: sub_activity.to_json}) do |c|
          c.response_header.status.should == 200
          json_response = JSON.parse(c.response)
          c.response_header["WAIT_FOR_SUB_ACTIVITY"].should == "true"
        end
      end
    end

    # it "returns 400 if some of the required parameters are missing" do
    #   with_api(Server) do |api|
    #     signal = FactoryGirl.create(:activity, status: :executing)
    #     wf = signal.workflow
    #     user = wf.user
    #     sub_activity = { name: :my_name, actor_id: 100, retry: 100, retry_interval: 5, arguments: [1,2,3]}
    #     put_request(path: "/workflows/#{wf.id}/events/#{signal.id}/run_sub_activity", head: {"CLIENT_ID" => user.client_id}, query: {options: sub_activity.to_json}) do |c|
    #       c.response_header.status.should == 400
    #       json_response = JSON.parse(c.response)
    #       json_response['error'].should == {"my_name" => {"actor_type"=>["can't be blank"]}}
    #     end
    #   end
    # end
  end
end