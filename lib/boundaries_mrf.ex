defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  alias ActivityPub.MRF
  require Logger
  @behaviour MRF

  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  defp check_block(actor, object) do
    actor_info = URI.parse(actor)

    rejects = (
      ActivityPub.Config.get([:boundaries, :mute])
      ++
      ActivityPub.Config.get([:boundaries, :block])
      ) |> MRF.subdomains_regex()
        # |> IO.inspect(label: "MRF blocks")

    with {:ok, object} <- check_instance_block(actor_info, object, rejects),
         {:ok, object} <- check_actor_block(actor_info, object, rejects) do
      {:ok, filter_recipients(object)}
    else
      _e -> {:reject, nil}
    end
  end

  defp check_instance_block(%{host: actor_host} = _actor_info, object, rejects) do
    # IO.inspect(actor_host, label: "actor_host")

    if MRF.subdomain_match?(rejects, actor_host) do
      {:reject, nil}
    else
      {:ok, object}
    end
  end

  defp check_actor_block(%{host: actor_host, path: actor_path} = _actor_info, object, rejects) do
    clean_url = "#{actor_host}#{actor_path}"
    # IO.inspect(path, label: "path")

    if MRF.subdomain_match?(rejects, clean_url) do
      {:reject, nil}
    else
      {:ok, object}
    end
  end

  defp filter_recipients(object) do
    deafen = (
      ActivityPub.Config.get([:boundaries, :deafen])
      ++
      ActivityPub.Config.get([:boundaries, :block])
      ) |> MRF.subdomains_regex()
        # |> IO.inspect(label: "MRF deafen")

    object
    |> filter_recipients("to", deafen)
    |> filter_recipients("cc", deafen)
    |> filter_recipients("bto", deafen)
    |> filter_recipients("bcc", deafen)
    |> filter_recipients("audience", deafen)
  end

  defp filter_recipients(object, field, deafen) do
    case object[field] do
      recipients when is_list(recipients) ->
        Map.put(object, field, filter_actors(recipients, deafen))
      recipient when is_binary(recipient) ->
        Map.put(object, field, filter_actors([recipient], deafen))
      _ -> object
    end
  end

  defp filter_actors(actors, deafen) do
    Enum.reject(actors || [], &filter_actor(&1, deafen))
  end
  defp filter_actor(actor, deafen) do
    actor_info = URI.parse(actor)
    clean_url = "#{actor_info.host}#{actor_info.path}"
    MRF.subdomain_match?(deafen, actor_info.host) || MRF.subdomain_match?(deafen, clean_url)
  end

  @impl true
  def filter(%{"actor" => actor} = object) do
    check_block(actor, object)
  end

  def filter(%{"id" => actor, "type" => obj_type} = object)
      when obj_type in @supported_actor_types do
    check_block(actor, object)
  end

  def filter(object) do
    Logger.warn("BoundariesMRF: no matching filter for #{object}")
    {:ok, object}
  end
end
