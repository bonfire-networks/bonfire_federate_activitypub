defmodule Bonfire.Federate.ActivityPub.MirroredGroupFollowButtonUITest do
  @moduledoc """
  The round Follow button on our mirror of a remote group, after joining it. Joining sends the group's home instance a `Follow`, which stays a pending request until its `Accept` arrives, so the button has to show the request rather than a plain Follow, and clicking it must not fail.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures
  alias Bonfire.Classify.Categories
  alias Bonfire.Social.Graph.Follows

  @community "https://lemmy2.local/c/pics"

  @pics %{
    name: "Lemmy (pics)",
    dir: "lemmy",
    id: @community,
    actor: "community_actor_pics.json",
    announces: []
  }

  # the ROUND Follow in the group's hero, told apart from any other follow toggle by its tooltip
  @round_not_following "[data-id=follow][data-tip='Follow group']"
  # once you have joined, the hero keeps the Follow toggle in its "More group actions" menu, in words rather than as the round icon, so a pending request reads "Requested …" there
  @pending_follow "[data-role=group-hero-follow] [data-id=unfollow]"

  setup do
    served = Map.new(served_for([@pics]))

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
    {:ok, group: group, me: me, conn: conn(user: me, account: account)}
  end

  test "after joining a mirrored group, its round Follow shows the pending request, not a plain Follow",
       %{conn: conn, group: group, me: me} do
    assert {:ok, _} = Categories.join_and_follow_group(me, group)

    refute Follows.following?(me, group),
           "control: no `Accept` has arrived, so the follow is still pending"

    assert Bonfire.Social.Requests.requested?(me, :follow, group),
           "control: the follow is a pending request"

    conn
    |> visit(Bonfire.Common.URIs.path(group))
    |> wait_async()
    |> refute_has(@round_not_following)
    |> assert_has_or_open_browser(@pending_follow, text: "Requested")
  end

  test "clicking the round Follow of a mirrored group you joined gives no error", %{
    conn: conn,
    group: group,
    me: me
  } do
    assert {:ok, _} = Categories.join_and_follow_group(me, group)

    conn
    |> visit(Bonfire.Common.URIs.path(group))
    |> wait_async()
    # the hero's Follow control in its pending state (the same one the test above looks for): the control the page offers for the request that joining sent
    |> click_button(@pending_follow, "")
    |> refute_has("[data-id=flash_error]")
  end
end
