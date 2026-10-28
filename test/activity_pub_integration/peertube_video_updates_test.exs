defmodule Bonfire.Federate.ActivityPub.PeertubeVideoUpdatesTest do
  @moduledoc """
  A PeerTube video is one item here, however many times PeerTube tells us about it.

  PeerTube sends an `Update` of a video, the whole `Video` embedded and under a new id each time, to the followers of its channel and of its account: at most once per video per `views.videos.local_buffer_update_interval` (30 minutes by default) while it gets views, and on likes, captions and more, old videos included. Each made a new copy of the video when we did not hold it (bonfire.cafe, 27 October: 436 to 652 copies of each of 7 videos), and one we did hold was refused as a change of owner, as the video names two (its account and its channel). Reported as bonfire-app#2433.

  The fixtures are tube.tchncs.de's own documents (`fixtures/peertube/tube_*.json`, the host rewritten to `.local`): the video is one of those copied hundreds of times on bonfire.cafe. An `Update` is only delivered, never served, so it is built here as PeerTube's `send-update.ts` makes one.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  import Ecto.Query

  @moduletag :federation

  alias ActivityPub.Federator.Transformer

  @account "https://tube.tchncs.local/accounts/bonfirenetworks"
  @channel "https://tube.tchncs.local/video-channels/bonfire"
  @video_id "https://tube.tchncs.local/videos/watch/59353f51-17a1-4dd7-9935-e74c5e4ae1e2"

  defp fixture(name),
    do: "../fixtures/peertube/#{name}" |> Path.expand(__DIR__) |> File.read!() |> Jason.decode!()

  setup do
    video = fixture("tube_video.json")
    assert video["id"] == @video_id, "control: the fixture's video"

    mock(fn
      %{method: :get, url: @account} -> json(fixture("tube_account.json"))
      %{method: :get, url: @channel} -> json(fixture("tube_channel.json"))
      %{method: :get, url: @video_id} -> json(video)
      env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    %{video: video}
  end

  # as a delivery is: its HTTP signature checked first, which fetches the signer
  defp delivered(document) do
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: document["actor"])

    Transformer.handle_incoming(document,
      from_inbox: true,
      authenticated: :http_signature,
      signed_by: document["actor"]
    )
  end

  # as PeerTube makes one (`send-update.ts`): from the account, the whole video embedded, a new id each time
  defp update_of(video, views) do
    %{
      "id" => "#{@video_id};#{System.unique_integer([:positive])}",
      "type" => "Update",
      "actor" => @account,
      "to" => video["to"],
      "cc" => video["cc"],
      "object" => Map.put(video, "views", views)
    }
  end

  defp media_for_video do
    repo().all(
      from(m in Bonfire.Files.Media,
        where: fragment("?->'json_ld'->>'id'", m.metadata) == ^@video_id
      )
    )
  end

  test "Updates of a video we do not hold make one item of it, not one each", %{video: video} do
    delivered(update_of(video, 849))

    assert [%{id: media_id}] = media_for_video(),
           "control: the first Update made the video an item"

    delivered(update_of(video, 850))

    assert [media] = media_for_video(), "the second Update made another copy of the video"

    assert media.id == media_id,
           "the second Update replaced the item the first one made (#{media_id}, now #{media.id})"

    assert get_in(media.metadata, ["json_ld", "views"]) == 850,
           "the second Update did not update the item the first one made"
  end

  test "an Update of a video we hold updates it, rather than making another", %{video: video} do
    # held as it is after a lookup or a backfill: fetched, stored, and made an item
    assert {:ok, _} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(@video_id)

    assert [%{id: media_id}] = media_for_video(), "control: we hold the video as one item"

    assert {:ok, _} = delivered(update_of(video, 849))

    assert [%{id: ^media_id} = media] = media_for_video(),
           "the Update made another item, or replaced the one we held"

    assert get_in(media.metadata, ["json_ld", "views"]) == 849,
           "the item still has what the Update changed as it was"
  end

  # The item takes the id the adapter made for the video (so it is dated when the video was published), so making it again meant inserting that id twice: `bonfire_files_media_pkey`. Seen in production on 28 October; a retried job is one way (inserted, then publishing failed, then run again).
  test "the item of a video is made once when its Create is handled again, as a retried job does",
       %{video: video} do
    create = %{
      "id" => "#{@video_id}/activity",
      "type" => "Create",
      "actor" => @account,
      "to" => video["to"],
      "cc" => video["cc"],
      "object" => video
    }

    assert {:ok, _} = delivered(create)
    assert [%{id: media_id}] = media_for_video(), "control: the Create made the video an item"

    {:ok, creator} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(@account)

    {:ok, activity} = ActivityPub.Object.get_cached(ap_id: create["id"])
    {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: @video_id)

    assert is_binary(ap_object.pointer_id), "control: the adapter made an id for the video"

    feed_activities = fn ->
      repo().all(from(a in Bonfire.Data.Social.Activity, where: a.object_id == ^media_id))
    end

    assert [_] = feed_activities.(), "control: the Create put the video in the feed once"

    # the same step again, as a retried job runs it
    Bonfire.Files.Media.ap_receive_activity(creator, activity, ap_object, [])

    assert [%{id: ^media_id}] = media_for_video()
    assert [_] = feed_activities.(), "handling it again put the video in the feed twice"
  end

  # as `maybe_fetch_and_save` finds a link it saved before, by its URL: a copy made before items took the adapter's id has another id
  test "the item of a video is found by its URL too, when a copy has another id", %{video: video} do
    create = %{
      "id" => "#{@video_id}/activity",
      "type" => "Create",
      "actor" => @account,
      "to" => video["to"],
      "cc" => video["cc"],
      "object" => video
    }

    assert {:ok, _} = delivered(create)
    assert [%{id: media_id}] = media_for_video(), "control: the Create made the video an item"

    {:ok, creator} =
      Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(@account)

    {:ok, activity} = ActivityPub.Object.get_cached(ap_id: create["id"])
    {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: @video_id)

    # handled once more, for an id no item has
    Bonfire.Files.Media.ap_receive_activity(
      creator,
      activity,
      %{ap_object | pointer_id: Needle.UID.generate(Bonfire.Files.Media)},
      []
    )

    assert [%{id: ^media_id}] = media_for_video()
  end

  test "a Create and an Announce of the same video make one item", %{video: video} do
    # as the account's and the channel's outboxes name it (`tube_account_outbox_page.json`)
    delivered(%{
      "id" => "#{@video_id}/activity",
      "type" => "Create",
      "actor" => @account,
      "to" => video["to"],
      "cc" => video["cc"],
      "object" => video
    })

    delivered(%{
      "id" => "#{@video_id}/announces/#{System.unique_integer([:positive])}",
      "type" => "Announce",
      "actor" => @channel,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => @video_id
    })

    assert [_] = media_for_video()
  end
end
