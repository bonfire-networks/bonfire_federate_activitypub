defmodule Bonfire.Federate.ActivityPub.LockOutgoingTest do
  @moduledoc """
  Closing a thread tells the instances holding it.

  We already READ an incoming `Lock`: `Blocks.ap_receive_activity/3` applies it as the same `:lock` block a local author or moderator applies, checking standing first (`moderation_authority/3` accepts the object's author, or an actor with authority over the group named in `audience`). Emitting it is the other half — without it, a Bonfire thread closes for everyone here and stays open everywhere else, so remote software keeps offering a reply box for replies our boundaries then refuse.

  The AUTHOR case comes first and is not group-specific: the actor is the object's `attributedTo`, which every receiver can verify, and it is what our own ingest already accepts. A moderator closing someone else's thread additionally names the group in `audience`, which is what lets the receiver check standing.

  ⚠️ Not everything locked is a thread. Archiving a group locks the group itself (`Categories.soft_delete/2`), and `Lock` is per-POST everywhere it is implemented — Lemmy sends it with a post as `object` — so a `Lock{Group}` would invent a shape with no receiver. What a closed group declares instead is `postingRestrictedToMods` on its actor.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @remote_actor "https://mocked.local/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} -> json(APSimulate.actor_json(@remote_actor))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  defp ap_id!(object) do
    assert {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: object)
    ap_id
  end

  defp activity_for(ap_id, verb),
    do: ActivityPub.Object.get_activity_for_object_ap_id(ap_id, verb)

  test "an author closing their own thread federates a Lock" do
    author = fake_user!()

    post =
      Bonfire.Posts.Fake.fake_post!(author, "public", %{
        post_content: %{html_body: "<p>closing this</p>"}
      })

    ap_id = ap_id!(post)

    assert {:ok, _} = Blocks.lock(post, current_user: author)

    assert %{data: %{"object" => object}} = activity_for(ap_id, "Lock"),
           "a thread that closes here and stays open everywhere else invites replies our own boundaries will refuse"

    assert object == ap_id or e(object, "id", nil) == ap_id
  end

  test "reopening it federates an Undo of the Lock" do
    author = fake_user!()

    post =
      Bonfire.Posts.Fake.fake_post!(author, "public", %{
        post_content: %{html_body: "<p>reopening</p>"}
      })

    ap_id = ap_id!(post)

    assert {:ok, _} = Blocks.lock(post, current_user: author)

    # an `Undo` wraps the LOCK ACTIVITY, not the post, so it is found by the lock's id rather than the post's
    assert %{data: %{"id" => lock_id}} = activity_for(ap_id, "Lock")

    assert {:ok, _} = Blocks.unlock(post, current_user: author)

    assert %{data: %{"object" => %{"type" => "Lock"}}} = activity_for(lock_id, "Undo"),
           "a reopened thread has to say so, or remote software keeps hiding the reply box that was restored"
  end

  # The echo guard. Applying an incoming lock goes through the very same `Blocks.lock/2` (from the `Lock` handler, and from `Threads.ap_receive_comments_enabled/4` for the `commentsEnabled` form) so without this, receiving a lock would re-announce the origin's decision back at the fediverse as though it were ours.
  test "locking a REMOTE object federates nothing" do
    author = fake_user!()

    # a genuinely remote object has to ARRIVE, not be published here on their behalf: a locally-published post has no AP object of the origin's
    ap_id = "#{@remote_actor}/statuses/theirs"

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "type" => "Create",
               "id" => "#{ap_id}/activity",
               "actor" => @remote_actor,
               "to" => [ActivityPub.Config.public_uri()],
               "object" => %{
                 "id" => ap_id,
                 "type" => "Note",
                 "attributedTo" => @remote_actor,
                 "content" => "<p>theirs, not ours</p>",
                 "to" => [ActivityPub.Config.public_uri()]
               }
             })

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id)

    assert {:ok, _} = Blocks.lock(pointer_id, current_user: author)

    refute activity_for(ap_id, "Lock"),
           "the origin decides whether its own thread is closed; re-announcing that would be us speaking for them"
  end

  # The guard that keeps the two uses of `:lock` apart. Exercised by locking the group DIRECTLY rather than by archiving one, which is what actually does this in the product: archiving also pushes an actor `Update`, whose delivery for an already-archived group is a known crash (parked in `group_actor_update_test.exs`), and that would fail this test for a reason that has nothing to do with the guard.
  test "locking a character federates no Lock" do
    creator = fake_user!()

    group =
      Bonfire.Classify.Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    # a group is an ACTOR, not an object, so its ap_id comes from the actor lookup
    assert {:ok, %{ap_id: ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

    assert {:ok, _} = Blocks.lock(group, current_user: creator)

    refute activity_for(ap_id, "Lock"),
           "`Lock` is per-post everywhere it is implemented, so a group-level one would be a shape with no receiver; a closed group says `postingRestrictedToMods` on its actor instead"
  end
end
