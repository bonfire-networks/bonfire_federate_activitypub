defmodule Bonfire.Federate.ActivityPub.GroupRemotePostingTest do
  @moduledoc """
  Writing a post into a MIRRORED remote community, from the instance doing the writing.

  This is the direction the group-page composer takes when the group lives somewhere else, and the whole point of the post is to reach that community's instance. Lemmy rejects a post that is not public (`Public` must be in `to`/`cc`), and every other 1b12 implementation files a group post into a public feed, so a post addressed to the group alone is delivered and then invisible — which is exactly how it failed in production on 2026-09-05.

  The boundary comes from the mirror's own `default_content_visibility`, which nobody here chose: `Categories.create_remote/2` derives the mirror's dimensions from what the community's actor declares, an actor that declares no join restriction is treated as open, and open cascades to `global` visibility. So the addressing asserted here is the end of a chain that starts at a remote actor document, which is why it is worth asserting at the wire rather than at the setting.

  The composer opts are taken from `Bonfire.Classify.Boundaries` rather than hardcoded, so this tracks what `group_live.sface` actually passes instead of a copy of it that can drift.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Boundaries, as: ClassifyBoundaries
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.Outgoing

  @community "https://lemmy.local/c/technology"
  @fixtures Path.join([__DIR__, "..", "fixtures"])

  setup do
    mock(fn
      %{method: :get, url: @community} ->
        json(fixture("lemmy", "community_actor.json"))

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp mirrored_community do
    assert {:ok, %Bonfire.Classify.Category{type: :group} = group} =
             Adapter.maybe_create_remote_actor(%{"id" => @community})

    group
  end

  # Mirrors what the group page hands the smart input (`group_live.sface`): the group's stored default content visibility as the boundary, and the group itself as a circle so the post is addressed to it.
  defp post_in_group_as_composer_would(user, group, html_body) do
    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: user,
               post_attrs: %{post_content: %{html_body: html_body}},
               context_id: uid(group),
               to_circles: ClassifyBoundaries.post_circles_for_group(group),
               to_boundaries: List.wrap(ClassifyBoundaries.read_default_content_visibility(group))
             )

    post
  end

  defp addressing(post) do
    assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)
    List.wrap(data["to"]) ++ List.wrap(data["cc"])
  end

  test "a mirrored community defaults its posts to a federating boundary" do
    group = mirrored_community()

    assert ClassifyBoundaries.read_default_content_visibility(group) == "public",
           "the mirror's dimensions cascade to `global` visibility, whose posts have to federate — anything else is a boundary that keeps the post on the instance that wrote it"
  end

  test "a post written into a mirrored community is addressed publicly" do
    group = mirrored_community()
    post = post_in_group_as_composer_would(fake_user!(), group, "<p>into the community</p>")

    assert ActivityPub.Config.public_uri() in addressing(post),
           "Lemmy rejects a post with no `Public` in to/cc outright, and the rest of the threadiverse files it where nobody can see it"
  end

  test "and still names the community it belongs to" do
    group = mirrored_community()
    post = post_in_group_as_composer_would(fake_user!(), group, "<p>into the community</p>")

    assert {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)

    assert @community == actor.ap_id,
           "control: the mirror resolves back to the community's own id, so the assertions below are about that community"

    assert actor.ap_id in addressing(post),
           "Lemmy reads addressing from to/cc alone, so a post that names the community only in `audience` is delivered but never filed"

    assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)

    assert data["audience"] == actor.ap_id,
           "FEP-1b12 marks belonging with `audience`, so a group post without it is just a post"
  end

  # The regression guard proper: the failure in production was not a missing group, it was a boundary that dropped `Public` while keeping the group, so the post looked correctly addressed until you checked what was NOT there.
  test "the post is not addressed to the community alone" do
    group = mirrored_community()
    post = post_in_group_as_composer_would(fake_user!(), group, "<p>into the community</p>")

    assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)

    refute List.wrap(data["to"]) == [] and List.wrap(data["cc"]) == [@community],
           "this is the exact shape the production report produced: the community in `cc`, nothing in `to`, no `Public` anywhere"
  end
end
