defmodule PoolLad.Queue do
  use GenServer

  require Logger

  @this_module __MODULE__

  def start_link({pool_opts, worker_opts}) do
    name = Keyword.fetch!(pool_opts, :name)
    GenServer.start_link(@this_module, {pool_opts, worker_opts}, name: name)
  end

  @impl true
  def init({pool_opts, worker_opts}) do
    worker_count = Keyword.fetch!(pool_opts, :worker_count)
    worker_module = Keyword.fetch!(pool_opts, :worker_module)
    worker_supervisor = Keyword.fetch!(pool_opts, :worker_supervisor)

    if worker_count < 1 do
      raise "Queue requires at least one child"
    end

    # Covenience so we don't have to re-build these opts every
    # time a child needs to be restarted.
    child_init_opts = {worker_supervisor, worker_module, worker_opts}

    queue =
      1..worker_count
      |> Enum.map(fn _ -> start_child(child_init_opts) end)
      |> :queue.from_list()

    {:ok, %{child_init_opts: child_init_opts, queue: queue}}
  end

  @impl true
  def handle_call(:get_next_pid, _from, %{queue: queue} = state) do
    # This is faster than round-robin with rem(offset, worker_count)
    # and then retrieving the pid by index from a list.
    {{:value, pid}, queue} = :queue.out(queue)
    next_queue = :queue.in(pid, queue)

    {:reply, pid, %{state | queue: next_queue}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, old_pid, reason}, state) when is_pid(old_pid) do
    Logger.warn("Server #{inspect(old_pid)} down: #{inspect(reason)}. Restarting...")
    restart_child(old_pid, state)
  end

  defp start_child({supervisor_name, worker_module, worker_opts}) do
    # Make sure when the child exits it is never restarted by the Supervisor.
    # Instead, we will restart it from within this server.
    child_spec = worker_opts |> worker_module.child_spec() |> Map.put(:restart, :temporary)

    {:ok, pid} = DynamicSupervisor.start_child(supervisor_name, child_spec)

    Logger.debug("Started new server #{inspect(pid)}.")

    # Make sure we get notified when the child exits. Based on the exit reason
    # we will either restart the child, or remove the child from the queue.
    _ref = Process.monitor(pid)

    pid
  end

  defp restart_child(
         old_pid,
         %{
           child_init_opts: child_init_opts,
           queue: queue
         } = state
       ) do
    queue_without_old_pid = :queue.filter(fn pid -> pid !== old_pid end, queue)

    pid = start_child(child_init_opts)
    next_queue = :queue.in(pid, queue_without_old_pid)

    {:noreply, %{state | queue: next_queue}}
  end
end
