![Elixir CI](https://github.com/hqoss/pool_lad/workflows/Elixir%20CI/badge.svg)
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/4cfbf336d5914e09971c015bd68426a0)](https://www.codacy.com/gh/hqoss/pool_lad?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=hqoss/pool_lad&amp;utm_campaign=Badge_Grade)
[![Hex.pm](https://img.shields.io/hexpm/v/pool_lad.svg)](https://hex.pm/packages/pool_lad)
[![Coverage Status](https://coveralls.io/repos/github/hqoss/pool_lad/badge.svg?branch=master)](https://coveralls.io/github/hqoss/pool_lad?branch=master)

# 🙅‍♂️ PoolLad

`pool_lad` is the younger & more energetic version of [`poolboy`](https://github.com/devinus/poolboy).

It's still the _**lightweight, generic pooling library with focus on
simplicity, performance, and rock-solid disaster recovery**_ that we all love...

...but it has just gotten a much needed facelift!

## Table of contents

-   [Installation](#installation)

-   [API Documentation](#api-documentation)

-   [Sample usage](#sample-usage)

-   [Example application](#example-application)

    -   [Define a worker server](#define-a-worker-server)
    -   [Start the pool](#start-the-pool)
    -   [Do the work](#do-the-work)

-   [`pool_lad` over `poolboy`](#pool_lad-over-poolboy)

-   [TODO](#todo)

## Installation

Add `:pool_lad` as a dependency to your project's `mix.exs`:

```elixir
defp deps do
  [
    {:pool_lad, "~> 0.0.2"}
  ]
end
```

## API Documentation

The full documentation is [published on hex](https://hexdocs.pm/pool_lad/).

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

## TODO

A quick and dirty tech-debt tracker, used in conjunction with Issues.

-   [ ] Add overflow functionality
-   [ ] Beautify PoolLad over :poolboy section
