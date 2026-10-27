defmodule Bonfire.Federate.ActivityPub.DataMigrations.DuplicateRemoteMediaTest do
  @moduledoc """
  The copies of a remote video that each PeerTube `Update` made before it was fixed (bonfire.cafe, 27 October: 436 to 652 copies of each of 7 videos) are removed, keeping the earliest, which is then what the video's AP id leads to. Nothing is federated: the video is someone else's.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  import Ecto.Query

  @moduletag :federation

  alias Bonfire.Federate.ActivityPub.DataMigrations.DuplicateRemoteMedia
  alias Bonfire.Files.Media

  @creator "https://mocked.local/users/karen"
  @video_id "https://tube.tchncs.local/videos/watch/59353f51-17a1-4dd7-9935-e74c5e4ae1e2"
  @other_video_id "https://tube.tchncs.local/videos/watch/0ebcbb97-6c23-43c1-801b-320ba81129de"

  setup do
    mock(fn
      %{method: :get, url: @creator} -> json(Simulate.actor_json(@creator))
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @creator)
    {:ok, creator} = Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(actor)

    %{creator: creator}
  end

  # as each `Update` made one before the fix: a new media under a new id, published to feeds
  defp copy_of(creator, ap_id, n) do
    {:ok, activity} =
      Media.create_and_publish(
        creator,
        "#{ap_id}/files/#{n}.mp4",
        "video/mp4",
        0,
        %{json_ld: %{"id" => ap_id, "type" => "Video", "views" => n}},
        boundary: "public"
      )

    id(activity.object)
  end

  defp media_of(ap_id) do
    repo().all(
      from(m in Media,
        where: fragment("?->'json_ld'->>'id'", m.metadata) == ^ap_id,
        order_by: [asc: m.id],
        select: m.id
      )
    )
  end

  defp activities_of(media_ids),
    do:
      repo().aggregate(
        from(a in Bonfire.Data.Social.Activity, where: a.object_id in ^media_ids),
        :count
      )

  defp deletes_sent,
    do:
      repo().aggregate(
        from(o in ActivityPub.Object, where: fragment("?->>'type'", o.data) == "Delete"),
        :count
      )

  defp run,
    do: DuplicateRemoteMedia.base_query() |> repo().all() |> DuplicateRemoteMedia.migrate()

  test "the copies of a remote video are removed, keeping the earliest", %{creator: creator} do
    [earliest | later] = ids = for n <- 1..3, do: copy_of(creator, @video_id, n)

    # what each later `Update` looked it up by, if anything: the latest copy, as the last link made
    Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(List.last(later), @video_id,
      type: :object
    )

    assert media_of(@video_id) == ids, "control: three copies"
    assert activities_of(later) > 0, "control: the later copies are in feeds"
    deletes_before = deletes_sent()

    run()

    assert media_of(@video_id) == [earliest], "the copies were not removed, or the wrong one kept"
    assert activities_of(later) == 0, "the removed copies are still in feeds"

    leads_to = Bonfire.Federate.ActivityPub.AdapterUtils.pointer_id_from_ap_object(@video_id)

    assert leads_to == earliest,
           "the video's AP id leads to #{inspect(leads_to)}, not the copy kept (#{earliest}); the removed: #{inspect(later)}"

    assert deletes_sent() == deletes_before, "a Delete of someone else's video was federated"
  end

  test "a remote video held once is left as it is", %{creator: creator} do
    once = copy_of(creator, @other_video_id, 1)

    run()

    assert media_of(@other_video_id) == [once]
    assert activities_of([once]) > 0
  end

  test "running it again changes nothing", %{creator: creator} do
    [earliest | _] = for n <- 1..2, do: copy_of(creator, @video_id, n)

    run()
    assert media_of(@video_id) == [earliest]

    assert [] = DuplicateRemoteMedia.base_query() |> repo().all(),
           "a video left with one copy is still selected"
  end
end
