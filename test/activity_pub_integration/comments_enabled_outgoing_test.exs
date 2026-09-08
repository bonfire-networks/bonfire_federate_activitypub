defmodule Bonfire.Federate.ActivityPub.CommentsEnabledOutgoingTest do
  @moduledoc """
  A thread we have closed says so on the wire.

  `commentsEnabled` is how the threadiverse states a thread's reply status ON THE OBJECT, where a `Lock` activity states a CHANGE to it. We already read it on the way in (`Threads.ap_receive_comments_enabled/4`, applied at the type-agnostic ingest seam), turning `false` into the same `:lock` block a local moderator would apply. Emitting it is the other half, and without it a locked Bonfire thread federates as open: remote software offers a reply box, the reply is delivered, and our boundaries refuse it — the author finds out by being ignored.

  Locally a lock is a `:cannot_participate` grant to the guest, local and activity_pub circles on the object's own ACL (`Blocks.mutate(:block, …, :lock, …)`), so what is asserted here is that the wire field follows the boundary actually in force rather than a separate flag that can drift from it.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  alias Bonfire.Federate.ActivityPub.Outgoing

  defp post!(creator, html_body, boundary \\ "public") do
    Bonfire.Posts.Fake.fake_post!(creator, boundary, %{post_content: %{html_body: html_body}})
  end

  defp object_data(post) do
    assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)
    data
  end

  test "an open thread says comments are enabled" do
    creator = fake_user!()
    post = post!(creator, "<p>anyone may reply to this</p>")

    assert object_data(post)["commentsEnabled"] == true,
           "stated either way rather than omitted, since an absent field reads as unknown and remote software then guesses"
  end

  # The AP object is serialised at publish time, so re-serialising is what this test needs in order to read the field back; the `Update` below is a device for that, NOT the shape a lock should federate as. A lock announces itself as `Lock` (with the moderator's reason in `summary`, which an Update has nowhere to put), and `commentsEnabled` is the STATE a fresh fetch or backfill reads — one event, one field, never both for the same change.
  test "a locked thread says comments are disabled once the change is federated" do
    creator = fake_user!()
    post = post!(creator, "<p>this one gets closed</p>")

    assert {:ok, _} = Bonfire.Boundaries.Blocks.block(post, :lock, current_user: creator)
    assert {:ok, _} = Outgoing.maybe_federate(creator, :update, post)

    assert object_data(post)["commentsEnabled"] == false,
           "a thread closed to replies that federates as open invites replies our own boundaries will refuse"
  end

  # Media builds its own AP object rather than going through `Posts`, and until now emitted NEITHER field — so it federated saying nothing about who may reply, while its boundaries decided exactly that. It matters more than it sounds: a threadiverse image post arrives here as Media, so this is the type carrying much of what a group relays.
  test "media says who may reply, in both vocabularies" do
    creator = fake_user!()
    media = Bonfire.Social.Fake.upload_media(:images, creator, "a picture")

    assert {:ok, _} = Bonfire.Files.Media.publish(creator, media, boundary: "public")

    data = object_data(media)

    assert data["commentsEnabled"] == true
    assert data["interactionPolicy"]["canReply"]["automaticApproval"] != []
  end

  # A post only its mentions can see lists nobody public under `canReply` because of who it is ADDRESSED to, not because anyone closed it, and the field cannot tell those apart. Saying `false` there is read by the receiving instance as a lock (`Threads.ap_receive_comments_enabled/4` applies the same `:lock` block a moderator would), which closes the conversation against the very people it was sent to — the dance tests caught it as the mentioned user being refused permission to reply.
  test "a post nobody public can read says nothing about comments" do
    creator = fake_user!()
    mentioned = fake_user!()

    post =
      post!(creator, "<p>just between us @#{mentioned.character.username}</p>", "mentions")

    assert {:ok, %{object: %{data: data}}} = Outgoing.push_now!(post)

    refute Map.has_key?(data, "commentsEnabled"),
           "the field states whether a thread is CLOSED, so an object nobody public could reply to anyway has to omit it rather than answer a question that was not asked"
  end

  # Both fields answer the same question for different readers, so they are built together from one boundary check (`AdapterUtils.ap_prepare_outgoing_interaction_policy/3`) rather than queried twice. Asserted so a future change cannot let them disagree.
  test "the two vocabularies always agree" do
    creator = fake_user!()
    open = post!(creator, "<p>open</p>")
    locked = post!(creator, "<p>closed</p>")

    assert {:ok, _} = Bonfire.Boundaries.Blocks.block(locked, :lock, current_user: creator)
    assert {:ok, _} = Outgoing.maybe_federate(creator, :update, locked)

    for post <- [open, locked] do
      data = object_data(post)

      remotes_may_reply? =
        ActivityPub.Config.public_uri() in e(
          data,
          "interactionPolicy",
          "canReply",
          "automaticApproval",
          []
        )

      assert data["commentsEnabled"] == remotes_may_reply?,
             "`commentsEnabled` and `canReply` state the same fact to different software, so a reader choosing either must get the same answer"
    end
  end

  # The round trip, and the reason this is testable without a peer: both halves are ours, so what we emit has to be what `Threads.ap_receive_comments_enabled/4` reads back as the same state.
  test "what we emit is what our own ingest reads back" do
    creator = fake_user!()
    locked = post!(creator, "<p>closed</p>")
    open = post!(creator, "<p>open</p>")

    assert {:ok, _} = Bonfire.Boundaries.Blocks.block(locked, :lock, current_user: creator)
    assert {:ok, _} = Outgoing.maybe_federate(creator, :update, locked)

    assert object_data(locked)["commentsEnabled"] == false
    assert object_data(open)["commentsEnabled"] == true

    # the ingest side keys on exactly these values, so a mismatch here means a Bonfire thread arrives at another Bonfire with the opposite reply status
    assert %{"commentsEnabled" => false} = object_data(locked)
    assert %{"commentsEnabled" => true} = object_data(open)
  end
end
