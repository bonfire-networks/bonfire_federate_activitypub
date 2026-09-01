defmodule Bonfire.Federate.ActivityPub.SmithereenInteropTest do
  @moduledoc """
  Interop pass for FEP-400e publicly-appendable collections, as Smithereen sends them.

  Fixture is a REAL capture from a public group on a Smithereen 1.0.3-dev instance (2026-09-01), with hostnames rewritten to `.local`; provenance is in the group federation plan.

  **A Smithereen group publishes nothing through its outbox.** The captured group's outbox is empty (`totalItems: 0`) while its `wall` holds the posts, so a consumer that only understands FEP-1b12 announces sees an empty group rather than a broken one, which is harder to notice.

  | | threadiverse (1b12) | Smithereen (400e) |
  |---|---|---|
  | where content lives | outbox, as `Announce` | the `wall` collection |
  | belongs-to marker | `audience` | `target`, an inline Collection object |
  | moderators | `attributedTo` collection URL | `attributedTo` array of inline Persons |

  These tests assert what the payloads say rather than what we do with them: that is what a captured fixture is for, and the ingest work is tracked in the plan's phase 3.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @fixtures Path.join([__DIR__, "..", "fixtures", "smithereen"])

  test "the group actor is a Group whose content lives in a wall, not an outbox" do
    actor = fixture("group_actor.json")

    assert actor["type"] == "Group"
    assert actor["wall"], "the wall is where a 400e group's posts are appended"
    assert actor["manuallyApprovesFollowers"] == false
  end

  # Every threadiverse implementor points `attributedTo` at a collection URL. Smithereen sends the
  # admins inline instead, each with a title, so code that assumes a URL here will not cope.
  test "moderators arrive inline rather than as a collection URL" do
    actor = fixture("group_actor.json")
    admins = actor["attributedTo"]

    assert is_list(admins), "an array of Person objects, not a collection URL"

    for admin <- admins do
      assert admin["type"] == "Person"
      assert admin["id"]
    end
  end

  # `followers` pointing at `/members` is the one place this family states outright that following
  # and membership are the same relationship, which is open question 3 for our own groups.
  test "followers and members are the same collection" do
    actor = fixture("group_actor.json")

    assert actor["followers"] =~ "/members"
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
