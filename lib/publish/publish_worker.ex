# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.APPublishWorker do
  use ActivityPub.Workers.WorkerHelper, queue: "ap_publish", max_attempts: 1
  use Arrows

  @moduledoc """
  Module for publishing ActivityPub activities.

  Intended entry point for this module is the `__MODULE__.enqueue/2` function
  provided by `ActivityPub.Workers.WorkerHelper` module.

  Note that the `"context_id"` argument refers to the ID of the object being
  federated and not to the ID of the object context, if present.
  """

  import Untangle
  import Bonfire.Federate.ActivityPub
  alias Bonfire.Common.Utils
  alias Bonfire.Federate.ActivityPub.Utils, as: APUtils

  def maybe_enqueue(verb, thing, subject) do
    if APUtils.is_local?(subject) do
      enqueue(
        verb,
        %{
          "context_id" => thing,
          "user_id" => Utils.ulid(subject)
        },
        unique: [period: 5]
      )

      :ok

    else
      info("Skip (re)federating out '#{verb}' activity of object '#{Utils.ulid(thing)}' by a remote actor")
      :skip
    end
  end

  @doc """
  Enqueues a number of jobs provided a verb and a list of string IDs.
  """
  @spec batch_enqueue(String.t(), list(String.t())) :: list(Oban.Job.t())
  def batch_enqueue(verb, ids) do
    Enum.map(ids, fn id -> enqueue(verb, %{"context_id" => id}) end)
  end

  @impl Worker
  def perform(%{args: %{"op" => "delete" = verb, "context_id" => context_id}}) do
    # filter to include deleted objects
    Bonfire.Common.Pointers.get!(context_id, filters_override: [deleted: true])
    |> do_perform(verb)
  end

  def perform(%{args: %{"op" => verb, "context_id" => context_id}}) do
    Bonfire.Common.Pointers.get!(context_id, skip_boundary_check: true)
    |> do_perform(verb)
  end

  defp do_perform(object, verb) do
    object
    # preload common assocs needed by publisher, seperately in case any assocs don't exists
    |> repo().maybe_preload(character: [:peered])
    |> repo().maybe_preload(created: [:peered])
    |> repo().maybe_preload(creator: [:peered])
    |> repo().maybe_preload(edge: [:object])
    |> Bonfire.Federate.ActivityPub.Publisher.publish(verb, ...)
    # NOTE: we check this before putting things in the queue instead
    # |> only_local(verb, &Bonfire.Federate.ActivityPub.Publisher.publish/2)
  end

  # defp only_local(
  #        %CommonsPub.Resources.Resource{context_id: context_id} = context,
  #        verb,
  #        commit_fn
  #      ) do
  #   with {:ok, character} <- Bonfire.Me.Characters.one(id: context_id),
  #        true <- is_nil(character.peer_id) do
  #     commit_fn.(verb, context)
  #   else
  #     _ ->
  #       :ignored
  #   end
  # end

  # defp only_local(context, verb, commit_fn) do
  #   if Bonfire.Federate.ActivityPub.Utils.is_local?(context) do
  #     commit_fn.(verb, context)
  #   else
  #     warn("Skip (re)federating out this #{verb} of a remote object")
  #     {:discard, :not_local}
  #   end
  # end
end
