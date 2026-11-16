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
  @private_community "https://voyager.lemmy.ml/c/privfedtest"
  @fixtures Path.join([__DIR__, "..", "fixtures"])

  setup do
    mock(fn
      %{method: :get, url: @community} ->
        json(fixture("lemmy", "community_actor.json"))

      %{method: :get, url: @private_community} ->
        json(fixture("lemmy", "community_actor_private.json"))

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

  # A community elsewhere is addressed only by a post whose boundary suits it: PieFed re-announces whatever `Create` is addressed to one of its communities as Public to all its followers, whatever the post's own `to` (`pyfedi/app/activitypub/routes.py:1895-1922`), and Lemmy refuses a non-public one in a public community. So a followers-only or mentions-only post in its thread goes to whom it names, and not to the community
  test "a post that isn't public isn't addressed to a public community elsewhere, while a public one is" do
    group = mirrored_community()
    user = fake_user!()
    post = post_in_group_as_composer_would(user, group, "<p>into the community</p>")
    post = repo().maybe_preload(post, [:tree, replied: [thread: [created: :creator]]])

    public = Bonfire.Federate.ActivityPub.AdapterUtils.determine_recipients(user, post, true)
    assert @community in public.cc, "control: a public post is addressed to the community"
    assert public.audience == @community

    not_public = Bonfire.Federate.ActivityPub.AdapterUtils.determine_recipients(user, post, false)

    refute @community in not_public.cc,
           "a non-public post was addressed to a public community elsewhere"

    assert is_nil(not_public.audience), "and named it as its audience, which PieFed reads too"
  end

  # Deleting a post of ours that's in a community elsewhere has to reach the community, which then relays it to its followers. Lemmy accepts a plain `Delete` of a post from anyone on the post's own instance who isn't banned from the community (`verify_delete_post_or_comment`, `verify_domains_match(actor, object_id)`), so the author's and our admin's both count, as long as the community is addressed
  describe "deleting a post of ours in a mirrored community" do
    test "by its author sends their Delete to the community" do
      group = mirrored_community()
      author = fake_user!()
      post = post_in_group_as_composer_would(author, group, "<p>soon gone</p>")
      {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)

      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: author)

      assert %{data: delete} = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
             "a Delete was sent"

      {:ok, %{ap_id: author_ap_id}} = ActivityPub.Actor.get_cached(pointer: author)
      assert delete["actor"] == author_ap_id

      assert @community in (List.wrap(delete["to"]) ++ List.wrap(delete["cc"])),
             "addressed to the community, so it reaches its inbox"
    end

    test "by an admin here sends a Delete to the community, from our instance" do
      group = mirrored_community()
      author = fake_user!()
      post = post_in_group_as_composer_would(author, group, "<p>soon gone</p>")
      {:ok, %{data: %{"id" => ap_id}}} = ActivityPub.Object.get_cached(pointer: post)
      {:ok, admin} = Bonfire.Me.Users.make_admin(fake_user!(), skip_boundary_check: true)

      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: admin)

      assert %{data: delete} = ActivityPub.Object.get_activity_for_object_ap_id(ap_id, "Delete"),
             "a Delete was sent"

      assert URI.parse(delete["actor"]).host == URI.parse(ap_id).host,
             "from someone on the post's own instance, which is what Lemmy checks"

      assert @community in (List.wrap(delete["to"]) ++ List.wrap(delete["cc"])),
             "addressed to the community, so it reaches its inbox"
    end
  end

  # A Lemmy community that approves its followers is a Private one (`community_visibility` in `crates/apub/objects/src/utils/functions.rs`), and `verify_visibility` there refuses an object with `Public` in `to`/`cc` in such a community. These tests record what we do about that today, so a change to it shows up here.
  describe "a Private Lemmy community (manuallyApprovesFollowers: true)" do
    defp private_mirror do
      assert {:ok, %Bonfire.Classify.Category{type: :group} = group} =
               Adapter.maybe_create_remote_actor(%{"id" => @private_community})

      group
    end

    # a local person who joined: the Join button sends a Follow, and the community's Accept of it (the captured shape, bound to this Follow) makes them a member
    defp member_of(group) do
      user = fake_user!()
      {:ok, user_actor} = ActivityPub.Actor.get_cached(pointer: user)

      assert {:ok, %{member: false, requested: true}} =
               Bonfire.Classify.Categories.join_and_follow_group(user, group)

      follow_activity =
        ActivityPub.Object.fetch_latest_activity(user_actor.ap_id, @private_community, "Follow")

      accept =
        fixture("mbin", "accept_follow_after_join.json")
        |> Map.put("actor", @private_community)
        |> put_in(["object", "id"], follow_activity.data["id"])
        |> put_in(["object", "actor"], user_actor.ap_id)
        |> put_in(["object", "object"], @private_community)

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(accept)

      assert Bonfire.Classify.Categories.member?(user, group),
             "control: the person is a member, so what follows is not about a non-member being refused"

      user
    end

    defp post_in(user, group, boundary) do
      assert {:ok, post} =
               Bonfire.Posts.publish(
                 current_user: user,
                 post_attrs: %{post_content: %{html_body: "<p>into the private community</p>"}},
                 context_id: uid(group),
                 to_circles: ClassifyBoundaries.post_circles_for_group(group),
                 to_boundaries: [boundary]
               )

      post
    end

    defp wire(post) do
      assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)
      Map.take(data, ["to", "cc", "audience"])
    end

    test "the actor declares itself as one" do
      actor = fixture("lemmy", "community_actor_private.json")

      assert actor["manuallyApprovesFollowers"] == true,
             "control: the capture is a community that approves its followers"
    end

    test "is mirrored as on request to join, global to read, and members-only to post" do
      dims = Bonfire.Boundaries.Presets.group_dimension_slugs(private_mirror())

      assert dims[:membership] == "on_request"
      assert dims[:visibility] == "global"
      assert dims[:participation] == "group_members"
    end

    test "a public post in it is addressed publicly, to the community, with it as audience" do
      group = private_mirror()
      post = post_in(member_of(group), group, "public")
      wire = wire(post)

      assert ActivityPub.Config.public_uri() in (List.wrap(wire["to"]) ++ List.wrap(wire["cc"])),
             "Public is in to/cc, which Lemmy refuses in a Private community"

      assert @private_community in (List.wrap(wire["to"]) ++ List.wrap(wire["cc"]))
      assert wire["audience"] == @private_community
    end

    test "a post that isn't public in it is not addressed to the community" do
      group = private_mirror()
      user = member_of(group)
      post = post_in(user, group, "public")
      post = repo().maybe_preload(post, [:tree, replied: [thread: [created: :creator]]])

      recipients =
        Bonfire.Federate.ActivityPub.AdapterUtils.determine_recipients(user, post, false)

      addressed = List.wrap(recipients.to) ++ List.wrap(recipients.cc)

      refute ActivityPub.Config.public_uri() in addressed

      refute @private_community in addressed,
             "so Lemmy never receives it: it is accepted there only when addressed to the community and its followers, never Public"

      assert is_nil(recipients.audience)
    end
  end
end
