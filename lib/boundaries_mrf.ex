defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  use Bonfire.Common.Utils
  use Arrows
  alias ActivityPub.MRF
  alias Bonfire.Boundaries
  import Where
  @behaviour MRF

  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  @impl true
  def filter(activity, is_local?) do
    dump(activity, "to filter")

    authors = all_actors(activity)
    recipients = all_recipients(activity)

    local_author_ids = authors
    |> local_actor_ids()
    |> dump("local_author_ids")

    local_recipient_ids = recipients
    |> local_actor_ids()
    |> dump("local_recipient_ids")

    # num_local_authors = length(local_author_ids)
    is_local? #= (num_local_authors && num_local_authors == length(authors))
    |> dump("is_local?")

    with {:ok, activity} <- maybe_check_and_filter(:ghost, is_local?, local_author_ids, local_recipient_ids, activity),
         {:ok, activity} <- maybe_check_and_filter(:silence, is_local?, local_author_ids, local_recipient_ids, activity) do

          {:ok, activity}

         else e ->
          error(e)
          {:reject, nil}
    end
  end

  defp maybe_check_and_filter(check_block_type, is_local?, local_author_ids, local_recipient_ids, activity) do
    block_types = Boundaries.Blocks.types_blocked(check_block_type)

    cond do
      is_follow?(activity) and :silence == check_block_type and is_local? ->
        dump("reject following silenced remote actors")

        block_or_filter_recipients(block_types, activity, local_author_ids)

      is_follow?(activity) and :silence == check_block_type and !is_local? ->
        dump("accept follows from silenced remote actors")

        {:ok, activity}

      is_follow?(activity) and :ghost == check_block_type and !is_local? ->
        dump("reject follows from ghosted remote actors")

        if !activity_blocked?(block_types, local_recipient_ids, activity), do:
          {:ok, activity}

      :silence == check_block_type and is_local? ->
        dump("do nothing with silencing on outgoing local activities")

        {:ok, activity}

      :silence == check_block_type and !is_local? ->
        dump("check for silenced actor/instances & filter recipients of incoming remote activities")
        # FIXME!
        if !activity_blocked?(block_types, [], activity), do:
          block_or_filter_recipients(block_types, activity, local_recipient_ids)

      :ghost == check_block_type and is_local? ->
        dump("filter ghosted recipients of outgoing local activities")

        block_or_filter_recipients(block_types, activity, local_author_ids)

      :ghost == check_block_type and !is_local? ->
        dump("do nothing with ghosting on incoming remote activities")

        {:ok, activity}

      true ->
        error("no cond matched")
        nil
      end
  end

  defp activity_blocked?(block_types, local_actor_ids, activity) do
    rejects = rejects_regex(block_types)
    |> dump("MRF instance_wide blocks from config")

    object_blocked?(block_types, local_actor_ids, rejects, id_or_object_id(e(activity, "actor", nil))) |> dump("activity's actor?")
    || object_blocked?(block_types, local_actor_ids, rejects, id_or_object_id(e(activity, "object", "attributedTo", nil))) |> dump("object's actor?")
    || object_blocked?(block_types, local_actor_ids, rejects, id_or_object_id(activity)) |> dump("activity's instance?")
    || object_blocked?(block_types, local_actor_ids, rejects, id_or_object_id(e(activity, "object", nil))) |> dump("object's instance?")
  end

  defp object_blocked?(block_types, local_author_ids, rejects, canonical_uri) when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)
    # |> dump("uri")

    instance_blocked_in_config?(uri, rejects)
    || actor_or_instance_blocked?(block_types, local_author_ids, uri, rejects)
  end
  defp object_blocked?(_, _, _, _) do
    dump("no URI")
    nil
  end

  defp instance_blocked_in_config?(%{host: actor_host} = _actor_uri, rejects) do
    MRF.subdomain_match?(rejects, actor_host)
    # || Bonfire.Federate.ActivityPub.Instances.is_blocked?(actor_uri, :any, :instance_wide)
    # ^ NOTE: no need to check the instance block in DB here because that's being handled by Peered.is_blocked? triggered by Actors.is_blocked? via actor_or_instance_blocked?
  end

  defp actor_or_instance_blocked?(block_types, local_author_ids, %URI{} = actor_uri, rejects) do
    clean_url = "#{actor_uri.host}#{actor_uri.path}"

    # dump(block_types, "block_types")
    # dump(actor_uri, "actor_uri")
    dump(local_author_ids, "local_author_ids")

    MRF.subdomain_match?(rejects, clean_url)
    # || Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
    || Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_uri, block_types, user_ids: local_author_ids) #|> dump()
  end

  defp block_or_filter_recipients(block_types, activity, local_actor_ids) do
    case filter_recipients(block_types, activity, local_actor_ids) do
      %{"type" => type} when type in ["Update", "Delete", "Flag"] ->
        debug("accept #{type} with no recipients")
        {:ok, activity}
      %{to: []} ->
        dump("reject activity because all recipients were filtered")
        nil
      %{"to" => []} ->
        dump("reject activity because all recipients were filtered")
        nil
      activity ->
        {:ok, activity}
        |> dump("filtered")
    end
  end

  defp filter_recipients(block_types, activity, local_actor_ids) do
    rejects = rejects_regex(block_types)
    |> dump("MRF actor filter from config")

    activity
    |> filter_recipients_field(:to, block_types, rejects, local_actor_ids)
    |> filter_recipients_field(:cc, block_types, rejects, local_actor_ids)
    |> filter_recipients_field(:bto, block_types, rejects, local_actor_ids)
    |> filter_recipients_field(:bcc, block_types, rejects, local_actor_ids)
    |> filter_recipients_field(:audience, block_types, rejects, local_actor_ids)
  end

  defp filter_recipients_field(activity, field, block_types, rejects, local_actor_ids) do
    case activity[field] do
      recipients when is_list(recipients) ->
        Map.put(activity, field, filter_actors(recipients, block_types, rejects, local_actor_ids))
      recipient when is_binary(recipient) ->
        Map.put(activity, field, filter_actors([recipient], block_types, rejects, local_actor_ids))
      _ ->
        if is_atom(field), do: filter_recipients_field(activity, to_string(field), block_types, rejects, local_actor_ids),
        else: activity
    end
  end


  defp filter_actors(actors, block_types, rejects, local_actor_ids) do
    (actors || [])
    |> Enum.reject(&filter_actor(&1, block_types, rejects, local_actor_ids))
  end
  defp filter_actor(@public_uri, _block_types, _rejects, _local_actor_ids) do
    false
  end
  defp filter_actor(%{ap_id: actor}, block_types, rejects, local_actor_ids) when is_binary(actor) do
    filter_actor(actor, block_types, rejects, local_actor_ids)
  end
  defp filter_actor(%{"id" => actor}, block_types, rejects, local_actor_ids) when is_binary(actor) do
    filter_actor(actor, block_types, rejects, local_actor_ids)
  end
  defp filter_actor(actor, block_types, rejects, local_actor_ids) when is_binary(actor) do
    actor_uri = URI.parse(actor)
    # |> dump("uri")
    clean_actor_uri = "#{actor_uri.host}#{actor_uri.path}"
    MRF.subdomain_match?(rejects, actor_uri.host) |> dump("filter #{actor_uri.host} blocked #{inspect block_types} instance in config?")
    || MRF.subdomain_match?(rejects, clean_actor_uri) |> dump("filter #{clean_actor_uri} blocked #{inspect block_types} actor in config?")
  #  || Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
    || Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_uri, block_types, user_ids: local_actor_ids) |> dump("filter #{actor_uri} blocked #{inspect block_types} actor or instance in DB, either instance-wide or by specified local_actor_ids?")
  end

  def all_actors(activity) do
    actors = (
      [e(activity, "actor", nil)]
      ++ [e(activity, "object", "actor", nil)]
      ++ [e(activity, "object", "attributedTo", nil)]
    )
    |> List.flatten()
    |> filter_empty(nil)
    # |> dump

    (actors || [activity]) # for actors themselves
    # |> dump
    |> Enum.map(&id_or_object_id/1)
    # |> dump
    |> filter_empty([])
    # |> dump
    |> Enum.uniq()
    |> dump
  end

  def all_recipients(activity, fields \\ [:to, :bto, :cc, :bcc, :audience]) do
    activity
    # |> dump
    |> all_fields(fields)
    |> dump
  end

  defp all_fields(activity, fields) do
    fields
    # |> dump
    |> Enum.map(&( id_or_object_id(Utils.e(activity, &1, nil)) ))
    # |> dump
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
  defp id_or_object_id(objects) when is_list(objects) do
    Enum.map(objects, &id_or_object_id/1)
  end
  defp id_or_object_id(other) do
    error(other)
    nil
  end

  defp is_follow?(%{"type" => "Follow"}) do
    true
  end
  defp is_follow?(%{type: "Follow"}) do
    true
  end
  defp is_follow?(_) do
    false
  end

  defp local_actor_ids(actors) do
    ap_base_uri = ActivityPubWeb.base_url() <> System.get_env("AP_BASE_PATH", "/pub")
    # |> dump("ap_base_uri")

    actors
    |> Enum.map(&id_or_object_id/1)
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(&1, ap_base_uri))
    # |> dump("before local_actor_ids")
    |> Enum.map(&maybe_get_or_fetch_by_ap_id/1)
    |> filter_empty([])
  end

  defp maybe_get_or_fetch_by_ap_id(ap_id) do
    with {:ok, %{pointer_id: pointer_id}} <- ActivityPub.Actor.get_or_fetch_by_ap_id(ap_id) do
      pointer_id
    else _ ->
      nil
    end
  end

  defp rejects_regex(block_types) do
    (block_types ++ [:block])
    |> Enum.flat_map(&ActivityPub.Config.get([:boundaries, &1]))
    |> MRF.subdomains_regex()
  end
end
