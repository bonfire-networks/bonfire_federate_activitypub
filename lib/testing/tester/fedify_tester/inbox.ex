# dev/test-only, like `Testing.Interop`: not compiled into prod releases at all
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.Tester.FedifyTester.Inbox do
    @moduledoc """
    Fedify's ephemeral inbox (`fedify inbox`), following an actor of ours: owns the program's port, keeps all it prints, and answers whether it has said something yet. Start it with `start_supervised`, so it stops (and the program with it) when the test ends.

    It is tunnelled (no `-T`), as Fedify refuses private addresses and `fedify inbox` has no option to allow them; and with `-d`, its debug log (lookups, what it sends, how it checks what it receives), for a failure message.

    It counts as started once its server is up, before it has followed: a caller waits for its `Follow` to reach us, counting what arrives from before it starts this.
    """
    use GenServer

    @start_timeout 60_000

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def child_spec(opts),
      do: %{id: {__MODULE__, opts[:follow]}, start: {__MODULE__, :start_link, [opts]}}

    @doc "Its actor's URI."
    def actor(pid), do: GenServer.call(pid, :actor)

    @doc "All it has printed so far."
    def output(pid), do: GenServer.call(pid, :output)

    @doc "Whether it says `text` within `seconds` (or has already)."
    def await(pid, text, seconds),
      do: GenServer.call(pid, {:await, text, seconds * 1000}, seconds * 1000 + 5_000)

    @impl true
    def init(opts) do
      # so `terminate/2` runs when the test's supervisor stops it, and kills the program
      Process.flag(:trap_exit, true)

      port =
        Port.open({:spawn_executable, System.find_executable("fedify")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["inbox", "-d", "-f", Keyword.fetch!(opts, :follow), "-a", "*"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      state = %{port: port, os_pid: os_pid, output: "", waiters: []}

      case read_until_started(state, System.monotonic_time(:millisecond) + @start_timeout) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    end

    # it is started once its server is up: it prints its table of actor and inboxes only after our inbox has answered its Follow (`fedify inbox`'s follow loop awaits the POST), which through two tunnels took over a minute on 25 October, so its actor (`<url>i`) is read from the URL it prints first
    defp read_until_started(%{port: port} = state, deadline) do
      case Regex.run(~r/ephemeral ActivityPub server is up and running: (\S+)/u, state.output) do
        [_, url] ->
          {:ok, Map.put(state, :actor, String.trim_trailing(url, "/") <> "/i")}

        _ ->
          receive do
            {^port, {:data, data}} ->
              read_until_started(%{state | output: state.output <> data}, deadline)

            {^port, {:exit_status, status}} ->
              {:error, {{:fedify_inbox_exited, status}, state.output}}
          after
            max(deadline - System.monotonic_time(:millisecond), 0) ->
              kill(state)
              {:error, {:fedify_inbox_did_not_start, state.output}}
          end
      end
    end

    @impl true
    def handle_call(:actor, _from, state), do: {:reply, state.actor, state}
    def handle_call(:output, _from, state), do: {:reply, state.output, state}

    def handle_call({:await, text, timeout}, from, state) do
      if String.contains?(state.output, text) do
        {:reply, true, state}
      else
        ref = make_ref()
        Process.send_after(self(), {:await_timeout, ref}, timeout)
        {:noreply, %{state | waiters: [{ref, text, from} | state.waiters]}}
      end
    end

    @impl true
    def handle_info({port, {:data, data}}, %{port: port} = state) do
      output = state.output <> data

      {said, waiting} =
        Enum.split_with(state.waiters, fn {_ref, text, _from} ->
          String.contains?(output, text)
        end)

      Enum.each(said, fn {_ref, _text, from} -> GenServer.reply(from, true) end)
      {:noreply, %{state | output: output, waiters: waiting}}
    end

    def handle_info({:await_timeout, ref}, state) do
      {timed_out, waiting} = Enum.split_with(state.waiters, fn {r, _, _} -> r == ref end)
      Enum.each(timed_out, fn {_ref, _text, from} -> GenServer.reply(from, false) end)
      {:noreply, %{state | waiters: waiting}}
    end

    def handle_info({port, {:exit_status, status}}, %{port: port} = state),
      do: {:stop, {:fedify_inbox_exited, status}, state}

    def handle_info(_other, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state), do: kill(state)

    defp kill(%{os_pid: os_pid}), do: System.cmd("kill", [to_string(os_pid)])
  end
end
