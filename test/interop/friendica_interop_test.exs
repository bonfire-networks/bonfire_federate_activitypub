defmodule Bonfire.Federate.ActivityPub.FriendicaInteropTest do
  @moduledoc """
  Interop pass for Friendica forums, the origin of `audience` addressing.

  Fixtures are REAL captures from a public Friendica 2026.05 forum (2026-09-01), with hostnames rewritten to `.local`; provenance is in the group federation plan.

  Friendica matters twice over: it proposed `audience` for the non-public case, and it is a full FEP-1b12 peer that ALSO consumes Lemmy's activity-wrapped announces. What its own outbox shows is only the forum's own posts, never a relay, so its bare-id relay shape still has no capture.

  These tests assert what the payloads say rather than what we do with them, which is what a captured fixture is for.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @fixtures Path.join([__DIR__, "..", "fixtures", "friendica"])

  test "a forum is a Group actor with no moderators collection" do
    actor = fixture("forum_actor.json")

    assert actor["type"] == "Group"

    refute actor["attributedTo"],
           "Friendica publishes no moderators, so incoming moderation can only be validated as same-origin"
  end

  # The property Friendica proposed, and the trap: it is on the ACTIVITY only. Lemmy puts `audience`
  # on the object too, so attribution code that reads only the object misses Friendica entirely.
  test "audience is on the activity, not on the object" do
    create = fixture("create_article.json")

    assert create["audience"], "the Create carries the forum as its audience"
    refute create["object"]["audience"], "but the object does not"
  end

  test "actor and attribution arrive as inline objects, not id strings" do
    create = fixture("create_article.json")

    assert is_map(create["actor"]), "an inline Group object rather than an id"
    assert create["actor"]["type"] == "Group"
    assert is_map(create["object"]["attributedTo"])
  end

  # Friendica emits interaction policies in production, which is worth pinning: it is evidence the
  # property is deployed rather than proposed, and it uses the current spelling.
  test "posts carry an interactionPolicy using the current spelling" do
    object = fixture("create_article.json")["object"]

    assert %{"canQuote" => %{"automaticApproval" => [_ | _]}} = object["interactionPolicy"],
           "`automaticApproval`, not the deprecated `always`"
  end

  test "thread starters are titled Articles" do
    object = fixture("create_article.json")["object"]

    assert object["type"] == "Article"
    assert object["name"], "a real title, as NodeBB also sends"
  end

  # Captured 2026-10-20 from `friendica.world/profile/testgroup3`, a Group account that a member (`mayel`) posted an `Article` in, then deleted. What its followers get is NOT the threadiverse shape: the `Announce` carries the post by bare id (`object` is a string, so the receiver has to fetch it), and the deletion comes as the group's `Undo` of that same `Announce`, never a `Delete` or an announced `Delete`.
  describe "a Friendica group's relay of a member's post" do
    import Tesla.Mock
    import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures, only: [author_actor: 1]

    alias Bonfire.Federate.ActivityPub.AdapterUtils

    @group "https://friendica.local/profile/testgroup3"

    setup do
      article = fixture("article_by_member.json")
      article_id = article["id"]
      author_id = article["attributedTo"]

      mock(fn
        %{method: :get, url: @group} -> json(fixture("group_actor.json"))
        %{method: :get, url: ^article_id} -> json(article)
        %{method: :get, url: ^author_id} -> json(author_actor(author_id))

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}

        %{method: :get} ->
          %Tesla.Env{status: 404, body: ""}
      end)

      %{article: article}
    end

    defp receive_activity(activity) do
      case ActivityPub.Federator.Transformer.handle_incoming(activity) do
        {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
        other -> other
      end
    end

    defp in_group_feed?(article) do
      group = AdapterUtils.get_character_by_ap_id!(@group)

      with {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) <-
             ActivityPub.Object.get_cached(ap_id: article["id"]) do
        Bonfire.Social.FeedLoader.feed_contains?(:user_activities, pointer_id,
          by: group,
          current_user: group
        )
      else
        _ -> false
      end
    end

    test "an Announce carrying only the post's id is fetched, stored and filed as the group's", %{
      article: article
    } do
      announce = fixture("announce_bare_id.json")
      assert is_binary(announce["object"]), "control: the object is a bare id"

      receive_activity(announce)

      assert in_group_feed?(article),
             "the post the group announced by id should land in the group's feed"
    end

    test "the group's Undo of that Announce takes the post out of its feed again", %{
      article: article
    } do
      receive_activity(fixture("announce_bare_id.json"))
      assert in_group_feed?(article), "control: the announce put it in the feed"

      receive_activity(fixture("undo_announce.json"))

      refute in_group_feed?(article),
             "the group undid its announce, which is how Friendica says the post is gone"
    end
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
