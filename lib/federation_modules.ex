# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.FederationModules do
  # TODO refactor for Bonfire.Common.ExtensionBehaviour
  @moduledoc """
  A Global cache of known federation modules to be queried by activity and/or object type.

  Use of the FederationModules Service requires:

  1. Exporting `federation_module/0` in relevant modules (in context modules indicating what activity or object types the module can handle)
  2. To populate `:bonfire, :federation_search_path` in config with the list of OTP applications where federation modules are declared.
  3. Start the `Bonfire.Federate.ActivityPub.FederationModules` application before querying.
  4. OTP 21.2 or greater, though we recommend using the most recent
     release available.

  While this module is a GenServer, it is only responsible for setup
  of the cache and then exits with :ignore having done so. It is not
  recommended to restart the service as this will lead to a stop the
  world garbage collection of all processes and the copying of the
  entire cache to each process that has queried it since its last
  local garbage collection.
  """

  import Untangle
  alias Bonfire.Common.Utils

  use GenServer, restart: :transient

  @typedoc """
  A query is either a federation_module name atom or (Pointer) id binary
  """
  @type query :: binary | atom | tuple

  @spec start_link(ignored :: term) :: GenServer.on_start()
  @doc "Populates the global cache with federation_module data via introspection."
  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  def data() do
    :persistent_term.get(__MODULE__)
  rescue
    e in ArgumentError ->
      debug("Gathering a list of federation modules...")
      populate()
  end

  defp data_init() do
    error("The FederationModules service was not started. Please add it to your Application.")

    populate()
  end

  @spec federation_module(query :: query) :: {:ok, atom} | {:error, :not_found}
  @doc "Get a Federation Module identified by activity and/or object type, as string or {activity, object} tuple."
  def federation_module({verb, type} = query) when is_atom(type) do
    case Map.get(data(), query) do
      nil ->
        # fallback to context module
        Bonfire.Common.ContextModule.context_module(type)

      other ->
        {:ok, other}
    end
  end

  def federation_module(query) when is_atom(query) do
    case Map.get(data(), query) do
      nil ->
        # fallback to context module
        Bonfire.Common.ContextModule.context_module(query)

      other ->
        {:ok, other}
    end
  end

  def federation_module(query)
      when is_binary(query) or is_atom(query) or is_tuple(query) do
    case Map.get(data(), query) do
      nil ->
        {:error, :not_found}

      other ->
        {:ok, other}
    end
  end

  @doc "Look up a Federation Module, throw :not_found if not found."
  def federation_module!(query), do: Map.get(data(), query) || throw(:not_found)

  @spec federation_modules([binary | atom]) :: [binary]
  @doc "Look up many types at once, throw :not_found if any of them are not found"
  def federation_modules(modules) do
    data = data()
    Enum.map(modules, &Map.get(data, &1))
  end

  def maybe_federation_module(query) do
    # fallback
    with {:ok, module} <- federation_module(query) do
      module
    else
      _ ->
        nil
    end
  end

  def federation_function_error(error, _args) do
    warn(
      error,
      "FederationModules - there's no federation module declared for this schema: 1) No function federation_module/0 was found that returns this type (as a binary, tuple, or within a list). 2)"
    )

    nil
  end

  # GenServer callback

  @doc false
  def init(_) do
    populate()
    :ignore
  end

  def populate() do
    indexed =
      search_path()
      # |> IO.inspect
      |> Enum.flat_map(&app_modules/1)
      # |> debug(limit: :infinity)
      |> Enum.filter(&declares_federation_module?/1)
      # |> debug(limit: :infinity)
      |> Enum.reduce(%{}, &index/2)

    # |> IO.inspect
    :persistent_term.put(__MODULE__, indexed)
    indexed
  end

  defp app_modules(app), do: app_modules(app, Application.spec(app, :modules))
  defp app_modules(_, nil), do: []
  defp app_modules(_, mods), do: mods

  # called by populate/0
  defp search_path(),
    do: Application.fetch_env!(:bonfire, :federation_search_path)

  # called by populate/0
  defp declares_federation_module?(module),
    do:
      Code.ensure_loaded?(module) and
        function_exported?(module, :federation_module, 0)

  # called by populate/0
  defp index(mod, acc), do: index(acc, mod, mod.federation_module())

  # called by index/2
  defp index(acc, declaring_module, handle_federation)
       when is_list(handle_federation) do
    Enum.map(handle_federation, &{&1, declaring_module})
    |> Enum.into(%{})
    |> Map.merge(acc)
  end

  defp index(acc, declaring_module, handle_federation) do
    Map.merge(%{handle_federation => declaring_module}, acc)
  end
end
