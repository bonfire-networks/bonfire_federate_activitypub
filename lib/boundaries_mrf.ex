defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  use Bonfire.Common.Utils
  use Arrows
  alias ActivityPub.MRF
  import Where
  @behaviour MRF

  @supported_actor_types ActivityPub.Utils.supported_actor_types()

  @impl true
  def filter(activity) do
    dump(activity, "to filter")
    ap_base_uri = ActivityPubWeb.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
    # |> dump("ap_base_uri")

    authors = all_actors(activity)
    recipients = all_recipients(activity)

    local_user_ids = (authors ++ recipients)
    |> Enum.filter(&( String.starts_with?(&1, ap_base_uri)))
    |> Enum.uniq()
    |> Enum.map(&( ActivityPub.Actor.get_or_fetch_by_ap_id(&1) ~> e(:pointer_id, nil) ))
    |> dump("local_user_ids")

    if  !check_block(e(activity, "id", nil))
        and !check_block(e(activity, "actor", nil))
        and !check_block(e(activity, "object", nil))
        and !check_block(e(activity, "object", "attributedTo", nil))
        and !check_block(e(activity, "object", "id", nil)) do
      {:ok, filter_recipients(activity, local_user_ids)} |> dump("filtered")
    else
      {:reject, nil}
    end
  end

  defp check_block(canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)

    rejects = (
      ActivityPub.Config.get([:boundaries, :silence])
      ++
      ActivityPub.Config.get([:boundaries, :ghost])
      ++
      ActivityPub.Config.get([:boundaries, :block])
      )
      |> MRF.subdomains_regex()
      |> dump("MRF instance_wide blocks from config")

    check_instance_block(uri, rejects)
    || check_actor_block(uri, rejects)
  end

  defp check_block(_canonical_uri), do: nil

  defp check_instance_block(%{host: actor_host} = actor_uri, rejects) do
    MRF.subdomain_match?(rejects, actor_host) # || Bonfire.Federate.ActivityPub.Instances.is_blocked?(actor_uri, :any, :instance_wide) # no need to check the instance block in DB here because that's handled by Peered.is_blocked?
  end

  defp check_actor_block(%{host: actor_host, path: actor_path} = actor_uri, rejects) do
    clean_url = "#{actor_host}#{actor_path}"
    # dump(actor_uri, "actor_uri")

    MRF.subdomain_match?(rejects, clean_url)
    || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, :any, :instance_wide) #|> IO.inspect
  end

  defp filter_recipients(activity, local_user_ids) do
    ghost = (
      ActivityPub.Config.get([:boundaries, :silence])
      ++
      ActivityPub.Config.get([:boundaries, :ghost])
      ++
      ActivityPub.Config.get([:boundaries, :block])
      ) |> MRF.subdomains_regex()
        # |> dump("MRF filter")

    activity
    |> filter_recipients("to", ghost, local_user_ids)
    |> filter_recipients("cc", ghost, local_user_ids)
    |> filter_recipients("bto", ghost, local_user_ids)
    |> filter_recipients("bcc", ghost, local_user_ids)
    |> filter_recipients("audience", ghost, local_user_ids)
  end

  defp filter_recipients(activity, field, ghost, local_user_ids) do
    case activity[field] do
      recipients when is_list(recipients) ->
        Map.put(activity, field, filter_actors(recipients, ghost, local_user_ids))
      recipient when is_binary(recipient) ->
        Map.put(activity, field, filter_actors([recipient], ghost, local_user_ids))
      _ -> activity
    end
  end

  defp filter_actors(actors, ghost, local_user_ids) do
    Enum.reject(actors || [], &filter_actor(&1, ghost, local_user_ids))
  end
  defp filter_actor(%{ap_id: actor}, ghost, local_user_ids) when is_binary(actor) do
    filter_actor(actor, ghost, local_user_ids)
  end
  defp filter_actor(%{"id" => actor}, ghost, local_user_ids) when is_binary(actor) do
    filter_actor(actor, ghost, local_user_ids)
  end
  defp filter_actor(actor, ghost, local_user_ids) when is_binary(actor) do
    actor_uri = URI.parse(actor)
    clean_actor_uri = "#{actor_uri.host}#{actor_uri.path}"
    MRF.subdomain_match?(ghost, actor_uri.host) # instance blocked in config
    || MRF.subdomain_match?(ghost, clean_actor_uri) # actor blocked in config
  #  || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, :any, :instance_wide) # TEMP: will be included when we do per-iser
    || Bonfire.Federate.ActivityPub.Actors.is_blocked?(actor_uri, :any, user_ids: local_user_ids) # actor or instance blocked in DB, either instance-wide or by specified local_user_ids
  end

  def all_actors(activity) do
    [e(activity, "actor", nil)]
    ++ [e(activity, "object", "actor", nil)]
    ++ [e(activity, "object", "attributedTo", nil)]
    |> List.flatten()
    |> Enum.map(&id_or_object_id/1)
    |> filter_empty([])
    |> Enum.uniq()
    |> debug
  end

  def all_recipients(activity, fields \\ ["to", "bto", "cc", "bcc", "audience"]) do
    all_fields(activity, fields)
    |> debug
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

end
