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
    # bring one in the normal way first, via the community's announce
    announce = fixture("announce_create_page.json")
    reported = announce["object"]["object"]

    served =
      served
      |> Map.put(announce["actor"], community_actor(announce["actor"]))
      |> Map.put(reported["id"], reported)
      |> Map.put(reported["attributedTo"], person_actor(reported["attributedTo"]))

    mock(fn %{method: :get, url: url} ->
      case served[url] do
        nil -> %Tesla.Env{status: 404, body: ""}
        body -> json(body)
      end
    end)

    case ActivityPub.Federator.Transformer.handle_incoming(announce) do
      {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      {:error, _} -> :ok
    end

    {:ok, reported: reported["id"]}
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

    # No `Lock` clause exists anywhere in the codebase, so a locked thread silently stays open.
    @tag :todo
    test "a Lock is understood" do
      lock = fixture("mod_lock_page.json")

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(lock),
             "a Lock closes a thread to further replies, and dropping it loses a moderator's decision"
    end

    # The existing `Add`/`Remove` clause applies real semantics only to collections this library
    # owns, so moderator changes on a REMOTE community fall through and mirrored groups never see
    # who moderates them.
    @tag :todo
    test "an Add to a remote community's moderators collection takes effect" do
      add = fixture("mod_add_mod.json")

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(add),
             "a mirrored group should learn about moderator changes announced by its origin"
    end
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
