defmodule Bonfire.Federate.ActivityPub.RemoteActorSuspensionTest do
  @moduledoc """
  A remote actor suspended at its origin (Mastodon serves it with `"suspended": true`, after a `Delete` of the actor or in an `Update` of it) is kept here, with its posts, but hidden instance-wide, so it comes back when the origin lifts the suspension. A real deletion (a Tombstone, or 404/410 without `suspended`) still deletes it.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Me.Users
  alias Bonfire.Social.FeedLoader

  @remote_actor "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    Process.put(:federating, true)
    n = System.unique_integer([:positive])
    post_id = "#{@remote_actor}/statuses/suspended-later-#{n}"

    mock(fn
      %{method: :get, url: @remote_actor} -> json(Simulate.actor_json(@remote_actor))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, %{pointer: %{id: pointer_id}}} =
             Transformer.handle_incoming(%{
               "type" => "Create",
               "id" => post_id <> "/activity",
               "actor" => @remote_actor,
               "to" => [@public],
               "object" => %{
                 "id" => post_id,
                 "type" => "Note",
                 "attributedTo" => @remote_actor,
                 "content" => "a remote post, its author suspended later",
                 "to" => [@public]
               }
             })

    {:ok, remote_user} = Users.by_ap_id(@remote_actor)
    viewer = fake_user!()

    assert {:ok, post} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true)

    assert FeedLoader.feed_contains?(:remote, post, viewer),
           "control: the remote post shows in the fediverse feed before any suspension"

    refute Blocks.is_blocked?(remote_user, :silence, :instance_wide),
           "control: the remote user is not hidden before any suspension"

    %{remote_user: remote_user, post: post, viewer: viewer}
  end

  defp origin_serves(actor_response) do
    mock(fn
      %{method: :get, url: @remote_actor} -> actor_response
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)
  end

  defp suspended_actor_json,
    do: Simulate.actor_json(@remote_actor) |> Map.put("suspended", true)

  defp receive_actor_delete do
    Oban.Testing.with_testing_mode(:inline, fn ->
      Transformer.handle_incoming(%{
        "type" => "Delete",
        "id" => "#{@remote_actor}#delete",
        "actor" => @remote_actor,
        "object" => @remote_actor,
        "to" => [@public]
      })
    end)
  end

  defp assert_hidden(remote_user, post, viewer) do
    assert {:ok, _} = Users.by_id(id(remote_user)),
           "a suspended remote user should be kept, not deleted"

    assert Blocks.is_blocked?(remote_user, :silence, :instance_wide),
           "a suspended remote user should be hidden instance-wide"

    refute FeedLoader.feed_contains?(:remote, post, viewer),
           "a suspended remote user's post should not show in the fediverse feed"
  end

  defp assert_visible(remote_user, post, viewer) do
    assert {:ok, _} = Users.by_id(id(remote_user))

    refute Blocks.is_blocked?(remote_user, :silence, :instance_wide),
           "an unsuspended remote user should not be hidden any more"

    assert FeedLoader.feed_contains?(:remote, post, viewer),
           "an unsuspended remote user's post should show again in the fediverse feed"
  end

  test "a Delete of an actor its origin serves as suspended keeps and hides it", %{
    remote_user: remote_user,
    post: post,
    viewer: viewer
  } do
    origin_serves(json(suspended_actor_json()))

    receive_actor_delete()

    assert_hidden(remote_user, post, viewer)
  end

  test "a Delete of an actor its origin answers 410 for, as suspended, keeps and hides it", %{
    remote_user: remote_user,
    post: post,
    viewer: viewer
  } do
    origin_serves(%Tesla.Env{
      status: 410,
      body: Jason.encode!(suspended_actor_json()),
      headers: [{"content-type", "application/activity+json"}]
    })

    receive_actor_delete()

    assert_hidden(remote_user, post, viewer)
  end

  test "an Update of a suspended actor without `suspended` shows it again", %{
    remote_user: remote_user,
    post: post,
    viewer: viewer
  } do
    origin_serves(json(suspended_actor_json()))
    receive_actor_delete()
    assert_hidden(remote_user, post, viewer)

    # the origin lifts the suspension
    origin_serves(json(Simulate.actor_json(@remote_actor)))

    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "type" => "Update",
               "id" => "#{@remote_actor}#updates/unsuspended",
               "actor" => @remote_actor,
               "object" => Simulate.actor_json(@remote_actor),
               "to" => [@public]
             })

    assert_visible(remote_user, post, viewer)
  end

  test "an Update signed by the actor saying it is suspended keeps and hides it", %{
    remote_user: remote_user,
    post: post,
    viewer: viewer
  } do
    assert {:ok, _} =
             Transformer.handle_incoming(
               %{
                 "type" => "Update",
                 "id" => "#{@remote_actor}#updates/suspended",
                 "actor" => @remote_actor,
                 "object" => suspended_actor_json(),
                 "to" => [@public]
               },
               authenticated: :http_signature,
               signed_by: @remote_actor
             )

    assert_hidden(remote_user, post, viewer)
  end

  test "a Delete of an actor its origin answers 410 for, not suspended, still deletes it", %{
    remote_user: remote_user
  } do
    origin_serves(%Tesla.Env{status: 410, body: ""})

    receive_actor_delete()

    assert {:error, :not_found} = Users.by_id(id(remote_user)),
           "a remote actor deleted at its origin should be deleted here too"
  end
end
