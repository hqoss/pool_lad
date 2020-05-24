defmodule PoolLadTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  @this_module __MODULE__
  @worker_pool Module.concat(@this_module, WorkerPool)

  # @worker_supervisor Module.concat(@worker_pool, Supervisor)

  defmodule TestWorker do
    @moduledoc false

    use GenServer

    @this_module __MODULE__

    def start_link(opts), do: GenServer.start_link(@this_module, opts)

    @impl true
    def init(opts) do
      initial_colours = Keyword.get(opts, :initial_colours, [])
      {:ok, initial_colours}
    end

    @impl true
    def handle_call(:get_random_colour, _from, colours) do
      colour = Enum.random(colours)
      {:reply, {:ok, colour}, colours}
    end
  end

  setup_all do
    pool_opts = [
      name: @worker_pool,
      worker_count: 3,
      worker_module: TestWorker
    ]

    worker_opts = [initial_colours: ~w(red green blue)a]

    [pool_opts: pool_opts, worker_opts: worker_opts]
  end

  setup %{pool_opts: pool_opts, worker_opts: worker_opts} do
    assert {:ok, pid} = start_supervised(PoolLad.child_spec(pool_opts, worker_opts))
    assert %PoolLad.State{worker_supervisor: worker_supervisor} = :sys.get_state(pid)

    test_pid = self()

    [pid: pid, test_pid: test_pid, worker_supervisor: worker_supervisor]
  end

  describe "PoolLad" do
    test "child_spec/1 returns a valid child spec", %{
      pool_opts: pool_opts,
      worker_opts: worker_opts
    } do
      assert %{
               id: :worker_pool,
               start: {PoolLad, :start_link, [^pool_opts, ^worker_opts]}
             } = child_spec = PoolLad.child_spec(pool_opts, worker_opts)

      assert ^child_spec = PoolLad.child_spec({pool_opts, worker_opts})
    end

    test "start_link/2 starts a linked DynamicSupervisor", %{
      pid: pid,
      worker_supervisor: worker_supervisor
    } do
      links = pid |> Process.info() |> Keyword.get(:links)
      assert Enum.member?(links, worker_supervisor) === true
    end

    test "start_link/2 starts workers under its DynamicSupervisor with provided opts", %{
      worker_opts: worker_opts,
      worker_supervisor: worker_supervisor
    } do
      assert [
               {:undefined, worker_pid_1, :worker, [TestWorker]},
               {:undefined, worker_pid_2, :worker, [TestWorker]},
               {:undefined, worker_pid_3, :worker, [TestWorker]}
             ] = DynamicSupervisor.which_children(worker_supervisor)

      assert :sys.get_state(worker_pid_1) === worker_opts[:initial_colours]
      assert :sys.get_state(worker_pid_2) === worker_opts[:initial_colours]
      assert :sys.get_state(worker_pid_3) === worker_opts[:initial_colours]
    end

    test "start_link/2 correctly configures its internal state", %{
      pid: pid,
      worker_opts: worker_opts,
      worker_supervisor: worker_supervisor
    } do
      assert %PoolLad.State{
               borrow_caller_monitors: borrow_caller_monitors,
               child_init_opts: {^worker_supervisor, TestWorker, ^worker_opts},
               waiting: waiting,
               worker_monitors: worker_monitors,
               workers: workers
             } = :sys.get_state(pid)

      assert :queue.is_empty(waiting) === true

      supervised_pids =
        worker_supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, pid, _, _} -> pid end)

      assert workers |> Enum.all?(fn worker -> Enum.member?(supervised_pids, worker) end)

      assert :ets.tab2list(borrow_caller_monitors) === []

      assert worker_monitors
             |> :ets.tab2list()
             |> Enum.all?(fn {pid, _reference} -> Enum.member?(supervised_pids, pid) end)
    end

    test "basic borrow", %{pid: pid} do
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

    test "borrow when no workers available, wait", %{pid: pid, test_pid: test_pid} do
      assert {:ok, first_worker} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      spawn(fn ->
        {:ok, worker} = PoolLad.borrow(pid)
        send(test_pid, worker)
      end)

      # Ensure we actually wait...
      refute_receive(_, 250)

      assert :ok = PoolLad.return(pid, first_worker)

      assert_receive(^first_worker)
    end

    test "borrow when no workers available, no-wait", %{pid: pid} do
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      assert {:error, :full} = PoolLad.borrow(pid, false)
    end

    test "borrow when no workers available, wait, cancel waiting", %{pid: pid, test_pid: test_pid} do
      assert {:ok, first_worker} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      timeout = 250

      caller_pid =
        spawn(fn ->
          Process.send_after(test_pid, :waiting, 0)
          result = PoolLad.borrow(pid, true, timeout)
          send(test_pid, result)
        end)

      assert_receive(:waiting)

      # Ensure the caller is in the waiting queue
      assert %PoolLad.State{
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
               waiting: waiting,
               workers: [^first_worker]
             } = :sys.get_state(pid)

      assert :queue.is_empty(waiting) === true

      assert_receive({:error, :timeout})
    end

    test "basic return", %{pid: pid} do
      assert {:ok, first_worker} = PoolLad.borrow(pid)
      assert {:ok, second_worker} = PoolLad.borrow(pid)
      assert {:ok, third_worker} = PoolLad.borrow(pid)

      assert :ok = PoolLad.return(pid, first_worker)

      assert %PoolLad.State{
               workers: [^first_worker]
             } = :sys.get_state(pid)

      assert :ok = PoolLad.return(pid, second_worker)

      assert %PoolLad.State{
               workers: [^second_worker, ^first_worker]
             } = :sys.get_state(pid)

      assert :ok = PoolLad.return(pid, third_worker)

      assert %PoolLad.State{
               workers: [^third_worker, ^second_worker, ^first_worker]
             } = :sys.get_state(pid)
    end

    test "ignored return", %{pid: pid} do
      assert {:ok, worker} = PoolLad.borrow(pid)

      assert :ok = PoolLad.return(pid, worker)

      assert capture_log(fn ->
               assert :ok = PoolLad.return(pid, worker)

               :timer.sleep(5)
             end) =~ "#{inspect(worker)} already returned. Ignoring..."
    end

    test "ignored return (the worker on loan has died)" do
      :todo
    end

    test "worker restart (empty waiting queue)", %{
      pid: pid,
      worker_supervisor: worker_supervisor
    } do
      original_worker_pids =
        worker_supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, worker_pid, _, _} -> worker_pid end)

      assert random_worker_pid = Enum.random(original_worker_pids)

      assert capture_log(fn ->
               assert true = Process.exit(random_worker_pid, :boom)

               :timer.sleep(5)

               {_, new_worker_pid, _, _} =
                 worker_supervisor
                 |> DynamicSupervisor.which_children()
                 |> Enum.find(fn {_, worker_pid, _, _} ->
                   worker_pid not in original_worker_pids
                 end)

               remaining_worker_pids =
                 worker_supervisor
                 |> DynamicSupervisor.which_children()
                 |> Enum.filter(fn {_, worker_pid, _, _} -> worker_pid !== new_worker_pid end)
                 |> Enum.map(fn {_, worker_pid, _, _} -> worker_pid end)

               assert %PoolLad.State{
                        workers: [^new_worker_pid | ^remaining_worker_pids]
                      } = :sys.get_state(pid)
             end) =~ "Worker #{inspect(random_worker_pid)} died. Restarting..."
    end

    test "worker restart (waiting queue not empty)", %{
      pid: pid,
      test_pid: test_pid,
      worker_supervisor: worker_supervisor
    } do
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      assert {_, random_worker_pid, _, _} =
               worker_supervisor |> DynamicSupervisor.which_children() |> Enum.random()

      _caller_pid =
        spawn(fn ->
          assert {:ok, new_worker_pid} = PoolLad.borrow(pid)
          send(test_pid, new_worker_pid)

          # Simulate a long-running process, assume return happens later.
          # Should the return occur immediately after the send/2 above
          # the worker pid would have been returned straight back into
          # the pool and our test invalidated.
          :timer.sleep(5_000)
        end)

      assert capture_log(fn ->
               assert true = Process.exit(random_worker_pid, :boom)

               assert_receive(new_worker_pid)

               assert {_, ^new_worker_pid, _, _} =
                        worker_supervisor
                        |> DynamicSupervisor.which_children()
                        |> Enum.find(fn {_, worker_pid, _, _} ->
                          worker_pid === new_worker_pid
                        end)

               assert %PoolLad.State{workers: []} = :sys.get_state(pid)
             end) =~ "Worker #{inspect(random_worker_pid)} died. Restarting..."
    end

    test "caller died while worker was on loan", %{pid: pid, test_pid: test_pid} do
      assert %PoolLad.State{workers: [next_worker | rest]} = :sys.get_state(pid)

      caller_pid =
        spawn(fn ->
          assert {:ok, ^next_worker} = PoolLad.borrow(pid)
          send(test_pid, :borrow_successful)

          # Simulate a long-running process so that we can
          # send an explicit exit signal to it later.
          :timer.sleep(5_000)
        end)

      ref = Process.monitor(caller_pid)

      assert_receive(:borrow_successful)

      assert %PoolLad.State{workers: ^rest} = :sys.get_state(pid)

      Process.exit(caller_pid, :boom)

      assert_receive({:DOWN, ^ref, :process, ^caller_pid, :boom})

      assert %PoolLad.State{
               borrow_caller_monitors: borrow_caller_monitors,
               workers: [^next_worker | ^rest]
             } = :sys.get_state(pid)

      assert [] = :ets.tab2list(borrow_caller_monitors)
    end

    test "caller died while waiting for a worker", %{pid: pid, test_pid: test_pid} do
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)
      assert {:ok, _} = PoolLad.borrow(pid)

      caller_pid =
        spawn(fn ->
          Process.send_after(test_pid, :waiting, 0)
          assert {:ok, _next_worker} = PoolLad.borrow(pid)
        end)

      ref = Process.monitor(caller_pid)

      assert_receive(:waiting)

      assert %PoolLad.State{waiting: waiting} = :sys.get_state(pid)

      assert {{:value, {{^caller_pid, _ref}, _request_id, _borrow_caller_monitor}}, _next_queue} =
               :queue.out(waiting)

      Process.exit(caller_pid, :boom)

      assert_receive({:DOWN, ^ref, :process, ^caller_pid, :boom})

      assert %PoolLad.State{waiting: waiting} = :sys.get_state(pid)
      assert :queue.is_empty(waiting) === true
    end
  end

  test "transaction executes the borrow and return cycle", %{pid: pid} do
    assert %PoolLad.State{workers: workers} = :sys.get_state(pid)

    assert {:ok, colour} =
             PoolLad.transaction(pid, fn worker -> GenServer.call(worker, :get_random_colour) end)

    assert %PoolLad.State{workers: ^workers} = :sys.get_state(pid)
  end
end
