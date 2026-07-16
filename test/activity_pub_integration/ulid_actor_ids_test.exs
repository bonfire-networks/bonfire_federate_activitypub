defmodule Bonfire.Federate.ActivityPub.UlidActorIdsTest do
  @moduledoc """
  Phase 2: NEW local actors (created after a configured ULID cutoff) federate with a
  ULID-based `id` — `/pub/person/<ULID>`, `/pub/group/<ULID>` — instead of the
  username-based `/pub/actors/<username>`. Existing actors keep username URLs, and
  WebFinger keeps advertising `acct:<username>@host`.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  alias Bonfire.Common.URIs
  alias Bonfire.Common.Types
  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  # lexicographic bounds: every real ULID sorts between these two.
  @all_new String.duplicate("0", 26)
  @all_old String.duplicate("Z", 26)

  # cutoffs live under IdCutoffs `:recorded` (in test env, config/test.exs records epoch-zero so the NEW scheme is on by default); Application.put_env because conn requests read the cutoff in other processes. `set_cutoff(nil)` covers the never-recorded case.
  @cutoffs_module Bonfire.Common.Settings.IdCutoffs

  setup do
    original = Application.get_env(:bonfire_common, @cutoffs_module)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:bonfire_common, @cutoffs_module)
        v -> Application.put_env(:bonfire_common, @cutoffs_module, v)
      end
    end)

    :ok
  end

  defp set_cutoff(v) do
    Application.put_env(
      :bonfire_common,
      @cutoffs_module,
      Keyword.put(
        Application.get_env(:bonfire_common, @cutoffs_module) || [],
        :recorded,
        ulid_actor_ids_since: v
      )
    )
  end

  describe "canonical_url generation with the ULID cutoff" do
    test "a post-cutoff USER federates as /pub/person/<ULID>" do
      set_cutoff(@all_new)
      user = fake_user!()

      # preload_if_needed: true because this test calls canonical_url directly on a fresh user
      # that hasn't preloaded :shared_user (federation code paths preload it at the source)
      assert URIs.canonical_url(user, preload_if_needed: true) =~ "/pub/person/#{user.id}"
      refute URIs.canonical_url(user, preload_if_needed: true) =~ "/pub/actors/"
    end

    test "a shared user (organisation) federates as /pub/organization/<ULID>" do
      set_cutoff(@all_new)
      user = fake_user!()
      # a shared user is a User carrying a SharedUser mixin (a team/organisation account)
      org = %{user | shared_user: %Bonfire.Data.SharedUser{label: "Test Org"}}

      assert URIs.canonical_url(org) =~ "/pub/organization/#{user.id}"
      refute URIs.canonical_url(org) =~ "/pub/person/"
    end

    test "the service/instance actor keeps its username URL even under the cutoff" do
      # the service actor is a User with a hand-crafted id that sorts AFTER real ULIDs, so a naive
      # `id > cutoff` would wrongly treat it as new — it must be exempted (reserved_username_actor_ids).
      set_cutoff(@all_new)
      user = fake_user!()
      svc = %{user | id: AdapterUtils.service_character_id()}

      assert URIs.canonical_url(svc) =~ "/pub/actors/"
      refute URIs.canonical_url(svc) =~ "/pub/person/"
    end

    test "a post-cutoff GROUP federates as /pub/group/<ULID>" do
      set_cutoff(@all_new)
      user = fake_user!()

      {:ok, group} =
        Categories.create(user, %{name: "Ulid Group #{System.unique_integer([:positive])}"}, true)

      group = repo().maybe_preload(group, [:character])

      assert URIs.canonical_url(group) =~ "/pub/group/#{group.id}"
      refute URIs.canonical_url(group) =~ "/pub/actors/"
    end

    test "a post-cutoff USER passed as a (virtual) Pointer still gets the person URL (mention/batch path)" do
      # mention resolution and `get_actors_by_ids` hand actor formatting a `%Needle.Pointer{}`,
      # not a concrete `%User{}` — the type segment must resolve via the pointer's table_id,
      # else it falls back to the username URL and mentions/cc diverge from the canonical actor id
      user = fake_user!()
      {:ok, pointer} = Bonfire.Common.Needles.one(user.id, skip_boundary_check: true)

      pointer =
        repo().maybe_preload(pointer, [:shared_user, character: [:peered]], prune: true)

      assert URIs.canonical_url(pointer) =~ "/pub/person/#{user.id}"
      refute URIs.canonical_url(pointer) =~ "/pub/actors/"
    end

    test "a POST passed as a (virtual) Pointer gets the object URL, not misclassified as an actor" do
      # regression: a bare `%Needle.Pointer{}` carries a VIRTUAL `:character` field, so
      # `canonical_url` wrongly matched the actor clause and tripped its `character: [:peered]`
      # preload guard even though the pointer is a Post. It must resolve the virtual pointer to the
      # concrete `%Post{}` (which has no `:character`) and build the OBJECT url.
      set_cutoff(@all_new)
      user = fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: "an object, not an actor"}},
          boundary: "public"
        )

      # keep the pointer BARE: preloading a concrete assoc (e.g. `created:`) would follow the virtual
      # and hand `canonical_url` a `%Post{}` directly, bypassing the very Pointer-resolution clause under
      # test. A bare pointer still carries the virtual `:character` — the OLD code matched the actor clause
      # on it and raised for `character: [:peered]`. `preload_if_needed: true` lets the resolved `%Post{}`
      # lazily load its locality assoc (the deliberate lazy-caller opt, as on the guest-interaction path).
      {:ok, pointer} = Bonfire.Common.Needles.one(post.id, skip_boundary_check: true)
      assert %Needle.Pointer{} = pointer

      url = URIs.canonical_url(pointer, preload_if_needed: true)
      assert url =~ "/pub/objects/#{post.id}"
      refute url =~ "/pub/person/"
      refute url =~ "/pub/actors/"
    end

    test "a pre-cutoff USER keeps the username URL" do
      set_cutoff(@all_old)
      user = fake_user!()

      assert URIs.canonical_url(user) =~ "/pub/actors/#{user.character.username}"
      refute URIs.canonical_url(user) =~ "/pub/person/"
    end

    test "with the cutoff unset, everything keeps the username URL" do
      set_cutoff(nil)
      user = fake_user!()

      assert URIs.canonical_url(user) =~ "/pub/actors/#{user.character.username}"
    end
  end

  describe "incoming resolution of ULID actor URLs" do
    test "get_local_character_by_ap_id resolves /pub/person/<ULID> to the user" do
      set_cutoff(@all_new)
      user = fake_user!()
      ap_id = URIs.canonical_url(user, preload_if_needed: true)
      assert ap_id =~ "/pub/person/"

      assert Types.uid(AdapterUtils.get_local_character_by_ap_id(ap_id)) == user.id
    end

    test "get_or_fetch_pointable_by_ap_id resolves /pub/person/<ULID> to the user" do
      set_cutoff(@all_new)
      user = fake_user!()
      ap_id = URIs.canonical_url(user, preload_if_needed: true)

      assert {:ok, pointable} = AdapterUtils.get_or_fetch_pointable_by_ap_id(ap_id)
      assert Types.uid(pointable) == user.id
    end

    test "get_or_fetch_pointable_by_ap_id resolves /pub/group/<ULID> to the group" do
      set_cutoff(@all_new)
      user = fake_user!()

      {:ok, group} =
        Categories.create(user, %{name: "Res Group #{System.unique_integer([:positive])}"}, true)

      ap_id = URIs.canonical_url(repo().maybe_preload(group, [:character]))
      assert ap_id =~ "/pub/group/"

      assert {:ok, pointable} = AdapterUtils.get_or_fetch_pointable_by_ap_id(ap_id)
      assert Types.uid(pointable) == group.id
    end
  end

  describe "serving ULID actor documents + canonical 301s" do
    test "GET /pub/person/<ULID> serves the actor JSON with the ULID id" do
      set_cutoff(@all_new)
      user = fake_user!()

      ret =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/person/#{user.id}")
        |> response(200)
        |> Jason.decode!()

      assert ret["id"] =~ "/pub/person/#{user.id}"
      assert ret["preferredUsername"] == user.character.username
    end

    test "a real shared user serves actor JSON with type Organization at /pub/organization/<ULID>" do
      set_cutoff(@all_new)
      user = fake_user!()
      Bonfire.Me.SharedUsers.init_shared_user(user, %{"label" => "Test Org"})

      ret =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/organization/#{user.id}")
        |> response(200)
        |> Jason.decode!()

      assert ret["type"] == "Organization"
      assert ret["id"] =~ "/pub/organization/#{user.id}"
      assert ret["preferredUsername"] == user.character.username
    end

    test "GET /pub/actors/<username> for a post-cutoff user 301s to the ULID URL" do
      set_cutoff(@all_new)
      user = fake_user!()

      loc =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/actors/#{user.character.username}")
        |> redirected_to(301)

      assert loc =~ "/pub/person/#{user.id}"
    end

    test "GET /pub/person/<ULID> for a pre-cutoff user 301s to the username URL" do
      set_cutoff(@all_old)
      user = fake_user!()

      loc =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/pub/person/#{user.id}")
        |> redirected_to(301)

      assert loc =~ "/pub/actors/#{user.character.username}"
    end
  end

  describe "WebFinger stays username-based for a ULID-id actor" do
    test "acct: subject uses the username while aliases point at the ULID id" do
      set_cutoff(@all_new)
      user = fake_user!()
      username = user.character.username

      {:ok, actor} = ActivityPub.Actor.get_cached(username: username)
      wf = ActivityPub.Federator.WebFinger.represent_user(actor)

      # the handle advertised to the network is still the username, NOT the ULID
      assert wf["subject"] =~ "acct:#{username}@"
      refute wf["subject"] =~ user.id

      # but the actor it resolves to is the ULID-based id
      assert actor.data["id"] =~ "/pub/person/#{user.id}"

      assert Enum.any?(
               List.wrap(wf["aliases"]),
               &(is_binary(&1) and &1 =~ "/pub/person/#{user.id}")
             )
    end
  end
end
