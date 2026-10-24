defmodule Bonfire.Federate.ActivityPub.RefetchDeletedTest do
  @moduledoc """
  A remote post we hold, deleted at its origin: when it is fetched from there again (a relay checked against its origin, an unsigned delivery confirmed by fetching, a background refresh), the post is deleted here too, as if its author's `Delete` had arrived, and not only its AP copy marked as a `Tombstone`.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer

  @remote_actor "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    post_id = "#{@remote_actor}/statuses/deleted-later-#{n}"

    mock(fn
      %{method: :get, url: @remote_actor} -> json(Simulate.actor_json(@remote_actor))
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
                 "content" => "a remote post, deleted later at its origin",
                 "to" => [@public]
               }
             })

    assert {:ok, _} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true),
           "control: the post was made here"

    %{post_id: post_id, pointer_id: pointer_id}
  end

  test "is deleted here too when fetched again from its origin", %{
    post_id: post_id,
    pointer_id: pointer_id
  } do
    # its origin now says it is gone
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: ^post_id} ->
        json(%{"id" => post_id, "type" => "Tombstone", "formerType" => "Note"})

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    Fetcher.fetch_fresh_object_from_id(post_id, return_tombstones: true)

    assert {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: post_id)
    assert ActivityPub.Object.is_deleted?(ap_object), "its AP copy is marked deleted"

    refute match?({:ok, _}, Bonfire.Posts.read(pointer_id, skip_boundary_check: true)),
           "the AP copy says deleted, but the post is still up here"
  end
end
