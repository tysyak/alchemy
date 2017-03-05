defmodule Alchemy.Discord.RateManager do
  @moduledoc false
  # Used to keep track of rate limits. All api requests must request permission to
  # run from here.
  use GenServer
  require Logger
  import Alchemy.Discord.RateLimits
  alias ALchemy.Discord.RateLimits.RateInfo


  def start_link(token) do
    GenServer.start_link(__MODULE__, token, name: API)
  end


  # Starts a new task to go through the whole process
  def send_req(req, route) do
    Task.async(__MODULE__, :request, [req, route])
  end


  # Wrapper method around applying for a slot
  def apply(route) do
    GenServer.call(API, {:apply, route})
  end




  # Applies for a bucket, waiting and retrying if it fails to get a slot
  def request(req, route) do
    case apply(route) do
      {:wait, n} ->
        Process.sleep(n)
        request(req, route)
      {:go, token} ->
        process_req(req, token, route)
    end
  end


  # Wrapper method around processing an API response
  def process(result, route) do
    GenServer.call(API, {:process, route, result})
  end


  # Performs the request, and then sends the info back to the genserver to handle
  defp process_req({m, f, a}, token, route) do
    result = apply(m, f, [token | a])
    case process(result, route) do
      {:retry, time} ->
        Logger.info "Local rate limit encountered for route #{route}" <>
                    "\n retrying in #{time} ms."
        Process.sleep(time)
        request({m, f, a}, route)
      done ->
        done
    end
  end


  defmodule State do
    @moduledoc false
    defstruct [:token, :global, :rates]
  end


  def init(token) do
    table = :ets.new(:rates, [:named_table])
    {:ok, %State{token: token, rates: table}}
  end


  defp get_rates(route) do
    case :ets.lookup(:rates, route) do
      [{^route, info}] -> info
      [] -> default_info()
    end
  end


  defp update_rates(_route, nil) do
    nil
  end
  defp update_rates(route, info) do
    :ets.insert(:rates, {route, info})
  end


  defp set_global(timeout) do
    GenServer.call(API, {:set_global, timeout})
  end


  def throttle(%{remaining: remaining} = rates) when remaining > 0 do
    {:go, %{rates | remaining: remaining - 1}}
  end
  def throttle(rates) do
    now = DateTime.utc_now |> DateTime.to_unix
    wait_time = rates.reset_time - now
    cond do
      wait_time > 0 ->
        {:wait, wait_time * 1000}
      wait_time == 0 ->
        {:wait, 1000}
      # this means the reset_time has passed
      true ->
        {:go, %{rates | remaining: rates.limit - 1,
                        reset_time: now + 2}}
    end
  end


  def handle_call({:apply, route}, _, state) do
    case throttle(get_rates(route)) do
      {:wait, time} ->
        Logger.debug "Timeout of #{time} under route #{route}"
        {:reply, {:wait, time}, state}
      {:go, new_rates} ->
        update_rates(route, new_rates)
        {:reply, {:go, state.token}, state}
    end
  end


  def handle_call({:process, route, result}, _, state) do
    response = case result do
      {:ok, data, rates} ->
        update_rates(route, rates)
        {:ok, data}
      {:local, timeout, rates} ->
        update_rates(route, rates)
        {:retry, timeout}
      {:global, timeout} ->
        set_global(timeout)
        {:retry, timeout}
      error ->
        error
    end
    {:reply, response, state}
  end


  def handle_call({:set_global, timeout}, _, state) do
    Task.start(fn ->
      Process.sleep(timeout)
      GenServer.call(API, :reset_global)
    end)
    {:reply, :ok, %{state | global: {:wait, timeout}}}
  end

end
