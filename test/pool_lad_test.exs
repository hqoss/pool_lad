defmodule PoolLadTest do
  use ExUnit.Case

  @this_module __MODULE__
  @worker_pool Module.concat(@this_module, WorkerPool)
  @worker_supervisor Module.concat(@worker_pool, Supervisor)

  setup_all do
    pool_opts = [
      name: @worker_pool,
      worker_count: 3,
      worker_module: TestWorker
    ]

    worker_opts = [initial_colours: ~w(red green blue)a]

    [pool_opts: pool_opts, worker_opts: worker_opts]
  end

  describe "PoolLad" do
    test "start_link/2 starts a linked DynamicSupervisor", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      # TODO check if start_supervised is enough here..
      assert {:ok, pid} = PoolLad.start_link(pool_opts, worker_opts)

      assert worker_supervisor = Process.whereis(@worker_supervisor)

      links = pid |> Process.info() |> Keyword.get(:links)

      # Ensure only the caller and the DynamicSupervisor are linked
      assert Enum.count(links) === 2
      assert Enum.member?(links, self()) === true
      assert Enum.member?(links, worker_supervisor) === true

      assert :ok = GenServer.stop(pid)
    end

    test "start_link/2 starts workers under its DynamicSupervisor", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      worker_module = pool_opts[:worker_module]

      assert [
               {:undefined, _worker_pid_1, :worker, [^worker_module]},
               {:undefined, _worker_pid_2, :worker, [^worker_module]},
               {:undefined, _worker_pid_3, :worker, [^worker_module]}
             ] = DynamicSupervisor.which_children(@worker_supervisor)
    end

    test "start_link/2 starts all workers with worker_opts", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      worker_module = pool_opts[:worker_module]

      assert [
               {:undefined, worker_pid_1, :worker, [^worker_module]},
               {:undefined, worker_pid_2, :worker, [^worker_module]},
               {:undefined, worker_pid_3, :worker, [^worker_module]}
             ] = DynamicSupervisor.which_children(@worker_supervisor)

      assert :sys.get_state(worker_pid_1) === worker_opts[:initial_colours]
      assert :sys.get_state(worker_pid_2) === worker_opts[:initial_colours]
      assert :sys.get_state(worker_pid_3) === worker_opts[:initial_colours]
    end

    test "start_link/2 correctly configures its internal state", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      assert worker_supervisor = Process.whereis(@worker_supervisor)

      assert %PoolLad.State{
               borrow_caller_monitors: borrow_caller_monitors,
               child_init_opts: {^worker_supervisor, TestWorker, ^worker_opts},
               waiting: waiting,
               worker_monitors: worker_monitors,
               workers: workers
             } = :sys.get_state(pid)

      assert :queue.is_empty(waiting) === true

      supervised_pids =
        @worker_supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, pid, _, _} -> pid end)

      assert workers |> Enum.all?(fn worker -> Enum.member?(supervised_pids, worker) end)

      assert :ets.tab2list(borrow_caller_monitors) === []

      assert worker_monitors
             |> :ets.tab2list()
             |> Enum.all?(fn {pid, _reference} -> Enum.member?(supervised_pids, pid) end)
    end

    test "basic borrow", %{pool_opts: pool_opts, worker_opts: worker_opts} do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      assert %PoolLad.State{
               borrow_caller_monitors: borrow_caller_monitors,
               workers: workers
             } = :sys.get_state(pid)

      assert [] = :ets.tab2list(borrow_caller_monitors)
      assert [next_worker | rest] = workers

      assert {:ok, ^next_worker} = PoolLad.borrow(pid)

      assert [{^next_worker, reference}] = :ets.tab2list(borrow_caller_monitors)
      assert is_reference(reference) === true

      assert %PoolLad.State{
               workers: ^rest
             } = :sys.get_state(pid)
    end

    test "borrow when no workers available, wait", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      assert {:ok, first_worker} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      test_pid = self()

      spawn(fn ->
        {:ok, worker} = PoolLad.borrow(pid)
        send(test_pid, worker)
      end)

      # Ensure we actually wait...
      refute_receive(_, 250)

      assert :ok = PoolLad.return(pid, first_worker)

      assert_receive(^first_worker)
    end

    test "borrow when no workers available, no-wait", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      assert {:error, :full} = PoolLad.borrow(pid, false)
    end

    test "borrow when no workers available, wait, cancel waiting", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))

      assert {:ok, first_worker} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      test_pid = self()
      timeout = 250

      caller_pid =
        spawn(fn ->
          result = PoolLad.borrow(pid, true, timeout)
          send(test_pid, result)
        end)

      :timer.sleep(5)

      # Ensure the caller is in the waiting queue
      assert %PoolLad.State{
               # borrow_caller_monitors: borrow_caller_monitors,
               waiting: waiting,
               workers: []
             } = :sys.get_state(pid)

      assert {{:value, {from, request_id, borrow_caller_monitor}}, next_queue} =
               :queue.out(waiting)

      assert {^caller_pid, tag} = from
      assert is_reference(request_id) === true
      assert is_reference(borrow_caller_monitor) === true
      assert is_reference(tag) === true
      assert :queue.is_empty(next_queue) === true

      # Ensure we actually time out...
      :timer.sleep(timeout + 1)

      assert :ok = PoolLad.return(pid, first_worker)

      assert %PoolLad.State{
               # borrow_caller_monitors: borrow_caller_monitors,
               waiting: waiting,
               workers: [^first_worker]
             } = :sys.get_state(pid)

      assert :queue.is_empty(waiting) === true

      assert_receive({:error, :timeout})
    end

    test "basic return" do
    end

    test "ignored return" do
    end

    test "ignored return (the worker on loan has died)" do
    end

    test "worker restart (empty waiting queue)" do
    end

    test "worker restart (waiting queue not empty)" do
    end

    test "caller died while worker was on loan" do
    end

    test "caller died while waiting for a worker" do
    end
  end
end
