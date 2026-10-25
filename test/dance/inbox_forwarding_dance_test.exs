defmodule Bonfire.Federate.ActivityPub.Dance.InboxForwardingTest do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2) between two real instances: no echo. A reply from the other instance to our user's post is not forwarded back to that instance, though one of its users follows ours: its server sent the reply, so it has it.

  With two instances every remote follower of ours is on the sender's server, so a forward that does reach someone is tested with mocked remotes (`Bonfire.Federate.ActivityPub.InboxForwardingTest`). What this shows is the rest of the path holding between real instances: the reply arrives signed (FEP-8b32), is known as a reply to our post, and is skipped only because no inbox is left.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows

  setup context do
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)

    clean_slate(context)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:activity_pub, :sign_object_integrity_proofs),
        else: Application.put_env(:activity_pub, :sign_object_integrity_proofs, orig)
    end)
  end

  @tag :test_instance
  test "a reply from the other instance is not forwarded back to it", context do
    alice = context[:local][:user]

    # what the receiver decided about forwarding each activity, as the forwarder tells it (a telemetry event, sent from whichever instance's process decided)
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:activity_pub, :forwarder, :decided],
      fn _event, _measurements, metadata, _ ->
        send(
          test_pid,
          {:forwarding, metadata.activity_id, metadata.activity_type, metadata.decision}
        )
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # signed by its author (FEP-8b32), as only such a reply is forwarded
    Application.put_env(:activity_pub, :sign_object_integrity_proofs, true)

    # a user on the other instance follows ours, so is a remote follower of ours, on the replier's server
    TestInstanceRepo.apply(fn ->
      assert {:ok, alice_there} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])

      assert {:ok, _follow} = Follows.follow(context[:remote][:user], alice_there)
    end)

    text = "a post to reply to #{System.unique_integer([:positive])}"

    {:ok, _post} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: text}},
        boundary: "public"
      )

    # another user there replies to it
    TestInstanceRepo.apply(fn ->
      replier = fancy_fake_user!("Replier")[:user]

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(:my, text,
                 current_user: context[:remote][:user]
               )

      assert {:ok, _reply} =
               Posts.publish(
                 current_user: replier,
                 post_attrs: %{
                   post_content: %{html_body: "a reply from over there"},
                   reply_to_id: activity.object.id
                 },
                 boundary: "public"
               )
    end)

    # passed every check (signed, a reply to our post, not ours, public) but the last: the only follower's inbox is the sender's server's
    assert_receive {:forwarding, _id, "Create", {:skip, :nobody_to_forward_to}}, 30_000
  end
end
