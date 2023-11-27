defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  use Bonfire.Common.Utils
  use Arrows
  require ActivityPub.Config
  import Untangle
  alias ActivityPub.MRF
  alias Bonfire.Boundaries
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @behaviour MRF

  @impl true
  def filter(activity, is_local?) do
    info(activity, "to filter")

    authors =
      AdapterUtils.all_actors(activity)
      |> debug("authors")

    local_author_ids =
      authors
      |> AdapterUtils.local_actor_ids()
      |> debug("local_author_ids")

    recipients = AdapterUtils.all_recipients(activity)

    local_recipient_ids =
      recipients
      |> AdapterUtils.local_actor_ids()
      |> debug("local_recipient_ids")

    # num_local_authors = length(local_author_ids)
    # = (num_local_authors && num_local_authors == length(authors))
    debug(is_local?, "is_local?")

    with {:ok, activity} <-
           maybe_check_and_filter(
             :ghost,
             is_local?,
             local_author_ids,
             local_recipient_ids,
             activity
           ),
         {:ok, activity} <-
           maybe_check_and_filter(
             :silence,
             is_local?,
             local_author_ids,
             local_recipient_ids,
             activity
           ) do
      {:ok, activity}
      |> debug("Boundary check OK!")
    else
      {:reject, e} ->
        warn(e, "Activity rejected by Boundaries")
        {:reject, e}

      {:error, e} ->
        warn(e, "Activity rejected by Boundaries")
        {:reject, e}

      e ->
        warn(e, "Activity rejected by Boundaries")
        {:reject, e}
    end
  end

  defp maybe_check_and_filter(
         check_block_type,
         is_local?,
         local_author_ids,
         local_recipient_ids,
         activity
       ) do
    block_types = Boundaries.Blocks.types_blocked(check_block_type)
    is_follow? = AdapterUtils.is_follow?(activity)

    rejects =
      rejects_regex(block_types)
      |> debug("MRF instance_wide blocks from config")

    cond do
      is_follow? and :silence == check_block_type and is_local? ->
        debug("do not follow silenced remote actors")

        # block_or_filter_recipients(block_types, activity, local_author_ids, is_local?)
        # activity_blocked?(block_types, local_author_ids, activity, rejects) || 
        object_blocked?(
          block_types,
          local_author_ids,
          rejects,
          AdapterUtils.id_or_object_id(e(activity, "object", nil))
        )
        |> debug("fabbb") || {:ok, activity}

      is_follow? and :silence == check_block_type and !is_local? ->
        debug("accept follows from silenced remote actors")

        {:ok, activity}

      is_follow? and :ghost == check_block_type and !is_local? ->
        debug("reject follows from ghosted remote actors")

        activity_blocked?(block_types, local_recipient_ids, activity, rejects) || {:ok, activity}

      :silence == check_block_type and is_local? ->
        debug("do nothing with silencing on outgoing local activities")

        {:ok, activity}

      :silence == check_block_type and !is_local? ->
        debug(
          "check for silenced actor/instances & filter recipients of incoming remote activities"
        )

        activity_blocked?(block_types, [], activity, rejects) ||
          block_or_filter_recipients(
            block_types,
            activity,
            local_author_ids,
            local_recipient_ids,
            is_local?
          )

      :ghost == check_block_type and is_local? ->
        debug("filter ghosted recipients of outgoing local activities")

        block_or_filter_recipients(
          block_types,
          activity,
          local_author_ids,
          local_recipient_ids,
          is_local?
        )

      :ghost == check_block_type and !is_local? ->
        debug("do nothing with ghosting on incoming remote activities")

        {:ok, activity}

      true ->
        error("no filter cond matched")
    end
  end

  defp activity_blocked?(block_types, local_character_ids, activity, rejects) do
    object_blocked?(
      block_types,
      local_character_ids,
      rejects,
      AdapterUtils.id_or_object_id(e(activity, "actor", nil))
    )
    |> debug("activity's actor?") ||
      object_blocked?(
        block_types,
        local_character_ids,
        rejects,
        AdapterUtils.id_or_object_id(e(activity, "object", "attributedTo", nil))
      )
      |> debug("object's actor?") ||
      object_blocked?(
        block_types,
        local_character_ids,
        rejects,
        AdapterUtils.id_or_object_id(activity)
      )
      |> debug("activity's instance?") ||
      object_blocked?(
        block_types,
        local_character_ids,
        rejects,
        AdapterUtils.id_or_object_id(e(activity, "object", nil))
      )
      |> debug("object or its instance?")
  end

  defp object_blocked?(block_types, local_author_ids, rejects, canonical_uri)
       when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)

    # |> debug("uri")

    instance_blocked_in_config?(uri, rejects) ||
      actor_or_instance_blocked?(block_types, local_author_ids, uri, rejects)
  end

  defp object_blocked?(_, _, _, canonical_uri) do
    warn(canonical_uri, "no valid URI")
    nil
  end

  defp instance_blocked_in_config?(%{host: actor_host} = _actor_uri, rejects) do
    MRF.subdomain_match?(rejects, actor_host)

    # || Bonfire.Federate.ActivityPub.Instances.is_blocked?(actor_uri, :any, :instance_wide)
    # ^ NOTE: no need to check the instance block in DB here because that's being handled by Peered.is_blocked? triggered by Actors.is_blocked? via actor_or_instance_blocked?
  end

  defp actor_or_instance_blocked?(
         block_types,
         local_author_ids,
         %URI{} = actor_uri,
         rejects
       ) do
    clean_url = "#{actor_uri.host}#{actor_uri.path}"

    # debug(block_types, "block_types")
    # debug(actor_uri, "actor_uri")

    local_author_ids =
      local_author_ids
      |> Enum.map(&(elem(&1, 1) |> ulid()))
      |> debug("local_author_ids")

    # || Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
    # |> debug()
    MRF.subdomain_match?(rejects, clean_url) ||
      Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_uri, block_types,
        user_ids: local_author_ids
      )
  end

  defp block_or_filter_recipients(
         block_types,
         activity,
         local_author_ids,
         local_recipient_ids,
         is_local?
       ) do
    case filter_recipients(
           block_types,
           activity,
           local_author_ids,
           local_recipient_ids,
           is_local?
         ) do
      %{type: "Create"} = filtered ->
        apply_filtered_recipients(filtered, activity, is_local?)

      %{"type" => "Create"} = filtered ->
        apply_filtered_recipients(filtered, activity, is_local?)

      %{data: %{"type" => "Create"}} = filtered ->
        apply_filtered_recipients(filtered, activity, is_local?)

      filtered ->
        debug(filtered, "accept non-create activity (even with no recipients)")
        {:ok, filtered}
    end
  end

  defp apply_filtered_recipients(filtered, activity, is_local?) do
    if filtered != activity,
      do: debug(filtered, "activity has been filtered"),
      else: debug("no blocks apply")

    if e(filtered, :to, nil) || e(filtered, :cc, nil) || e(filtered, :bto, nil) ||
         e(filtered, :bcc, nil) || e(filtered, :audience, nil) ||
         e(activity, "publishedDate", nil) || e(activity, "object", "publishedDate", nil) ||
         e(activity, "object", "type", nil) == "Tombstone" do
      # ^ `publishedDate` here is intended as an exception for bookwyrm which doesn't put audience info
      {:ok, filtered}
    else
      if is_local? do
        debug(
          activity,
          "do not federate local activity because it has no recipients or they were all filtered"
        )

        :ignore
      else
        debug(
          activity,
          "reject remote activity because it has no recipients or they were all filtered"
        )

        {:reject,
         "Do not accept incoming federated activity because it has no recipients or they were all filtered"}
      end
    end
  end

  defp filter_recipients(block_types, activity, local_author_ids, local_recipient_ids, is_local?) do
    rejects =
      rejects_regex(block_types)
      |> debug("MRF actor filter from config")

    activity
    |> filter_recipients_field(
      :to,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      is_local?
    )
    |> filter_recipients_field(
      :cc,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      is_local?
    )
    |> filter_recipients_field(
      :bto,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      is_local?
    )
    |> filter_recipients_field(
      :bcc,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      is_local?
    )
    |> filter_recipients_field(
      :audience,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      is_local?
    )
  end

  defp filter_recipients_field(
         activity,
         field,
         block_types,
         rejects,
         local_author_ids,
         local_recipient_ids,
         is_local?
       ) do
    case activity[field] do
      recipients when is_list(recipients) and recipients != [] ->
        Map.put(
          activity,
          field,
          filter_actors(
            activity,
            recipients,
            block_types,
            rejects,
            local_author_ids,
            local_recipient_ids,
            is_local?
          )
        )

      recipient when is_binary(recipient) ->
        Map.put(
          activity,
          field,
          filter_actors(
            activity,
            [recipient],
            block_types,
            rejects,
            local_author_ids,
            local_recipient_ids,
            is_local?
          )
        )

      _ ->
        if is_atom(field),
          do:
            filter_recipients_field(
              activity,
              to_string(field),
              block_types,
              rejects,
              local_author_ids,
              local_recipient_ids,
              is_local?
            ),
          else: activity
    end
  end

  defp filter_actors(
         activity,
         actors,
         block_types,
         rejects,
         local_author_ids,
         local_recipient_ids,
         is_local?
       ) do
    (actors || [])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> debug("before filter")
    |> Enum.reject(
      &filter_actor?(
        activity,
        &1,
        block_types,
        rejects,
        local_author_ids,
        local_recipient_ids,
        is_local?
      )
    )
  end

  defp filter_actor?(
         _activity,
         uri,
         _block_types,
         _rejects,
         _local_author_ids,
         _local_recipient_ids,
         _is_local?
       )
       when ActivityPub.Config.is_in(uri, :public_uris) do
    false
  end

  # defp filter_actor?(
  #        activity,
  #        %{ap_id: actor},
  #        block_types,
  #        rejects,
  #        local_author_ids,
  #        local_recipient_ids,
  #        is_local?
  #      )
  #      when is_binary(actor) do
  #   filter_actor?(
  #     activity,
  #     actor,
  #     block_types,
  #     rejects,
  #     local_author_ids,
  #     local_recipient_ids,
  #     is_local?
  #   )
  # end

  # defp filter_actor?(
  #        activity,
  #        %{"id" => actor},
  #        block_types,
  #        rejects,
  #        local_author_ids,
  #        local_recipient_ids,
  #        is_local?
  #      )
  #      when is_binary(actor) do
  #   filter_actor?(
  #     activity,
  #     actor,
  #     block_types,
  #     rejects,
  #     local_author_ids,
  #     local_recipient_ids,
  #     is_local?
  #   )
  # end

  defp filter_actor?(
         activity,
         recipient,
         block_types,
         rejects,
         local_author_ids,
         local_recipient_ids,
         is_local?
       ) do
    recipient_actor =
      e(recipient, :ap_id, nil) || e(recipient, "id", nil) || e(recipient, :data, "id", nil) ||
        recipient

    # |> debug("uri")

    debug(is_local?, "is_local???")

    if is_binary(recipient_actor) do
      recipient_actor_uri = URI.parse(recipient_actor)
      clean_recipient_actor_uri = "#{recipient_actor_uri.host}#{recipient_actor_uri.path}"

      author_ids =
        local_author_ids
        |> Enum.map(&(elem(&1, 1) |> ulid()))

      {by_characters, actor_to_check} =
        if is_local? do
          debug(
            "local activity - need to check if local author blocks the (maybe remote) recipient"
          )

          local_recipient = e(local_recipient_ids, recipient_actor, nil) || recipient_actor

          {author_ids, local_recipient}
        else
          debug("remote activity - need to check if the local recipient blocks the remote author")

          local_recipient = e(local_recipient_ids, recipient_actor, nil) || recipient_actor

          {local_recipient, e(author_ids, nil) || AdapterUtils.all_actors(activity)}
        end
        |> debug("by_characters & actor_to_check")

      #  || Bonfire.Federate.ActivityPub.Peered.is_blocked?(recipient_actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
      MRF.subdomain_match?(rejects, recipient_actor_uri.host)
      |> debug(
        "filter '#{recipient_actor_uri.host}' blocked #{inspect(block_types)} instance in config?"
      ) ||
        MRF.subdomain_match?(rejects, clean_recipient_actor_uri)
        |> debug(
          "filter '#{clean_recipient_actor_uri}' blocked #{inspect(block_types)} actor in config?"
        ) ||
        Bonfire.Federate.ActivityPub.Peered.is_blocked?(actor_to_check, block_types,
          user_ids: by_characters
        )
        |> debug(
          "filter '#{id(actor_to_check) || inspect(actor_to_check)}' blocked (#{inspect(block_types)}) by #{inspect(by_characters)} in DB, either instance-wide or by specified local_actor_ids?"
        )
    end
  end

  defp rejects_regex(block_types) do
    (filter_empty(block_types, []) ++ [:block])
    # |> debug()
    |> Enum.map(&ActivityPub.Config.get([:boundaries, &1]))
    |> filter_empty([])
    # |> debug()
    |> MRF.subdomains_regex()
  end
end
