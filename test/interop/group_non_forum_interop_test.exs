defmodule Bonfire.Federate.ActivityPub.GroupNonForumInteropTest do
  @moduledoc """
  `Group` actors that are NOT communities: PeerTube channels, and Funkwhale channels when we capture one.

  A channel is owned by one account, only that account publishes to it, and everyone else follows and comments. Mobilizon is deliberately not here: it IS a community group and has its own module.

  The two implementations do not even agree on the actor type, which is the first thing to know before writing anything that keys on it: **PeerTube channels are `Group`, Funkwhale channels are `Person`** (both with `attributedTo` pointing at the owning account). So a Funkwhale channel never reaches the group code at all, and needs nothing from it.

  The useful discovery is that a channel says so itself, in the threadiverse's own vocabulary: PeerTube emits **`postingRestrictedToMods: true`**, complete with the `lemmy:` context term, which `remote_dims/1` already maps to `participation: "moderators"`. So the affordance problem — offering local people a "post here" that would go nowhere — is answered by the payload rather than by detecting what software is on the other end. Software sniffing via nodeinfo is the fallback for actors that declare nothing.

  ⚠️ `attributedTo` means something different here than in the threadiverse: it is the OWNER account, not a moderators collection.

  Fixture is a real capture (2026-09-02) from a live public channel, hosts rewritten.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @channel "https://framatube.local/video-channels/joinpeertube"
  @owner "https://framatube.local/accounts/framasoft"
  @funkwhale_channel "https://funkwhale.local/federation/actors/antistamina"
  @funkwhale_owner "https://funkwhale.local/federation/actors/skeyby"

  setup do
    served = %{
      @channel => fixture("peertube", "channel_actor.json"),
      @owner => person_actor(@owner),
      @funkwhale_channel => fixture("funkwhale", "channel_actor.json"),
      @funkwhale_owner => person_actor(@funkwhale_owner)
    }

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    :ok
  end

  test "a PeerTube channel becomes a group people can reply in but not post into" do
    assert fixture("peertube", "channel_actor.json")["postingRestrictedToMods"] == true,
           "the fixture should carry the declaration this test is about"

    assert {:ok, channel} = Adapter.maybe_create_remote_actor(%{"id" => @channel})

    assert %Bonfire.Classify.Category{type: :group} = channel,
           "it declares `Group`, so it becomes one: what differs is the affordances, not the type"

    assert Bonfire.Boundaries.Presets.group_dimension_slugs(channel)[:participation] ==
             "moderators",
           "a channel says only its owner publishes, so offering local users a 'post here' that goes nowhere is the failure to avoid"
  end

  test "and treats the owning account as its moderator" do
    assert {:ok, channel} = Adapter.maybe_create_remote_actor(%{"id" => @channel})

    assert Bonfire.Classify.Categories.moderators(channel) != [],
           "the channel names its owner in `attributedTo`, and the owner is who moderates it"
  end

  # Funkwhale models the same idea as a `Person`, so it never reaches the group code. Pinned because our own comparison notes said `Group`, and anything keyed on the type would have been wrong.
  test "a Funkwhale channel is a Person, so it does not become a group" do
    actor = fixture("funkwhale", "channel_actor.json")

    assert actor["type"] == "Person", "captured 2026-09-02 from a live channel"
    assert actor["attributedTo"] =~ "/actors/", "owned by an account, like a PeerTube channel"

    assert {:ok, channel} =
             Adapter.maybe_create_remote_actor(%{"id" => @funkwhale_channel})

    refute match?(%Bonfire.Classify.Category{}, channel),
           "it does not claim to be a group, so we should not make it one"
  end

  # Not a group, but not a plain person either: it is operated by another actor, which is what
  # `SharedUser` is for. Routed by configuration the way FediGroups actors are, rather than by
  # scattered special cases, because PeerTube and Funkwhale disagree about the actor type.
  # ⚠️ RED until `SharedUser` can link a user PROFILE and not only local ACCOUNTS: a remote channel's
  # operator is remote, so today there is nothing to hang the relationship on.
  @tag :todo
  test "a Funkwhale channel becomes a SharedUser labelled Channel, showing who operates it" do
    assert {:ok, channel} = Adapter.maybe_create_remote_actor(%{"id" => @funkwhale_channel})

    assert e(repo().maybe_preload(channel, :shared_user), :shared_user, :label, nil) == "Channel",
           "the label is what makes it displayable as a channel rather than as a person"
  end

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp person_actor(ap_id) do
    Simulate.actor_json("https://mocked.local/users/karen")
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
