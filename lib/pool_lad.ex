defmodule PoolLad do
  @moduledoc """
  `pool_lad` is the younger & more energetic version of [`:poolboy`](https://github.com/devinus/poolboy).

  It's still the _**lightweight, generic pooling library with focus on
  simplicity, performance, and rock-solid disaster recovery**_ that we all love...

  ...but it has just gotten a much needed facelift!

  ## Sample usage

  The APIs are almost identical to those of [`:poolboy`](https://github.com/devinus/poolboy).

  Via manual ownership:

      iex(1)> {:ok, worker} = PoolLad.borrow(MyWorkerPool)
      {:ok, #PID<0.256.0>}
      iex(2)> GenServer.call(worker, :get_random_colour)
      :blue
      iex(3)> PoolLad.return(MyWorkerPool, worker)
      :ok

  Via transactional ownership:

      iex(1)> PoolLad.transaction(
      ...(1)>   MyWorkerPool,
      ...(1)>   fn worker -> GenServer.call(worker, :get_random_colour) end
      ...(1)> )
      :green
  """

  use GenServer

  require Logger

  @borrow_timeout 5_000
  @ets_access if Mix.env() === :test, do: :public, else: :private
  @this_module __MODULE__

  defmodule State do
    @moduledoc false

    @enforce_keys ~w(borrow_caller_monitors child_init_opts worker_monitors workers)a
    defstruct borrow_caller_monitors: nil,
              child_init_opts: nil,
              waiting: :queue.new(),
              worker_monitors: nil,
              workers: nil
  end

  ##############
  # Public API #
  ##############

  @doc """
  Returns a specification to start this module under a `Supervisor`.

  ## Usage

      pool_opts = [name: MyWorkerPool, worker_count: 3, worker_module: MyWorker]
      worker_opts = [initial_colours: ~w(red green blue)a]

      children = [
        {PoolLad, {pool_opts, worker_opts}}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Calls `child_spec/2`.
  """
  @spec child_spec({keyword(), keyword()}) :: Supervisor.child_spec()
  def child_spec({pool_opts, worker_opts}) do
    child_spec(pool_opts, worker_opts)
  end

  @doc """
  Returns a specification to start this module under a `Supervisor`.

  ## Usage

      pool_opts = [name: MyWorkerPool, worker_count: 3, worker_module: MyWorker]
      worker_opts = [initial_colours: ~w(red green blue)a]

      children = [
        PoolLad.child_spec(pool_opts, worker_opts)
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec(keyword(), keyword()) :: Supervisor.child_spec()
  def child_spec(pool_opts, worker_opts) do
    %{
      id: :worker_pool,
      start: {PoolLad, :start_link, [pool_opts, worker_opts]}
    }
  end

  @doc """
  Starts a new `PoolLad` worker pool.

  Needs to be supplied `pool_opts` and `worker_opts`.

  Pool options;

  * `:name` (required): unique name, used to interact with the pool
  * `:worker_count` (required): the number of workers to be started and supervised
  * `:worker_module` (required): the module to be used as a worker, must implement `child_spec/1`

  Worker options; passed as the `init_arg` when starting `worker_module`.

  ## Supervision

  See `child_spec/1`, `child_spec/2`.
  """
  @spec start_link(keyword(), keyword()) :: GenServer.on_start()
  def start_link(pool_opts, worker_opts) do
    name = Keyword.fetch!(pool_opts, :name)
    GenServer.start_link(@this_module, {pool_opts, worker_opts}, name: name)
  end

  @doc """
  Attempts to "borrow" a worker (pid), or waits until one becomes available.

  ## Examples

  ### Get, or wait

  If no workers are currently available waits (blocks) until one becomes available,
  or until `timeout` elapses in which case `{:error, :timeout}` will be returned.

  Assuming we only have one worker available:

      iex(1)> {:ok, pid} = PoolLad.borrow(MyWorkerPool)
      {:ok, #PID<0.229.0>}
      iex(2)> result = PoolLad.borrow(MyWorkerPool) # will wait (block) for 5 seconds first
      {:error, :timeout}

  ### Synchronous get

  If no workers are currently available, returns `{:error, :full}` immediately.

  Assuming we only have one worker available:

      iex(1)> {:ok, pid} = PoolLad.borrow(MyWorkerPool, false)
      {:ok, #PID<0.229.0>}
      iex(2)> result = PoolLad.borrow(MyWorkerPool, false) # will return imediately
      {:error, :full}

  ### Custom timeout

  You can configure your own `timeout` like so:

      iex(1)> {:ok, pid} = PoolLad.borrow(MyWorkerPool, true, 2_500)
  """
  @spec borrow(module(), boolean(), integer()) ::
          {:ok, pid()} | {:error, reason :: :full | :timeout}
  def borrow(pool, wait? \\ true, timeout \\ @borrow_timeout) do
    # Used to track which caller processes are waiting for a worker.
    # If a timeout occurs, we will use this reference to remove the
    # caller process from the queue.
    cancel_reference = make_ref()

    try do
      GenServer.call(pool, {:borrow, cancel_reference, wait?}, timeout)
    catch
      :exit, _value ->
        GenServer.cast(pool, {:cancel_waiting, cancel_reference})
        {:error, :timeout}
    end
  end

  @doc """
  Returns the borrowed worker (pid) back to the pool.

  ## Examples

      iex(1)> {:ok, pid} = PoolLad.borrow(MyWorkerPool)
      {:ok, #PID<0.229.0>}
      iex(2)> PoolLad.return(MyWorkerPool, pid)
      :ok

  ⚠️ If the worker died while on loan and a return was attempted,
  the return will be accepted but _ignored_ and a warning will be logged.

  ⚠️ If the return was attempted more than once, the return will be
  accepted but _ignored_ and a warning will be logged.
  """
  @spec return(module, pid) :: :ok
  def return(pool, pid) do
    GenServer.cast(pool, {:return, pid})
  end

  @doc """
  Both the borrow _and_ the return are facilitated via a single transaction.

  Should `function` raise, a safe return of the worker to the pool is guaranteed.

      iex(1)> PoolLad.transaction(
      ...(1)>   MyWorkerPool,
      ...(1)>   fn worker -> GenServer.call(worker, :get_random_colour) end
      ...(1)> )
      :green
  """
  @spec transaction(module(), function(), integer()) :: term | {:error, :timeout}
  def transaction(pool, function, timeout \\ @borrow_timeout) do
    with {:ok, pid} <- borrow(pool, true, timeout) do
      try do
        function.(pid)
      after
        :ok = GenServer.cast(pool, {:return, pid})
      end
    end
  end

  ######################
  # Callback Functions #
  ######################

  @impl true
  def init({pool_opts, worker_opts}) do
    name = Keyword.fetch!(pool_opts, :name)
    worker_count = Keyword.fetch!(pool_opts, :worker_count)
    worker_module = Keyword.fetch!(pool_opts, :worker_module)

    # Make sure we can check whether the module implements child_spec/1.
    {:module, worker_module} = Code.ensure_loaded(worker_module)

    if worker_count < 1 do
      raise "Queue requires at least one child"
    end

    unless function_exported?(worker_module, :child_spec, 1) do
      raise "Worker module must implement child_spec/1"
    end

    worker_supervisor = Module.concat(name, Supervisor)

    {:ok, worker_supervisor} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: worker_supervisor)

    # Used to monitor caller processes.
    #
    # Should any of them terminate, we will make sure to return the borrowed pid
    # back to the workers list, or send it directly to the next waiting process.
    borrow_caller_monitors = :ets.new(:borrow_caller_monitors, [@ets_access])

    # Used to monitor worker processes started under the worker supervisor.
    #
    # Should any of them terminate, we will make sure to start a new one, update
    # the workers list, and send the new pid to the next waiting process if applicable.
    worker_monitors = :ets.new(:worker_monitors, [@ets_access])

    # Covenience so we don't have to re-build these opts every
    # time a worker needs to be (re-)started.
    child_init_opts = {worker_supervisor, worker_module, worker_opts}

    workers =
      1..worker_count
      |> Enum.map(fn _ -> start_child(child_init_opts, worker_monitors) end)

    {:ok,
     %State{
       borrow_caller_monitors: borrow_caller_monitors,
       child_init_opts: child_init_opts,
       worker_monitors: worker_monitors,
       workers: workers
     }}
  end

  @impl true
  def handle_call(
        {:borrow, cancel_reference, wait?},
        {caller_pid, _tag} = from,
        %State{waiting: waiting, workers: []} = state
      ) do
    case wait? do
      true ->
        # Monitor the caller process. If the caller process terminates for any reason,
        # we will be notified and can remove its reference from waiting queue.
        caller_monitor = Process.monitor(caller_pid)

        # Enqueue, so as soon as the next borrowed worker pid is returned,
        # we can send it as a reply explicitly to this caller and consider
        # the borrow successful.
        next_waiting = :queue.in({from, cancel_reference, caller_monitor}, waiting)
        {:noreply, %{state | waiting: next_waiting}}

      false ->
        {:reply, {:error, :full}, state}
    end
  end

  @impl true
  def handle_call(
        {:borrow, _caller_reference, _wait?},
        {caller_pid, _tag},
        %State{borrow_caller_monitors: borrow_caller_monitors, workers: [pid | remaining]} = state
      ) do
    # Monitor the caller process. If the caller process terminates for any reason,
    # we will be notified and can return the borrowed pid back to the worker pool,
    # or lend it to the next process waiting.
    caller_monitor = Process.monitor(caller_pid)

    # Consider the borrow successful. Will be used to look up
    # and demonitor upon successful return, or if the caller process dies.
    true = :ets.insert(borrow_caller_monitors, {pid, caller_monitor})

    {:reply, {:ok, pid}, %{state | workers: remaining}}
  end

  @impl true
  def handle_cast({:return, pid}, %{borrow_caller_monitors: borrow_caller_monitors} = state) do
    case :ets.lookup(borrow_caller_monitors, pid) do
      # Every successful (ongoing) borrow is monitored and recorded in ets.
      [{^pid, caller_monitor}] ->
        # We can now stop monitoring the original caller process.
        true = Process.demonitor(caller_monitor, [:flush])
        true = :ets.delete(borrow_caller_monitors, pid)

        handle_return(pid, state, Process.alive?(pid))

      # The caller attempted to return the pid more than once.
      [] ->
        Logger.warn("#{inspect(pid)} already returned. Ignoring...")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:cancel_waiting, cancel_reference}, %State{waiting: waiting} = state) do
    next_waiting =
      :queue.filter(
        fn
          {_pid, ^cancel_reference, caller_monitor} ->
            true = Process.demonitor(caller_monitor, [:flush])
            false

          _ ->
            true
        end,
        waiting
      )

    {:noreply, %{state | waiting: next_waiting}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %State{borrow_caller_monitors: borrow_caller_monitors} = state
      ) do
    case :ets.match(borrow_caller_monitors, {:"$1", ref}) do
      # Means there was an active borrow and the caller process died.
      # We handle this as a return of the borrowed worker pid.
      [[pid]] ->
        true = :ets.delete(borrow_caller_monitors, pid)
        handle_return(pid, state, true)

      # Either:
      # a) the caller process died while waiting for a worker pid to be sent
      # b) a monitored worker pid exited
      [] ->
        handle_exit({ref, pid}, state)
    end
  end

  #####################
  # Private Functions #
  #####################

  defp handle_return(pid, %State{} = state, false) do
    Logger.warn(
      "#{inspect(pid)} died while on loan and a new worker has since started in its place. Ignoring..."
    )

    {:noreply, state}
  end

  defp handle_return(
         pid,
         %State{
           borrow_caller_monitors: borrow_caller_monitors,
           waiting: waiting,
           workers: workers
         } = state,
         true
       ) do
    case :queue.out(waiting) do
      # There is at least one caller process waiting to borrow a worker pid.
      {{:value, {reply_to, _caller_reference, caller_monitor}}, next_waiting} ->
        # Consider the borrow successful. Will be used to look up
        # and demonitor upon successful return, or if the caller process dies.
        true = :ets.insert(borrow_caller_monitors, {pid, caller_monitor})

        # Sends an explicit reply to the next process awaiting one.
        #
        # Learn more @ https://hexdocs.pm/elixir/GenServer.html#reply/2.
        :ok = GenServer.reply(reply_to, {:ok, pid})
        {:noreply, %{state | waiting: next_waiting}}

      _ ->
        next_workers = [pid | workers]
        {:noreply, %{state | workers: next_workers}}
    end
  end

  defp handle_exit({ref, pid}, %State{waiting: waiting, worker_monitors: worker_monitors} = state) do
    case :ets.lookup(worker_monitors, pid) do
      # A monitored worker pid exited
      [{^pid, _ref}] ->
        Logger.warn("Worker #{inspect(pid)} died. Restarting...")
        true = :ets.delete(worker_monitors, pid)
        restart_child(pid, state)

      # The caller process died while waiting for a worker pid to be sent.
      [] ->
        next_waiting =
          :queue.filter(fn {_, _, caller_monitor} -> caller_monitor !== ref end, waiting)

        {:noreply, %{state | waiting: next_waiting}}
    end
  end

  defp restart_child(
         old_pid,
         %State{
           child_init_opts: child_init_opts,
           worker_monitors: worker_monitors,
           workers: workers
         } = state
       ) do
    # In this scenario, might want to start the child via Process.send_after()
    # to make sure no weird race conditions happen when trying to start a new
    # child under a Supervisor that might be shutting down.
    pid = start_child(child_init_opts, worker_monitors)
    next_workers = List.delete(workers, old_pid)
    handle_return(pid, %{state | workers: next_workers}, true)
  end

  defp start_child({supervisor_name, worker_module, worker_opts}, worker_monitors) do
    # Make sure when the child exits it is never restarted by the Supervisor.
    # Instead, we will restart it from within this server.
    child_spec = worker_opts |> worker_module.child_spec() |> Map.put(:restart, :temporary)

    {:ok, pid} = DynamicSupervisor.start_child(supervisor_name, child_spec)

    # We will get notified when the worker exits.
    ref = Process.monitor(pid)
    true = :ets.insert(worker_monitors, {pid, ref})

    Logger.debug("Started worker #{inspect(pid)}.")

    pid
  end
end
