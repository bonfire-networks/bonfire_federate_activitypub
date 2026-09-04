defmodule Bonfire.Federate.ActivityPub.GroupIncomingPostTest do
  @moduledoc """
  A member of a REMOTE instance posting into one of OUR groups, from the payload Lemmy actually sends.

  The half of group federation that has no other coverage. Every other group test either drives our own outgoing side or ingests an `Announce{Create{Page}}` relayed by a remote community we follow. Neither exercises this, which is a bare `Create{Page}` delivered to our group's inbox by the author's own server, and it is how a group we host gets used at all: a Lemmy user opens the community and writes a post.

  The fixture is a verbatim capture from `discuss.tchncs.de` during the 2026-09-04 live run, with hosts rewritten. Lemmy names the group three times over, in `audience` on the activity, in `audience` and `to` on the object, and in the activity's `cc`, so nothing about attribution here is ambiguous or needs guessing.

  Accepting such a post means four things, which is what these assert: it becomes a local object, it keeps the title and body Lemmy sent, it is filed as the GROUP's rather than as a stray post, and the group then announces it onward. That last one is what the group's followers elsewhere see, so a group that skips it looks like it dropped the post.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @author "https://lemmy.local/u/mayel"
  @post "https://lemmy.local/post/67072971"
  @comment "https://lemmy.local/comment/27985030"
  @group_placeholder "https://bonfire.local/pub/group/GROUP"

  setup do
    mock(fn
      %{method: :get, url: @author} ->
        json(APSimulate.actor_json(@author, "mayel"))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    incoming =
      Path.join([@fixtures, "lemmy", "create_page_to_group.json"])
      |> File.read!()
      |> String.replace(@group_placeholder, actor.ap_id)
      |> Jason.decode!()

    %{creator: creator, group: group, group_ap_id: actor.ap_id, incoming: incoming}
  end

  test "a post sent from a remote instance into our group is created locally", %{
    incoming: incoming
  } do
    assert {:ok, _} = Transformer.handle_incoming(incoming)

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @post),
           "the post was not stored at all"

    assert is_binary(pointer_id),
           "stored as an AP object with no local pointer, so it exists to federation but not to Bonfire"
  end

  test "and is filed as the group's, rather than as a stray post", %{
    creator: creator,
    group: group,
    incoming: incoming
  } do
    assert {:ok, _} = Transformer.handle_incoming(incoming)
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @post)

    assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, pointer_id,
             by: group,
             current_user: creator
           ),
           "Lemmy named the group in `audience` on both the activity and the object, and in `to`/`cc`, so there is nothing left to infer"
  end

  test "keeping the title and body Lemmy sent", %{incoming: incoming} do
    assert {:ok, _} = Transformer.handle_incoming(incoming)
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @post)

    assert {:ok, post} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true)

    assert e(post, :post_content, :name, nil) == "a post from lemmy to a bonfire group",
           "a Lemmy thread starter carries its title in `name`"

    assert e(post, :post_content, :html_body, nil) =~ "hello"
  end

  test "and the group announces it onward, as it does for a local post", %{
    group: group,
    group_ap_id: group_ap_id,
    incoming: incoming
  } do
    assert {:ok, _} = Transformer.handle_incoming(incoming)

    assert {:ok, %{pointer_id: pointer_id} = ap_object} =
             ActivityPub.Object.get_cached(ap_id: @post)

    # the local half first, so a failure below says whether the group's auto-boost did not happen or happened without federating
    assert Bonfire.Social.Boosts.get!(group, pointer_id),
           "the group did not boost the post locally"

    assert %{data: announce} = ActivityPub.Object.get_existing_announce(group_ap_id, ap_object),
           "a group that relays only what its own members write is invisible to the followers of everyone else"

    assert announce["type"] == "Announce"
  end

  # The case that carries most of a group's traffic: of the 40 most recent statuses mastodon.social held for a Lemmy community, 34 were boosts of COMMENTS and 6 of posts. It also arrives differently (a `Note` with `inReplyTo`, where a thread starter is a `Page`) and it can reach the group by two routes at once, the `audience` it names and the thread it replies into, so it is worth asserting separately rather than assuming the post case covers it.
  describe "a comment from a remote instance, on a post in our group" do
    setup %{creator: creator, group: group, group_ap_id: group_ap_id} do
      assert {:ok, parent} =
               Bonfire.Posts.publish(
                 current_user: creator,
                 post_attrs: %{post_content: %{html_body: "<p>a post to reply to</p>"}},
                 boundary: "public",
                 publish_in: uid(group)
               )

      {:ok, %{data: %{"id" => parent_ap_id}}} = ActivityPub.Object.get_cached(pointer: parent)
      creator_ap_id = ActivityPub.Actor.get_cached!(pointer: creator).ap_id

      incoming =
        Path.join([@fixtures, "lemmy", "create_note_reply_in_group.json"])
        |> File.read!()
        |> String.replace(@group_placeholder, group_ap_id)
        |> String.replace("https://bonfire.local/pub/objects/PARENT", parent_ap_id)
        |> String.replace("https://bonfire.local/pub/person/AUTHOR", creator_ap_id)
        |> Jason.decode!()

      %{parent: parent, incoming_reply: incoming}
    end

    test "is created locally, as a reply to the post it answers", %{
      parent: parent,
      incoming_reply: incoming
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @comment)
      assert is_binary(pointer_id)

      assert {:ok, reply} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true)
      reply = repo().maybe_preload(reply, :replied)

      assert e(reply, :replied, :reply_to_id, nil) == uid(parent),
             "a comment that loses its parent is just a post, and the thread it belongs to is gone"
    end

    test "is filed as the group's", %{creator: creator, group: group, incoming_reply: incoming} do
      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: @comment)

      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, pointer_id,
               by: group,
               current_user: creator
             )
    end

    test "and the group announces it onward", %{
      group: group,
      group_ap_id: group_ap_id,
      incoming_reply: incoming
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert {:ok, %{pointer_id: pointer_id} = ap_object} =
               ActivityPub.Object.get_cached(ap_id: @comment)

      assert Bonfire.Social.Boosts.get!(group, pointer_id),
             "the group did not boost the comment locally"

      assert %{data: announce} = ActivityPub.Object.get_existing_announce(group_ap_id, ap_object),
             "a group that announces only thread starters looks almost silent, and its threads look like nobody replied"

      assert announce["type"] == "Announce"
    end
  end
end
