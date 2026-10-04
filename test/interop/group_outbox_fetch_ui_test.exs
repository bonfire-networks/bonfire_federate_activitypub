defmodule Bonfire.Federate.ActivityPub.GroupOutboxFetchUITest do
  @moduledoc """
  "Get latest activities" in a mirrored group's ⋯ menu fetches that group's outbox, so its recent posts come in and are filed in the group.

  Same Lemmy community and outbox as `GroupOutboxFetchTest`, which covers the fetch itself; this covers the button reaching it with the group.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
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

    account = fake_account!()
    me = fake_user!(account)
    {:ok, group: group, conn: conn(user: me, account: account)}
  end

  test "the group's \"Get latest activities\" brings its recent posts into the group", %{
    conn: conn,
    group: group
  } do
    conn
    |> visit(Bonfire.Common.URIs.path(group))
    |> wait_async()
    |> click_button("[phx-click='Bonfire.Me.Users:fetch_outbox']", "Get latest activities")
    |> assert_has("*", text: "Syncing with remote server")

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    group = AdapterUtils.get_character_by_ap_id!(@community)

    for page <- Enum.map(outbox()["orderedItems"], & &1["object"]["object"]) do
      post = announced_post!(page["name"], page["id"])

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: group
             ),
             "#{page["name"]} should be filed in the group's feed"
    end
  end
end
