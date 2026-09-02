defmodule Bonfire.Federate.ActivityPub.GroupMobilizonInteropTest do
  @moduledoc """
  Mobilizon groups, which are real community groups rather than a `Group` actor used for something else.

  They have membership proper: `Member` objects carrying roles (invited / not_approved / member / moderator, in a custom `mz:` namespace that predates the FEPs), a `members` collection, a `memberCount`, and separate `discussions`, `events`, `posts`, `resources` and `todos` endpoints. That makes them the closest existing prior art for the member management the non-public plan wants, which is why they are worth their own module rather than a line in a comparison table.

  What they do NOT have is group-actor relay: distribution goes through an instance-level relay actor, and Mobilizon's own docs say federation "fully works only between Mobilizon instances". So there is no announce shape here for us to consume, and these tests are about the ACTOR — what a Mobilizon group becomes when we mirror it.

  ⚠️ The capture (2026-09-02, live public group, hosts rewritten) surfaced a mapping bug: it declares `manuallyApprovesFollowers: false` AND `openness: "moderated"`. Those do not contradict each other, because following and joining are different acts here, and Bonfire models them separately too — `Categories.join_group/3` adds someone to the members circle, and has its own branch for people who already follow. We nevertheless read `manuallyApprovesFollowers` as the membership signal, which is only correct where follow IS join, as in the threadiverse.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @group "https://mobilizon.local/@framasoft"

  setup do
    served = %{@group => fixture("group_actor.json")}

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

  test "becomes a local group, carrying its own name" do
    assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => @group})

    assert %Bonfire.Classify.Category{type: :group} = group

    assert e(repo().maybe_preload(group, :profile), :profile, :name, nil) == "Framasoft",
           "a mirrored group should be browsable, which starts with its own name"
  end

  # ⚠️ RED deliberately: the mis-mirroring the capture uncovered. Bonfire already separates joining
  # from following, so this is a mapping gap rather than a modelling one.
  @tag :todo
  test "mirrors moderated JOINING, which is not the same as open following" do
    actor = fixture("group_actor.json")

    assert actor["manuallyApprovesFollowers"] == false and actor["openness"] == "moderated",
           "the fixture should carry both, since the whole point is that they differ"

    assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => @group})

    assert Bonfire.Boundaries.Presets.group_dimension_slugs(group)[:membership] == "on_request",
           "the origin moderates who joins, so our mirror must not present joining as open"
  end

  # The roles are the prior art the non-public plan builds on, so pin what the actor advertises:
  # without a `members` collection there is nothing to sync when that work starts.
  test "advertises its membership, which is what member sync would read" do
    actor = fixture("group_actor.json")

    assert actor["members"] =~ "/members"
    assert is_integer(actor["memberCount"])
  end

  defp fixture(name) do
    @fixtures |> Path.join("mobilizon") |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
