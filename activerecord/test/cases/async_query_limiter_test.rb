# frozen_string_literal: true

require "cases/helper"

class AsyncQueryLimiterTest < ActiveRecord::TestCase
  class QueueingExecutor
    attr_reader :jobs

    def initialize
      @jobs = []
    end

    def post(&job)
      @jobs << job
      true
    end

    def run_next
      @jobs.shift.call
    end

    def run_all
      run_next until @jobs.empty?
    end
  end

  class DiscardingExecutor
    def post
      false
    end
  end

  class RejectingExecutor
    def post
      raise Concurrent::RejectedExecutionError
    end
  end

  class InlineExecutor
    def post(&job)
      job.call
      true
    end
  end

  def test_requires_a_positive_integer_or_nil
    assert_raises(ArgumentError) { ActiveRecord.with_async_query_concurrency(0) { } }
    assert_raises(ArgumentError) { ActiveRecord.with_async_query_concurrency(-1) { } }
    assert_raises(ArgumentError) { ActiveRecord.with_async_query_concurrency("2") { } }
    assert_nothing_raised { ActiveRecord.with_async_query_concurrency(nil) { } }
  end

  def test_returns_the_block_value
    result = ActiveRecord.with_async_query_concurrency(2) { :result }

    assert_equal :result, result
  end

  def test_nested_scopes_use_the_innermost_limiter
    ActiveRecord.with_async_query_concurrency(2) do
      outer_limiter = ActiveRecord::AsyncQueryLimiter.current

      ActiveRecord.with_async_query_concurrency(1) do
        assert_not_same outer_limiter, ActiveRecord::AsyncQueryLimiter.current
      end

      assert_same outer_limiter, ActiveRecord::AsyncQueryLimiter.current
    end

    assert_nil ActiveRecord::AsyncQueryLimiter.current
  end

  def test_nil_temporarily_removes_an_enclosing_limit
    ActiveRecord.with_async_query_concurrency(2) do
      outer_limiter = ActiveRecord::AsyncQueryLimiter.current

      ActiveRecord.with_async_query_concurrency(nil) do
        assert_nil ActiveRecord::AsyncQueryLimiter.current
      end

      assert_same outer_limiter, ActiveRecord::AsyncQueryLimiter.current
    end
  end

  def test_restores_the_scope_when_the_block_raises
    assert_raises(RuntimeError) do
      ActiveRecord.with_async_query_concurrency(1) { raise "boom" }
    end

    assert_nil ActiveRecord::AsyncQueryLimiter.current
  end

  def test_the_scope_is_isolated_from_other_threads
    ActiveRecord.with_async_query_concurrency(1) do
      limiter_in_other_thread = Thread.new { ActiveRecord::AsyncQueryLimiter.current }.value

      assert_nil limiter_in_other_thread
      assert_not_nil ActiveRecord::AsyncQueryLimiter.current
    end
  end

  def test_never_posts_more_than_the_limit
    executor = QueueingExecutor.new
    limiter = ActiveRecord::AsyncQueryLimiter.new(2)
    completed = []

    5.times { |index| limiter.post(executor) { completed << index } }

    assert_equal 2, executor.jobs.size

    executor.run_all

    assert_equal [0, 1, 2, 3, 4], completed
  end

  def test_queued_jobs_are_posted_to_their_own_executor
    first_executor = QueueingExecutor.new
    second_executor = QueueingExecutor.new
    limiter = ActiveRecord::AsyncQueryLimiter.new(1)

    limiter.post(first_executor) { }
    limiter.post(second_executor) { }

    assert_equal 1, first_executor.jobs.size
    assert_empty second_executor.jobs

    first_executor.run_next

    assert_equal 1, second_executor.jobs.size
  end

  def test_keeps_dispatching_after_a_job_raises
    executor = QueueingExecutor.new
    limiter = ActiveRecord::AsyncQueryLimiter.new(1)
    completed = []

    limiter.post(executor) { raise "boom" }
    limiter.post(executor) { completed << :second }

    assert_raises(RuntimeError) { executor.run_next }
    executor.run_next

    assert_equal [:second], completed
  end

  def test_keeps_dispatching_when_an_executor_discards_a_job
    executor = QueueingExecutor.new
    limiter = ActiveRecord::AsyncQueryLimiter.new(1)
    completed = []

    limiter.post(executor) { completed << :first }
    limiter.post(DiscardingExecutor.new) { completed << :discarded }
    limiter.post(executor) { completed << :last }

    executor.run_all

    assert_equal [:first, :last], completed
  end

  def test_keeps_dispatching_when_an_executor_rejects_a_job
    executor = QueueingExecutor.new
    limiter = ActiveRecord::AsyncQueryLimiter.new(1)
    completed = []

    limiter.post(executor) { completed << :first }
    limiter.post(RejectingExecutor.new) { completed << :rejected }
    limiter.post(executor) { completed << :last }

    assert_raises(Concurrent::RejectedExecutionError) { executor.run_next }
    executor.run_next

    assert_equal [:first, :last], completed
  end

  def test_caller_runs_does_not_recurse_for_each_queued_job
    queueing_executor = QueueingExecutor.new
    inline_executor = InlineExecutor.new
    limiter = ActiveRecord::AsyncQueryLimiter.new(1)
    completed = 0

    limiter.post(queueing_executor) { }
    10_000.times { limiter.post(inline_executor) { completed += 1 } }

    queueing_executor.run_next

    assert_equal 10_000, completed
  end
end
