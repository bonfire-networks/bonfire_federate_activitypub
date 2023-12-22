# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.FederationModules do
  @moduledoc """
  A automatically-generated global list of federation modules which can queried by activity and/or object type.

  To add a module to this list, you should declare `@behaviour Bonfire.Federate.ActivityPub.FederationModules` in it and define a `federation_module/0` function which returns a list of object and/or activity types which that module handles.

  Example:
  ```
  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Announce",
      {"Create", "Announce"},
      {"Undo", "Announce"},
      {"Delete", "Announce"}
    ]
  ```

  You should also then implement these two functions:
  - for outgoing federation: `ap_publish_activity(subject_struct, verb, object_struct)`
  - for incoming federation: `ap_receive_activity(subject_struct, activity_json, object_json)`
  """
  @behaviour Bonfire.Common.ExtensionBehaviour

  import Untangle
  # alias Bonfire.Common.Utils

  @doc "Get a Federation Module identified by activity and/or object type, given a activity and/or object (string or {activity, object} tuple)."
  @callback federation_module() :: any
  def federation_module(query, modules \\ linked_federation_modules())

  def federation_module({_verb, type} = query, modules) when is_atom(type) do
    case Map.get(modules || linked_federation_modules(), query) do
      nil ->
        # fallback to context module (with object type only)
        Bonfire.Common.ContextModule.context_module(type)

      other ->
        {:ok, other}
    end
  end

  def federation_module(query, modules) when is_atom(query) do
    case Map.get(modules || linked_federation_modules(), query) do
      nil ->
        # fallback to context module
        Bonfire.Common.ContextModule.context_module(query)

      other ->
        {:ok, other}
    end
  end

  def federation_module(query, modules)
      when is_binary(query) or is_atom(query) or is_tuple(query) do
    case Map.get(modules || linked_federation_modules(), query) do
      nil ->
        {:error, :not_found}

      other ->
        {:ok, other}
    end
  end

  @doc "Look up a Federation Module, throw :not_found if not found."
  def federation_module!(query) do
    with {:ok, module} <- federation_module(query) do
      module
    else
      _e ->
        throw(:not_found)
    end
  end

  def maybe_federation_module(query, fallback \\ nil) do
    with {:ok, module} <- federation_module(query) do
      module
    else
      _ ->
        fallback
    end
  end

  @doc "Look up many types at once, throw :not_found if any of them are not found"
  def federation_modules(queries) do
    modules = modules()
    Enum.map(queries, &federation_module(&1, modules))
  end

  def app_modules() do
    Bonfire.Common.ExtensionBehaviour.behaviour_app_modules(__MODULE__)
  end

  def modules() do
    Bonfire.Common.ExtensionBehaviour.behaviour_modules(__MODULE__)
  end

  # TODO: cache the linked activity/object types
  def linked_federation_modules() do
    Bonfire.Common.ExtensionBehaviour.apply_modules(modules(), :federation_module)
    |> Map.new()
  end
end
