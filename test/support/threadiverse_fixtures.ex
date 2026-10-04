defmodule Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures do
  @moduledoc """
  Captured threadiverse fixtures (Lemmy, PieFed, NodeBB, Mbin), and receiving them as a remote instance would deliver them. Shared by the interop tests, which check what is stored, and the UI tests, which check what is shown.

  An implementor is a map of `name`, `dir` (under `test/fixtures`), `id` (the community actor's id), `actor` (its fixture) and `announces` (fixtures of `Announce{Create{…}}` from it).
  """
  import ExUnit.Assertions
  use Bonfire.Common.Repo

  @fixtures Path.join([__DIR__, "..", "fixtures"])

  def fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  @doc "What a mock should serve for these implementors, as `{url, body}` pairs: each community actor, its moderators collection and their actors, each announced object and its author."
  def served_for(implementors) do
    Enum.flat_map(implementors, fn imp ->
      objects =
        for file <- imp.announces do
          object = fixture(imp.dir, file)["object"]["object"]

          [
            {object["id"], object},
            {object["attributedTo"], author_actor(object["attributedTo"])}
          ]
        end
        |> List.flatten()

      actor = fixture(imp.dir, imp.actor)

      # Real captures, because the three differ in ways worth exercising: Lemmy's collection omits `totalItems` entirely, PieFed's has it, and NodeBB's items are full inline actor objects rather than id strings. Mbin has no capture, so it falls back to a minimal collection.
      moderators =
        case actor["attributedTo"] do
          url when is_binary(url) ->
            collection = moderators_collection(imp, url)

            [{url, collection}] ++
              for id <- collection["orderedItems"] || [],
                  is_binary(id),
                  do: {id, author_actor(id)}

          _ ->
            []
        end

      [{imp.id, actor}] ++ objects ++ moderators
    end)
  end

  @doc "What a mock should serve for a community's outbox, as `{url, body}` pairs: the outbox itself, and each item's Announce, Create, announced object and its author, so whatever fetching the outbox dereferences is served."
  def outbox_served(outbox) do
    [{outbox["id"], outbox}] ++
      Enum.flat_map(outbox["orderedItems"], fn announce ->
        create = announce["object"]
        object = create["object"]

        [
          {announce["id"], announce},
          {create["id"], create},
          {object["id"], object},
          {object["attributedTo"], author_actor(object["attributedTo"])}
        ]
      end)
  end

  def receive_announce(announce) do
    case ActivityPub.Federator.Transformer.handle_incoming(announce) do
      {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      {:error, _} -> :ok
    end
  end

  def announced_post!(name, ap_id) do
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id),
           "#{name}: the announced object should be stored as an ap_object"

    refute is_nil(pointer_id), "#{name}: the announced object must be linked to a local record"

    Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)
    # `prune: true` because the implementors don't all land on the same local schema (a `Page` and an `Article` need not become the same thing), so the assoc list has to be filtered per schema
    |> repo().maybe_preload(
      [
        :post_content,
        :activity,
        :replied,
        created: [creator: [character: [:peered]]]
      ],
      prune: true
    )
  end

  def author_actor(ap_id) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => "Person",
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  # Mbin's magazine actor points at a moderators collection we never captured (its instance answers unauthenticated fetches with 500), so stand in a minimal one rather than skip the implementor.
  defp moderators_collection(imp, url) do
    path = @fixtures |> Path.join(imp.dir) |> Path.join("moderators_collection.json")

    if File.exists?(path) do
      fixture(imp.dir, "moderators_collection.json")
    else
      %{"type" => "OrderedCollection", "id" => url, "orderedItems" => ["#{imp.id}/moderator1"]}
    end
  end
end
