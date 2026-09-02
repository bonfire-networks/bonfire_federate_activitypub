defmodule Bonfire.Federate.ActivityPub.ThreadiverseModerationTest do
  @moduledoc """
  What a threadiverse community sends when its moderators act, and what we currently do with it.

  Unlike the post fixtures next door, these are NOT outbox captures: a community outbox only ever holds post announces, because Lemmy builds it from a `PostQuery`. They come from Lemmy's own committed test assets (`crates/apub/apub/assets/lemmy/activities/`), which its deserialization tests run against, so they are authoritative rather than approximations. Only hostnames were rewritten.

  The five shapes, and what each is for:

  | fixture | type | carries |
  |---|---|---|
  | `mod_remove_note.json` | `Delete` | `summary` = the removal reason |
  | `mod_lock_page.json` | `Lock` | `summary` = the lock reason |
  | `mod_flag_page.json` | `Flag` | `summary` = the report reason |
  | `mod_add_mod.json` | `Add` | `target` = the `/moderators` collection |
  | `mod_remove_mod.json` | `Remove` | `target` = the `/moderators` collection |

  Tests that assert on the payloads are green: they record what this family sends, which is the point of a fixture. Tests that assert on our handling are tagged `:todo` and are the spec for the moderation gaps the Lemmy coverage audit found.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  @fixtures Path.join([__DIR__, "..", "fixtures", "lemmy"])
  @community "http://lemmy.local/c/main"

  # Every one of these activities names a moderator, a community and a target object, and the handler fetches them before it does anything else. Without this the specs below fail on a missing mock, which would say nothing about whether we handle the activity.
  setup do
    served =
      %{@community => community_actor(@community)}
      |> Map.merge(
        Map.new(
          [
            "http://lemmy.local/u/lemmy_alpha",
            "http://lemmy.local/u/lemmy_beta",
            "http://lemmy2.local/u/lemmy_alpha"
          ],
          &{&1, person_actor(&1)}
        )
      )

    # a report names a post, and reporting one we have never seen tests nothing about the report:
    # bring one in the normal way first, via the community's announce.
    # Both kinds, because they are different objects locally: a self-post becomes a `Post`, while a
    # link post becomes `Bonfire.Files.Media` (pinned next door in `threadiverse_interop_test.exs`),
    # which carries the `replied` mixin and so has a thread of its own. Link posts are most of what
    # Lemmy federates, so moderating one is the case that matters most
    announce = fixture("announce_create_page.json")
    text_announce = fixture("announce_create_page_text.json")
    reported = announce["object"]["object"]
    text_post = text_announce["object"]["object"]

    # a moderator ON THE ANNOUNCING COMMUNITY'S host, so it is same-origin with the group and
    # therefore has standing. Derived from the announce rather than hardcoded, because Lemmy's assets
    # use `http://` while its captured outbox uses `https://`, and an actor we do not serve fails as
    # "unresolvable actor" rather than as "refused"
    community_moderator = "#{announce["actor"] |> String.split("/c/") |> List.first()}/u/a_mod"

    # the collection the community's `attributedTo` points at, which is where its moderators are
    # declared and therefore what a moderator change has to be checked against
    moderators_collection = "#{announce["actor"]}/moderators"

    served =
      served
      |> Map.put(announce["actor"], community_actor(announce["actor"]))
      |> Map.put(community_moderator, person_actor(community_moderator))
      |> Map.put(
        moderators_collection,
        moderators_collection(moderators_collection, [community_moderator])
      )
      |> Map.merge(Map.new([reported, text_post], &{&1["id"], &1}))
      |> Map.merge(
        Map.new([reported, text_post], &{&1["attributedTo"], person_actor(&1["attributedTo"])})
      )

    serve(served)

    for a <- [announce, text_announce] do
      case ActivityPub.Federator.Transformer.handle_incoming(a) do
        {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
        {:error, _} -> :ok
      end
    end

    # the community the ingested posts actually belong to, which is what a lock has to name: Lemmy's
    # own assets refer to their test community, not to the one these announces came from
    {:ok,
     reported: reported["id"],
     text_post: text_post["id"],
     announced_by: announce["actor"],
     community_moderator: community_moderator,
     moderators_collection: moderators_collection,
     served: served}
  end

  describe "what the payloads say" do
    # The audit corrected an earlier assumption here, so it is worth pinning: a moderator removing
    # someone's post does NOT send `Remove`. It sends `Delete` with the reason in `summary`, and
    # `Remove` is reserved for collection membership.
    test "a mod removal is a Delete carrying its reason, not a Remove" do
      remove = fixture("mod_remove_note.json")

      assert remove["type"] == "Delete"
      assert remove["summary"] == "bad comment"
      assert remove["audience"] =~ "/c/"
    end

    test "a lock carries its reason too" do
      lock = fixture("mod_lock_page.json")

      assert lock["type"] == "Lock"
      assert lock["summary"] == "A reason for the lock"
      assert lock["object"] =~ "/post/"
    end

    # This is the privacy-correct shape the plan credits PieFed with, and Lemmy already sends it:
    # a report goes to the community alone, never to its followers.
    test "a report is addressed to the community only, with no cc" do
      flag = fixture("mod_flag_page.json")

      assert flag["type"] == "Flag"
      assert flag["to"] == ["http://lemmy.local/c/main"]
      refute flag["cc"], "a report must not be announced to followers"
      assert flag["summary"] == "report this post"
    end

    test "moderator changes name the collection they modify" do
      for {file, type} <- [{"mod_add_mod.json", "Add"}, {"mod_remove_mod.json", "Remove"}] do
        activity = fixture(file)

        assert activity["type"] == type
        assert activity["target"] == "http://lemmy.local/c/main/moderators"
        assert activity["object"] =~ "/u/", "the object is the person being added or removed"
      end
    end
  end

  describe "what we do with them" do
    # This family puts the reason in `summary`, where Mastodon-family senders use `content`. We read
    # both, since a report reaching a moderator without its reason is barely a report.
    test "a report's reason survives ingest", %{reported: reported} do
      flag = fixture("mod_flag_page.json") |> Map.put("object", reported)

      assert {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(flag)

      assert e(activity, :data, "content", nil) == "report this post",
             "the reason belongs in `summary` for this family, and must not be lost"
    end

    # Locking is a `:lock` block on the object, which is exactly what our own "lock a post" does, so what arrives from the threadiverse needs no new local concept.
    # This is also the positive control for the two refusal tests below: until a lock WITH standing is shown to take effect, "refused" and "never reached the handler" are indistinguishable, and the refusals prove nothing on their own.
    test "a Lock closes the thread to further replies", %{
      reported: link_post,
      text_post: text_post,
      announced_by: community,
      community_moderator: moderator
    } do
      someone = fake_user!()

      # a link post and a self-post, which are different local objects (`Media` and `Post`) sharing
      # the `replied` mixin, so both have a thread and both are lockable
      for locked <- [link_post, text_post] do
        {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: locked)
        post = Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)

        assert Bonfire.Boundaries.can?(someone, :reply, post),
               "#{locked}: the thread should start out open, or this test proves nothing"

        # Lemmy's asset names its own test community, so point the lock at the community this post is
        # actually in, and at a moderator on that host. Authority is same-origin with the GROUP.
        lock =
          fixture("mod_lock_page.json")
          |> Map.merge(%{
            "object" => locked,
            "audience" => community,
            "actor" => moderator,
            # two locks are two activities, and reusing the fixture's id makes the second a duplicate
            "id" =>
              "#{fixture("mod_lock_page.json")["id"]}/#{locked |> String.split("/") |> List.last()}"
          })

        assert {:ok, activity} = ActivityPub.Federator.Transformer.handle_incoming(lock),
               "#{locked}: the transformer must accept a Lock before the adapter can act on it"

        assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity),
               "#{locked}: and the adapter must route it to a module that applies it"

        refute Bonfire.Boundaries.can?(someone, :reply, post),
               "#{locked}: a Lock closes a thread to further replies, and dropping it loses a moderator's decision"
      end
    end

    # A `Lock` closes someone's thread, so who may send one matters as much as what it does. The
    # 1b12 convention is that a receiver accepts moderation from an actor mod-listed for the group,
    # or same-origin with it. These two pin the refusals, since an authority check nobody tests is
    # one that silently stops working.
    test "a Lock from an actor with no authority over the group is refused", %{reported: locked} do
      someone = fake_user!()

      {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: locked)
      post = Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)

      # an actor the mock DOES serve, so this exercises the refusal rather than a failed fetch, and
      # one on another host than the community, so it is neither same-origin nor mod-listed
      fixture("mod_lock_page.json")
      |> Map.merge(%{"object" => locked, "actor" => "http://lemmy2.local/u/lemmy_alpha"})
      |> receive_moderation()

      assert Bonfire.Boundaries.can?(someone, :reply, post),
             "a stranger's Lock must not close a thread on this instance"
    end

    # A moderator of one community must not be able to close threads elsewhere, so naming a group
    # you do moderate is not enough: the object has to be in it.
    test "a Lock of an object that is not in the named group is refused", %{reported: in_group} do
      someone = fake_user!()

      author = fake_user!()

      assert {:ok, elsewhere} =
               Bonfire.Posts.publish(
                 current_user: author,
                 post_attrs: %{post_content: %{html_body: "a thread in no group at all"}},
                 boundary: "public"
               )

      refute in_group == nil

      elsewhere_url =
        elsewhere
        |> repo().maybe_preload([:peered, created: [creator: [character: [:peered]]]])
        |> Bonfire.Common.URIs.canonical_url()

      fixture("mod_lock_page.json")
      |> Map.put("object", elsewhere_url)
      |> receive_moderation()

      assert Bonfire.Boundaries.can?(someone, :reply, elsewhere),
             "the activity names a community this actor moderates, but the thread is not in it"
    end

    # Who moderates a community changes, and a mirror that never hears about it keeps handing
    # `:moderate` to the wrong people. Applied as a re-sync of the community's own collection rather
    # than as a delta, so what we end up asserting is what the origin publishes.
    test "an Add to a remote community's moderators collection re-syncs the mirror", %{
      announced_by: community,
      community_moderator: existing_mod,
      moderators_collection: collection,
      served: served
    } do
      {:ok, group} =
        Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => community})

      promoted = "#{community |> String.split("/c/") |> List.first()}/u/newly_promoted"

      refute promoted in moderator_urls(group),
             "the new moderator should not be there yet, or this test proves nothing"

      # the origin's list has changed by the time its Add reaches us, which is the state we adopt
      serve(
        served
        |> Map.put(promoted, person_actor(promoted))
        |> Map.put(collection, moderators_collection(collection, [existing_mod, promoted]))
      )

      # asserting on the RETURN, not only on the effect: a refreshed actor would re-sync the list
      # too, so without this the test cannot tell whether the moderator change was handled or merely
      # coincided with something else that re-read the collection
      assert {:ok, %Bonfire.Classify.Category{}} =
               fixture("mod_add_mod.json")
               |> Map.merge(%{
                 "actor" => existing_mod,
                 "object" => promoted,
                 "target" => collection,
                 "cc" => [community]
               })
               |> receive_moderation(),
             "a moderator change should be handled by the groups module rather than swallowed"

      assert promoted in moderator_urls(group),
             "a mirrored group should learn who moderates it when its origin says so"
    end

    # The community declares its own moderators, so an Add naming a collection that the named
    # community does not claim as its own must not change anything: otherwise anyone could hand
    # themselves `:moderate` over any mirror by pointing an Add at it.
    test "an Add from an actor with no authority over the community is refused", %{
      announced_by: community,
      moderators_collection: collection,
      served: served
    } do
      {:ok, group} =
        Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => community})

      stranger = "http://lemmy2.local/u/lemmy_alpha"
      promoted = "http://lemmy2.local/u/opportunist"

      serve(
        served
        |> Map.put(promoted, person_actor(promoted))
        |> Map.put(collection, moderators_collection(collection, [promoted]))
      )

      fixture("mod_add_mod.json")
      |> Map.merge(%{
        "actor" => stranger,
        "object" => promoted,
        "target" => collection,
        "cc" => [community],
        # on the STRANGER'S own host, so origin containment passes and what refuses this is the
        # authority check. With the fixture's own id the activity is rejected before it ever reaches
        # that check, and this test would pass without proving anything about authority
        "id" => "http://lemmy2.local/activities/add/#{System.unique_integer([:positive])}"
      })
      |> receive_moderation()
      |> refute_handled_as_group_change()

      refute promoted in moderator_urls(group),
             "an actor with no standing in this community must not be able to name its moderators"
    end
  end

  # ingest a moderation activity the way a delivery would: through the transformer, then the adapter
  defp receive_moderation(activity) do
    case ActivityPub.Federator.Transformer.handle_incoming(activity) do
      {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      other -> other
    end
  end

  # A refused moderator change must not come back as a handled one. Pairs with the positive test,
  # which asserts the opposite shape: together they show the difference is the actor's standing and
  # not something upstream quietly dropping the activity.
  defp refute_handled_as_group_change(result) do
    refute match?({:ok, %Bonfire.Classify.Category{}}, result),
           "expected the moderator change to be refused, got: #{inspect(result)}"

    result
  end

  defp moderator_urls(group) do
    Bonfire.Classify.Categories.moderators(group)
    |> repo().maybe_preload(character: [:peered])
    |> Enum.map(&Bonfire.Common.URIs.canonical_url/1)
  end

  # re-callable, so a test can change what an origin serves (a moderator list that has since changed)
  defp serve(served) do
    mock(fn %{method: :get, url: url} ->
      case served[url] do
        nil -> %Tesla.Env{status: 404, body: ""}
        body -> json(body)
      end
    end)
  end

  # Lemmy's captured collection, rebased onto our community's id. Its shape is the point: a bare `OrderedCollection` that does NOT say whose it is, which is why the owner has to be found from the activity's addressing and then verified against the group's own `attributedTo`.
  defp moderators_collection(id, moderators) do
    fixture("moderators_collection.json")
    |> Map.merge(%{"id" => id, "orderedItems" => moderators, "totalItems" => length(moderators)})
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  # the assets use `/c/main`, so rebase our captured community actor onto that id
  defp community_actor(ap_id) do
    fixture("community_actor.json")
    |> Map.merge(%{
      "id" => ap_id,
      "preferredUsername" => "main",
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox",
      "followers" => "#{ap_id}/followers",
      "attributedTo" => "#{ap_id}/moderators"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  defp person_actor(ap_id) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
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
