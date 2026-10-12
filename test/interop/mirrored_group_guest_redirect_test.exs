defmodule Bonfire.Federate.ActivityPub.MirroredGroupGuestRedirectTest do
  @moduledoc """
  A guest opening our mirror of a remote group is sent to the group on its own instance, as a guest opening a remote person's profile already is (`Bonfire.Me.Profiles.LiveHandler`): remote characters are shown only to people signed in here, who can act on them from here.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures

  @community "https://lemmy2.local/c/pics"

  @pics %{
    name: "Lemmy (pics)",
    dir: "lemmy",
    id: @community,
    actor: "community_actor_pics.json",
    announces: []
  }

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

    {:ok, group: group}
  end

  test "a guest opening a mirrored group is redirected to it on its own instance", %{
    group: group
  } do
    username = group.character.username

    for path <- [Bonfire.Common.URIs.path(group), "/&#{username}"] do
      conn = get(build_conn(),path)
      assert redirected_to(conn, 302) == @community, "#{path} should redirect to the origin"
    end
  end

  test "someone signed in sees our mirror of the group", %{group: group} do
    account = fake_account!()
    me = fake_user!(account)

    conn = get(conn(user: me, account: account), Bonfire.Common.URIs.path(group))
    assert conn.status == 200
  end

  test "control: a guest opening a LOCAL group sees it here" do
    group =
      Bonfire.Classify.Simulate.fake_group!(fake_user!(), %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    conn = get(build_conn(),Bonfire.Common.URIs.path(group))
    assert conn.status == 200
  end
end
