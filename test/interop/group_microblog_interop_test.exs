defmodule Bonfire.Federate.ActivityPub.GroupMicroblogInteropTest do
  @moduledoc """
  What microblog consumers send us about group content, and whether we read it correctly.

  Mastodon, Akkoma, GoToSocial and the Misskey family have no group model at all. They see a group thread as ordinary statuses by their original authors, and they interact with it as such: a boost is `Announce` with a **bare object id**, a reply is `Create{Note}` with `inReplyTo` and **no `audience`**. Neither says anything about the group.

  Both shapes are ambiguous in a way that matters here:

  | shape | the group reading | the microblog reading |
  |---|---|---|
  | `Announce` + bare id | Friendica's group relay, which announces exactly this way | a person boosted a post |
  | `Create{Note}` + `inReplyTo` | a reply belonging to the group's thread | a reply to a status |

  What separates them is the ACTOR, not the payload: a `Group` announcing is a relay, a `Person` announcing is a boost. Getting that wrong in either direction is bad — a boost read as a relay would re-attribute someone's post to the booster, and a relay read as a boost would leave group content unattributed.

  Fixtures are real captures from a live public outbox (2026-09-02), hosts rewritten. ⚠️ The AP lib carries its own Mastodon fixtures, but they are 2018-era and predate `context`, `contentMap`, `likes`, `replies`, `shares` and `interactionPolicy`.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @community "https://lemmy.local/c/technology"
  @booster "https://mastodon.local/users/Gargron"

  setup do
    announce = fixture("lemmy", "announce_create_page_text.json")
    announced = announce["object"]["object"]

    served =
      %{
        @community => fixture("lemmy", "community_actor.json") |> Map.put("id", @community),
        @booster => person_actor(@booster),
        announced["id"] => announced,
        announced["attributedTo"] => person_actor(announced["attributedTo"])
      }

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    # the group thread these consumers will interact with. `handle_incoming/1` alone: it hands off to
    # the adapter itself for this shape, and calling `receive_activity/1` after it processes the
    # announce a second time, which the boost rejects as a repeat
    {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(announce)

    {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: announced["id"])

    refute is_nil(pointer_id),
           "the announced post must have a local record, or these tests are interacting with nothing"

    {:ok,
     post: Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true),
     post_ap_id: announced["id"],
     group: AdapterUtils.get_character_by_ap_id!(@community)}
  end

  test "a person's boost of a group post is a boost, not a group relay", %{
    post: post,
    post_ap_id: post_ap_id,
    group: group
  } do
    boost = fixture("mastodon", "announce_boost.json") |> Map.put("object", post_ap_id)

    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(boost)

    booster = AdapterUtils.get_character_by_ap_id!(@booster)

    assert Bonfire.Social.Boosts.boosted?(booster, post),
           "a bare-id Announce from a Person is an ordinary boost, and the same shape a group relay uses"

    assert Bonfire.Social.Boosts.boosted?(group, post),
           "and it must not displace the GROUP's own relay of that post, which is what attributes it to the group"
  end

  test "a reply carrying no audience still threads into the group's thread", %{
    post: post,
    post_ap_id: post_ap_id
  } do
    replied = receive_reply(post_ap_id) |> repo().maybe_preload(:replied)

    assert e(replied, :replied, :reply_to_id, nil) == uid(post),
           "the reply names the group post, so it belongs to that thread"

    assert e(replied, :replied, :thread_id, nil) ==
             e(repo().maybe_preload(post, :replied), :replied, :thread_id, nil) || uid(post),
           "and it joins that thread rather than starting one of its own"
  end

  # Threading is local plumbing; this is what members of the group actually see. A remote reply that
  # threads but never reaches the group's feed would mean people browsing the group miss every reply
  # from a microblog consumer, which is most of the fediverse.
  # The LOCAL reply is the control: if replies do not show in a group's feed at all, then the remote
  # one behaving the same way is consistency, not a federation gap. Whatever a local reply does, a
  # remote reply to the same thread should do.
  test "a remote reply reaches the group's feed exactly as a local reply does", %{
    post: post,
    post_ap_id: post_ap_id,
    group: group
  } do
    local_member = fake_user!()

    # what the UI actually submits when someone replies inside a group thread: the thread as
    # `context_id` and the group mentioned (`threads_live_handler.ex` sets `context_id: thread_id`
    # and `mentions: [published_in_id]`). Replying without either would be a control for a case the
    # product does not have, and would say nothing about whether the remote reply is treated worse.
    thread_id = e(repo().maybe_preload(post, :replied), :replied, :thread_id, nil) || uid(post)

    assert {:ok, local_reply} =
             Bonfire.Posts.publish(
               current_user: local_member,
               post_attrs: %{
                 post_content: %{html_body: "<p>a local reply in the same thread</p>"},
                 reply_to_id: uid(post),
                 context_id: thread_id,
                 mentions: [uid(group)]
               },
               boundary: "public",
               context_id: thread_id,
               mentions: [uid(group)]
             )

    # `feed_contains?/3` answers with the matching ACTIVITY rather than a boolean, so coerce before
    # comparing, or the comparison is between a struct and `false`
    in_feed? = fn object ->
      !!Bonfire.Social.FeedLoader.feed_contains?(:user_activities, object,
        by: group,
        current_user: group
      )
    end

    remote_reply = receive_reply(post_ap_id)

    assert in_feed?.(remote_reply) == in_feed?.(local_reply),
           "a reply from a microblog consumer should reach the group's feed on the same terms as a local reply (local: #{inspect(in_feed?.(local_reply))}, remote: #{inspect(in_feed?.(remote_reply))})"

    # Pinning WHICH way, since the equality above holds for either. Update this line in the same
    # change that alters the behaviour, rather than letting the equality silently absorb it.
    assert in_feed?.(local_reply),
           "a local reply carrying the thread context and a mention of the group reaches its feed"
  end

  # a captured Mastodon reply, re-pointed at the group thread this module set up
  defp receive_reply(post_ap_id) do
    reply =
      fixture("mastodon", "create_reply.json")
      |> put_in(["object", "inReplyTo"], post_ap_id)
      |> put_in(["object", "inReplyToAtomUri"], post_ap_id)

    refute reply["object"]["audience"],
           "a microblog reply says nothing about the group, which is the whole point of these tests"

    assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(reply)

    assert {:ok, %{pointer_id: pointer_id}} =
             ActivityPub.Object.get_cached(ap_id: reply["object"]["id"])

    refute is_nil(pointer_id), "the reply should have become a local record"

    Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)
  end

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  # `Simulate.actor_json/1` only answers for a handful of fixed ids, so rebase one onto whichever
  # actor a fixture names, the same way the other interop modules do
  defp person_actor(ap_id) do
    Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => "Person",
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end
end
