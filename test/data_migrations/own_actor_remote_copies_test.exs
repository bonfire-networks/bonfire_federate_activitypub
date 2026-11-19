defmodule Bonfire.Federate.ActivityPub.DataMigrations.OwnActorRemoteCopiesTest do
  @moduledoc """
  Copies of our own actors stored as remote objects (bonfire.cafe, 18 November: the `Bonfire_Networks` group and `Federation_Bot`) are removed, so their URLs lead to the actors again. While its copy was there, every incoming `Join` to the group failed with "no local group to act on".

  Only actors: other rows under our host stored as remote (eg. remote actors' `Update`s under ids minted here before ids were derived from their sender) are records of what others did, and are kept.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Ecto.Query

  @moduletag :federation

  alias Bonfire.Federate.ActivityPub.DataMigrations.OwnActorRemoteCopies

  setup do
    creator = fake_user!()
    group = Bonfire.Classify.Simulate.fake_group!(creator)

    # public, as the group on bonfire.cafe is, and as a URL lookup from elsewhere needs (it is boundary-checked)
    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    %{group: group, group_ap_id: actor.ap_id, actor_data: actor.data}
  end

  # a row as found on bonfire.cafe: our actor's own document, stored as someone else's, with nothing of ours behind it
  defp stored_remote!(data) do
    repo().insert!(%ActivityPub.Object{id: Ecto.UUID.generate(), data: data, local: false})
  end

  defp rows_for(ap_id),
    do:
      repo().all(
        from(o in ActivityPub.Object, where: fragment("?->>'id'", o.data) == ^ap_id, select: o.id)
      )

  defp run,
    do: OwnActorRemoteCopies.base_query() |> repo().all() |> OwnActorRemoteCopies.migrate()

  test "a remote copy of one of our actors is removed, and its URL leads to the actor again", %{
    group: group,
    group_ap_id: group_ap_id,
    actor_data: actor_data
  } do
    assert {:ok, before} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(group_ap_id),
           "control: with no copy, the URL is the group's"

    assert id(before) == id(group)

    stored_remote!(actor_data)

    assert {:ok, %{pointer_id: nil}} = ActivityPub.Object.get_cached(ap_id: group_ap_id),
           "control: the copy is what the URL finds"

    run()

    assert rows_for(group_ap_id) == []

    # our actors have no row, so the URL is the group's again once the copy is gone
    assert {:ok, character} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(group_ap_id)

    assert id(character) == id(group)
  end

  test "keeps remote actors, and rows under our host that are not actors", %{
    group_ap_id: group_ap_id
  } do
    remote_actor =
      stored_remote!(
        Bonfire.Federate.ActivityPub.Simulate.actor_json(
          "https://elsewhere.local/users/someone",
          "someone"
        )
      )

    update =
      stored_remote!(%{
        "id" => "#{ActivityPub.Web.base_url()}/pub/objects/#{Ecto.UUID.generate()}",
        "type" => "Update",
        "actor" => "https://elsewhere.local/users/someone",
        "object" => "https://elsewhere.local/users/someone"
      })

    run()

    assert [_] = rows_for(remote_actor.data["id"])
    assert [_] = rows_for(update.data["id"])
    assert rows_for(group_ap_id) == []
  end

  test "running it again changes nothing", %{group_ap_id: group_ap_id, actor_data: actor_data} do
    stored_remote!(actor_data)

    run()
    run()

    assert rows_for(group_ap_id) == []
    assert OwnActorRemoteCopies.base_query() |> repo().all() == []
  end
end
