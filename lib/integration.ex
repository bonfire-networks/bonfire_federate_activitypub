# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_federate_activitypub)

defmodule Bonfire.Federate.ActivityPub do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  alias Bonfire.Common.Utils

  # TODO: make these configurable/extensible
  def do_not_federate_user_ids,
    do: [
      Utils.maybe_apply(Bonfire.Social, :automod_id, [], fallback_return: nil),
      Bonfire.Federate.ActivityPub.AdapterUtils.service_character_id()
    ]

  def repo, do: Config.repo()

  def disable(scope \\ :instance)

  def disable(:instance) do
    # Oban.cancel_all_jobs(Oban.Job)

    set_federating(:instance, false)
  end

  def disable(subject) do
    set_federating(subject, false)
  end

  def set_federating(:instance, set) do
    # Oban.cancel_all_jobs(Oban.Job)

    Settings.set([activity_pub: [instance: [federating: set]]],
      scope: :instance,
      skip_boundary_check: true
    )
  end

  def set_federating(subject, set) do
    Settings.set([activity_pub: [user_federating: set]],
      scope: subject,
      skip_boundary_check: true
    )
  end

  @doc "Set allowlist-only mode. Writes to the existing `federating` / `user_federating` key as `:allowlist_only`."
  def set_allowlist_only(:instance, true) do
    Settings.set([activity_pub: [instance: [federating: :allowlist_only]]],
      scope: :instance,
      skip_boundary_check: true
    )
  end

  def set_allowlist_only(:instance, false) do
    Settings.set([activity_pub: [instance: [federating: true]]],
      scope: :instance,
      skip_boundary_check: true
    )
  end

  def set_allowlist_only(subject, true) do
    Settings.set([activity_pub: [user_federating: :allowlist_only]],
      scope: subject,
      skip_boundary_check: true
    )
  end

  def set_allowlist_only(subject, false) do
    Settings.set([activity_pub: [user_federating: true]],
      scope: subject,
      skip_boundary_check: true
    )
  end

  @doc """
  Returns the federation mode for the given subject (or instance if nil).

  - `true` — open federation
  - `:allowlist_only` — only federate with allowlisted domains/actors
  - `false` — federation disabled

  Accepts `opts[:federation_mode]` as a pre-computed shortcut (used by MRF to avoid
  repeated Settings lookups per actor in a single filter pass).
  """
  def federation_mode(subject \\ nil, opts \\ [])

  def federation_mode(nil, opts) when is_list(opts) do
    case opts[:federation_mode] do
      nil -> compute_federation_mode(opts[:subject] || Utils.current_user(opts), opts)
      mode -> mode
    end
  end

  def federation_mode(subject, opts) when is_list(opts) do
    case opts[:federation_mode] do
      nil -> compute_federation_mode(subject, opts)
      mode -> mode
    end
  end

  @doc "Returns `true` if federation is enabled (open or allowlist-only), `nil` for manual/paused mode, `false` if disabled."
  def federating?(subject \\ nil, opts \\ []) do
    case federation_mode(subject, opts) do
      false -> false
      nil -> nil
      _ -> true
    end
  end

  @doc "Returns `true` if the subject is in allowlist-only mode."
  def allowlist_only?(subject \\ nil, opts \\ []),
    do: federation_mode(subject, opts) == :allowlist_only

  @doc """
  Returns `true` if the given subject (actor, Peered, URI, etc.) can federate, checking:
  - federation is not disabled
  - not blocked (blocks always win)
  - if in allowlist-only mode, also allowlisted

  Pass `federation_mode:` in opts (pre-computed by MRF) to skip the Settings lookup.
  Pass `block_types:` to scope the block check (`:ghost`, `:silence`, `:any`).
  """
  def federation_allowed?(subject, opts \\ []) do
    block_types = block_types_for(opts)
    local_user = local_user_for(opts)

    mode = federation_mode(local_user || subject, opts)

    # resolve Peered once so both blocked? and allowlisted? skip an extra DB lookup
    mode != false &&
      (
        peered = Bonfire.Federate.ActivityPub.Peered.get_or_nil(subject, opts)
        subject_to_check = peered || subject

        # callers that already enforce blocks (e.g. via `can?`) can pass `skip_block_check: true`
        # to avoid the redundant block query
        block_opts = block_opts_for(opts, local_user)

        not_blocked =
          opts[:skip_block_check] == true or
            !Bonfire.Federate.ActivityPub.Peered.actor_blocked?(
              subject_to_check,
              block_types,
              block_opts
            )

        # local subjects don't have Peered records and are always allowed;
        # BoundariesMRF handles per-recipient allowlist filtering for outgoing activities
        not_blocked &&
          (mode != :allowlist_only or
             (is_nil(peered) and Bonfire.Federate.ActivityPub.AdapterUtils.local_subject?(subject)) or
             Bonfire.Federate.ActivityPub.Peered.actor_allowlisted?(subject_to_check, opts))
      )
      |> info("federation_allowed?")
  end

  @doc """
  Keeps those of `subjects` that `federation_allowed?/2` allows with the same `opts`, eg. the followers a post fans out to.

  What `federation_allowed?/2` looks up for each subject is looked up once for all of them: the acting user and the federation mode, the subjects' `Peered` records, their instances' circles, and which of those subjects and instances are blocked. Each subject is then checked by `federation_allowed?/2` itself, which reads these from `opts[:resolved]`, so the rules are the same ones. Anything not looked up here (a subject that is not an `ActivityPub.Actor`, or the per-user allowlist in allowlist-only mode) is still queried per subject.
  """
  def filter_federation_allowed(subjects, opts \\ [])

  def filter_federation_allowed([], _opts), do: []

  def filter_federation_allowed(subjects, opts) when is_list(subjects) do
    opts = Utils.to_options(opts)
    local_user = local_user_for(opts)

    # the mode depends on the subject only when there is no acting user
    opts =
      if local_user,
        do: Keyword.put_new(opts, :federation_mode, federation_mode(local_user, opts)),
        else: opts

    if opts[:federation_mode] == false do
      []
    else
      resolved = resolve_for_federation_checks(subjects, local_user, opts)

      opts =
        Keyword.put(opts, :resolved, Map.merge(opts[:resolved] || %{}, resolved))

      Enum.filter(subjects, &federation_allowed?(&1, opts))
    end
  end

  defp resolve_for_federation_checks(subjects, local_user, opts) do
    actors =
      Enum.filter(subjects, fn
        %ActivityPub.Actor{ap_id: ap_id, pointer_id: pointer_id} ->
          is_binary(ap_id) and is_binary(pointer_id)

        _ ->
          false
      end)

    # by pointer id, as `Peered.get/1` finds an actor's Peered, but keyed by the actor's id, as `Peered.get_or_nil/2` reads them
    peereds_by_id =
      actors
      |> Enum.map(& &1.pointer_id)
      |> Bonfire.Federate.ActivityPub.Peered.list_by_uids()
      |> Map.new(&{&1.id, &1})

    peered_by_urls =
      for %{ap_id: ap_id, pointer_id: pointer_id} <- actors,
          Map.has_key?(peereds_by_id, pointer_id),
          into: %{},
          do: {ap_id, peereds_by_id[pointer_id]}

    hosts =
      peered_by_urls
      |> Map.values()
      |> Enum.map(fn peered ->
        case peered do
          %{peer: %{display_hostname: host}} when is_binary(host) -> host
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    found_circles = Bonfire.Federate.ActivityPub.Instances.get_instance_circles(hosts)

    # `:none` for a host with no circle, so it is not looked up again for each of its actors
    circles_by_hosts = Map.new(hosts, &{&1, Map.get(found_circles, &1, :none)})

    # what `federation_allowed?/2` checks for blocks: an actor's Peered, or the actor's own id when it has none, and its instance's circle
    block_subjects =
      Enum.map(actors, &(peered_by_urls[&1.ap_id] || &1.pointer_id)) ++
        (circles_by_hosts |> Map.values() |> Enum.reject(&(&1 == :none)))

    blocked =
      if opts[:skip_block_check] != true do
        Utils.maybe_apply(
          Bonfire.Boundaries.Blocks,
          :blocked_subset_for,
          [block_subjects, block_types_for(opts), block_opts_for(opts, local_user)],
          fallback_return: nil
        )
      end

    %{
      local_user: local_user,
      peered_by_urls: peered_by_urls,
      allowlist_circles_by_hosts: circles_by_hosts,
      blocked: blocked
    }
  end

  # translate direction → block_types (set by federate_actor? shim in adapter)
  defp block_types_for(opts) do
    case opts[:direction] do
      :out -> :ghost
      :in -> :silence
      _ -> opts[:block_types] || :any
    end
  end

  # resolve by_actor (AP Actor struct) to local character for per-user block/allowlist context, unless `filter_federation_allowed/2` already did it for every subject
  defp local_user_for(opts) do
    case opts[:resolved] do
      %{local_user: local_user} ->
        local_user

      _ ->
        case opts[:by_actor] do
          nil ->
            case opts[:user_ids] do
              ids when is_list(ids) and ids != [] -> ids
              id when is_binary(id) -> id
              _ -> Utils.current_user(opts[:user_ids]) || Utils.current_user(opts)
            end

          by_actor ->
            case Utils.maybe_apply(
                   Bonfire.Federate.ActivityPub.AdapterUtils,
                   :get_character,
                   [by_actor],
                   fallback_return: nil
                 ) do
              {:ok, character} -> character
              _ -> nil
            end
        end
    end
  end

  # `local_user` is threaded in because a PER-USER block is a question about whose list to read, and the publisher identifies the blocker with `by_actor` rather than `current_user`: without this, fanning a post out to followers consults only instance-wide blocks, so someone I ghosted keeps receiving my posts
  defp block_opts_for(opts, local_user) do
    case local_user do
      nil -> opts
      user -> Keyword.put_new(Utils.to_options(opts), :current_user, user)
    end
  end

  @doc """
  Whether `subject` (the acting current user) could FEDERATE an interaction (follow, reply, like,
  boost, DM, mention) with `target`. `target` may be a user/character or an object (post/activity)
  — `is_local?/2` and `federation_allowed?/2` both resolve the relevant peered/creator internally,
  so callers pass whichever they have (for a post, pass its author/subject when known). Accounts
  for the effective federation mode: a LOCAL target is always federatable (no federation needed); a
  REMOTE target only when federation is open, or — under allowlist-only — when allowlisted. See #647.

  Cheapest check first: the cached `federation_mode` short-circuits the whole branch under open
  federation (no per-target Peered lookup), and the computed `mode` is threaded into
  `federation_allowed?` so it isn't looked up twice.
  """
  def interaction_allowed?(subject, target, opts \\ []) do
    case federation_mode(subject, opts) do
      # open — any target is federatable
      true ->
        true

      # disabled or manual/paused — only local interactions reach their target (nothing is
      # pushed to remotes), so federation can't help here regardless of the target
      mode when mode in [false, nil] ->
        Bonfire.Federate.ActivityPub.AdapterUtils.is_local?(target, opts)

      # allowlist-only — local target, or remote target that is allowlisted; reuse
      # federation_allowed? for the allowlist check (caller passes skip_block_check when it has
      # already enforced blocks via can?)
      mode ->
        Bonfire.Federate.ActivityPub.AdapterUtils.is_local?(target, opts) or
          federation_allowed?(
            target,
            [direction: :out, current_user: subject, federation_mode: mode] ++ opts
          )
    end
  end

  def federating_default?(fallback_default \\ true) do
    case ProcessTree.get(:federating) do
      nil ->
        {:default, instance_federating?(fallback_default)}

      other ->
        {:override, other}
    end
  end

  if Config.env() == :test do
    # In tests, read instance-level Bonfire Settings (DB-scoped per instance) so that dance
    # tests with two instances can have independent federation modes.
    defp instance_federating?(fallback_default) do
      case Settings.get([:activity_pub, :instance, :federating], :not_set,
             scope: :instance,
             one_scope_only: true
           ) do
        :not_set -> fallback_default
        other -> other
      end
    end
  else
    defp instance_federating?(_fallback_default), do: ap_instance_federating?()
  end

  defp ap_instance_federating?,
    do:
      Bonfire.Common.Extend.module_enabled?(ActivityPub) and
        ActivityPub.Config.federating?()

  ###

  defp compute_federation_mode([subject], opts), do: compute_federation_mode(subject, opts)

  defp compute_federation_mode([_ | _] = subjects, opts) do
    subjects |> Enum.map(&compute_federation_mode(&1, opts)) |> most_restrictive_mode()
  end

  if Config.env() == :dev do
    # In :dev, FEDERATE=yes overrides all per-user/per-instance DB settings (e.g. allowlist_only),
    # so federated e2e tests work without manually resetting actor settings between runs.
    defp compute_federation_mode(subject, opts) do
      if System.get_env("FEDERATE") in ["yes", "true"] do
        true |> info("computed_federation_mode (FEDERATE override)")
      else
        compute_federation_mode_from_settings(subject, opts)
      end
    end
  else
    defp compute_federation_mode(subject, opts),
      do: compute_federation_mode_from_settings(subject, opts)
  end

  defp most_restrictive_mode(modes) do
    Enum.find([false, :allowlist_only, :manual, nil, true], true, &(&1 in modes))
  end

  defp compute_federation_mode_from_settings(subject, opts) do
    case federating_default?(Keyword.get(opts, :fallback_default, true)) do
      {:override, false} ->
        false

      {:override, :allowlist_only} ->
        :allowlist_only

      {:default, false} ->
        false

      {_tag, instance_mode} when instance_mode in [nil, :manual] ->
        # instance is in manual/paused mode — user can only disable, not enable
        if user_federating?(subject) == false, do: false, else: nil

      {_tag, instance_mode} ->
        # single user-level Settings lookup; key now accepts true | :allowlist_only | false | :manual | nil
        case user_federating?(subject) do
          false ->
            false

          :allowlist_only ->
            :allowlist_only

          v when v in [:manual, nil] ->
            nil

          _ ->
            # instance :allowlist_only overrides an open user setting
            if instance_mode == :allowlist_only, do: :allowlist_only, else: true
        end
    end
    |> info("computed_federation_mode")
  end

  defp user_federating?(subject, default \\ :not_set)

  # Local AP actors: use pointer or pointer_id (Needle ULID) to look up their Bonfire settings
  defp user_federating?(%ActivityPub.Actor{pointer: %{id: _} = pointer}, default) do
    user_federating?(pointer, default)
  end

  defp user_federating?(%ActivityPub.Actor{pointer_id: pointer_id}, default)
       when is_binary(pointer_id) do
    user_federating?(pointer_id, default)
  end

  # Remote AP actors (no Needle pointer) and URI structs don't have per-user Bonfire settings
  defp user_federating?(%ActivityPub.Actor{}, _default), do: :not_set
  defp user_federating?(%URI{}, _default), do: :not_set

  defp user_federating?(subject, default) do
    Settings.get([:activity_pub, :user_federating], default,
      current_user: subject,
      one_scope_only: true,
      preload: true
    )
    |> debug()
  end
end
