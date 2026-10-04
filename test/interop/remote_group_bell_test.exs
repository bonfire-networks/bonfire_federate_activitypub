defmodule Bonfire.Federate.ActivityPub.RemoteGroupBellTest do
  @moduledoc """
  A bell on a group hosted elsewhere: once someone here has joined it, its new posts reach us, so they can ask to be notified of them, as for a local group.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @remote_group "https://mocked.local/groups/cooks"

  setup do
    group_json =
      APSimulate.actor_json(@remote_group, "cooks", %{"type" => "Group", "openness" => "open"})

    mock(fn
      %{method: :get, url: @remote_group} -> json(group_json)
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, group} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(group_json)
    {:ok, group} = Categories.get(id(group), skip_boundary_check: true)

    account = fake_account!()
    user = fake_user!(account)
    assert {:ok, _} = Categories.join_and_follow_group(user, group)
    assert Categories.member?(user, group), "control: they joined the remote group"

    # the group accepts their Follow, as a live one does: until then the follow is pending, and the bell is only offered once following
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)

    [follow] =
      ActivityPub.Object
      |> repo().all()
      |> Enum.filter(
        &(&1.local and &1.data["type"] == "Follow" and &1.data["actor"] == actor.ap_id and
            ActivityPub.Object.get_ap_id(&1.data["object"]) == @remote_group)
      )

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Accept",
               "id" => "#{@remote_group}/accept/#{System.unique_integer([:positive])}",
               "actor" => @remote_group,
               "object" => follow.data["id"],
               "to" => [actor.ap_id]
             })

    assert Bonfire.Social.Graph.Follows.following?(user, group),
           "control: the group accepted their follow"

    {:ok, group: group, user: user, conn: conn(user: user, account: account)}
  end

  test "a member can turn on the bell of a remote group", %{group: group, user: user} do
    assert {:ok, _} = Bonfire.Notify.Bells.enable(user, group)
    assert Bonfire.Notify.Bells.enabled?(user, group)
  end

  test "a member can turn on the bell from the remote group's page", %{
    conn: conn,
    group: group,
    user: user
  } do
    conn
    |> visit(Bonfire.Common.URIs.path(group))
    |> wait_async()
    |> click_button("[data-role=bell_button] button", "Notify me about new posts")
    |> assert_has("[data-role=bell_button]", text: "Stop notifying me")

    assert Bonfire.Notify.Bells.enabled?(user, group)
  end
end
