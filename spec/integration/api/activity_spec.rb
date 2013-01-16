require 'spec_helper'

describe Api::Workflow do
  include Rack::Test::Methods

  def app
    FullRackApp
  end

  before do
    header 'CLIENT_ID', RSPEC_CONSTANT_USER_CLIENT_ID
    WorkflowServer::AsyncClient.stub(:make_decision)
  end

  context "PUT /workflows/:id/events/:event_id/status/:new_status" do
    context "invalid status" do
      it "raises 400 if invalid new status" do
        activity = FactoryGirl.create(:activity)
        wf = activity.workflow
        user = wf.user
        put "/workflows/#{wf.id}/events/#{activity.id}/status/something_invalid"
        last_response.status.should == 400
        activity.reload
        json_response = JSON.parse(last_response.body)
        json_response['error'].should == "Invalid status something_invalid"
      end

      context "activity completed" do
        it "returns 400 if the activity is not in executing state" do
          activity = FactoryGirl.create(:activity, status: :open)
          wf = activity.workflow
          user = wf.user
          put "/workflows/#{wf.id}/events/#{activity.id}/status/completed"
          last_response.status.should == 400
          activity.reload
          json_response = JSON.parse(last_response.body)
          json_response['error'].should == "Activity #{activity.name} can't transition from open to completed"
        end

        it "returns 400 if the next decision is invalid" do
          decision = FactoryGirl.create(:decision)
          activity = FactoryGirl.create(:activity, status: :executing, parent: decision, workflow: decision.workflow)
          wf = activity.workflow
          user = wf.user
          header "Content-Type", "application/json"
          put "/workflows/#{wf.id}/events/#{activity.id}/status/completed", {args: {next_decision: :test_decision}}.to_json
          last_response.status.should == 400
          activity.reload
          json_response = JSON.parse(last_response.body)
          json_response['error'].should == "activity:#{activity.name} tried to make test_decision the next decision but is not allowed to."
          activity.status.should_not == :complete
        end

        it "returns 200 if the next decision is valid and the activity succeeds" do
          decision = FactoryGirl.create(:decision)
          activity = FactoryGirl.create(:activity, status: :executing, parent: decision, workflow: decision.workflow)
          wf = activity.workflow
          user = wf.user
          put "/workflows/#{wf.id}/events/#{activity.id}/status/completed"
          last_response.status.should == 200
          activity.reload
          activity.children.count.should == 1
          child = activity.children.first
          child.name.should == :make_initial_payment_succeeded
          activity.status.should == :complete
        end
      end
      context "activity errored" do
        it "returns 400 if the activity is not in executing state" do
          activity = FactoryGirl.create(:activity, status: :open)
          wf = activity.workflow
          user = wf.user
          put "/workflows/#{wf.id}/events/#{activity.id}/status/errored"
          last_response.status.should == 400
          json_response = JSON.parse(last_response.body)
          json_response['error'].should == "Activity #{activity.name} can't transition from open to errored"
        end

        it "returns 200 and records the error message" do
          activity = FactoryGirl.create(:activity, status: :executing, retry: 0)
          wf = activity.workflow
          user = wf.user
          header "Content-Type", "application/json"
          put "/workflows/#{wf.id}/events/#{activity.id}/status/errored", {args: {error: {a: 1, b: 2}}}.to_json
          last_response.status.should == 200
          activity.reload
          activity.status.should == :error
          activity.status_history.last["error"].should == {"a"=>1, "b"=>2}
        end
      end
    end
  end

  context "PUT /workflows/:id/events/:event_id/run_sub_activity" do
    it "raises 404 when run_sub_activity is called on something other than activity" do
      signal = FactoryGirl.create(:signal, status: :open)
      wf = signal.workflow
      user = wf.user
      sub_activity = { name: :make_initial_payment, actor_type: "LineItem", actor_id: 100, retry: 100, retry_interval: 5, arguments: [1,2,3]}
      header "Content-Type", "application/json"
      put "/workflows/#{wf.id}/events/#{signal.id}/run_sub_activity", {sub_activity: sub_activity}.to_json
      last_response.status.should == 404
      json_response = JSON.parse(last_response.body)
      json_response['error'].should == "Event with id(#{signal.id}) not found"
    end

    it "returns 400 when run_sub_activity is called while activity is not in executing state" do
      activity = FactoryGirl.create(:activity, status: :open)
      wf = activity.workflow
      user = wf.user
      sub_activity = { name: :make_initial_payment, actor_type: "LineItem", actor_id: 100, retry: 100, retry_interval: 5, arguments: [1,2,3]}
      header "Content-Type", "application/json"
      put "/workflows/#{wf.id}/events/#{activity.id}/run_sub_activity", {sub_activity: sub_activity}.to_json
      last_response.status.should == 400
      json_response = JSON.parse(last_response.body)
      json_response['error'].should == "Cannot run subactivity while in status(#{activity.status})"
    end

    it "runs the sub-activity" do
      signal = FactoryGirl.create(:activity, status: :executing)
      wf = signal.workflow
      user = wf.user
      sub_activity = { :name => :make_initial_payment, actorType: "LineItem", actor_id: 100, retry: 100, retry_interval: 5, arguments: [1,2,3]}
      header "Content-Type", "application/json"
      put "/workflows/#{wf.id}/events/#{signal.id}/run_sub_activity", {sub_activity: sub_activity}.to_json
      last_response.status.should == 200
      json_response = JSON.parse(last_response.body)
      last_response["WAIT_FOR_SUB_ACTIVITY"].should == "true"
    end

    it "returns 400 if some of the required parameters are missing" do
      activity = FactoryGirl.create(:activity, status: :executing)
      wf = activity.workflow
      user = wf.user
      sub_activity = { name: :my_name, actor_id: 100, retry: 100, retry_interval: 5, arguments: [1,2,3]}
      header "Content-Type", "application/json"
      put "/workflows/#{wf.id}/events/#{activity.id}/run_sub_activity", {options: sub_activity}.to_json
      last_response.status.should == 400
      json_response = JSON.parse(last_response.body)
      json_response['error'].should == "missing parameter: sub_activity"
    end
  end
end