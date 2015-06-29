require "migration/workers/migrator"

module Migration
  def self.queue_conversion_batch(args)
    types = args[:types] || []
    limit = args[:limit] || 1000
    WorkflowServer::Models::Workflow.where(
      :workflow_type.in => types,
      :migrated.in => [nil, false]
    ).limit(limit).each do |workflow|
      Migration::Workers::Migrator.perform_async(workflow.id)
    end
  end

  class MigrateWorkflow

    class WorkflowNotMigratable < StandardError; end

    def self.find_or_create_v2_workflow(v1_workflow)
      v2_user_id = V2::User.find_by_id(v1_workflow.user_id).id
      V2::Workflow.where(id: v1_workflow.id).first_or_create!(
        name: v1_workflow.name,
        decider: v1_workflow.decider,
        subject: v1_workflow.subject,
        user_id: v2_user_id,
        complete: v1_workflow.status == :complete
      )
    end

    def self.call(v1_workflow, v2_workflow, options = {})
      new.call(v1_workflow, v2_workflow, options)
    end

    def initialize
      @timers = []
    end

    attr_reader :timers

    def call(v1_workflow, v2_workflow, options = {})
      v2_workflow.with_lock do
        return if v2_workflow.migrated?

        ActiveRecord::Base.transaction do
          if options[:decision_history]
            v1_workflow.decisions.each do |decision|
              raise WorkflowNotMigratable.new("Cannot migrate node #{decision.id}") unless can_migrate?(decision)
              migrate_activity(decision, v2_workflow, { legacy_type: :decision, id: nil })
            end
          end
          v1_workflow.get_children.each do |signal|
            if has_special_cases?(signal) || options[:migrate_all]
              migrate_signal(signal, v2_workflow)
            else
              migrate_top_node(signal, v2_workflow)
            end
          end

          enqueue_timers if options.fetch(:enqueue_timers, true)
          v1_workflow.update_attributes!(migrated: true) # for ignoring delayed jobs
          v2_workflow.update_attributes!(migrated: true) # for knowing whether to signal v2 or not
        end
      end
      self
    rescue => e
      v1_workflow.workflows.each{|wf| wf.update_attributes!(migrated: false)}
      raise e
    end

    def enqueue_timers
      timers.each do |timer|
        V2::Schedulers::ScheduleAt.call(V2::Events::StartNode, timer) unless timer.current_server_status.to_sym == :complete
      end
    end

    def migrate_signal(v1_signal, v2_parent)
      v1_signal.children.each do |decision|
        migrate_node(decision, v2_parent)
      end
    end

    def migrate_top_node(v1_signal, v2_parent)
      decision = v1_signal.children.first
      migrate_single_node(decision, v2_parent)
    end

    def migrate_activity(v1_activity, v2_parent, attrs = {})
      node = V2::Node.new(
        mode: :blocking,
        current_server_status: attrs[:current_server_status] || server_status(v1_activity),
        current_client_status: attrs[:current_client_status] || client_status(v1_activity),
        name: attrs[:name] || v1_activity.name,
        fires_at: attrs[:fires_at] || Time.now - 1.second,
        parent: v2_parent,
        workflow_id: v2_parent.workflow_id,
        user_id: v2_parent.user_id,
        client_node_detail: V2::ClientNodeDetail.new(
          metadata: { version: "v2" },
          data: {}
        ),
        node_detail: V2::NodeDetail.new(
          legacy_type: attrs[:legacy_type] || :activity,
          retry_interval: 5,
          retries_remaining: 4
        )
      )
      node.id = attrs.fetch(:id, v1_activity.id)
      node.save!
      node
    end

    def migrate_single_node(node, v2_parent)
      raise WorkflowNotMigratable.new("Cannot migrate node #{node.id}") unless can_migrate?(node)

      case node
      when WorkflowServer::Models::Decision
        migrate_activity(node, v2_parent, legacy_type: :decision)
      when WorkflowServer::Models::Branch
        migrate_activity(node, v2_parent, legacy_type: :branch)
      when WorkflowServer::Models::Activity
        migrate_activity(node, v2_parent)
      when WorkflowServer::Models::Timer
        timer = migrate_activity(node, v2_parent, {
          name: "#{node.name}__timer__",
          fires_at: node.fires_at,
          legacy_type: :timer
        })
        timer.client_node_detail.update_attributes(data: {arguments: [node.name], options: {}})
        @timers << timer
        timer.workflow
      when WorkflowServer::Models::WorkflowCompleteFlag
        flag = migrate_activity(node, v2_parent, legacy_type: :flag)
        flag.workflow.complete!
        flag
      when WorkflowServer::Models::ContinueAsNewWorkflowFlag
        migrate_activity(node, v2_parent, legacy_type: :flag)
      when WorkflowServer::Models::Flag
        migrate_activity(node, v2_parent, legacy_type: :flag)
      when WorkflowServer::Models::Workflow
        v2_sub_workflow = MigrateWorkflow.find_or_create_v2_workflow(node)
        migrate_activity(node, v2_parent, {
          current_server_status: :complete,
          current_client_status: :complete,
          legacy_type: :flag,
          name: "Created sub-workflow #{v2_sub_workflow.id}",
        })
        v2_sub_workflow
      end
    end

    def migrate_node(node, v2_parent)
      new_v2_parent = migrate_single_node(node, v2_parent)
      if node.is_a?(WorkflowServer::Models::Workflow)
        sub_migration = MigrateWorkflow.call(node, new_v2_parent, { enqueue_timers: false })
        @timers += sub_migration.timers
      else
        node.children.each do |child|
          migrate_node(child, new_v2_parent)
        end
      end
    end

    def can_migrate?(node)
      if node.is_a?(WorkflowServer::Models::Timer)
        node.status.to_sym == :complete ||
          (node.status.to_sym == :scheduled && (node.fires_at - Time.now) > 1.hour)
      else
        status = node.status.to_sym
        status == :complete || status == :resolved || node.is_a?(WorkflowServer::Models::Workflow)
      end
    end

    def client_status(v1_node)
      case v1_node.status
      when :complete, :resolved
        :complete
      when :scheduled
        :ready
      end
    end

    def server_status(v1_node)
      return :deactivated if v1_node.inactive
      case v1_node.status
      when :complete, :resolved
        :complete
      when :scheduled
        :started
      end
    end

    def has_special_cases?(node)
      return true if node.is_a?(WorkflowServer::Models::Timer) && node.status != :complete
      return true if node.is_a?(WorkflowServer::Models::Workflow)
      !!node.children.all.to_a.find do |c|
        has_special_cases?(c)
      end
    end
  end
end
