defmodule Bonfire.Federate.ActivityPub.GroupIncomingObjectTypesTest do
  @moduledoc """
  Content that is NOT a post, sent from a remote instance into one of our groups.

  `group_incoming_post_test.exs` covers the Lemmy thread starter, which routes to `Bonfire.Posts` and is filed into the group there. But the ingest dispatch picks a handler by object type, and only some of those handlers derive the group the activity names: a poll goes to `Bonfire.Poll.Questions`, a Lemmy image post to `Bonfire.Files.Media`, and anything unrecognised to `Bonfire.Social.APActivities`. An `Article` is fine because `Bonfire.Articles.ap_receive_activity/4` delegates straight to `Posts`.

  A group that files the posts it is sent but silently drops the polls and images is worse than one that drops everything, because the gap is invisible from both ends: the sender sees a delivery accepted, and the group's members see a feed that looks complete. Each type below therefore asserts two things — that the object arrives at all, which proves the ingest path works and makes the second assertion meaningful, and that it is filed as the group's.

  The `Create` wrappers are built here rather than captured, because the captures we hold of these types are addressed to followers or relayed by a community rather than sent INTO a group. The objects inside them are verbatim: the poll is a Pleroma capture, the image post a Lemmy one. Addressing follows what Lemmy sends for a post into a group, naming the group in `audience` on both activity and object and in `to`/`cc` (see `group_incoming_post_test.exs`).
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @fixtures Path.join([__DIR__, "..", "fixtures"])

  @poll_author "https://patch.local/users/rin"
  @image_author "https://lemmy2.local/u/homesweethomeMrL"
  @article_author "https://nodebb.local/uid/47"
  @other_author "https://other.local/users/dave"

  setup do
    mock(fn
      %{method: :get, url: @poll_author} ->
        json(APSimulate.actor_json(@poll_author, "rin"))

      %{method: :get, url: @image_author} ->
        json(APSimulate.actor_json(@image_author, "homesweethomeMrL"))

      %{method: :get, url: @article_author} ->
        json(APSimulate.actor_json(@article_author, "nodebbuser"))

      %{method: :get, url: @other_author} ->
        json(APSimulate.actor_json(@other_author, "dave"))

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

    %{creator: creator, group: group, group_ap_id: actor.ap_id}
  end

  defp fixture(path) do
    @fixtures |> Path.join(path) |> File.read!() |> Jason.decode!()
  end

  # The addressing Lemmy uses for a post into a group: the group named in `audience` on the activity AND the object, and in `to`/`cc`, so nothing has to be inferred from the thread.
  defp create_into_group(object, actor, group_ap_id) do
    public = ActivityPub.Config.public_uri()

    object =
      object
      |> Map.merge(%{
        "attributedTo" => actor,
        "audience" => group_ap_id,
        "to" => [public, group_ap_id],
        "cc" => []
      })

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Create",
      "id" => "#{object["id"]}/activity",
      "actor" => actor,
      "audience" => group_ap_id,
      "to" => [public, group_ap_id],
      "cc" => [group_ap_id],
      "object" => object
    }
  end

  defp filed_as_group?(pointer_id, group, creator) do
    Bonfire.Social.FeedLoader.feed_contains?(:user_activities, pointer_id,
      by: group,
      current_user: creator
    )
  end

  # Being filed locally and being relayed are different things, and the second fails silently: if `Acts.Federate` never tied the incoming AP object to the new record, the auto-boost still creates a local boost while the `Announce` resolves to nothing. From the outside that group looks like it dropped the object.
  defp announce_by_group(object_id, group_ap_id) do
    assert {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: object_id)

    ActivityPub.Object.get_existing_announce(group_ap_id, ap_object)
  end

  # The positive control for the whole file. `Bonfire.Articles.ap_receive_activity/4` delegates to `Posts`, so an Article should already be filed — which is worth ASSERTING rather than reasoning about, both because NodeBB's thread starters are Articles and because it proves `filed_as_group?/3` can return true at all. Without it, three failures below could equally mean a broken helper.
  describe "an article" do
    setup %{group_ap_id: group_ap_id} do
      object =
        fixture("nodebb/announce_create_article.json")
        |> get_in(["object", "object"])

      %{
        incoming: create_into_group(object, @article_author, group_ap_id),
        object_id: object["id"]
      }
    end

    test "arrives", %{incoming: incoming, object_id: object_id} do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert is_binary(pointer_id)
    end

    test "is filed as the group's", %{
      incoming: incoming,
      object_id: object_id,
      group: group,
      creator: creator
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert filed_as_group?(pointer_id, group, creator),
             "an Article routes through `Posts`, which derives the group from the addressing — if this fails, the filing is broken for every type rather than only the ones below"
    end

    test "and the group announces it onward", %{
      incoming: incoming,
      object_id: object_id,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert %{data: %{"type" => "Announce"}} = announce_by_group(object_id, group_ap_id),
             "control for the announce assertions below: an Article already relays, so a failure here means the relay is broken generally"
    end
  end

  describe "a poll" do
    setup %{group_ap_id: group_ap_id} do
      object = fixture("poll_attachment.json") |> Map.drop(["@context"])

      %{
        incoming: create_into_group(object, @poll_author, group_ap_id),
        object_id: object["id"]
      }
    end

    test "arrives", %{incoming: incoming, object_id: object_id} do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert is_binary(pointer_id),
             "control: a poll sent into a group has to become a local object before it can be filed as anything"

      # Which handler took it decides which machinery could have filed it: `Questions` runs an epic with the Tag act, the `APActivities` fallback runs none. Pinned because the two are indistinguishable from the assertion above.
      assert {:ok, object} = Bonfire.Common.Needles.get(pointer_id, skip_boundary_check: true)

      assert Bonfire.Common.Types.object_type(object) == Bonfire.Poll.Question,
             "a Question should become a poll, not fall back to an APActivity, got #{inspect(Bonfire.Common.Types.object_type(object))}"
    end

    test "is filed as the group's", %{
      incoming: incoming,
      object_id: object_id,
      group: group,
      creator: creator
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert filed_as_group?(pointer_id, group, creator),
             "the activity names the group in `audience` and `to`, so a poll asked of a group belongs to it as much as a post does"
    end

    test "and the group announces it onward", %{
      incoming: incoming,
      object_id: object_id,
      group: group,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      # splits the two halves: a missing boost means the auto-boost never happened, a boost without an `Announce` means it happened but did not federate
      assert Bonfire.Social.Boosts.get!(group, pointer_id),
             "the group did not boost the poll locally, so the relay never had anything to send"

      assert %{data: %{"type" => "Announce"}} = announce_by_group(object_id, group_ap_id),
             "a poll filed but never relayed is invisible to the group's followers, which is what happens when `Acts.Federate` gets no `ap_object` to tie it to"
    end
  end

  describe "an image post" do
    setup %{group_ap_id: group_ap_id} do
      object =
        fixture("lemmy/announce_create_page_image.json")
        |> get_in(["object", "object"])

      %{
        incoming: create_into_group(object, @image_author, group_ap_id),
        object_id: object["id"]
      }
    end

    test "arrives", %{incoming: incoming, object_id: object_id} do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert is_binary(pointer_id),
             "control: a Lemmy image post routes to Media rather than Posts, so prove it lands before asking where it was filed"
    end

    test "is filed as the group's", %{
      incoming: incoming,
      object_id: object_id,
      group: group,
      creator: creator
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert filed_as_group?(pointer_id, group, creator),
             "image posts are what a picture community is FOR, so a group that files text and drops images has nothing in it"
    end

    test "and the group announces it onward", %{
      incoming: incoming,
      object_id: object_id,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert %{data: %{"type" => "Announce"}} = announce_by_group(object_id, group_ap_id),
             "Media runs no epic, so nothing here relays it unless the tagging path also boosts and federates"
    end
  end

  # The catch-all. A group federating publicly will be sent types nobody here has written a handler for, and the question is whether the fallback keeps the group attribution or throws it away with everything else it does not understand.
  describe "an object of a type we have no handler for" do
    setup %{group_ap_id: group_ap_id} do
      object = %{
        "id" => "https://other.local/objects/some-unhandled-thing",
        "type" => "Recipe",
        "name" => "something we do not model",
        "content" => "<p>but which was addressed to the group anyway</p>",
        "published" => "2026-09-07T12:00:00Z"
      }

      %{
        incoming: create_into_group(object, @other_author, group_ap_id),
        object_id: object["id"]
      }
    end

    test "arrives", %{incoming: incoming, object_id: object_id} do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert is_binary(pointer_id),
             "control: the fallback should keep an unrecognised object rather than discard it"
    end

    test "is filed as the group's", %{
      incoming: incoming,
      object_id: object_id,
      group: group,
      creator: creator
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: object_id)

      assert filed_as_group?(pointer_id, group, creator),
             "we may not understand what it is, but the sender was unambiguous about where it goes"
    end

    test "and the group announces it onward", %{
      incoming: incoming,
      object_id: object_id,
      group_ap_id: group_ap_id
    } do
      assert {:ok, _} = Transformer.handle_incoming(incoming)

      assert %{data: %{"type" => "Announce"}} = announce_by_group(object_id, group_ap_id),
             "the fallback keeps the object and files it, so the group should relay it like anything else it holds"
    end
  end

  # The other side of deriving the group ONCE for every handler: the derivation now also meets objects that can never belong to one. A reply naming no group falls back to the group of the thread it answers, and the thread here is a DM, whose parent is a `Message`, a schema with no `tree` assoc at all. Preloading an assoc a schema does not have raises rather than answering nothing (Bonfire treats it as a bug at the call site), and this one raises inside the inbox request, so the reply is answered with a 500 and never delivered. Which is how the message dance test found it.
  test "a reply to a message belongs to no group, and says so without failing", %{
    creator: creator
  } do
    assert {:ok, remote_author} = AdapterUtils.get_or_fetch_and_create_by_uri(@other_author)

    assert {:ok, dm} =
             Bonfire.Messages.send(
               creator,
               %{post_content: %{html_body: "<p>a message, not a group post</p>"}},
               remote_author
             )

    assert {:ok, %{data: %{"id" => dm_ap_id}}} = ActivityPub.Object.get_cached(pointer: dm)

    creator_ap_id = ActivityPub.Actor.get_cached!(pointer: creator).ap_id
    reply_id = "#{@other_author}/statuses/reply-to-a-dm"

    incoming = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type" => "Create",
      "id" => "#{reply_id}/activity",
      "actor" => @other_author,
      "to" => [creator_ap_id],
      "cc" => [],
      "object" => %{
        "id" => reply_id,
        "type" => "Note",
        "attributedTo" => @other_author,
        "content" => "<p>answering you privately</p>",
        "inReplyTo" => dm_ap_id,
        "to" => [creator_ap_id],
        "cc" => []
      }
    }

    assert {:ok, _} = Transformer.handle_incoming(incoming)

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: reply_id)

    assert is_binary(pointer_id),
           "a private reply is delivered like any other, and asking which group it is in must not be able to lose it"
  end
end
