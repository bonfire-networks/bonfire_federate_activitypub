defmodule Bonfire.Federate.ActivityPub.GroupOutboxFetchTest do
  @moduledoc """
  Fetching a mirrored group's outbox, as "Get latest activities" on its page does, brings its recent posts in and files them in the group.

  Driven by a Lemmy community's real outbox (`fixtures/lemmy/community_outbox_pics.json`, three of the 50 items it serves inline, each the 1b12 `Announce{Create{Page}}`).
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @community "https://lemmy2.local/c/pics"

  @pics %{
    name: "Lemmy (pics)",
    dir: "lemmy",
    id: @community,
    actor: "community_actor_pics.json",
    announces: []
  }

  defp outbox, do: fixture("lemmy", "community_outbox_pics.json")

  defp posts, do: Enum.map(outbox()["orderedItems"], & &1["object"]["object"])

  setup do
    served = Map.new(served_for([@pics]) ++ outbox_served(outbox()))

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    {:ok, group} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @community})

    {:ok, group: group, user: fake_user!()}
  end

  test "fetching a mirrored group's outbox files its recent posts in the group", %{
    group: group,
    user: user
  } do
    for page <- posts() do
      refute match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: page["id"])),
             "control: #{page["name"]} isn't here before the fetch"
    end

    # the same call, with the same options, as the "Get latest activities" button's handler (`Bonfire.Me.Users.LiveHandler`, "fetch_outbox")
    ActivityPub.Federator.Fetcher.fetch_outbox([pointer: group],
      mode: :async,
      fetch_collection: :async,
      fetch_collection_entries: true,
      user_id: id(user),
      triggered_by: "LiveHandler:fetch_outbox"
    )

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    group = AdapterUtils.get_character_by_ap_id!(@community)

    for page <- posts() do
      post = announced_post!(page["name"], page["id"])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: group
             ),
             "#{page["name"]} should be filed in the group's feed"
    end
  end
end
