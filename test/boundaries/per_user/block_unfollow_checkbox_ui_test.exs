defmodule Bonfire.Federate.ActivityPub.BlockUnfollowCheckboxUITest do
  @moduledoc """
  The `also_unfollow_and_notify` checkbox in the ghost form, driven through the profile page rather than by calling `Blocks.block/3` with the option. It only renders for someone remote, which is why this lives with the federation tests: they can serve a remote actor.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  alias Bonfire.Social.Graph.Follows

  @remote "https://checkboxhost.local/users/follower"

  setup do
    mock_global(fn
      %{method: :get, url: @remote} ->
        json(Simulate.actor_json(@remote, "follower"))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote)
    {:ok, follower} = Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(actor)
    {:ok, _} = Follows.follow(follower, me, skip_boundary_check: true)

    assert Follows.following?(follower, me), "control: they follow me before the ghost"

    {:ok, me: me, follower: follower, conn: conn(user: me, account: account)}
  end

  defp open_ghost_form(conn, follower) do
    conn
    |> visit(Bonfire.Common.URIs.path(follower))
    |> wait_async()
    |> within(
      "[data-id='hero_more_actions-profile_hero'] [data-role='ghost_modal']",
      &click_button(&1, "Ghost #{e(follower, :profile, :name, nil)}")
    )
  end

  test "ghosting with the box ticked removes them from my followers", %{
    conn: conn,
    me: me,
    follower: follower
  } do
    conn
    |> open_ghost_form(follower)
    |> check(
      "[data-role=also_unfollow_and_notify]",
      Bonfire.UI.Boundaries.BlockUnfollowNotifyLive.offer(:ghost),
      exact: false
    )
    |> click_button("[data-role=ghost]", "Ghost")
    |> assert_has("[role=alert]", text: "ghosted")

    refute Follows.following?(follower, me)
  end

  test "ghosting with the box unticked keeps their follow", %{
    conn: conn,
    me: me,
    follower: follower
  } do
    conn
    |> open_ghost_form(follower)
    |> assert_has("[data-role=also_unfollow_and_notify]")
    |> click_button("[data-role=ghost]", "Ghost")
    |> assert_has("[role=alert]", text: "ghosted")

    assert Follows.following?(follower, me)
  end
end
