# Overview

`pool_lad` is the younger & more energetic version of [`poolboy`](https://github.com/devinus/poolboy).

It's still the _**lightweight, generic pooling library with focus on
simplicity, performance, and rock-solid disaster recovery**_ that we all love...

...but it has just gotten a much needed facelift!

## Installation

Add `:pool_lad` as a dependency to your project's `mix.exs`:

```elixir
defp deps do
  [
    {:pool_lad, "~> 0.0.5"}
  ]
end
```

## API Documentation

See `PoolLad`.

## Sample usage

The APIs are almost identical to those of [`:poolboy`](https://github.com/devinus/poolboy).

Via manual ownership:

```elixir
iex(1)> {:ok, pid} = PoolLad.borrow(MyWorkerPool)
{:ok, #PID<0.229.0>}
iex(2)> GenServer.call(pid, :get_latest_count)
{:ok, 42}
iex(3)> PoolLad.return(MyWorkerPool, pid)
:ok
```

Via transactional ownership:

```elixir
iex(1)> PoolLad.transaction(
  MyWorkerPool,
  fn pid -> GenServer.call(pid, :get_latest_count) end
)
{:ok, 42}
```

## Example application

### Define a worker server

```elixir
defmodule MyWorker do
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
    {:reply, colour, colours}
  end
end
```

### Start the pool

```elixir
pool_opts = [
  name: MyWorkerPool,
  worker_count: 3,
  worker_module: MyWorker
]

worker_opts = [initial_colours: ~w(red green blue)a]

children = [
  PoolLad.child_spec(pool_opts, worker_opts)
]

opts = [strategy: :one_for_one, name: MyApp.Supervisor]
Supervisor.start_link(children, opts)
```

### Do the work

Via manual ownership:

```elixir
iex(1)> {:ok, worker} = PoolLad.borrow(MyWorkerPool)
{:ok, #PID<0.256.0>}
iex(2)> GenServer.call(worker, :get_random_colour)
:blue
iex(3)> PoolLad.return(MyWorkerPool, worker)
:ok
```

Via transactional ownership:

```elixir
iex(1)> PoolLad.transaction(
...(1)>   MyWorkerPool,
...(1)>   fn worker -> GenServer.call(worker, :get_random_colour) end
...(1)> )
:green
```

## `pool_lad` over `poolboy`

-   Elixir-first
-   Modern APIs, e.g. `DynamicSupervisor`
-   Less code, less pesky logs, less noise
-   More documentation
-   Same performance
-   Maintained
-   0 dependencies
