defmodule Bonfire.Federate.ActivityPub.GroupSensitivePostsTest do
  @moduledoc """
  A post arriving in a group marked sensitive is stored sensitive when it says nothing either way: Lemmy and PieFed comments carry no `sensitive` field at all, so a comment in a NSFW community would otherwise arrive here unmarked. A post that says `sensitive: false` keeps it, unlike on Lemmy, PieFed and Mbin, which mark every post in a NSFW community whatever it says.

  Two ways a post is in a group here: addressed to one of our groups (`AdapterUtils.local_group_audiences/2`), or relayed by a remote community we mirror (`AdapterUtils.mirrored_group/2`).
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures

  alias Bonfire.Classify.Simulate
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate
  alias ActivityPub.Federator.Transformer
  alias Bonfire.Social.Objects

  @lemmy_author "https://lemmy.local/u/mayel"
  @lemmy_comment "https://lemmy.local/comment/27985030"
  @bonfire_author "https://bonfire-remote.local/pub/actors/ada"
  @bonfire_note "https://bonfire-remote.local/pub/objects/01JBONFIRENOTE000000000001"
  @bonfire_sensitive_note "https://bonfire-remote.local/pub/objects/01JBONFIRENOTE000000000002"
  @group_placeholder "https://bonfire.local/pub/group/GROUP"
  @public "https://www.w3.org/ns/activitystreams#Public"

  @lemmy_nsfw %{
    name: "Lemmy",
    dir: "lemmy",
    id: "https://lemmy.local/c/nsfw_art",
    actor: "community_actor_nsfw.json",
    announces: ["announce_create_page_nsfw.json", "announce_create_note_nsfw.json"]
  }
  @piefed_nsfw %{
    name: "PieFed",
    dir: "piefed",
    id: "https://piefed.local/c/nsfw_photos",
    actor: "community_actor_nsfw.json",
    announces: ["announce_create_page_nsfw.json", "announce_create_note_nsfw.json"]
  }

  setup do
    served =
      Map.new(
        served_for([@lemmy_nsfw, @piefed_nsfw]) ++
          [
            {@lemmy_author, APSimulate.actor_json(@lemmy_author, "mayel")},
            {@bonfire_author, author_actor(@bonfire_author)}
          ]
      )

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

  defp sensitive?(ap_id) do
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id),
           "the post was not stored"

    assert {:ok, post} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true)
    e(repo().maybe_preload(post, :sensitive), :sensitive, :is_sensitive, false) == true
  end

  defp local_group!(marked?) do
    creator = fake_user!()
    group = Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    if marked?, do: assert({:ok, _} = Objects.set_sensitivity(group, true))

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: group)
    %{creator: creator, group: group, group_ap_id: actor.ap_id}
  end

  defp to_group(dir, file, group_ap_id) do
    Path.join([__DIR__, "..", "fixtures", dir, file])
    |> File.read!()
    |> String.replace(@group_placeholder, group_ap_id)
    |> Jason.decode!()
  end

  # the Lemmy comment, as a reply to a post published in the group
  defp lemmy_comment_in(%{creator: creator, group: group, group_ap_id: group_ap_id}) do
    assert {:ok, parent} =
             Bonfire.Posts.publish(
               current_user: creator,
               post_attrs: %{post_content: %{html_body: "<p>a post to reply to</p>"}},
               boundary: "public",
               publish_in: uid(group)
             )

    {:ok, %{data: %{"id" => parent_ap_id}}} = ActivityPub.Object.get_cached(pointer: parent)
    creator_ap_id = ActivityPub.Actor.get_cached!(pointer: creator).ap_id

    to_group("lemmy", "create_note_reply_in_group.json", group_ap_id)
    |> Jason.encode!()
    |> String.replace("https://bonfire.local/pub/objects/PARENT", parent_ap_id)
    |> String.replace("https://bonfire.local/pub/person/AUTHOR", creator_ap_id)
    |> Jason.decode!()
  end

  describe "in one of our groups" do
    test "a Note with `sensitive: true` is stored sensitive" do
      %{group_ap_id: group_ap_id} = local_group!(false)

      assert {:ok, _} =
               Transformer.handle_incoming(
                 to_group("bonfire", "create_note_to_group_sensitive.json", group_ap_id)
               )

      assert sensitive?(@bonfire_sensitive_note) == true
    end

    test "a Lemmy comment in a group not marked sensitive is stored not sensitive" do
      incoming = lemmy_comment_in(local_group!(false))
      refute Map.has_key?(incoming["object"], "sensitive"), "control: Lemmy comments say nothing"

      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert sensitive?(@lemmy_comment) == false
    end

    test "a Bonfire Note with `sensitive: false` in a group marked sensitive is stored not sensitive" do
      %{group_ap_id: group_ap_id} = local_group!(true)

      assert {:ok, _} =
               Transformer.handle_incoming(
                 to_group("bonfire", "create_note_to_group.json", group_ap_id)
               )

      assert sensitive?(@bonfire_note) == false,
             "its author said it is not sensitive, which we keep"
    end

    test "a Lemmy comment, which has no `sensitive`, in our group marked sensitive is stored sensitive" do
      incoming = lemmy_comment_in(local_group!(true))

      assert {:ok, _} = Transformer.handle_incoming(incoming)
      assert sensitive?(@lemmy_comment) == true
    end
  end

  describe "relayed by a NSFW community we mirror" do
    for imp <- [@lemmy_nsfw, @piefed_nsfw] do
      test "a #{imp.name} comment, which has no `sensitive`, is stored sensitive" do
        imp = unquote(Macro.escape(imp))
        assert {:ok, _} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(imp.id)

        [page_file, note_file] = imp.announces
        receive_announce(fixture(imp.dir, page_file))

        announce = fixture(imp.dir, note_file)
        note = announce["object"]["object"]
        refute Map.has_key?(note, "sensitive"), "control: its comments say nothing"

        receive_announce(announce)
        assert sensitive?(note["id"]) == true
      end
    end

    test "an Update of that Lemmy comment keeps it sensitive" do
      imp = @lemmy_nsfw
      assert {:ok, _} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(imp.id)

      [page_file, note_file] = imp.announces
      receive_announce(fixture(imp.dir, page_file))

      announce = fixture(imp.dir, note_file)
      create = announce["object"]
      note = create["object"]
      receive_announce(announce)
      assert sensitive?(note["id"]) == true, "control: stored sensitive"

      unique = System.unique_integer([:positive])

      update = %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => "#{note["id"]}/update/#{unique}",
        "type" => "Update",
        "actor" => create["actor"],
        "to" => [@public, "#{imp.id}/followers"],
        "audience" => imp.id,
        "object" => Map.put(note, "content", "<p>edited by its author</p>")
      }

      assert {:ok, _} =
               Transformer.handle_incoming(%{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "id" => "#{imp.id}/activities/announce/#{unique}",
                 "type" => "Announce",
                 "actor" => imp.id,
                 "to" => [@public],
                 "cc" => ["#{imp.id}/followers"],
                 "object" => update
               })

      assert sensitive?(note["id"]) == true,
             "an edit that says nothing about it does not unmark it"
    end
  end
end
