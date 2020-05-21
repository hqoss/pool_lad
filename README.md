# 🙅‍♂️ PoolLad

`pool_lad` is the simpler and more modern version of `:poolboy`.

## Table of contents

-   [Installation](#installation)
-   [Documentation](#documentation)
-   [Sample usage](#sample-usage)

## Installation

Add `:pool_lad` as a dependency to your project's `mix.exs`:

```elixir
defp deps do
  [
    {:pool_lad, "~> 0.0.1"}
  ]
end
```

## Documentation

The full documentation is [published on hex](https://hexdocs.pm/pool_lad/).

## Sample usage

Configure and start with `Supervisor`:

```elixir
pool_opts = [
  name: MyWorkerPool
  worker_count: 3
  worker_module: MyWorker
]

worker_opts = []

children = [
  {PoolLad, {pool_opts, worker_opts}},
  # ... other children
]

{:ok, pid} = Supervisor.start_link(children, strategy: :one_for_one)
```

Then from our app:

```elixir
# Will call the next MyWorker in the queue.
PoolLad.transaction(MyWorkerPool, fn pid -> GenServer.call(pid, :message) end)
```
