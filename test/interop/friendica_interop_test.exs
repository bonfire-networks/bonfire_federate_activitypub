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

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
