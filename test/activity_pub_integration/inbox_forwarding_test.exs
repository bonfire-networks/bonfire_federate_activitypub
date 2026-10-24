defmodule Bonfire.Federate.ActivityPub.InboxForwardingTest do
  @moduledoc """
  Inbox forwarding (ActivityPub 7.1.2), with our data: a remote reply in one of our users' threads, signed by its author, is passed on exactly as it reached us to the remote followers of our users in that thread (`ActivityPub.Federator.Forwarder`, whose own rules, such as which inboxes are left out and what is never forwarded, `ActivityPub.Federator.ForwarderTest` tests).

  Whose followers (`Adapter.forward_to_followers_of_actors/2`): the local authors of the post replied to and of its ancestors, and the local boosters and quoters of the post, in no particular order. Or `:relayed_by_group` when a group we host relays the activity already, by the group relay's own rule, and then it is not forwarded.

  The posts are made as our users make them (`Posts.publish`), since the adapter only knows a post that way.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  use Oban.Testing, repo: Bonfire.Common.Repo

  import Tesla.Mock
  import ActivityPub.Test.IntegrityProofHelpers

  alias Bonfire.Posts
  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Quotes
  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Forwarder
  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Worker.ReceiverHelpers
  alias ActivityPub.Federator.Workers.PublisherWorker
  alias ActivityPub.Safety.IntegrityProofs

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @replier "https://replier.local/users/rita"
  # two followers of our users on different servers, so each has an inbox of its own, and a third on the first one's server, sharing its inbox
  @follower "https://follower.local/users/fern"
  @other_follower "https://other.local/users/olive"
  @colleague "https://follower.local/users/flo"
  @group_placeholder "https://bonfire.local/pub/group/GROUP"
  @public "https://www.w3.org/ns/activitystreams#Public"
  @context [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/data-integrity/v2"
  ]

  setup do
    key = new_key(:ed25519)

    actors = %{
      @replier =>
        APSimulate.actor_json(@replier, "rita")
        |> Map.put("assertionMethod", [multikey(@replier, key)]),
      @follower => APSimulate.actor_json(@follower, "fern"),
      @other_follower => APSimulate.actor_json(@other_follower, "olive"),
      @colleague => APSimulate.actor_json(@colleague, "flo")
    }

    mock_remotes(actors)

    # known before anything it sends is handled, as checking the HTTP signature of a delivery to our inbox fetches the actor
    assert {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @replier)

    alice = fake_user!()
    post = publish(alice)

    %{key: key, actors: actors, alice: alice, post: post, post_id: ap_object(post).data["id"]}
  end

  # the remote servers: their actors, and an inbox that takes deliveries, which are sent to `test_pid` when given
  defp mock_remotes(actors, test_pid \\ nil) do
    mock(fn
      %{method: :get, url: url} when is_map_key(actors, url) ->
        json(actors[url])

      %{method: :post, url: url, body: body, headers: headers} ->
        if test_pid, do: send(test_pid, {:posted, url, body, headers})
        %Tesla.Env{status: 202, body: ""}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  defp publish(user, opts \\ []) do
    {:ok, post} =
      [
        current_user: user,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "<p>a post of ours</p>"}}
      ]
      |> Keyword.merge(opts)
      |> Posts.publish()

    post
  end

  defp ap_object(%{id: id}) do
    {:ok, object} = ActivityPub.Object.get_cached(pointer: id)
    object
  end

  defp ap_id(user) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user)
    actor.ap_id
  end

  defp inbox(actor_id),
    do: actor_id |> URI.parse() |> Map.merge(%{path: "/inbox"}) |> URI.to_string()

  # `follower` follows our `user`, from their server
  defp followed_from_elsewhere(user, follower \\ @follower) do
    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "@context" => "https://www.w3.org/ns/activitystreams",
               "id" => "#{follower}/follows/#{System.unique_integer([:positive])}",
               "type" => "Follow",
               "actor" => follower,
               "object" => ap_id(user)
             })
  end

  # the replier's signed reply to `in_reply_to`
  defp reply(%{key: key}, in_reply_to, extra \\ %{}) do
    n = System.unique_integer([:positive])

    %{
      "@context" => @context,
      "id" => "#{@replier}/activities/#{n}",
      "type" => "Create",
      "actor" => @replier,
      "to" => [@public],
      "object" => %{
        "id" => "#{@replier}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => @replier,
        "content" => "<p>a reply</p>",
        "inReplyTo" => in_reply_to,
        "to" => [@public]
      }
    }
    |> Map.merge(extra)
    |> sign(key)
  end

  # the replier's signed `type` (an `Update` or a `Delete`) of `object`
  defp signed(%{key: key}, type, object) do
    %{
      "@context" => @context,
      "id" =>
        "#{@replier}/activities/#{String.downcase(type)}-#{System.unique_integer([:positive])}",
      "type" => type,
      "actor" => @replier,
      "to" => [@public],
      "object" => object
    }
    |> sign(key)
  end

  # a reply we hold already, as its first delivery left it
  defp held_reply(context, in_reply_to) do
    received = reply(context, in_reply_to)

    assert {:ok, _} =
             Transformer.handle_incoming(received,
               from_inbox: true,
               authenticated: :integrity_proof,
               signed_by: @replier
             )

    received["object"]
  end

  # delivered to our inbox over the replier's verified HTTP signature, as the receiver worker gets it
  defp deliver(received) do
    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => received,
          "signed_by" => @replier,
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :verified
    )
  end

  # who it goes to, asked as the receiver asks it, over the replier's HTTP signature, which does not cover what we pass on: a `{:skip, reason}` says why nothing is queued
  defp recipients(received),
    do:
      Forwarder.recipients(received,
        from_inbox: true,
        authenticated: :http_signature,
        signed_by: @replier
      )

  # the queued forwards of `received`
  defp forwards(received) do
    for %{args: %{"op" => "publish_one", "params" => params}} = job <-
          all_enqueued(worker: PublisherWorker),
        Jason.decode!(params["json"])["id"] == received["id"],
        do: job
  end

  defp forward_to(post, received),
    do: Adapter.forward_to_followers_of_actors(ap_object(post), received)

  # in no particular order
  defp ap_ids(actors) when is_list(actors), do: actors |> Enum.map(& &1.ap_id) |> Enum.sort()

  describe "the adapter names" do
    test "the local authors of the post and of its ancestors",
         %{alice: alice, post: post} = context do
      bob = fake_user!()

      bobs_reply =
        publish(bob,
          post_attrs: %{
            post_content: %{html_body: "<p>a reply of ours</p>"},
            reply_to_id: post.id
          }
        )

      received = reply(context, ap_object(bobs_reply).data["id"])

      assert ap_ids(forward_to(bobs_reply, received)) == Enum.sort([ap_id(bob), ap_id(alice)])
    end

    test "not a remote author up the thread", %{alice: alice} = context do
      parent = held_reply(context, context.post_id)
      {:ok, held} = ActivityPub.Object.get_cached(ap_id: parent["id"])

      assert ap_ids(Adapter.forward_to_followers_of_actors(held, reply(context, parent["id"]))) ==
               [ap_id(alice)]
    end

    test "the local boosters and quoters of the post", %{alice: alice, post: post} = context do
      booster = fake_user!()
      assert {:ok, _} = Boosts.boost(booster, post)

      quoter = fake_user!()
      quote_post = publish(quoter, quotes: [post])
      assert {:ok, _} = Quotes.accept_quote(quote_post, post, current_user: alice)

      assert ap_ids(forward_to(post, reply(context, context.post_id))) ==
               Enum.sort([ap_id(alice), ap_id(booster), ap_id(quoter)])
    end

    test "nobody for a post with nothing of ours up its thread", context do
      remote_post = reply(context, nil) |> update_in(["object"], &Map.delete(&1, "inReplyTo"))
      assert {:ok, _} = Transformer.handle_incoming(remote_post)
      {:ok, held} = ActivityPub.Object.get_cached(ap_id: remote_post["object"]["id"])

      assert Adapter.forward_to_followers_of_actors(held, reply(context, held.data["id"])) == []
    end
  end

  # who else gets a copy, by what the adapter names; the rest of who gets one, and who does not, is the library's (`ActivityPub.Federator.ForwarderTest`)
  describe "a signed reply to a post of ours" do
    setup %{alice: alice} do
      followed_from_elsewhere(alice)
      :ok
    end

    test "further down the thread, a reply to a remote reply, goes to the post's author's followers too",
         context do
      parent = held_reply(context, context.post_id)

      assert {:ok, %{inboxes: inboxes}} = recipients(reply(context, parent["id"]))
      assert inbox(@follower) in inboxes
    end

    test "goes to the remote followers of a local booster of the post too",
         %{alice: alice, post: post} = context do
      booster = fake_user!()
      assert {:ok, _} = Boosts.boost(booster, post)
      followed_from_elsewhere(booster, @colleague)

      assert {:ok, %{inboxes: inboxes, signer: signer}} =
               recipients(reply(context, context.post_id))

      assert inbox(@colleague) in inboxes
      assert signer.ap_id in [ap_id(alice), ap_id(booster)]
    end
  end

  describe "a group we host relays it, so the adapter says :relayed_by_group" do
    setup do
      creator = fake_user!()
      group = Simulate.fake_group!(creator)

      assert :ok =
               Bonfire.Classify.Boundaries.replace(group, creator, %{
                 membership: "open",
                 visibility: "global",
                 participation: "anyone",
                 default_content_visibility: "public"
               })

      {:ok, group_actor} = ActivityPub.Actor.get_cached(pointer: group)
      %{group_ap_id: group_actor.ap_id}
    end

    test "for a reply addressed to the group, which its auto-boost relays",
         %{post: post, group_ap_id: group_ap_id} = context do
      received =
        reply(context, context.post_id, %{"audience" => group_ap_id, "cc" => [group_ap_id]})

      assert forward_to(post, received) == :relayed_by_group
    end

    test "so such a reply, delivered to our inbox, is not forwarded as well",
         %{alice: alice, group_ap_id: group_ap_id} = context do
      # the same as a reply that is forwarded ("delivered to our inbox" below), but for the group it is addressed to
      followed_from_elsewhere(alice)

      received =
        reply(context, context.post_id, %{"audience" => group_ap_id, "cc" => [group_ap_id]})

      assert {:skip, :relayed_by_group} = recipients(received)
      assert {:ok, _} = deliver(received)
      assert forwards(received) == []
    end

    test "for an edit of a post in the group, which the group announces",
         %{group_ap_id: group_ap_id} = context do
      incoming =
        Path.join([@fixtures, "lemmy", "create_page_to_group.json"])
        |> File.read!()
        |> String.replace(@group_placeholder, group_ap_id)
        |> Jason.decode!()

      assert {:ok, _} = Transformer.handle_incoming(incoming)
      {:ok, in_group} = ActivityPub.Object.get_cached(ap_id: incoming["object"]["id"])

      update =
        %{
          "@context" => @context,
          "id" => "#{@replier}/activities/update-#{System.unique_integer([:positive])}",
          "type" => "Update",
          "actor" => incoming["actor"],
          "to" => incoming["to"],
          "cc" => incoming["cc"],
          "audience" => group_ap_id,
          "object" => Map.put(incoming["object"], "content", "<p>an edit</p>")
        }
        |> sign(context.key)

      assert Adapter.forward_to_followers_of_actors(in_group, update) == :relayed_by_group
    end
  end

  describe "delivered to our inbox" do
    setup %{alice: alice} do
      for follower <- [@follower, @other_follower], do: followed_from_elsewhere(alice, follower)
      :ok
    end

    test "a signed reply is queued for each inbox, exactly as received, signed as our user",
         %{alice: alice} = context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)

      forwards = forwards(received)

      assert forwards |> Enum.map(& &1.args["params"]["inbox"]) |> Enum.sort() ==
               Enum.sort([inbox(@follower), inbox(@other_follower)])

      for %{args: %{"params" => params}} <- forwards do
        assert Jason.decode!(params["json"]) == received
        assert params["actor_ap_id"] == ap_id(alice)
      end
    end

    test "each queued forward is posted to its inbox as received, still carrying the replier's proof, in a request with our user's HTTP signature",
         %{alice: alice} = context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)

      mock_remotes(context.actors, self())
      for %{args: args} <- forwards(received), do: perform_job(PublisherWorker, args)

      for inbox <- [inbox(@follower), inbox(@other_follower)] do
        assert_received {:posted, ^inbox, body, headers}
        assert Jason.decode!(body) == received

        # the body's FEP-8b32 proof is the replier's, untouched, so the receiver can trust the reply came from them
        assert IntegrityProofs.verify(Jason.decode!(body)) == {:ok, @replier}

        # the request's HTTP signature, in either format, is our user's, who passes it on
        http_signature =
          for {name, value} <- headers, name in ["signature", "signature-input"], do: value

        assert http_signature != []
        assert Enum.any?(http_signature, &String.contains?(&1, ap_id(alice)))
        refute Enum.any?(http_signature, &String.contains?(&1, @replier))
      end
    end

    test "a reply that is refused is not forwarded", context do
      # an activity of a deactivated actor's is refused when it is stored
      {:ok, replier} = ActivityPub.Actor.get_cached(ap_id: @replier)
      ActivityPub.Actor.deactivate(replier)

      received = reply(context, context.post_id)
      refute match?({:ok, _}, deliver(received))

      assert forwards(received) == []
    end

    test "a reply delivered again is not forwarded again", context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)
      first = length(forwards(received))
      assert first > 0

      deliver(received)

      assert length(forwards(received)) == first
    end

    test "a Delete of a reply is forwarded, though handling it takes the reply away", context do
      received = reply(context, context.post_id)
      assert {:ok, _} = deliver(received)

      delete = signed(context, "Delete", received["object"]["id"])
      assert {:ok, _} = deliver(delete)

      assert inbox(@follower) in Enum.map(forwards(delete), & &1.args["params"]["inbox"])
    end
  end
end
