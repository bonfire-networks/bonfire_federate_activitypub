defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  use Bonfire.Common.Utils
  use Arrows
  alias ActivityPub.MRF
  alias Bonfire.Boundaries
  import Where
  @behaviour MRF

  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  @impl true
  def filter(activity) do
    dump(activity, "to filter")

    authors = all_actors(activity)
    recipients = all_recipients(activity)

    local_author_ids = authors
    |> local_actor_ids()
    |> dump("local_author_ids")

    local_recipient_ids = recipients
    |> local_actor_ids()
    |> dump("local_recipient_ids")

    with {:ok, activity} <- check_blocks(:ghost, local_author_ids, activity),
         {:ok, activity} <- check_blocks(:silence, local_recipient_ids, activity) do

      {:ok, activity}
    end
  end

  defp check_blocks(block_type, local_actor_ids, activity) do
    block_types = Boundaries.block_types(block_type)
    |> dump("block_types")

    if  !check_block(block_types, local_actor_ids, e(activity, "actor", nil)) # activity's actor
        and !check_block(block_types, local_actor_ids, e(activity, "object", "attributedTo", nil)) # object's actor
        and !check_block(block_types, local_actor_ids, activity) # activity's instance
        and !check_block(block_types, local_actor_ids, e(activity, "object", nil)) do # object's instance
          case filter_recipients(block_types, activity, local_actor_ids) do
            %{"to" => []} ->
              debug("reject activity because all actors were filtered")
              {:reject, nil}
            activity ->
              {:ok, activity}
              |> dump("filtered")
          end
    else
      {:reject, nil}
    end
  end

  defp check_block(block_types, local_author_ids, %{"id" => canonical_uri}), do: check_block(block_types, local_author_ids, canonical_uri)
  defp check_block(block_types, local_author_ids, canonical_uri) when is_binary(canonical_uri) do
    attack_the_blocks(block_types, local_author_ids, canonical_uri)
  end
  defp check_block(_, _, _canonical_uri), do: nil

  defp attack_the_blocks(block_types, local_author_ids, canonical_uri) do
    uri = URI.parse(canonical_uri)

    rejects = rejects_regex(block_types)
    # |> dump("MRF instance_wide blocks from config")

    check_instance_block(uri, rejects)
    || check_actor_block(block_types, local_author_ids, uri, rejects)
  end

  defp check_instance_block(%{host: actor_host} = actor_uri, rejects) do
    MRF.subdomain_match?(rejects, actor_host)
    # || Bonfire.Federate.ActivityPub.Instances.is_blocked?(actor_uri, :any, :instance_wide)
    # ^ NOTE: no need to check the instance block in DB here because that's being handled by Peered.is_blocked? triggered by Actors.is_blocked? via check_actor_block
  end

  defp check_actor_block(block_types, local_author_ids, %{host: actor_host, path: actor_path} = actor_uri, rejects) do
    clean_url = "#{actor_host}#{actor_path}"
    # dump(actor_uri, "actor_uri")

    MRF.subdomain_match?(rejects, clean_url)
    # || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
    || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, block_types, user_ids: local_author_ids) #|> dump()
  end

  defp filter_recipients(block_types, activity, local_actor_ids) do
    rejects = rejects_regex(block_types)
    # |> dump("MRF actor filter from config")

    activity
    |> filter_recipients("to", block_types, rejects, local_actor_ids)
    |> filter_recipients("cc", block_types, rejects, local_actor_ids)
    |> filter_recipients("bto", block_types, rejects, local_actor_ids)
    |> filter_recipients("bcc", block_types, rejects, local_actor_ids)
    |> filter_recipients("audience", block_types, rejects, local_actor_ids)
  end

  defp filter_recipients(activity, field, block_types, rejects, local_actor_ids) do
    case activity[field] do
      recipients when is_list(recipients) ->
        Map.put(activity, field, filter_actors(recipients, block_types, rejects, local_actor_ids))
      recipient when is_binary(recipient) ->
        Map.put(activity, field, filter_actors([recipient], block_types, rejects, local_actor_ids))
      _ -> activity
    end
  end

  defp filter_actors(actors, block_types, rejects, local_actor_ids) do
    Enum.reject(actors || [], &filter_actor(&1, block_types, rejects, local_actor_ids))
  end
  defp filter_actor(%{ap_id: actor}, block_types, rejects, local_actor_ids) when is_binary(actor) do
    filter_actor(actor, block_types, rejects, local_actor_ids)
  end
  defp filter_actor(%{"id" => actor}, block_types, rejects, local_actor_ids) when is_binary(actor) do
    filter_actor(actor, block_types, rejects, local_actor_ids)
  end
  defp filter_actor(actor, block_types, rejects, local_actor_ids) when is_binary(actor) do
    actor_uri = URI.parse(actor)
    clean_actor_uri = "#{actor_uri.host}#{actor_uri.path}"
    MRF.subdomain_match?(rejects, actor_uri.host) # instance blocked in config
    || MRF.subdomain_match?(rejects, clean_actor_uri) # actor blocked in config
  #  || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, :any, :instance_wide) # TEMP: will be included when we do per-iser
    || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, block_types, user_ids: local_actor_ids) # actor or instance blocked in DB, either instance-wide or by specified local_actor_ids
  end

  def all_actors(activity) do
    [e(activity, "actor", nil)]
    ++ [e(activity, "object", "actor", nil)]
    ++ [e(activity, "object", "attributedTo", nil)]
    |> List.flatten()
    |> Enum.map(&id_or_object_id/1)
    |> filter_empty([])
    |> Enum.uniq()
    |> dump
  end

  def all_recipients(activity, fields \\ ["to", "bto", "cc", "bcc", "audience"]) do
    all_fields(activity, fields)
    |> dump
  end

  defp all_fields(activity, fields) do
    Enum.map(fields, &( activity[&1] |> id_or_object_id ))
    |> List.flatten()
    |> filter_empty([])
    |> Enum.uniq()
  end

  defp id_or_object_id(%{"id" => id}) when is_binary(id) do
    id
  end
  defp id_or_object_id(id) when is_binary(id) do
    id
  end
  defp id_or_object_id(_) do
    nil
  end

  defp local_actor_ids(actors) do
    ap_base_uri = ActivityPubWeb.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
    # |> dump("ap_base_uri")

    actors
    |> Enum.map(&id_or_object_id/1)
    |> filter_empty([])
    |> Enum.filter(&( String.starts_with?(&1, ap_base_uri)))
    |> Enum.uniq()
    |> Enum.map(&( ActivityPub.Actor.get_or_fetch_by_ap_id(&1) ~> e(:pointer_id, nil) ))
  end

  defp rejects_regex(block_types) do
    (block_types ++ [:block])
    |> Enum.flat_map(&ActivityPub.Config.get([:boundaries, &1]))
    |> MRF.subdomains_regex()
  end
end
