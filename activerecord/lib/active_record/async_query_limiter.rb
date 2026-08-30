# frozen_string_literal: true

require "active_support/isolated_execution_state"

module ActiveRecord
  # Limits how many asynchronous queries from one execution context can occupy
  # their connection pool executors at the same time.
  class AsyncQueryLimiter # :nodoc:
    STATE_KEY = :active_record_async_query_limiter
    private_constant :STATE_KEY

    DISPATCH_QUEUE_KEY = :active_record_async_query_limiter_dispatch_queue
    DISPATCHING_KEY = :active_record_async_query_limiter_dispatching
    private_constant :DISPATCH_QUEUE_KEY, :DISPATCHING_KEY

    Job = Struct.new(:executor, :callable)
    private_constant :Job

    class << self
      def with(concurrency)
        limiter = concurrency.nil? ? nil : new(concurrency)
        state = ActiveSupport::IsolatedExecutionState
        previously_defined = state.key?(STATE_KEY)
        previous_limiter = state[STATE_KEY]
        state[STATE_KEY] = limiter

        begin
          yield
        ensure
          if previously_defined
            state[STATE_KEY] = previous_limiter
          else
            state.delete(STATE_KEY)
          end
        end
      end

      def current
        ActiveSupport::IsolatedExecutionState[STATE_KEY]
      end
    end

    def initialize(concurrency)
      unless concurrency.is_a?(Integer) && concurrency.positive?
        raise ArgumentError, "concurrency must be a positive integer or nil"
      end

      @concurrency = concurrency
      @mutex = Mutex.new
      @queue = []
      @running = 0
    end

    def post(executor, &block)
      raise ArgumentError, "no block given" unless block

      job = Job.new(executor, block)
      dispatch = @mutex.synchronize do
        if @running < @concurrency
          @running += 1
          job
        else
          @queue << job
          nil
        end
      end

      dispatch(dispatch) if dispatch
      true
    end

    private
      # Executor fallback policies can run a posted job immediately. Queue
      # dispatches on the current fiber so a long caller-runs chain does not
      # recurse and overflow the stack.
      def dispatch(job)
        dispatch_queue = Thread.current[DISPATCH_QUEUE_KEY] ||= []
        dispatch_queue << [self, job]
        return if Thread.current[DISPATCHING_KEY]

        Thread.current[DISPATCHING_KEY] = true
        error = nil

        begin
          while limiter_and_job = dispatch_queue.shift
            limiter, queued_job = limiter_and_job
            begin
              limiter.send(:submit, queued_job)
            rescue Exception => exception
              error ||= exception
            end
          end
        ensure
          Thread.current[DISPATCH_QUEUE_KEY] = nil
          Thread.current[DISPATCHING_KEY] = nil
        end

        raise error if error
      end

      def submit(job)
        started = false
        accepted = job.executor.post do
          started = true
          begin
            job.callable.call
          ensure
            dispatch_next
          end
        end

        dispatch_next unless accepted
      rescue Exception
        # If caller-runs executed the job, its ensure already released the slot.
        dispatch_next unless started
        raise
      end

      def dispatch_next
        job = @mutex.synchronize do
          if @queue.empty?
            @running -= 1
            nil
          else
            @queue.shift
          end
        end

        dispatch(job) if job
      end
  end
end
