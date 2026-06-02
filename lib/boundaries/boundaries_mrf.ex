defmodule Bonfire.Federate.ActivityPub.BoundariesMRF do
  @moduledoc "Filter activities depending on their origin instance, actor, or other criteria"
  use Bonfire.Common.Utils
  use Arrows
  import Untangle
  import Bonfire.Federate.ActivityPub
  import ActivityPub.Config, only: [is_in: 2]
  alias ActivityPub.MRF
  alias Bonfire.Boundaries
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub.Peered

  @behaviour MRF

  @filter_for_verbs ["Create", "Accept"]

  @impl true
  def filter(activity, opts) when is_list(opts) do
    info(activity, "to filter")

    authors =
      AdapterUtils.all_actors(activity)
      |> debug("authors")

    recipients = AdapterUtils.all_object_recipients(activity)

    # one batched query for the whole author+recipient set, shared by both `local_actor_ids/2` calls
    prefetched_objects = AdapterUtils.objects_for_actors(authors ++ recipients)

    local_author_ids =
      authors
      |> AdapterUtils.local_actor_ids(prefetched_objects)
      |> debug("local_author_ids")

    local_recipient_ids =
      recipients
      |> AdapterUtils.local_actor_ids(prefetched_objects)
      |> debug("local_recipient_ids")

    is_public? = Enum.any?(recipients, &ActivityPub.Utils.has_as_public?/1)

    # pre-resolve, for the whole recipient+author set in one query each, the data the per-recipient
    # block/allowlist checks need — so `actor_blocked?`/`instance_allowlisted?` read from these maps
    # instead of querying per actor (avoids n+X). Leaf checks fall back to per-call query if absent.
    all_uris =
      (authors ++ recipients)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    peered_by_urls =
      Peered.list_by_canonical_uris(all_uris)
      |> Map.new(fn %{canonical_uri: uri} = peered -> {uri, peered} end)

    allowlist_circles_by_hosts =
      all_uris
      |> Enum.map(&URIs.base_domain/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Instances.get_instance_circles()

    # candidate subjects the allowlist checks run against: the resolved instance-circles + peereds
    allowlist_candidates = Map.values(allowlist_circles_by_hosts) ++ Map.values(peered_by_urls)

    # the local users whose per-user allowlist circles may apply (authors + recipients)
    scope_user_ids =
      (local_author_ids ++ local_recipient_ids)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    resolved =
      %{
        peered_by_urls: peered_by_urls,
        allowlist_circles_by_hosts: allowlist_circles_by_hosts,
        # which candidates are instance-wide allowlisted (one query)
        allowlisted_ids:
          Utils.maybe_apply(
            Bonfire.Boundaries.Allowlist,
            :instance_wide_allowlisted_subset,
            [allowlist_candidates],
            fallback_return: nil
          ),
        # per-user: %{user_id => MapSet(allowlisted candidate ids)} (one query per in-scope user)
        allowlisted_by_user:
          Utils.maybe_apply(
            Bonfire.Boundaries.Allowlist,
            :allowlisted_by_users_subset,
            [allowlist_candidates, scope_user_ids],
            fallback_return: nil
          )
      }
      |> info("pre-resolved data for MRF checks")

    opts =
      opts
      |> Keyword.put(:is_public, is_public?)
      |> Keyword.put(:resolved, resolved)

    # num_local_authors = length(local_author_ids)
    # = (num_local_authors && num_local_authors == length(authors))

    with {:ok, activity} <-
           maybe_check_and_filter(
             :ghost,
             local_author_ids,
             local_recipient_ids,
             activity,
             opts
           ),
         {:ok, activity} <-
           maybe_check_and_filter(
             :silence,
             local_author_ids,
             local_recipient_ids,
             activity,
             opts
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

      :ignore ->
        debug("Activity will not be federated")
        # {:ignore, "Activity will not be federated"}
        :ignore

      e ->
        warn(e, "Activity rejected by Boundaries")
        {:reject, e}
    end
  end

  def filter(object, is_local?) when is_boolean(is_local?) do
    filter(object, is_local: is_local?)
  end

  defp maybe_check_and_filter(
         check_block_type,
         local_author_ids,
         local_recipient_ids,
         activity,
         opts
       ) do
    is_local? =
      opts[:is_local]
      |> debug("is_local?")

    block_types = Boundaries.Blocks.types_blocked(check_block_type)
    is_follow? = AdapterUtils.is_follow?(activity)

    rejects = rejects_regex(block_types)

    cond do
      is_follow? and :silence == check_block_type and is_local? ->
        debug("do not follow silenced remote actors")

        # block_or_filter_recipients(block_types, activity, local_author_ids, opts)
        # activity_blocked?(block_types, local_author_ids, activity, rejects) || 
        object_blocked?(
          block_types,
          local_author_ids,
          rejects,
          AdapterUtils.id_or_object_id(ed(activity, "object", nil)),
          opts
        )
        |> debug("object_blocked") || {:ok, activity}

      is_follow? and :silence == check_block_type and !is_local? ->
        debug("accept follows from silenced remote actors")

        {:ok, activity}

      is_follow? and :ghost == check_block_type and !is_local? ->
        debug("reject follows from ghosted remote actors")

        activity_blocked?(block_types, local_recipient_ids, activity, rejects, opts) ||
          {:ok, activity}

      :silence == check_block_type and is_local? ->
        debug("do nothing with silencing on outgoing local activities")

        {:ok, activity}

      :silence == check_block_type and !is_local? ->
        debug(
          "check for silenced actor/instances & filter recipients of incoming remote activities"
        )

        # blanket instance-wide check (no user scope) for public posts or when no local recipients;
        # per-recipient check handles user-scoped blocks for addressed activities
        ((local_recipient_ids == [] or opts[:is_public]) and
           activity_blocked?(block_types, [], activity, rejects, opts)) ||
          block_or_filter_recipients(
            block_types,
            activity,
            local_author_ids,
            local_recipient_ids,
            opts
          )

      :ghost == check_block_type and is_local? ->
        debug("filter ghosted recipients of outgoing local activities")

        block_or_filter_recipients(
          block_types,
          activity,
          local_author_ids,
          local_recipient_ids,
          opts
        )

      :ghost == check_block_type and !is_local? ->
        debug("do nothing with ghosting on incoming remote activities")

        {:ok, activity}

      true ->
        error("no filter cond matched")
    end
  end

  defp activity_blocked?(block_types, local_character_ids, activity, rejects, opts) do
    object_blocked?(
      block_types,
      local_character_ids,
      rejects,
      AdapterUtils.id_or_object_id(ed(activity, "actor", nil)),
      opts
    )
    |> debug("activity's actor?") ||
      object_blocked?(
        block_types,
        local_character_ids,
        rejects,
        AdapterUtils.id_or_object_id(ed(activity, "object", "attributedTo", nil)),
        opts
      )
      |> debug("object's actor?") ||
      object_blocked?(
        block_types,
        local_character_ids,
        rejects,
        AdapterUtils.id_or_object_id(activity),
        opts
      )
      |> debug("activity's instance?") ||
      object_blocked?(
        block_types,
        local_character_ids,
        rejects,
        AdapterUtils.id_or_object_id(ed(activity, "object", nil)),
        opts
      )
      |> debug("object or its instance?")
  end

  defp object_blocked?(block_types, local_author_ids, rejects, canonical_uri, opts)
       when is_binary(canonical_uri) do
    uri = URI.parse(canonical_uri)
    # |> debug("uri")

    instance_blocked_in_config?(uri, rejects) ||
      actor_or_instance_blocked?(block_types, local_author_ids, uri, nil, rejects, opts)
  end

  defp object_blocked?(block_types, local_author_ids, rejects, %{} = object, opts) do
    canonical_uri = URIs.canonical_url(object)
    uri = URI.parse(canonical_uri)

    instance_blocked_in_config?(uri, rejects) ||
      actor_or_instance_blocked?(block_types, local_author_ids, uri, object, rejects, opts)
  end

  defp object_blocked?(block_types, local_author_ids, rejects, objects, opts)
       when is_list(objects) do
    Enum.any?(objects, &object_blocked?(block_types, local_author_ids, rejects, &1, opts))
  end

  defp object_blocked?(_, _, _, canonical_uri, _opts) do
    warn(canonical_uri, "no valid URI")
    # raise "no valid URI"
    nil
  end

  defp instance_blocked_in_config?(%{host: actor_host} = _actor_uri, rejects) do
    MRF.subdomain_match?(rejects, actor_host)

    # || Bonfire.Federate.ActivityPub.Instances.instance_blocked?(actor_uri, :any, :instance_wide)
    # ^ NOTE: no need to check the instance block in DB here because that's being handled by Peered.actor_blocked? triggered by Actors.is_blocked? via actor_or_instance_blocked?
  end

  defp actor_or_instance_blocked?(
         block_types,
         local_author_ids,
         %URI{} = actor_uri,
         actor,
         rejects,
         opts
       ) do
    clean_url = "#{actor_uri.host}#{actor_uri.path}"

    # debug(block_types, "block_types")
    # debug(actor_uri, "actor_uri")

    local_author_ids =
      local_author_ids
      |> Enum.map(fn
        {ap_id, id} ->
          id

        # |> uid()

        other ->
          other
      end)
      |> debug("local_author_ids")

    # || Bonfire.Federate.ActivityPub.Peered.actor_blocked?(actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
    # |> debug()
    MRF.subdomain_match?(rejects, clean_url) ||
      not federation_allowed?(actor || actor_uri,
        block_types: block_types,
        user_ids: local_author_ids,
        resolved: opts[:resolved]
      )
  end

  defp block_or_filter_recipients(
         block_types,
         activity,
         local_author_ids,
         local_recipient_ids,
         opts
       ) do
    case filter_recipients(
           block_types,
           activity,
           local_author_ids,
           local_recipient_ids,
           opts
         )
         |> debug("with_filtered_recipients") do
      %{type: verb} = filtered when verb in @filter_for_verbs ->
        apply_filtered_recipients(filtered, activity, opts)

      %{"type" => verb} = filtered when verb in @filter_for_verbs ->
        apply_filtered_recipients(filtered, activity, opts)

      %{data: %{"type" => verb}} = filtered when verb in @filter_for_verbs ->
        apply_filtered_recipients(filtered, activity, opts)

      filtered ->
        debug(filtered, "accept non-create activity (even with no recipients)")
        {:ok, filtered}
    end
  end

  defp apply_filtered_recipients(filtered, activity, opts) do
    if filtered != activity,
      do: debug(filtered, "activity has been filtered"),
      else: debug("no blocks apply")

    if ed(filtered, :to, nil) || ed(filtered, :cc, nil) || ed(filtered, :bto, nil) ||
         ed(filtered, :bcc, nil) || ed(filtered, :audience, nil) ||
         e(activity, "publishedDate", nil) || ed(activity, "object", "publishedDate", nil) ||
         is_in(ed(activity, "object", "type", nil), ["Tombstone", "Place"]) do
      # ^ `publishedDate` here is intended as an exception for bookwyrm which doesn't put audience info
      # TODO: put exceptions in config
      {:ok, filtered}
    else
      if opts[:is_local] do
        if opts[:from_c2s] do
          debug(
            activity,
            "try self-addressing local activity because it has no recipients or they were all filtered"
          )

          maybe_self_address_activity(filtered)
        else
          info(activity, "Skip federation of local activity with no recipients")
          :ignore
        end
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

  # Add the actor as a recipient when no other recipients remain
  defp maybe_self_address_activity(activity) do
    actor = AdapterUtils.id_or_object_id(ed(activity, "actor", nil) || ed(activity, :actor, nil))

    if actor do
      # Use bto (blind to) so it's not visible to others but activity is still processed
      existing_bto = ed(activity, :bto, nil) || []

      {:ok,
       activity
       |> Map.put(:bto, List.wrap(existing_bto) ++ [actor])}
    else
      warn(activity, "Could not self-address activity - no actor found")
      :ignore
    end
  end

  defp filter_recipients(block_types, activity, local_author_ids, local_recipient_ids, opts) do
    rejects = rejects_regex(block_types)

    activity
    |> filter_recipients_field(
      :to,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      opts
    )
    |> filter_recipients_field(
      :cc,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      opts
    )
    |> filter_recipients_field(
      :bto,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      opts
    )
    |> filter_recipients_field(
      :bcc,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      opts
    )
    |> filter_recipients_field(
      :audience,
      block_types,
      rejects,
      local_author_ids,
      local_recipient_ids,
      opts
    )
  end

  defp filter_recipients_field(
         activity,
         field,
         block_types,
         rejects,
         local_author_ids,
         local_recipient_ids,
         opts,
         recursing \\ false
       ) do
    case Enums.maybe_get(activity, field, nil) ||
           Enums.maybe_get(e(activity, "object", %{}), field, nil) do
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
            opts
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
            opts
          )
        )

      _ ->
        if !recursing do
          cond do
            is_atom(field) ->
              filter_recipients_field(
                activity,
                to_string(field),
                block_types,
                rejects,
                local_author_ids,
                local_recipient_ids,
                opts,
                true
              )

            is_binary(field) ->
              if atom_field = Types.maybe_to_atom!(field) do
                filter_recipients_field(
                  activity,
                  atom_field,
                  block_types,
                  rejects,
                  local_author_ids,
                  local_recipient_ids,
                  opts,
                  true
                )
              end

            true ->
              nil
          end
        end || activity
    end
  end

  defp filter_actors(
         activity,
         actors,
         block_types,
         rejects,
         local_author_ids,
         local_recipient_ids,
         opts
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
        opts
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
         _opts
       )
       when is_in(uri, :public_uris) do
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
         opts
       ) do
    recipient_actor =
      (ed(recipient, :ap_id, nil) || ed(recipient, "id", nil) || e(recipient, :data, "id", nil) ||
         recipient)
      |> debug("recipient_actor")

    is_local? = opts[:is_local]
    debug(is_local?, "is_local???")

    if is_binary(recipient_actor) do
      recipient_actor_uri = URI.parse(recipient_actor)
      clean_recipient_actor_uri = "#{recipient_actor_uri.host}#{recipient_actor_uri.path}"

      author_ids =
        local_author_ids
        |> Enum.map(
          &elem(&1, 1)
          # |> uid()
        )

      {by_characters, actor_to_check} =
        if is_local? do
          debug(
            "local activity - need to check if local author blocks the (maybe remote) recipient"
          )

          local_recipient = ed(local_recipient_ids, recipient_actor, nil) || recipient_actor

          {author_ids, local_recipient}
        else
          debug("remote activity - need to check if the local recipient blocks the remote author")

          local_recipient_id =
            Enum.find_value(local_recipient_ids, fn {ap_id, id} ->
              if ap_id == recipient_actor, do: id
            end) || recipient_actor

          {local_recipient_id, ed(author_ids, nil) || AdapterUtils.all_actors(activity)}
        end
        |> debug("by_characters & actor_to_check")

      #  || Bonfire.Federate.ActivityPub.Peered.actor_blocked?(recipient_actor_uri, :any, :instance_wide) # NOTE: no need to check the instance-wide block here because that's being handled by Boundaries.is_blocked?
      MRF.subdomain_match?(rejects, recipient_actor_uri.host)
      |> debug(
        "filter '#{recipient_actor_uri.host}' blocked #{inspect(block_types)} instance in config?"
      ) ||
        MRF.subdomain_match?(rejects, clean_recipient_actor_uri)
        |> debug(
          "filter '#{clean_recipient_actor_uri}' blocked #{inspect(block_types)} actor in config?"
        ) ||
        not Bonfire.Federate.ActivityPub.federation_allowed?(actor_to_check,
          block_types: block_types,
          user_ids: by_characters,
          resolved: opts[:resolved]
        )
        |> debug(
          "filter '#{id(actor_to_check) || inspect(actor_to_check)}' federation_allowed? (#{inspect(block_types)}) by #{inspect(by_characters)}?"
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
    |> debug("MRF instance_wide blocks from config")
  end

  # def actor_blocked?(
  #       actor,
  #       direction \\ nil,
  #       by_user \\ nil,
  #       opts \\ []
  #     )

  # def actor_blocked?(
  #       actor,
  #       :in,
  #       by_user,
  #       opts
  #     ) do
  #   actor_blocked?(
  #     actor,
  #     :silence,
  #     by_user,
  #     opts
  #   )
  # end

  # def actor_blocked?(
  #       actor,
  #       :out,
  #       by_user,
  #       opts
  #     ) do
  #   actor_blocked?(
  #     actor,
  #     :ghost,
  #     by_user,
  #     opts
  #   )
  # end

  # def actor_blocked?(
  #       actor,
  #       nil,
  #       by_user,
  #       opts
  #     ) do
  #   actor_blocked?(
  #     actor,
  #     [:ghost, :silence],
  #     by_user,
  #     opts
  #   )
  # end

  # def actor_blocked?(
  #       actor,
  #       check_block_types,
  #       by_user,
  #       opts
  #     ) do
  #   block_types = Boundaries.Blocks.types_blocked(check_block_types)

  #   rejects = rejects_regex(block_types)

  #   actor = actor |> repo().maybe_preload(character: [:peered])

  #   object_blocked?(
  #     block_types,
  #     List.wrap(by_user),
  #     rejects,
  #     AdapterUtils.id_or_object_id(actor) || actor,
  #     opts
  #   )
  #   |> debug()
  # end
end
