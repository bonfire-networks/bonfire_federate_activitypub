defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  alias ActivityPub.MRF
  require Logger
  @behaviour MRF

  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  defp check_block(canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)

    rejects = (
      ActivityPub.Config.get([:boundaries, :mute])
      ++
      ActivityPub.Config.get([:boundaries, :block])
      ) |> MRF.subdomains_regex()
        # |> IO.inspect(label: "MRF blocks")

    check_instance_block(uri, rejects) || check_actor_block(uri, rejects)
  end

  defp check_block(_canonical_uri), do: nil

  defp check_instance_block(%{host: actor_host} = actor_uri, rejects) do
    MRF.subdomain_match?(rejects, actor_host) # || Bonfire.Federate.ActivityPub.Instances.is_blocked?(actor_uri) # no need to check the instance block in DB here because that's handled by Peered.is_blocked?
  end

  defp check_actor_block(%{host: actor_host, path: actor_path} = actor_uri, rejects) do
    clean_url = "#{actor_host}#{actor_path}"
    # IO.inspect(actor_uri, label: "actor_uri")

    MRF.subdomain_match?(rejects, clean_url) || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri) #|> IO.inspect
  end

  defp filter_recipients(activity) do
    deafen = (
      ActivityPub.Config.get([:boundaries, :deafen])
      ++
      ActivityPub.Config.get([:boundaries, :block])
      ) |> MRF.subdomains_regex()
        # |> IO.inspect(label: "MRF deafen")

    activity
    |> filter_recipients("to", deafen)
    |> filter_recipients("cc", deafen)
    |> filter_recipients("bto", deafen)
    |> filter_recipients("bcc", deafen)
    |> filter_recipients("audience", deafen)
  end

  defp filter_recipients(activity, field, deafen) do
    case activity[field] do
      recipients when is_list(recipients) ->
        Map.put(activity, field, filter_actors(recipients, deafen))
      recipient when is_binary(recipient) ->
        Map.put(activity, field, filter_actors([recipient], deafen))
      _ -> activity
    end
  end

  defp filter_actors(actors, deafen) do
    Enum.reject(actors || [], &filter_actor(&1, deafen))
  end
  defp filter_actor(actor, deafen) do
    actor_uri = URI.parse(actor)
    clean_url = "#{actor_uri.host}#{actor_uri.path}"
    MRF.subdomain_match?(deafen, actor_uri.host) || MRF.subdomain_match?(deafen, clean_url) || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri)
  end

  @impl true
  def filter(activity) do
    # TODO: also check that actors and object instances aren't from blocked instances

    if  !check_block(activity["id"])
        and !check_block(activity["actor"])
        and !check_block(activity["object"]["attributedTo"])
        and !check_block(activity["object"]["id"]) do
      {:ok, filter_recipients(activity)}
    else
      {:reject, nil}
    end
  end

end
