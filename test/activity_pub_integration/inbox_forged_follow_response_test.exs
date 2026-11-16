defmodule Bonfire.Federate.ActivityPub.InboxForgedFollowResponseTest do
  @moduledoc """
  What a delivery to the shared inbox that nobody signed can do to the Follows of our users: nothing. An `Accept` or a `Reject` of a Follow changes the state of a follow only when the remote actor it names as its author really sent it, and only when that actor is the one the Follow was addressed to.

  Each forged delivery is posted to `/pub/shared_inbox` with no `Signature` header, as anyone on the internet can, and the queued jobs are run. The control of each is the same document delivered with a verified HTTP signature (faked the way the fork's controller tests do it: assign `valid_signature: true` and the signer), which does change the follow.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Social.Graph.Follows
  alias ActivityPub.Tests.ObanHelpers

  @remote_instance "https://mocked.local"
  # the actor our users follow
  @remote_actor @remote_instance <> "/users/karen"
  # a third party, who is not the one followed
  @third_party @remote_instance <> "/users/kip"
  # an actor that approves its followers by hand
  @locked_actor @remote_instance <> "/users/locked"

  setup do
    mock(fn
      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @third_party} ->
        json(Simulate.actor_json(@third_party))

      %{method: :get, url: @locked_actor} ->
        json(Simulate.actor_json(@locked_actor, "locked", %{"manuallyApprovesFollowers" => true}))

      # whatever else, including the ids of the forged activities, which nobody serves
      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @third_party)

    :ok
  end

  # a local user who asked to follow `actor_id`
  defp requested_follow(actor_id) do
    follower = fake_user!()
    {:ok, ap_follower} = ActivityPub.Federator.Adapter.get_actor_by_id(follower.id)
    {:ok, ap_followed} = ActivityPub.Actor.get_cached_or_fetch(ap_id: actor_id)
    {:ok, followed} = Bonfire.Me.Users.by_ap_id(actor_id)

    {:ok, follow} = Follows.follow(follower, followed)
    {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    assert Follows.requested?(follower, followed), "control: the follow was requested"

    %{
      follower: follower,
      followed: followed,
      follower_id: ap_follower.data["id"],
      ap_followed: ap_followed,
      follow_activity: follow_activity
    }
  end

  # a local user who follows `actor_id`, which accepted
  defp established_follow(actor_id) do
    %{follower: follower, followed: followed} = ctx = requested_follow(actor_id)

    accept =
      response("Accept", actor_id, ctx.follower_id, actor_id, "#{@remote_instance}/accepts")
      |> put_in(["object", "id"], ctx.follow_activity.data["id"])

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(accept, from_inbox: true)

    assert Follows.following?(follower, followed), "control: the follow was accepted"

    ctx
  end

  # an Accept or a Reject as a remote server sends it, with the Follow it answers written out, as Mastodon does: `author` says it is theirs, whoever really sent it
  defp response(type, author, follower_id, followed_id, id_base) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => type,
      "id" => "#{id_base}/#{System.unique_integer([:positive])}",
      "actor" => author,
      "to" => [follower_id],
      "object" => %{
        "type" => "Follow",
        "actor" => follower_id,
        "object" => followed_id
      }
    }
  end

  # posted to the shared inbox with nothing signing it, then the queued jobs are run
  defp deliver_unsigned(doc) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/activity+json")
      |> post("/pub/shared_inbox", doc)

    ObanHelpers.perform_all()
    conn
  end

  # posted to the shared inbox over a verified HTTP signature by `signer`, then the queued jobs are run
  defp deliver_signed(signer_id, doc) do
    {:ok, _signer} = ActivityPub.Actor.get_cached_or_fetch(ap_id: signer_id)

    conn =
      build_conn()
      # the signer is mapped from the key id, as the identity plug does for a known actor
      |> assign(:valid_signature, true)
      |> put_req_header("signature", "keyId=\"#{signer_id}#main-key\"")
      |> put_req_header("content-type", "application/activity+json")
      |> post("/pub/shared_inbox", doc)

    ObanHelpers.perform_all()
    conn
  end

  describe "a Reject of a follow" do
    test "control: the followed actor's own signed Reject ends a follow it accepted" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        established_follow(@remote_actor)

      doc =
        response(
          "Reject",
          @remote_actor,
          follower_id,
          @remote_actor,
          @remote_instance <> "/rejects"
        )

      assert deliver_signed(@remote_actor, doc).status == 200

      refute Follows.following?(follower, followed)
    end

    test "that nobody signed, in the name of the followed actor, does not end the follow" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        established_follow(@remote_actor)

      # sent by anyone, on a host that is not the followed actor's
      doc = response("Reject", @remote_actor, follower_id, @remote_actor, "https://evil.local/r")

      deliver_unsigned(doc)

      assert Follows.following?(follower, followed),
             "a Reject nobody signed made our user unfollow"
    end

    test "that nobody signed, in the name of a third party, does not end the follow" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        established_follow(@remote_actor)

      # the Follow it answers was not sent to the third party at all
      doc = response("Reject", @third_party, follower_id, @remote_actor, "https://evil.local/r")

      deliver_unsigned(doc)

      assert Follows.following?(follower, followed),
             "an unsigned Reject by an actor the follow was not addressed to made our user unfollow"
    end

    test "signed by a third party, naming a Follow of somebody else, does not end the follow" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        established_follow(@remote_actor)

      doc =
        response(
          "Reject",
          @third_party,
          follower_id,
          @remote_actor,
          @remote_instance <> "/rejects"
        )

      deliver_signed(@third_party, doc)

      assert Follows.following?(follower, followed),
             "a Reject by an actor the follow was not addressed to made our user unfollow"
    end
  end

  describe "an Accept of a follow" do
    test "control: the locked actor's own signed Accept completes the request" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        requested_follow(@locked_actor)

      doc =
        response(
          "Accept",
          @locked_actor,
          follower_id,
          @locked_actor,
          @remote_instance <> "/accepts"
        )

      assert deliver_signed(@locked_actor, doc).status == 200

      assert Follows.following?(follower, followed)
    end

    test "that nobody signed, in the name of the locked actor, leaves the request pending" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        requested_follow(@locked_actor)

      doc = response("Accept", @locked_actor, follower_id, @locked_actor, "https://evil.local/a")

      deliver_unsigned(doc)

      refute Follows.following?(follower, followed),
             "an Accept nobody signed completed a follow of a locked account"

      assert Follows.requested?(follower, followed), "the request is still pending"
    end

    test "that nobody signed, in the name of a third party, leaves the request pending" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        requested_follow(@locked_actor)

      # the Follow it answers was sent to the locked actor, not to the third party
      doc = response("Accept", @third_party, follower_id, @locked_actor, "https://evil.local/a")

      deliver_unsigned(doc)

      refute Follows.following?(follower, followed),
             "an unsigned Accept by an actor the follow was not addressed to completed it"

      assert Follows.requested?(follower, followed), "the request is still pending"
    end

    test "signed by a third party, naming a Follow of somebody else, leaves the request pending" do
      %{follower: follower, followed: followed, follower_id: follower_id} =
        requested_follow(@locked_actor)

      doc =
        response(
          "Accept",
          @third_party,
          follower_id,
          @locked_actor,
          @remote_instance <> "/accepts"
        )

      deliver_signed(@third_party, doc)

      refute Follows.following?(follower, followed),
             "an Accept by an actor the follow was not addressed to completed it"

      assert Follows.requested?(follower, followed), "the request is still pending"
    end
  end
end
