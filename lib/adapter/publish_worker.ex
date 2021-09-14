# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Federate.ActivityPub.APPublishWorker do
  use ActivityPub.Workers.WorkerHelper, queue: "ap_publish", max_attempts: 1

  @moduledoc """
  Module for publishing ActivityPub activities.

  Intended entry point for this module is the `__MODULE__.enqueue/2` function
  provided by `ActivityPub.Workers.WorkerHelper` module.

  Note that the `"context_id"` argument refers to the ID of the object being
  federated and not to the ID of the object context, if present.
  """

  require Logger

  @doc """
  Enqueues a number of jobs provided a verb and a list of string IDs.
  """
  @spec batch_enqueue(String.t(), list(String.t())) :: list(Oban.Job.t())
  def batch_enqueue(verb, ids) do
    Enum.map(ids, fn id -> enqueue(verb, %{"context_id" => id}) end)
  end

  @impl Worker
  def perform(%{args: %{"op" => "delete", "context_id" => context_id}}) do
    # filter for deleted objects
    Bonfire.Common.Pointers.one!(id: context_id)
    |> Bonfire.Common.Pointers.follow!(deleted: true)
    |> Bonfire.Repo.maybe_preload(:character)
    |> Bonfire.Repo.maybe_preload(created: [:peered])
    |> only_local("delete", &Bonfire.Federate.ActivityPub.Publisher.publish/2)
  end

  def perform(%{args: %{"context_id" => context_id, "op" => verb}}) do
    Bonfire.Common.Pointers.one!(id: context_id)
    |> Bonfire.Common.Pointers.follow!()
    |> Bonfire.Repo.maybe_preload(:character)
    |> Bonfire.Repo.maybe_preload(created: [:peered])
    |> only_local(verb, &Bonfire.Federate.ActivityPub.Publisher.publish/2)
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

  defp only_local(context, verb, commit_fn) do
    if Bonfire.Federate.ActivityPub.Utils.check_local(context) do
      commit_fn.(verb, context)
    else
      IO.puts("ignored due to non local activity")
      :ignored
    end
  end
end
