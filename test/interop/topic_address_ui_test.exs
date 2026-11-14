defmodule Bonfire.Federate.ActivityPub.TopicAddressUITest do
  @moduledoc """
  A mirrored remote topic selected inside its group shows its address on its own server (`+harvest@bonfire.local`), copyable, under the topic tabs, so someone can search for it from another server. The group's address stays in the hero.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock

  @group "https://bonfire.local/pub/actors/garden"
  @topic "https://bonfire.local/pub/actors/harvest"

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

    account = fake_account!()
    me = fake_user!(account)

    {:ok, group: group, topic: topic, conn: conn(user: me, account: account)}
  end

  defp topic_path(group, topic),
    do: Bonfire.Common.URIs.path(group) <> "/topic/" <> topic.character.username

  test "the mirrored topic's address is its remote one, under the tabs", %{
    conn: conn,
    group: group,
    topic: topic
  } do
    group_address =
      group
      |> repo().maybe_preload(character: [:peered])
      |> Bonfire.Me.Characters.display_username(true, nil, "")

    topic_address =
      topic
      |> repo().maybe_preload(character: [:peered])
      |> Bonfire.Me.Characters.display_username(true, nil, "")

    # the control: the address is the topic's own, on its origin server, shown with no prefix
    assert topic_address == "harvest@bonfire.local"

    conn
    |> visit(topic_path(group, topic))
    |> wait_async()
    # the visible text may break before the host (`<wbr>`), so the handle and the host are checked apart
    |> assert_has("[data-role=group-topic-info] [data-role=group-address]", text: "harvest")
    |> assert_has("[data-role=group-topic-info] [data-role=group-address]",
      text: "@bonfire.local"
    )
    |> assert_has(
      "[data-id=group_hero] [data-role=group-address-copy][phx-hook=Copy][data-clipboard-text='!#{group_address}']"
    )
    |> assert_has(
      "[data-role=group-topic-info] [data-role=group-address-copy][phx-hook=Copy][data-clipboard-text='!#{topic_address}']"
    )
    |> assert_has(
      "[data-role=group-topic-info] [data-role=group-address-copy][phx-hook=Copy][data-clipboard-text='@#{topic_address}']"
    )

    # old: the `+` prefixed address was the copy target
    # |> assert_has("[data-role=group-topic-info] [data-role=group-address][phx-hook=Copy][data-clipboard-text='+harvest@bonfire.local']")
  end
end
