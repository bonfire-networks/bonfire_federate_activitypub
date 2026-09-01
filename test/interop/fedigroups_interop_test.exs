defmodule Bonfire.Federate.ActivityPub.FediGroupsInteropTest do
  @moduledoc """
  Interop pass for FediGroups: what Bonfire does with a real bot-group Announce.

  The fixtures are REAL captures from a bot-group's public outbox (2026-08-25), not hand-written approximations, so these exercise the ingest path against the wire shape that family actually sends. Instance hostnames are rewritten to `.local` stand-ins; provenance is in the group federation plan. FediGroups is stock Mastodon plus a polling bot, standing in for the whole mention-triggered bot-group family (tootgroup.py, MightyPork's group-actor), the opposite pole from Lemmy's FEP-1b12 shape.

  What makes this family awkward, and what these tests are really about: the announced post carries **no `audience`**, which is the property FEP-1b12 uses to say "this belongs to that group". The group appears only in `cc` and as a `Mention` tag, so attribution has to fall back to those.

  Tagged `:todo` because the Phase 4 incoming work is not implemented yet — these are its spec, and should be un-tagged as it lands rather than rewritten.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @fixtures Path.join([__DIR__, "..", "fixtures", "fedigroups"])
  @group_actor "https://fedigroups.local/users/xmpp"

  setup do
    note = fixture("announced_note_root.json")

    by_url = %{
      @group_actor => fixture("service_group_actor.json"),
      note["id"] => note,
      note["attributedTo"] => author_actor(note["attributedTo"])
    }

    mock(fn %{method: :get, url: url} ->
      case by_url[url] do
        nil -> %Tesla.Env{status: 404, body: ""}
        body -> json(body)
      end
    end)

    {:ok, announce: fixture("announce_note_root.json"), note: note}
  end

  test "the announced post is created, still attributed to its original author", %{
    announce: announce,
    note: note
  } do
    with_rewrite_config(fn ->
      post = receive_announce!(announce)

      assert e(post, :post_content, :html_body, nil) =~ "Quicksy",
             "the announced note's content should land locally"

      assert URIs.canonical_url(e(post, :created, :creator, nil)) == note["attributedTo"],
             "attribution stays with the original author, never the boosting group"
    end)
  end

  test "the announced post appears in the group's feed", %{announce: announce} do
    with_rewrite_config(fn ->
      post = receive_announce!(announce)

      group = AdapterUtils.get_character_by_ap_id!(@group_actor)

      assert %Bonfire.Classify.Category{} = group,
             "the Service actor should have been rewritten to a group by the allowlist"

      # A group's outbox feed IS how this codebase represents "post is in the group" — the same
      # check `groups_tag_mentions_test.exs` makes for a locally-mentioned group.
      assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
               by: group,
               current_user: group
             ),
             "the announced post should land in the group's feed"

      # FediGroups sends BOTH an Announce and a Mention, and either alone would put the post in
      # that feed — so record which mechanism actually did it, rather than assuming. Note these are
      # not independent: `Tags.maybe_auto_boost/4` means tagging a boostable category CAUSES a
      # boost, so the Mention alone can produce both.
      assert Bonfire.Social.Boosts.boosted?(group, post),
             "expected a boost by the group"

      assert Enum.any?(e(post, :tags, []), &(id(&1) == id(group))),
             "expected the group to be tagged on the post (from the Mention), which is what makes it a post IN the group rather than merely one the group boosted"
    end)
  end

  # The degrade-gracefully case: an operator who has opted OUT should still get the post, just from
  # a plain remote actor rather than a group. Note this needs the config explicitly emptied — since
  # the shipped default allowlists `fedigroups.local`, "didn't configure anything" is now the
  # rewritten case, not the unrewritten one.
  test "with the rewrite opted out, the boost still arrives but creates no group", %{
    announce: announce
  } do
    with_rewrite_config([], fn ->
      post = receive_announce!(announce)

      assert e(post, :post_content, :html_body, nil) =~ "Quicksy"

      refute match?(
               %Bonfire.Classify.Category{},
               AdapterUtils.get_character_by_ap_id!(@group_actor)
             ),
             "opted out, the Service actor should stay a plain remote actor"
    end)
  end

  # Ingest the Announce and return the LOCAL post it produced.
  #
  # Deliberately asserts on resulting state rather than on the return value: boost-edge creation reports `{:error, "You already boosted this."}` when fetching the announced object created the edge first, which is benign (see `peertube_announced_video_linked_test.exs`, which tolerates the same thing at a later point in the pipeline). Treating that as failure would test our plumbing instead of the interop behaviour we care about.
  defp receive_announce!(announce) do
    case ActivityPub.Federator.Transformer.handle_incoming(announce) do
      {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      {:error, _already_boosted} -> :ok
    end

    announced_post!(announce["object"])
  end

  defp announced_post!(ap_id) do
    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: ap_id),
           "the announced object should be stored as an ap_object"

    refute is_nil(pointer_id),
           "the announced object's ap_object must be linked to a local record, not orphaned"

    Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)
    # `character: [:peered]` nested under the creator, since `canonical_url/1` needs the peered
    # record to build a remote actor's URL and refuses to preload it on demand
    |> repo().maybe_preload([
      :post_content,
      :activity,
      :tags,
      created: [creator: [character: [:peered]]]
    ])
  end

  # the announced note's author, fetched by the adapter while ingesting the post.
  # `Simulate.actor_json/1` only matches a few hardcoded URLs, so start from one of those and swap
  # in the real actor's identity.
  defp author_actor(ap_id) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
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

  defp with_rewrite_config(config \\ [{{"Service", "Group"}, ["fedigroups.local"]}], fun) do
    previous = Application.get_env(:bonfire_federate_activitypub, :rewrite_actor_types)

    Application.put_env(:bonfire_federate_activitypub, :rewrite_actor_types, config)

    try do
      fun.()
    after
      Application.put_env(:bonfire_federate_activitypub, :rewrite_actor_types, previous)
    end
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
