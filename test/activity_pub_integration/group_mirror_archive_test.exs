defmodule Bonfire.Federate.ActivityPub.GroupMirrorArchiveTest do
  @moduledoc """
  A group deleted at its origin is archived here, not deleted, and comes back when the origin takes the deletion back.

  Lemmy's community `Delete` is reversible (an `Undo` of it restores the community), and ours is our archive, so an incoming `Delete{Group}` archives the mirror whether the origin archived or deleted it, leaving the local admin to clean up later. Our incoming `Delete` goes ahead only once the origin stops serving the object, so the origin here serves a `Tombstone`; its `Undo` once it serves the group again.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @remote_group "https://mocked.local/groups/tests"
  @remote_mod "https://mocked.local/users/karen"

  defp serve_group do
    mock(fn
      %{method: :get, url: @remote_group} ->
        json(APSimulate.actor_json(@remote_group, "tests", %{"type" => "Group"}))

      %{method: :get, url: @remote_mod} ->
        json(APSimulate.actor_json(@remote_mod))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  defp serve_tombstone do
    mock(fn
      %{method: :get, url: @remote_group} ->
        %Tesla.Env{
          status: 410,
          headers: [{"content-type", "application/activity+json"}],
          body:
            Jason.encode!(%{
              "id" => @remote_group,
              "type" => "Tombstone",
              "formerType" => "Group"
            })
        }

      %{method: :get, url: @remote_mod} ->
        json(APSimulate.actor_json(@remote_mod))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  setup do
    serve_group()
    :ok
  end

  test "a Delete of a mirrored group archives the mirror, and its Undo restores it" do
    assert {:ok, mirror} =
             Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(
               APSimulate.actor_json(@remote_group, "tests", %{"type" => "Group"})
             )

    assert {:ok, %Category{type: :group}} = Categories.get(id(mirror), skip_boundary_check: true),
           "control: the mirror is a live group"

    delete = %{
      "id" => "https://mocked.local/activities/delete-tests",
      "type" => "Delete",
      "actor" => @remote_mod,
      "object" => @remote_group,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    serve_tombstone()
    Transformer.handle_incoming(delete)

    refute repo().get(Category, id(mirror)),
           "the mirror is still live, so our members keep a group its origin closed"

    # archived rather than deleted: its mixins hang off the pointer and stay, which is what lets the origin's Undo bring it back (and its admin look at it before cleaning up). `get_archived/1` alone would also find a deleted one, from its deleted pointer
    assert {:ok, %{profile: %{name: _}}} = Categories.get_archived(id(mirror)),
           "the mirror was deleted rather than archived (its profile went with it)"

    assert repo().get(Bonfire.Data.ActivityPub.Peered, id(mirror)),
           "the mirror lost its link to the origin's actor, so an Undo of the Delete can't find it"

    serve_group()

    Transformer.handle_incoming(%{
      "id" => "https://mocked.local/activities/undo-delete-tests",
      "type" => "Undo",
      "actor" => @remote_mod,
      "object" => delete,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    })

    assert {:ok, %Category{type: :group}} =
             Categories.get(id(mirror), skip_boundary_check: true),
           "the origin restored the group, but its mirror stayed archived"
  end
end
