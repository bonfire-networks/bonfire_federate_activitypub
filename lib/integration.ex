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
    # translate direction → block_types (set by federate_actor? shim in adapter)
    block_types =
      case opts[:direction] do
        :out -> :ghost
        :in -> :silence
        _ -> opts[:block_types] || :any
      end

    # resolve by_actor (AP Actor struct) to local character for per-user block/allowlist context
    local_user =
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

    mode = federation_mode(local_user || subject, opts)

    # resolve Peered once so both blocked? and allowlisted? skip an extra DB lookup
    mode != false &&
      (
        peered = Bonfire.Federate.ActivityPub.Peered.get_or_nil(subject, opts)
        subject_to_check = peered || subject

        # callers that already enforce blocks (e.g. via `can?`) can pass `skip_block_check: true`
        # to avoid the redundant block query
        not_blocked =
          opts[:skip_block_check] == true or
            !Bonfire.Federate.ActivityPub.Peered.actor_blocked?(
              subject_to_check,
              block_types,
              opts
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
