# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.Outgoing do
  import Untangle
  import Bonfire.Federate.ActivityPub
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.BoundariesMRF
  alias Bonfire.Common
  alias Common.Utils
  alias Common.Enums
  alias Common.Extend
  alias Common.Types

  # defines default types that can be federated as AP Actors (overriden by config)
  @types_characters Application.compile_env(
                      :bonfire,
                      :types_character_schemas,
                      [
                        Bonfire.Data.Identity.User,
                        # CommonsPub.Communities.Community,
                        # CommonsPub.Collections.Collection,
                        Bonfire.Data.Identity.Character,
                        Bonfire.Classify.Category
                      ]
                    )

  def maybe_federate(subject, verb, thing, opts \\ []) do
    verb = verb || :create

    thing = AdapterUtils.preload_peered(thing)
    thing_local? = AdapterUtils.is_local?(thing)

    subject = AdapterUtils.preload_peered(subject)

    subject_local? =
      if is_nil(subject) or Enums.id(thing) == Enums.id(subject),
        do: thing_local?,
        else: AdapterUtils.is_local?(subject)

    federate_outgoing? = federate_outgoing?(subject)

    if (federate_outgoing? == true or (opts[:manually_fetching?] and federate_outgoing? != false)) and
         ((is_nil(subject) and thing_local?) or
            subject_local?) do
      prepare_and_queue(subject, verb, thing, opts)
    else
      info(
        thing,
        "Skip (re)federating out '#{verb}' activity by remote actor '#{Types.uid(subject)}'=#{subject_local?}, or remote object '#{Types.uid(thing)}'=#{thing_local?}"
      )

      :ignore
    end
  end

  def federate_outgoing?(subject \\ nil) do
    Bonfire.Federate.ActivityPub.federating?(subject) &&
      !BoundariesMRF.actor_blocked?(
        subject,
        :out
      )

    # and Bonfire.Common.Extend.module_enabled?(
    #   Bonfire.Federate.ActivityPub.Outgoing,
    #   subject
    # )
    # ^ TODO: to disabled only outgoing federation
  end

  defp prepare_and_queue(subject, verb, thing, opts)

  defp prepare_and_queue(_subject, verb, %{__struct__: type, id: _id} = character, _opts)
       when verb in [:update, :edit] and type in @types_characters do
    # Works for Users, Collections, Communities (not MN.ActivityPub.Actor)
    push_actor_update(character)
  end

  defp prepare_and_queue(subject, :delete, thing, opts) do
    case push_delete(Types.object_type(thing), subject, thing, opts)
         |> debug("result of push_delete") do
      {:ok, del} ->
        {:ok, del}

      # temp workaround
      [ok: del] ->
        {:ok, del}

      # none pushed?
      [] ->
        :ignore

      :ignore ->
        :ignore

      {:error, reason} ->
        error(reason, "Failed to delete")
    end
  end

  defp prepare_and_queue(subject, verb, %{__struct__: object_type} = local_object, _opts) do
    case Bonfire.Federate.ActivityPub.FederationModules.federation_module({verb, object_type}) do
      {:ok, module} when is_atom(module) ->
        info(
          module,
          "Federate.ActivityPub - delegating to module to handle verb '#{verb}' for object type #{object_type}"
        )

        cond do
          !Extend.module_enabled?(module) ->
            preparation_error(
              "Federation module #{module} was disabled, for verb {#{inspect(verb)}, #{object_type}}",
              [verb, local_object]
            )

          function_exported?(module, :ap_publish_activity, 3) ->
            Utils.maybe_apply(
              module,
              :ap_publish_activity,
              [subject, verb, local_object],
              current_user: subject,
              fallback_fun: &preparation_error/2,
              force_module: true
            )

          true ->
            Utils.maybe_apply(
              module,
              :ap_publish_activity,
              [verb, local_object],
              current_user: subject,
              fallback_fun: &preparation_error/2,
              force_module: true
            )
        end
        |> debug("donz")
        |> case do
          {:ok, activity} ->
            {:ok, activity}

          {:ok, activity, object} ->
            {:ok, activity, object}

          :ignore ->
            debug("Ignoring outgoing federation")
            :ignore

          e ->
            warn(
              e,
              "Unexpected result from federation preparation function `#{module}.ap_publish_activity` when trying to handle verb '#{verb}' for object type #{object_type}"
            )

            e
        end

      _ ->
        # TODO: fallback to creating a Note for unknown types that have a post content, Profile or Named?

        preparation_error(
          "No FederationModules or SchemaModules was defined for verb {#{inspect(verb)}, #{object_type}}",
          [verb, local_object]
        )
    end
  end

  defp prepare_and_queue(_subject, verb, object, _) do
    preparation_error("Unrecognised object for AP publisher", [verb, object])
  end

  def preparation_error(error, [_subject, verb, %{__struct__: object_type, id: id} = object]) do
    error(
      object,
      "Federate.ActivityPub - Unable to federate out - #{error}... object ID: #{id} - with verb: #{verb} ; object type: #{object_type}"
    )

    :ignore
  end

  def preparation_error(error, [_subject, verb, object]) do
    error(
      object,
      "Federate.ActivityPub - Unable to federate out - #{error} - with verb: #{verb}}"
    )

    :ignore
  end

  def preparation_error(error, object) do
    error(object, "Federate.ActivityPub - Unable to federate out - #{error}...")

    :ignore
  end

  defp push_delete(Bonfire.Data.Identity.Account, _subject, _, _opts) do
    debug("do not federate deletion of account, since that's an internal construct")
    :ignore
  end

  defp push_delete(Bonfire.Data.Identity.User, _subject, %{} = user, opts) do
    # TODO: is this broken?
    with %{} = actor <- opts[:ap_object] || AdapterUtils.character_to_actor(user) do
      ActivityPub.delete(
        actor,
        true,
        opts ++ [bcc: AdapterUtils.ids_or_object_ids(opts[:ap_bcc])]
      )
    end
  end

  defp push_delete(type, subject, character, opts)
       when type in @types_characters do
    # For Topics, Groups, and other non-user actors
    with %{} = actor <- opts[:ap_object] || AdapterUtils.character_to_actor(character) do
      ActivityPub.delete(
        actor,
        true,
        opts ++
          [
            subject: AdapterUtils.the_ap_id(ActivityPub.Actor.get_cached!(pointer: subject)),
            bcc: AdapterUtils.ids_or_object_ids(opts[:ap_bcc])
          ]
      )
    else
      e ->
        preparation_error("Could not find the AP actor to delete", e)
        :ignore
    end
  end

  # delete anything else
  defp push_delete(_other, subject, %{id: id} = _thing, opts) do
    with %{} = subject <- ActivityPub.Actor.get_cached!(pointer: subject),
         %{} = object <-
           opts[:ap_object] ||
             ActivityPub.Object.get_cached!(pointer: id) do
      ActivityPub.delete(
        object,
        true,
        opts ++
          [
            subject: AdapterUtils.the_ap_id(subject),
            bcc: AdapterUtils.ids_or_object_ids(opts[:ap_bcc])
          ]
      )
    else
      e ->
        preparation_error("Could not find the AP object to delete", e)
        :ignore
    end
  end

  def push_actor_update(%ActivityPub.Actor{} = actor) do
    with %{} = actor_object <-
           ActivityPub.Web.ActorView.render("actor.json", %{actor: actor}),
         params <- %{
           to: [AdapterUtils.public_uri()],
           cc: [actor.data["followers"]],
           object: actor_object,
           actor: actor,
           local: true
         } do
      ActivityPub.update(params)
    else
      e ->
        preparation_error("Error while attempting to federate the update", e)
    end
  end

  def push_actor_update(%{__struct__: type, id: id})
      when type in @types_characters do
    # Works for Users, Collections, Communities (not MN.ActivityPub.Actor)
    with {:ok, actor} <- ActivityPub.Actor.get_cached(pointer: id) do
      ActivityPub.Actor.set_cache(actor)
      push_actor_update(actor)
    else
      e ->
        preparation_error("Error while attempting to find the Actor to update", e)
    end
  end

  def push_now!(activity) do
    activity = ap_activity!(activity)

    # ActivityPub.Federator.perform(:publish, ap_activity!(activity))

    case Oban.Testing.perform_job(
           ActivityPub.Federator.Workers.PublisherWorker,
           %{"op" => "publish", "activity_id" => Enums.id(activity), "repo" => repo()},
           repo: repo()
         ) do
      {:ok, activity} -> {:ok, activity}
      :ok -> {:ok, activity}
    end

    # NOTE: the above is not needed IF running Oban in :inline testing mode
    # case activity do
    #   %{__struct__: ActivityPub.Object} = object -> {:ok, object}
    #   %{__struct__: ActivityPub.Actor} = actor -> {:ok, actor}
    # end
  end

  def ap_activity!(%{activity: %{federate_activity_pub: activity}}) do
    ap_activity!(activity)
  end

  def ap_activity!(%{federate_activity_pub: activity}) do
    ap_activity!(activity)
  end

  def ap_activity!(%{data: _} = activity) do
    activity
  end

  def ap_activity!({:ok, activity}) do
    ap_activity!(activity)
  end

  def ap_activity!({:ok, activity, _object}) do
    ap_activity!(activity)
  end
end
