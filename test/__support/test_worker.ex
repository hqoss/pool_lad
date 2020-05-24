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
    {:reply, colour, colours}
  end
end
