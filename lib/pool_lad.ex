defmodule PoolLad do
  alias PoolLad.Queue

  use Supervisor

  @this_module __MODULE__

  def start_link({pool_opts, worker_opts}) do
    name = Keyword.fetch!(pool_opts, :name)

    supervisor = Module.concat(name, Supervisor)
    worker_supervisor = Module.concat(name, WorkerSupervisor)

    # Add the worker_supervisor module name as it's going to be used
    # by the Queue server when starting new children.
    pool_opts = Keyword.put(pool_opts, :worker_supervisor, worker_supervisor)

    Supervisor.start_link(@this_module, {pool_opts, worker_opts}, name: supervisor)
  end

  def transaction(module, fun) do
    pid = GenServer.call(module, :get_next_pid)
    fun.(pid)
  end

  @impl true
  def init({pool_opts, worker_opts}) do
    worker_supervisor = Keyword.get(pool_opts, :worker_supervisor)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: worker_supervisor},
      {Queue, {pool_opts, worker_opts}}
    ]

    # If a child terminates, make sure they all terminate and restart.
    # Read more @ https://hexdocs.pm/elixir/Supervisor.html#module-strategies.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
