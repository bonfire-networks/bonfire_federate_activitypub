defmodule Bonfire.Federate.ActivityPub.TopicOutboxFetchUITest do
  @moduledoc """
  "Get latest activities" in the selected chip's menu of a mirrored remote topic, as a mirrored group has in its ⋯ menu (`GroupOutboxFetchUITest`): the button fetches the topic's outbox and flashes that it is syncing.

  A guest never sees this page: a remote group is shown to them on its own instance (`Bonfire.Classify.LiveHandler`), so the item is only offered to a signed-in user.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock

  @group "https://bonfire.local/pub/actors/garden"
  @topic "https://bonfire.local/pub/actors/harvest"

  @topic_menu "[data-id=group_topics] [id^=group-topic-menu-][id$=_panel]"
  @fetch "[phx-click='Bonfire.Me.Users:fetch_outbox']"

  defp actor(id, extra) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => id,
      "type" => "Group",
      "preferredUsername" => id |> String.split("/") |> List.last(),
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox",
      "followers" => "#{id}/followers",
      "attributedTo" => "#{id}/moderators",
      # listed, so local people see the topic in the group's chips (an unlisted actor is readable but not listed)
      "discoverable" => true
    })
    |> Map.merge(extra)
    |> put_in(["publicKey", "id"], "#{id}#main-key")
    |> put_in(["publicKey", "owner"], id)
  end

  setup do
    empty_outbox = fn id ->
      %{"id" => id, "type" => "OrderedCollection", "totalItems" => 0, "orderedItems" => []}
    end

    served = %{
      @group => actor(@group, %{"capabilities" => %{"acceptsJoins" => true}}),
      @topic => actor(@topic, %{"broader" => @group}),
      "#{@group}/outbox" => empty_outbox.("#{@group}/outbox"),
      "#{@topic}/outbox" => empty_outbox.("#{@topic}/outbox")
    }

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
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @group})

    {:ok, topic} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @topic})

    assert topic.type == :topic
    assert topic |> repo().preload(:tree, force: true) |> e(:tree, :parent_id, nil) == id(group)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, group: group, topic: topic, conn: conn(user: me, account: account)}
  end

  defp topic_path(group, topic),
    do: Bonfire.Common.URIs.path(group) <> "/topic/" <> topic.character.username

  test "the mirrored topic's chip menu offers \"Get latest activities\", which syncs it", %{
    conn: conn,
    group: group,
    topic: topic
  } do
    conn
    |> visit(topic_path(group, topic))
    |> wait_async()
    |> assert_has("[data-id=group_topics] [data-role=group-topic-current][aria-current=page]")
    |> assert_has(@topic_menu, text: "Copy link")
    |> assert_has("#{@topic_menu} #{@fetch}[phx-value-id='#{id(topic)}']",
      text: "Get latest activities"
    )
    |> click_button("#{@topic_menu} #{@fetch}", "Get latest activities")
    |> assert_has("*", text: "Syncing with remote server")
  end
end
