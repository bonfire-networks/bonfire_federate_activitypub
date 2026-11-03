defmodule Bonfire.Federate.ActivityPub.MirroredGroupSettingsRedirectTest do
  @moduledoc """
  The settings of a group hosted on another instance are managed there, so a moderator of our mirror who opens them lands on its Moderation page, the one that works across instances. That page shows join requests, but approving one is left to the group, since approving here would answer as the remote group. A local group keeps its settings, and its moderators approve join requests here.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Classify.Categories

  @group "https://mobilizon.local/@framasoft"
  @moderators "https://mobilizon.local/@framasoft/moderators"

  setup do
    Process.put([:bonfire, :default_pagination_limit], 10)

    account = fake_account!()
    me = fake_user!(account)
    {:ok, %{ap_id: my_ap_id}} = ActivityPub.Actor.get_cached(pointer: me)

    served = %{
      @group =>
        File.read!(Path.join([__DIR__, "..", "fixtures", "mobilizon", "group_actor.json"]))
        |> Jason.decode!(),
      @moderators => %{
        "type" => "OrderedCollection",
        "id" => @moderators,
        "orderedItems" => [my_ap_id]
      }
    }

    mock_global(fn
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

    assert Bonfire.Boundaries.Presets.group_dimension_slugs(group)[:membership] == "on_request",
           "control: the origin moderates who joins"

    assert {:ok, _} = Categories.sync_remote_moderators(group, @moderators)
    assert Bonfire.Boundaries.can?(me, :mediate, group), "control: a moderator of our mirror"

    {:ok, group: group, me: me, conn: conn(user: me, account: account)}
  end

  test "a mirror's settings land on its Moderation page", %{conn: conn, group: group} do
    for tab <- ["", "/boundaries", "/moderators"] do
      conn
      |> visit(Bonfire.Common.URIs.path(group) <> "/settings" <> tab)
      |> assert_path(Bonfire.Common.URIs.path(group) <> "/settings/moderation")
      |> assert_has("[data-role=page_title]", text: "Moderation")
    end
  end

  test "a mirror's Moderation page shows a join request, but approving it is left to the group",
       %{
         conn: conn,
         group: group,
         me: me
       } do
    requester = fake_user!(fake_account!(), %{name: "Hopeful Joiner"})
    assert {:ok, %{requested: true}} = Categories.join_and_follow_group(requester, group)
    request = "article[id*='#{join_request_id!(requester, group, me)}']"

    # both places a moderator decides on it
    for page <- [Bonfire.Common.URIs.path(group) <> "/settings/moderation", "/notifications"] do
      conn
      |> visit(page)
      |> wait_async()
      |> assert_has_or_open_browser("#{request} [data-role=join-request-notification]",
        text: "Hopeful Joiner"
      )
      |> assert_has("#{request} button[disabled]", text: "Cannot approve")
      |> assert_has("#{request} [data-role=join_request_remote_group][data-tip]")
      # the request alone, not the group's card under it
      |> refute_has("#{request} button", text: "Delete group")
    end
  end

  defp join_request_id!(requester, group, moderator) do
    assert {:ok, request} =
             Bonfire.Social.Requests.get(
               requester,
               Bonfire.Boundaries.Verbs.get_id!(:join),
               group,
               current_user: moderator
             ),
           "control: expected a join request row"

    id(request)
  end

  test "control: a local group keeps its settings, and its moderators approve join requests here" do
    account = fake_account!()
    owner = fake_user!(account)

    group =
      Bonfire.Classify.Simulate.fake_group!(owner, %{
        membership: "on_request",
        visibility: "global",
        participation: "group_members",
        default_content_visibility: "public"
      })

    requester = fake_user!(fake_account!(), %{name: "Hopeful Joiner"})
    assert {:ok, %{requested: true}} = Categories.join_and_follow_group(requester, group)

    conn = conn(user: owner, account: account)

    conn
    |> visit(Bonfire.Common.URIs.path(group) <> "/settings")
    |> assert_path(Bonfire.Common.URIs.path(group) <> "/settings")
    |> assert_has("#group-settings-overview")

    request = "article[id*='#{join_request_id!(requester, group, owner)}']"

    for page <- [Bonfire.Common.URIs.path(group) <> "/settings/moderation", "/notifications"] do
      conn
      |> visit(page)
      |> wait_async()
      |> assert_has_or_open_browser("#{request} button:not([disabled])", text: "Approve")
      |> refute_has("#{request} [data-role=join_request_remote_group]")
      |> refute_has("#{request} button", text: "Delete group")
    end
  end

  # Who moderates a group and what it is called are its origin's to say: a moderator of our mirror changing either here would change it for our users only, with nothing sent, until the next sync puts it back. Refused for now, until those changes are sent to the group's server (the TODO at `Categories.hosted_here/1`)
  describe "a mirror's moderators and name are its origin's" do
    setup do
      other = fake_user!()
      {:ok, %{ap_id: other_ap_id}} = ActivityPub.Actor.get_cached(pointer: other)
      %{other: other, other_ap_id: other_ap_id}
    end

    test "a moderator here can't remove or add one of the mirror's moderators, and can on a group hosted here",
         %{group: group, me: me, other: other, other_ap_id: other_ap_id} do
      {:ok, %{ap_id: my_ap_id}} = ActivityPub.Actor.get_cached(pointer: me)

      listed = %{
        "type" => "OrderedCollection",
        "id" => @moderators,
        "orderedItems" => [my_ap_id, other_ap_id]
      }

      assert {:ok, _} = Categories.sync_remote_moderators(group, listed)
      assert Bonfire.Boundaries.can?(other, :mediate, group), "control: listed by the origin"

      assert {:error, _} = Categories.remove_moderator(me, group, id(other))

      assert Bonfire.Boundaries.can?(other, :mediate, group),
             "demoted here, though the origin lists them"

      newcomer = fake_user!()
      assert {:error, _} = Categories.add_moderator(me, group, id(newcomer))

      refute Bonfire.Boundaries.can?(newcomer, :mediate, group),
             "promoted here, though the origin doesn't list them"

      # control: a group hosted here
      local = Bonfire.Classify.Simulate.fake_group!(me)
      assert {:ok, _} = Categories.add_moderator(me, local, id(other))
      assert {:ok, _} = Categories.remove_moderator(me, local, id(other))
      refute Bonfire.Boundaries.can?(other, :mediate, local)
    end

    test "a moderator here can't rename the mirror, and can rename a group hosted here", %{
      group: group,
      me: me
    } do
      before = e(Bonfire.Common.Repo.maybe_preload(group, :profile), :profile, :name, nil)

      assert {:error, _} = Categories.update(me, group, %{profile: %{name: "Renamed here"}})

      {:ok, reloaded} = Categories.get(id(group), skip_boundary_check: true)

      assert e(Bonfire.Common.Repo.maybe_preload(reloaded, :profile), :profile, :name, nil) ==
               before

      # control: a group hosted here
      local = Bonfire.Classify.Simulate.fake_group!(me)
      assert {:ok, _} = Categories.update(me, local, %{profile: %{name: "Renamed here"}})
    end
  end
end
