# frozen_string_literal: true

require 'spec_helper'

describe Que::Locker do
  describe "when starting up" do
    it "should log its settings" do
      Que::Locker.new.stop!

      events = logged_messages.select { |m| m['event'] == 'locker_start' }
      assert_equal 1, events.count

      event = events.first
      assert_equal true,         event['listen']
      assert_instance_of Fixnum, event['backend_pid']
      assert_nil                 event.fetch('poll_interval')

      assert_equal Que::Locker::DEFAULT_WAIT_PERIOD,        event['wait_period']
      assert_equal Que::Locker::DEFAULT_MINIMUM_QUEUE_SIZE, event['minimum_queue_size']
      assert_equal Que::Locker::DEFAULT_MAXIMUM_QUEUE_SIZE, event['maximum_queue_size']
      assert_equal Que::Locker::DEFAULT_WORKER_COUNT,       event['worker_priorities'].count

      # If the worker_count is six and the worker_priorities are [10, 30, 50], the
      # expected full set of worker priorities is [10, 30, 50, nil, nil, nil].

      expected_worker_priorities =
        Que::Locker::DEFAULT_WORKER_PRIORITIES +
        (
          Que::Locker::DEFAULT_WORKER_COUNT -
          Que::Locker::DEFAULT_WORKER_PRIORITIES.length
        ).times.map { nil }

      assert_equal expected_worker_priorities, event['worker_priorities']
    end

    it "should allow configuration of various parameters" do
      locker =
        Que::Locker.new \
          listen:             false,
          minimum_queue_size: 5,
          maximum_queue_size: 45,
          wait_period:        0.2,
          poll_interval:      0.4,
          worker_priorities:  [1, 2, 3, 4],
          worker_count:       8

      locker.stop!

      events = logged_messages.select { |m| m['event'] == 'locker_start' }
      assert_equal 1, events.count
      event = events.first
      assert_equal false, event['listen']
      assert_instance_of Fixnum, event['backend_pid']
      assert_equal 0.2, event['wait_period']
      assert_equal 0.4, event['poll_interval']
      assert_equal 5, event['minimum_queue_size']
      assert_equal 45, event['maximum_queue_size']
      assert_equal [1, 2, 3, 4, nil, nil, nil, nil], event['worker_priorities']
    end

    it "should allow a dedicated PG connection to be specified" do
      pg = NEW_PG_CONNECTION.call
      pid = pg.async_exec("select pg_backend_pid()").to_a.first['pg_backend_pid'].to_i

      locker = Que::Locker.new connection: pg
      sleep_until { DB[:que_lockers].select_map(:pid) == [pid] }
      locker.stop!
    end

    it "should have a high-priority work thread" do
      locker = Que::Locker.new
      assert_equal 1, locker.thread.priority
      locker.stop!
    end

    it "should register its presence in the que_lockers table" do
      worker_count = rand(10) + 1

      locker = Que::Locker.new(worker_count: worker_count)

      sleep_until { DB[:que_lockers].count == 1 }

      assert_equal worker_count, locker.workers.count

      record = DB[:que_lockers].first
      assert_equal Process.pid,        record[:ruby_pid]
      assert_equal Socket.gethostname, record[:ruby_hostname]
      assert_equal worker_count,       record[:worker_count]
      assert_equal true,               record[:listening]

      locker.stop!

      assert_equal 0, DB[:que_lockers].count
    end

    it "should clear invalid lockers from the table" do
      # Bogus locker from a nonexistent connection.
      DB[:que_lockers].insert(
        pid:           0,
        ruby_pid:      0,
        ruby_hostname: 'blah2',
        worker_count:  4,
        listening:     true,
      )

      # We want to spec that invalid lockers with the current backend's pid are
      # also cleared out, so:
      backend_pid =
        Que.execute("select pg_backend_pid()").first[:pg_backend_pid]

      DB[:que_lockers].insert(
        pid:           backend_pid,
        ruby_pid:      0,
        ruby_hostname: 'blah1',
        worker_count:  4,
        listening:     true,
      )

      assert_equal 2, DB[:que_lockers].count

      locker = Que::Locker.new
      sleep_until { DB[:que_lockers].count == 1 }

      record = DB[:que_lockers].first
      assert_equal backend_pid, record[:pid]
      assert_equal Process.pid, record[:ruby_pid]

      locker.stop!

      assert_equal 0, DB[:que_lockers].count
    end
  end

  it "should do batch polls every poll_interval to catch jobs that fall through the cracks" do
    assert_equal 0, DB[:que_jobs].count
    locker = Que::Locker.new poll_interval: 0.01, listen: false

    Que::Job.enqueue
    sleep_until { DB[:que_jobs].empty? }

    Que::Job.enqueue
    sleep_until { DB[:que_jobs].empty? }

    locker.stop!
  end

  describe "on startup" do
    it "should do batch polls for jobs" do
      job1, job2 = BlockJob.enqueue, BlockJob.enqueue

      locker = Que::Locker.new

      $q1.pop;      $q1.pop
      $q2.push nil; $q2.push nil

      locker.stop!

      assert_equal 0, DB[:que_jobs].count
    end

    it "should request enough jobs to fill the queue" do
      ids  = 3.times.map { BlockJob.enqueue(priority: 100).attrs[:job_id] }
      ids += 6.times.map { Que::Job.enqueue(priority: 101).attrs[:job_id] }

      locker = Que::Locker.new
      3.times { $q1.pop }

      # The default queue size is 8, so it shouldn't lock the 9th job.
      assert_equal ids[0..-2], DB[:pg_locks].where(locktype: 'advisory').select_order_map(:objid)

      3.times { $q2.push nil }
      locker.stop!
    end

    it "should repeat batch polls until the supply of available jobs is exhausted" do
      Que.execute <<-SQL
        INSERT INTO que_jobs (job_class, priority)
        SELECT 'Que::Job', 1
        FROM generate_series(1, 100) AS i;
      SQL

      locker = Que::Locker.new
      sleep_until { DB[:que_jobs].empty? }
      locker.stop!
    end

    it "should run the on_worker_start callback for each worker, if passed" do
      a = []
      m = Mutex.new
      locker = Que::Locker.new on_worker_start: proc { |w| m.synchronize { a << [w.object_id, Thread.current.object_id] } }
      ids = locker.workers.map{|w| [w.object_id, w.thread.object_id]}
      locker.stop!

      assert_equal ids.sort, a.sort
    end
  end

  describe "when doing a batch poll" do
    it "should not try to lock and work jobs it has already locked" do
      begin
        $performed = []

        class PollRelockJob < BlockJob
          def run
            $performed << @attrs[:job_id]
            super
          end
        end

        locker = Que::Locker.new poll_interval: 0.01, listen: false

        id1 = PollRelockJob.enqueue.attrs[:job_id]
        $q1.pop

        id2 = PollRelockJob.enqueue.attrs[:job_id]
        $q1.pop

        # Without the relock protection, we'd expect the first job to be worked twice.
        assert_equal [id1, id2], $performed

        $q2.push nil
        $q2.push nil

        locker.stop!
      ensure
        $performed = nil
      end
    end

    it "should request as many as necessary to reach the maximum_queue_size" do
      ids  = 3.times.map { BlockJob.enqueue(priority: 100).attrs[:job_id] }
      ids += 3.times.map { Que::Job.enqueue(priority: 101).attrs[:job_id] }

      locker = Que::Locker.new poll_interval: 0.01, listen: false
      3.times { $q1.pop }

      ids += 6.times.map { Que::Job.enqueue(priority: 101).attrs[:job_id] }
      sleep_until { DB[:pg_locks].where(locktype: 'advisory').select_order_map(:objid) == ids[0..10] }

      3.times { $q2.push nil }
      locker.stop!

      event = logged_messages.select{|m| m['event'] == 'locker_polled'}.first
      assert_equal 8, event['limit']
      assert_equal 6, event['locked']
    end

    it "should trigger a new batch poll when the queue drops to the minimum_queue_size threshold" do
      ids = 9.times.map { BlockJob.enqueue(priority: 100).attrs[:job_id] }

      locker = Que::Locker.new
      3.times { $q1.pop }

      # Should have locked first 8 only.
      assert_equal ids[0..7], DB[:pg_locks].where(locktype: 'advisory').select_order_map(:objid)

      # Get the queue size down to 2, and it should lock the final one.
      6.times { $q2.push nil }
      sleep_until { DB[:pg_locks].where(locktype: 'advisory').select_map(:objid).include?(ids[-1]) }
      3.times { $q2.push nil }

      locker.stop!
    end
  end

  describe "when receiving a NOTIFY of a new job" do
    it "should immediately lock, work, and unlock them" do
      assert_equal 0, DB[:que_jobs].count
      locker = Que::Locker.new
      sleep_until { DB[:que_lockers].count == 1 }

      job = BlockJob.enqueue
      $q1.pop

      locks = DB[:pg_locks].where(locktype: 'advisory').all
      assert_equal 1, locks.count
      assert_equal DB[:que_jobs].get(:job_id), locks.first[:objid]

      $q2.push nil
      sleep_until { DB[:que_jobs].count == 0 }
      sleep_until { DB[:pg_locks].where(locktype: 'advisory').count == 0 }

      locker.stop!

      events = logged_messages.select { |m| m['event'] == 'job_notified' }
      assert_equal 1, events.count
      event = events.first
      log = event['job']

      assert_equal job.attrs[:priority], log['priority']
      assert_equal job.attrs[:run_at], Time.parse(log['run_at'])
      assert_equal job.attrs[:job_id], log['job_id']
    end

    it "should not work jobs that are already locked" do
      assert_equal 0, DB[:que_jobs].count
      locker = Que::Locker.new
      sleep_until { DB[:que_lockers].count == 1 }

      id = nil
      q1, q2 = Queue.new, Queue.new
      t = Thread.new do
        Que.checkout do
          # NOTIFY won't propagate until transaction commits.
          Que.execute "BEGIN"
          Que::Job.enqueue
          id = Que.execute("SELECT job_id FROM que_jobs LIMIT 1").first[:job_id].to_i
          Que.execute "SELECT pg_advisory_lock($1)", [id]
          Que.execute "COMMIT"
          q1.push nil
          q2.pop
          Que.execute "SELECT pg_advisory_unlock($1)", [id]
        end
      end

      q1.pop
      locker.stop!
      q2.push nil
      t.join

      assert_equal [id], DB[:que_jobs].select_map(:job_id)
    end

    it "should not try to lock and work jobs it has already locked" do
      attrs  = BlockJob.enqueue.attrs
      locker = Que::Locker.new
      $q1.pop

      pid = DB[:que_lockers].where(:listening).get(:pid)

      payload = DB[:que_jobs].
        where(job_id: attrs[:job_id]).
        select(:priority, :run_at, :job_id).
        from_self(alias: :t).
        get{row_to_json(:t)}

      DB.notify "que_locker_#{pid}", payload: payload

      sleep 0.05 # Hacky
      assert_equal [], locker.job_queue.to_a

      $q2.push nil
      locker.stop!
    end

    it "of low importance should not lock them or add them to the JobQueue if it is full" do
      locker = Que::Locker.new worker_count:       1,
                               maximum_queue_size: 3

      sleep_until { DB[:que_lockers].count == 1 }

      BlockJob.enqueue(priority: 5)
      $q1.pop
      ids = 3.times.map { Que::Job.enqueue(priority: 5).attrs[:job_id] }
      sleep_until { locker.job_queue.to_a.map{|h| h[-1]} == ids }

      id = Que::Job.enqueue(priority: 10).attrs[:job_id]

      sleep 0.05 # Hacky.
      refute_includes locker.job_queue.to_a.map{|h| h[-1]}, id

      $q2.push nil
      locker.stop!
    end

    it "of significant importance should lock and add it to the JobQueue and dequeue/unlock the least important one to make room" do
      locker = Que::Locker.new worker_count:       1,
                               maximum_queue_size: 3

      sleep_until { DB[:que_lockers].count == 1 }

      BlockJob.enqueue priority: 5
      $q1.pop
      ids = 3.times.map { Que::Job.enqueue(priority: 5).attrs[:job_id] }

      sleep_until { locker.job_queue.to_a.map{|h| h[-1]} == ids }

      id = Que::Job.enqueue(priority: 2).attrs[:job_id]

      sleep_until { locker.job_queue.to_a.map{|h| h[-1]} == [id] + ids[0..1] }

      $q2.push nil
      locker.stop!
    end
  end

  describe "when told to shut down" do
    it "with #stop should inform its workers to stop" do
      BlockJob.enqueue
      locker  = Que::Locker.new
      workers = locker.workers
      locker.stop

      $q1.pop

      sleep_until { workers.count{|worker| worker.thread.status != false} == 1 }

      $q2.push nil

      locker.wait_for_stop
      workers.each { |worker| assert_equal false, worker.thread.status }
    end

    it "with #stop! should block until its workers are done" do
      locker  = Que::Locker.new
      workers = locker.workers
      locker.stop!
      workers.each { |worker| assert_equal false, worker.thread.status }

      events = logged_messages.select { |m| m['event'] == 'locker_stop' }
      assert_equal 1, events.count
    end

    it "should remove and unlock all the jobs in its queue" do
      6.times { BlockJob.enqueue }
      locker = Que::Locker.new

      job_ids = DB[:que_jobs].select_order_map(:job_id)

      sleep_until { DB[:pg_locks].where(locktype: 'advisory').select_order_map(:objid) == job_ids }

      3.times { $q1.pop }

      sleep_until { locker.job_queue.to_a.map{|h| h[-1]} == job_ids[3..5] }

      t = Thread.new { locker.stop! }

      sleep_until { locker.job_queue.to_a.empty? }
      sleep_until { DB[:pg_locks].where(locktype: 'advisory').select_order_map(:objid) == job_ids[0..2] }

      3.times { $q2.push nil }

      t.join
    end

    it "should wait for its currently running jobs to finish before returning" do
      locker = Que::Locker.new

      sleep_until { DB[:que_lockers].count == 1 }

      job_id = BlockJob.enqueue.attrs[:job_id]

      $q1.pop
      t = Thread.new { locker.stop! }
      $q2.push :nil
      t.join

      assert_equal 0, DB[:que_jobs].count
    end

    it "should clear its own record from the que_lockers table"
  end
end
