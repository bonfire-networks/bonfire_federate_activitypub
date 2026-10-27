defmodule Bonfire.Federate.ActivityPub.FetchedPublishedDateTest do
  @moduledoc """
  A post we fetch from its origin is dated when it was published there, however old, not when we fetched it: the origin is the authority on its own date (`ActivityPub.Utils.published_at/2`, `:fetched`), and Bonfire's post id carries that date.

  Reported for PeerTube videos looked up by URL in search (bonfire-app#2457), and fetched from an outbox with "Get latest activities" (bonfire-app#2433), both shown as new however old. The fixtures are tube.tchncs.de's own documents (`fixtures/peertube/tube_*.json`, the host rewritten to `.local`): an account whose outbox names its videos by id in `Create`s, and one of those videos.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  @moduletag :federation

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @account "https://tube.tchncs.local/accounts/bonfirenetworks"
  @outbox "https://tube.tchncs.local/accounts/bonfirenetworks/outbox"
  @video_id "https://tube.tchncs.local/videos/watch/59353f51-17a1-4dd7-9935-e74c5e4ae1e2"
  @published "2022-06-24T19:53:07.204Z"

  defp fixture(name),
    do: "../fixtures/peertube/#{name}" |> Path.expand(__DIR__) |> File.read!() |> Jason.decode!()

  setup do
    video = fixture("tube_video.json")
    assert video["published"] == @published, "control: the fixture's date"

    page = fixture("tube_account_outbox_page.json")

    assert @video_id in Enum.map(page["orderedItems"], & &1["object"]),
           "control: the outbox names it"

    mock(fn
      %{method: :get, url: @video_id} -> json(video)
      %{method: :get, url: @account} -> json(fixture("tube_account.json"))
      %{method: :get, url: @outbox} -> json(fixture("tube_account_outbox.json"))
      %{method: :get, url: @outbox <> "?page=1"} -> json(page)
      # the other videos the outbox names, which we have no copy of
      %{method: :get, url: "https://tube.tchncs.local/" <> _} -> %Tesla.Env{status: 404, body: ""}
      env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  defp post_date(post),
    do: Bonfire.Common.DatesTimes.date_from_pointer(post) |> DateTime.truncate(:second)

  defp published, do: elem(DateTime.from_iso8601(@published), 1) |> DateTime.truncate(:second)

  # the AP row first, then Bonfire's post: which of the two lost the date
  defp assert_dated_when_published(post) do
    assert {:ok, %ActivityPub.Object{inserted_at: inserted_at, authenticated: authenticated}} =
             ActivityPub.Object.get_uncached(ap_id: @video_id)

    assert DateTime.from_naive!(inserted_at, "Etc/UTC") |> DateTime.truncate(:second) ==
             published(),
           "the AP row is dated #{inspect(inserted_at)} (authenticated: #{inspect(authenticated)}), published #{@published}"

    assert post_date(post) == published(),
           "the AP row is right, Bonfire's post is dated #{inspect(post_date(post))} (authenticated: #{inspect(authenticated)}), published #{@published}"
  end

  test "a video looked up by its URL is dated when it was published, not when we fetched it" do
    assert {:ok, post} = AdapterUtils.get_by_url_ap_id_or_username(@video_id)

    assert_dated_when_published(post)
  end

  # a copy its author signed is as good as the post from its origin, date included (`ActivityPub.Utils.arrival/3`): stored from the copy, nothing fetched, and Bonfire's post id carries its date
  test "a boosted post carried as a copy its author signed is dated when it was published" do
    import ActivityPub.Test.IntegrityProofHelpers

    n = System.unique_integer([:positive])
    key = new_key(:ed25519)
    author = "https://signer-#{n}.local/users/alice"
    booster = "https://booster-#{n}.local/users/bob"

    mock(fn
      %{method: :get, url: ^author} ->
        json(
          Bonfire.Federate.ActivityPub.Simulate.actor_json(author, "alice")
          |> Map.put("assertionMethod", [multikey(author, key)])
        )

      %{method: :get, url: ^booster} ->
        json(Bonfire.Federate.ActivityPub.Simulate.actor_json(booster, "bob"))

      # the post's origin serves nothing
      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    post =
      %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/security/data-integrity/v2"
        ],
        "id" => "#{author}/notes/#{n}",
        "type" => "Note",
        "attributedTo" => author,
        "content" => "<p>an old post</p>",
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => @published
      }
      |> sign(key)

    boost = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{booster}/announces/#{n}",
      "type" => "Announce",
      "actor" => booster,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => post
    }

    assert {:ok, _} =
             ActivityPub.Federator.Transformer.handle_incoming(boost,
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: booster
             )

    assert {:ok, %{pointer_id: pointer_id, authenticated: :integrity_proof}} =
             ActivityPub.Object.get_uncached(ap_id: post["id"])

    assert post_date(pointer_id) == published(),
           "Bonfire's post is dated #{inspect(post_date(pointer_id))}, its signed copy's published #{@published}"
  end

  test "a video fetched from its account's outbox is dated when it was published" do
    {:ok, account} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @account)

    ActivityPub.Federator.Fetcher.fetch_outbox(account, mode: :sync, triggered_by: "test")

    assert {:ok, post} = AdapterUtils.get_by_url_ap_id_or_username(@video_id)

    assert_dated_when_published(post)
  end
end
