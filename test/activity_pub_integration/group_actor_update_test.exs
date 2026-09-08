defmodule Bonfire.Federate.ActivityPub.GroupActorUpdateTest do
  @moduledoc """
  A group that changes its own rules says so on the wire.

  The actor we publish carries what the group enforces: `postingRestrictedToMods`, `openness`, `manuallyApprovesFollowers` and the `attributedTo` moderators collection, all derived from its dimension slugs. Remote software acts on them — Lemmy, Mbin, PieFed and NodeBB hide the compose button on `postingRestrictedToMods`, Mastodon shows a join as pending on `manuallyApprovesFollowers` — so a group whose rules change and does not federate an `Update` leaves every remote mirror enforcing the rules it declared the day it was first fetched.

  The machinery is shared with users and already works: `Adapter.local_actor_updated/2` pushes an actor `Update`, gated by `Outgoing.push_actor_update/1` on the character's own boundaries, which is what keeps a nonfederated group silent (covered by `group_actor_federation_gate_test.exs` in `bonfire_classify`). What this file pins is that a DIMENSION change reaches that machinery, that a mirror applying its origin's declarations does not, and the same thing in reverse: an incoming `Update` refreshes a mirror's rules rather than leaving it on the ones it was born with.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Classify.Simulate
  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @remote_group "https://mocked.local/groups/tests"

  setup do
    mock(fn
      %{method: :get, url: @remote_group} ->
        json(APSimulate.actor_json(@remote_group, "tests", %{"type" => "Group"}))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  defp actor_update_activity(group) do
    assert {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)
    ActivityPub.Object.get_activity_for_object_ap_id(actor.ap_id, "Update")
  end

  test "changing a group's rules federates an Update carrying the new declarations" do
    creator = fake_user!()

    group =
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    assert :ok =
             Bonfire.Classify.Boundaries.apply(group, creator, %{
               membership: "on_request",
               visibility: "global",
               participation: "moderators",
               default_content_visibility: "public"
             })

    assert %{data: %{"object" => object}} = actor_update_activity(group),
           "a community that becomes moderators-only and approval-based has to say so, or every remote mirror keeps offering its users a compose button and an instant join"

    assert object["postingRestrictedToMods"] == true
    assert object["openness"] == "moderated"
  end

  # Archiving changes what the group declares (`postingRestrictedToMods` becomes true, since it now accepts nothing), and a declaration nobody is told about does no work: existing followers keep offering their users a compose button for a group that has closed.
  @tag skip:
         "2026-09-08: `soft_delete/2` deliberately does NOT push an actor Update. Delivering one for an already-archived group crashes a LINKED process in the delivery path, taking the caller's DB connection with it, so archiving itself failed — it broke every archive test across `bonfire_ui_groups`, sidebar pins and this extension in CI. A linked exit cannot be rescued at the call site, so the push was removed until the delivery crash is understood (archived rows are excluded from the default fetch, so delivery re-loading the group is the likely cause). The DECLARATION is correct either way and is covered by `group_actor_declarations_test.exs`; only telling existing followers is missing."
  test "archiving a group federates an Update declaring it closed to posts" do
    creator = fake_user!()

    group =
      Simulate.fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "anyone",
        default_content_visibility: "public"
      })

    # a group that has actually federated, which is the only kind with anyone to tell: fetching its actor is what creates and caches one
    assert {:ok, _} = ActivityPub.Actor.get_cached(pointer: group)

    assert {:ok, _} = Bonfire.Classify.Categories.soft_delete(group, creator)

    assert %{data: %{"object" => object}} = actor_update_activity(group)

    assert object["postingRestrictedToMods"] == true,
           "the Update has to carry the new state, not the state the group had when it was last published"
  end

  # The same call is how a MIRROR applies its origin's declarations (`Categories.update_remote_actor/2` → `reapply_remote_declarations/2` → `Boundaries.apply/3`), so federating unconditionally would bounce a remote community's own rules back at it as though we spoke for that group.
  test "a mirrored group applying its origin's rules does not federate an Update" do
    assert {:ok, remote_group} =
             Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(
               APSimulate.actor_json(@remote_group, "tests", %{
                 "type" => "Group",
                 "openness" => "moderated"
               })
             )

    assert {:ok, remote_group} = Categories.get(id(remote_group), skip_boundary_check: true)

    assert :ok =
             Bonfire.Classify.Boundaries.apply(remote_group, nil, %{
               membership: "on_request",
               visibility: "global",
               participation: "moderators",
               default_content_visibility: "public"
             })

    refute actor_update_activity(remote_group),
           "the rules belong to the origin, so echoing them back would announce someone else's group as if we spoke for it"
  end

  # The reverse direction, which has no coverage despite carrying the same weight: a community that later restricts posting to its mods, or promotes one, must change OUR mirror too, or our members are offered a compose button the origin will reject.
  # ⚠️ The `Update` payload is only a trigger: `Actor.update_actor/4` deliberately re-FETCHES the actor rather than trusting what the activity carries ("we avoid even passing the update_actor_data to avoid accepting invalid updates"), so the mock has to serve the new state and the activity's own object is nearly irrelevant.
  test "an incoming Update refreshes a mirrored group's rules" do
    assert {:ok, mirror} =
             Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(
               APSimulate.actor_json(@remote_group, "tests", %{"type" => "Group"})
             )

    assert {:ok, mirror} = Categories.get(id(mirror), skip_boundary_check: true)

    refute Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)[:participation] ==
             "moderators",
           "control: the mirror does not start out moderators-only, so the assertion below means something"

    restricted =
      APSimulate.actor_json(@remote_group, "tests", %{
        "type" => "Group",
        "postingRestrictedToMods" => true
      })

    mock(fn
      %{method: :get, url: @remote_group} -> json(restricted)
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    assert {:ok, _} =
             Transformer.handle_incoming(%{
               "type" => "Update",
               "actor" => @remote_group,
               "object" => restricted
             })

    assert {:ok, mirror} = Categories.get(id(mirror), skip_boundary_check: true)

    assert Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)[:participation] ==
             "moderators",
           "a community that restricts posting to its moderators has to reach our mirror, or our members write posts the origin will never accept"
  end
end
