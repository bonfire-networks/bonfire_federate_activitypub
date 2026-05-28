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
      nil -> compute_federation_mode(opts[:subject] || Utils.current_user(opts))
      mode -> mode
    end
  end

  def federation_mode(subject, opts) when is_list(opts) do
    case opts[:federation_mode] do
      nil -> compute_federation_mode(subject)
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
        peered = Bonfire.Federate.ActivityPub.Peered.get_or_nil(subject)
        subject_to_check = peered || subject

        not_blocked =
          !Bonfire.Federate.ActivityPub.Peered.actor_blocked?(
            subject_to_check,
            block_types,
            opts
          )

        not_blocked &&
          (mode != :allowlist_only or
             Bonfire.Federate.ActivityPub.Peered.actor_allowlisted?(subject_to_check, opts))
      )
      |> info("federation_allowed?")
  end

  def federating_default?() do
    case ProcessTree.get(:federating) do
      nil ->
        {:default,
         Bonfire.Common.Extend.module_enabled?(ActivityPub) and
           ActivityPub.Config.federating?()}

      other ->
        {:override, other}
    end
  end

  ###

  defp compute_federation_mode([subject]), do: compute_federation_mode(subject)

  defp compute_federation_mode([_ | _] = subjects) do
    subjects |> Enum.map(&compute_federation_mode/1) |> most_restrictive_mode()
  end

  defp most_restrictive_mode(modes) do
    Enum.find([false, :allowlist_only, :manual, nil, true], true, &(&1 in modes))
  end

  defp compute_federation_mode(subject) do
    case federating_default?() do
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

  defp user_federating?(subject, default \\ :not_set) do
    Settings.get([:activity_pub, :user_federating], default,
      current_user: subject,
      one_scope_only: true,
      preload: true
    )
    |> debug()
  end
end
