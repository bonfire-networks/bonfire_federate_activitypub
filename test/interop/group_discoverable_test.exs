defmodule Bonfire.Federate.ActivityPub.GroupDiscoverableTest do
  @moduledoc """
  A remote group that declares `discoverable: false` stays out of our group directory, as it does on its home server. Lemmy 1.0 sends that for an Unlisted community, which "doesn't appear in community list" there.

  It can still be found by its address and followed: being unlisted is about listing, not access.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @listed "https://mocked.local/groups/listed"
  @unlisted "https://mocked.local/groups/unlisted"

  setup do
    actors = %{
      @listed =>
        APSimulate.actor_json(@listed, "listed", %{"type" => "Group", "discoverable" => true}),
      @unlisted =>
        APSimulate.actor_json(@unlisted, "unlisted", %{"type" => "Group", "discoverable" => false})
    }

    mock(fn
      %{method: :get, url: url} ->
        case actors[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    {:ok, listed} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(actors[@listed])

    {:ok, unlisted} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(actors[@unlisted])

    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account), listed: listed, unlisted: unlisted}
  end

  test "a remote group that declares itself undiscoverable isn't listed", %{
    conn: conn,
    listed: listed,
    unlisted: unlisted
  } do
    conn
    |> visit("/groups")
    |> wait_async()
    # the positive control: without it, a directory that lists no remote groups at all would pass the refute below
    |> assert_has_or_open_browser("#group-preview-#{id(listed)}")
    |> refute_has("#group-preview-#{id(unlisted)}")
  end

  test "its mirror is unlisted rather than hidden", %{listed: listed, unlisted: unlisted} do
    assert Bonfire.Boundaries.Presets.group_dimension_slugs(unlisted)[:visibility] == "unlisted"
    assert Bonfire.Boundaries.Presets.group_dimension_slugs(listed)[:visibility] == "global"
  end

  # an `Update` re-applies what the group declares, so a community that stops being listed drops out here too. The `Update` is only a trigger: the actor is re-fetched, so the mock serves the new state (see `group_actor_update_test.exs`)
  test "a group that becomes undiscoverable later is unlisted", %{listed: listed} do
    now_unlisted =
      APSimulate.actor_json(@listed, "listed", %{"type" => "Group", "discoverable" => false})

    mock(fn
      %{method: :get, url: @listed} -> json(now_unlisted)
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "type" => "Update",
               "actor" => @listed,
               "object" => now_unlisted
             })

    assert Bonfire.Boundaries.Presets.group_dimension_slugs(listed)[:visibility] == "unlisted"
  end
end
