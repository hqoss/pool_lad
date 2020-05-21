defmodule PoolLadTest.Queue do
  alias PoolLad.Queue

  use ExUnit.Case

  @this_module __MODULE__

  defmodule Server do
    @moduledoc false

    use GenServer

    @this_module __MODULE__

    def start_link(opts), do: GenServer.start_link(@this_module, opts)

    @impl true
    def init(opts) do
      # Maintain init opts in state for later introspection.
      {:ok, opts}
    end
  end

  setup do
    assert {:ok, worker_supervisor} =
             start_supervised({DynamicSupervisor, strategy: :one_for_one})

    pool_opts = [
      name: @this_module,
      worker_count: 3,
      worker_module: Server,
      worker_supervisor: worker_supervisor
    ]

    worker_opts = [test_pid: self()]

    [pool_opts: pool_opts, worker_opts: worker_opts, worker_supervisor: worker_supervisor]
  end

  test "start_link/1 starts the worker modules under given DynamicSupervisor", %{
    pool_opts: pool_opts,
    worker_opts: worker_opts,
    worker_supervisor: worker_supervisor
  } do
    assert {:ok, pid} = Queue.start_link({pool_opts, worker_opts})

    assert [
             {_, worker_pid_1, _, _},
             {_, worker_pid_2, _, _},
             {_, worker_pid_3, _, _}
           ] = DynamicSupervisor.which_children(worker_supervisor)

    assert %{
             child_init_opts: {^worker_supervisor, Server, ^worker_opts},
             queue: queue
           } = :sys.get_state(pid)

    assert [^worker_pid_1, ^worker_pid_2, ^worker_pid_3] = :queue.to_list(queue)

    assert :ok = GenServer.stop(pid)
  end

  test "children are started with the provided worker opts", %{
    pool_opts: pool_opts,
    worker_opts: worker_opts,
    worker_supervisor: worker_supervisor
  } do
    assert {:ok, pid} = Queue.start_link({pool_opts, worker_opts})

    assert {_, worker_pid, _, _} =
             worker_supervisor |> DynamicSupervisor.which_children() |> Enum.random()

    assert ^worker_opts = :sys.get_state(worker_pid)
  end

  test "children are monitored and are restarted if they exit for whatever reason", %{
    pool_opts: pool_opts,
    worker_opts: worker_opts,
    worker_supervisor: worker_supervisor
  } do
    assert {:ok, pid} = start_supervised({Queue, {pool_opts, worker_opts}})

    children = DynamicSupervisor.which_children(worker_supervisor)
    assert {_, worker_pid, _, _} = Enum.random(children)

    reason = Enum.random(~w(kill shutdown any)a)
    Process.exit(worker_pid, reason)

    # Wait for the restart to take place.
    :timer.sleep(10)

    assert %{queue: queue} = :sys.get_state(pid)
    assert :queue.member(worker_pid, queue) === false

    next_children = DynamicSupervisor.which_children(worker_supervisor)

    assert Enum.find(next_children, fn {_, next_worker_pid, _, _} ->
             next_worker_pid === worker_pid
           end) === nil

    assert Enum.count(next_children) === Enum.count(children)
  end

  test "calling :get_next_pid retrieves the next worker pid in the queue", %{
    pool_opts: pool_opts,
    worker_opts: worker_opts,
    worker_supervisor: worker_supervisor
  } do
    assert {:ok, pid} = start_supervised({Queue, {pool_opts, worker_opts}})

    assert [
             {_, worker_pid_1, _, _},
             {_, worker_pid_2, _, _},
             {_, worker_pid_3, _, _}
           ] = DynamicSupervisor.which_children(worker_supervisor)

    assert [^worker_pid_1, ^worker_pid_2, ^worker_pid_3] =
             pid |> :sys.get_state() |> Map.get(:queue) |> :queue.to_list()

    assert ^worker_pid_1 = GenServer.call(pid, :get_next_pid)
    assert ^worker_pid_2 = GenServer.call(pid, :get_next_pid)
    assert ^worker_pid_3 = GenServer.call(pid, :get_next_pid)
    assert ^worker_pid_1 = GenServer.call(pid, :get_next_pid)
    assert ^worker_pid_2 = GenServer.call(pid, :get_next_pid)
    assert ^worker_pid_3 = GenServer.call(pid, :get_next_pid)
  end
end
