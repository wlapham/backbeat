module Backbeat
  class StateManager

    VALID_STATE_CHANGES = {
      current_client_status: {
        any: [:errored],
        pending: [:ready],
        ready: [:received],
        received: [:processing, :complete],
        processing: [:complete],
        errored: [:ready],
        complete: [:complete]
      },
      current_server_status: {
        any: [:deactivated, :errored, :retrying],
        deactivated: [:deactivated],
        pending: [:ready],
        ready: [:started],
        started: [:sent_to_client, :paused],
        sent_to_client: [:processing_children],
        paused: [:started],
        processing_children: [:complete],
        errored: [:retrying],
        retrying: [:ready],
        complete: [:complete]
      }
    }

    def self.transition(node, statuses = {})
      new(node).transition(statuses)
    end

    def self.with_rollback(node, rollback_statuses = {})
      manager = new(node)
      starting_statuses = manager.current_statuses
      yield manager
    rescue InvalidStatusChange
      raise
    rescue => e
      manager.rollback(starting_statuses.merge(rollback_statuses))
      raise
    end

    def initialize(node)
      @node = node
    end

    def transition(statuses)
      return if node.is_a?(Workflow)

      [:current_client_status, :current_server_status].each do |status_type|
        new_status = statuses[status_type]
        next unless new_status
        validate_status(new_status.to_sym, status_type)
      end

      update_statuses(statuses)
    end

    def rollback(statuses)
      return if node.is_a?(Workflow)

      update_statuses(statuses)
    end

    def current_statuses
      return if node.is_a?(Workflow)

      [:current_client_status, :current_server_status].reduce({}) do |statuses, status_type|
        statuses[status_type] = node.send(status_type).to_sym
        statuses
      end
    end

    private

    attr_reader :node

    def update_statuses(statuses)
      rows_affected = Node.where(id: node.id).where(current_statuses).update_all(statuses)
      if rows_affected == 0
        raise StaleStatusChange, "Stale status change data for node #{node.id}"
      else
        create_status_changes(statuses)
        node.reload
      end
    end

    def create_status_changes(new_statuses)
      new_statuses.each do |(status_type, new_status)|
        node.status_changes.create!(
          from_status: current_statuses[status_type],
          to_status: new_status,
          status_type: status_type
        )
      end
    end

    def validate_status(new_status, status_type)
      unless valid_status_change?(new_status, status_type)
        current_status = current_statuses[status_type]
        message = "Cannot transition #{status_type} from #{current_status} to #{new_status}"
        if status_type == :current_client_status
          error_data = { current_status: current_status, attempted_status: new_status }
          raise InvalidClientStatusChange.new(message, error_data)
        else
          raise InvalidServerStatusChange.new(message)
        end
      end
    end

    def valid_status_change?(new_status, status_type)
      new_status && valid_state_changes(status_type).include?(new_status)
    end

    def valid_state_changes(status_type)
      current_status = current_statuses[status_type]
      VALID_STATE_CHANGES[status_type][current_status] +
        VALID_STATE_CHANGES[status_type][:any]
    end
  end
end