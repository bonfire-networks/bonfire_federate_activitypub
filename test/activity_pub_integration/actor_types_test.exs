defmodule Bonfire.Federate.ActivityPub.ActorTypesTest do
  @moduledoc """
  How an AP actor's `type` maps to a local schema, in both directions. See the "Non-`Group` actors"
  section of the public group federation plan.

  Today the type does exactly one thing: pick a context module at `AdapterUtils.character_module/1`
  (`adapter_utils.ex:1666`). `Service`/`Application`/`Organization` are registered to
  `Bonfire.Me.SharedUsers` (`shared_users.ex:21`), but that module implements neither
  `create_remote/2` nor `create/2`, so `maybe_apply_or` silently falls back to
  `Users.create_remote/2` and the type is discarded.

  These tests pin the decided end state. Tests marked RED fail until that lands.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Me.Users
  alias Bonfire.Common.URIs

  @remote_instance "https://mocked.local"
  # resolved relative to this file, NOT to the cwd: CI builds the extension from `deps/`, where an app-root-relative path points at nothing
  @fixture Path.join([__DIR__, "..", "fixtures", "fedigroups", "service_group_actor.json"])
  @fedigroups_actor "https://fedigroups.local/users/xmpp"
  @other_host_actor "https://elsewhere.local/users/notagroup"
  @sibling_actor "https://fedigroups.local/users/sibling"

  # actors served to the adapter, which fetches/verifies over HTTP
  @remote_actors [
    {"Service", "a_service"},
    {"Service", "a_service_2"},
    {"Application", "an_app"},
    {"Organization", "an_org"},
    {"Person", "a_person"}
  ]

  setup do
    from_simulate =
      Map.new(@remote_actors, fn {type, username} ->
        ap_id = "#{@remote_instance}/users/#{username}"
        {ap_id, typed_actor_json(ap_id, type)}
      end)

    from_fixture =
      Map.new([@fedigroups_actor, @other_host_actor, @sibling_actor], &{&1, fixture_actor(&1)})

    by_url = Map.merge(from_simulate, from_fixture)

    mock(fn
      %{method: :get, url: url} ->
        case by_url[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end
    end)

    :ok
  end

  # ------------------------------------------------------------------
  # incoming: type picks the local schema
  # ------------------------------------------------------------------

  describe "incoming non-Person actors become shared users" do
    test "RED: a Service actor becomes a User with a SharedUser mixin labelled Service" do
      user = create_remote!("#{@remote_instance}/users/a_service")

      assert %Bonfire.Data.Identity.User{} = user

      assert e(user, :shared_user, :label, nil) == "Service",
             "expected a SharedUser mixin labelled Service, got #{inspect(e(user, :shared_user, nil))} — today the AP type is discarded and this is a plain remote User"
    end

    test "RED: an Application actor becomes a User labelled Application" do
      user = create_remote!("#{@remote_instance}/users/an_app")
      assert e(user, :shared_user, :label, nil) == "Application"
    end

    # the label is stored as the AS2 type verbatim (so it round-trips back out unchanged), hence the American spelling here
    test "RED: an Organization actor becomes a User labelled Organization" do
      user = create_remote!("#{@remote_instance}/users/an_org")
      assert e(user, :shared_user, :label, nil) == "Organization"
    end

    test "a Person actor gets NO SharedUser mixin" do
      user = create_remote!("#{@remote_instance}/users/a_person")

      assert %Bonfire.Data.Identity.User{} = user
      assert is_nil(e(user, :shared_user, nil)), "a plain Person must not become a shared user"
    end
  end

  describe "SharedUsers gaps that the remote path hits" do
    # `init_shared_user/3` calls `do_add_account(shared_user, nil)`, which has no matching clause
    # (`shared_users.ex:197-212`), so the remote path (no local account) crashes.
    test "RED: init_shared_user/3 works with no acting account" do
      user = Bonfire.Me.Fake.fake_user!()

      assert %Bonfire.Data.SharedUser{label: "Service"} =
               Bonfire.Me.SharedUsers.init_shared_user(user, "Service", nil)
    end

    # `authorized_to_manage?(_user, nil)` returns true (`shared_users.ex:188`), so a nil acting
    # account counts as authorised — remote actors must not become locally co-manageable.
    test "RED: add_account/4 refuses to add an account to a REMOTE shared user" do
      remote = create_remote!("#{@remote_instance}/users/a_service_2")
      account = Bonfire.Me.Fake.fake_account!()

      refute match?({:ok, _}, Bonfire.Me.SharedUsers.add_account(remote, account, nil, nil)),
             "a remote actor must not be co-managed by a local account"
    end
  end

  # ------------------------------------------------------------------
  # incoming: admin allowlist rewrites a bot-group's type
  # ------------------------------------------------------------------

  describe "rewriting a configured Service actor to Group" do
    test "the saved fixture is a real Service actor, not a Group" do
      assert fixture_json()["type"] == "Service",
             "fixture should capture what these services actually send"
    end

    test "RED: an allowlisted host's Service actor becomes a group Category" do
      with_rewrite_config([{{"Service", "Group"}, ["fedigroups.local"]}], fn ->
        assert {:ok, character} =
                 Adapter.maybe_create_remote_actor(fixture_actor(@fedigroups_actor))

        assert %Bonfire.Classify.Category{} = character,
               "expected a Category, got #{inspect(character.__struct__)} — no rewrite applied"

        assert e(character, :type, nil) == :group,
               "a rewritten group needs type: :group (also guards the Categories.create_remote/2 WIP stub)"
      end)
    end

    test "a Service actor from a NON-configured host is untouched" do
      with_rewrite_config([{{"Service", "Group"}, ["fedigroups.local"]}], fn ->
        assert {:ok, character} =
                 Adapter.maybe_create_remote_actor(fixture_actor(@other_host_actor))

        refute match?(%Bonfire.Classify.Category{}, character),
               "only allowlisted hosts may be rewritten"
      end)
    end

    test "a full-URI entry matches only that actor, not siblings on the same host" do
      with_rewrite_config([{{"Service", "Group"}, [@fedigroups_actor]}], fn ->
        assert {:ok, sibling} = Adapter.maybe_create_remote_actor(fixture_actor(@sibling_actor))
        refute match?(%Bonfire.Classify.Category{}, sibling)
      end)
    end

    test "RED: re-fetching keeps it a group and creates no second object" do
      with_rewrite_config([{{"Service", "Group"}, ["fedigroups.local"]}], fn ->
        assert {:ok, first} = Adapter.maybe_create_remote_actor(fixture_actor(@fedigroups_actor))
        assert {:ok, again} = Adapter.maybe_create_remote_actor(fixture_actor(@fedigroups_actor))

        assert id(first) == id(again), "re-fetch must not mint a second local object"
        assert %Bonfire.Classify.Category{} = again
      end)
    end

    # DECIDED: we record what the remote sent, and decide separately what to make of it locally.
    # Asserted so nobody later "fixes" the AP record into agreeing with the rewrite.
    test "the stored AP object still records the type the remote sent" do
      with_rewrite_config([{{"Service", "Group"}, ["fedigroups.local"]}], fn ->
        assert {:ok, _} = Adapter.maybe_create_remote_actor(fixture_actor(@fedigroups_actor))
        assert {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: @fedigroups_actor)

        assert ap_object.data["type"] == "Service",
               "ap_object.data is our audit record of the remote document, so it must NOT be rewritten"
      end)
    end
  end

  # ------------------------------------------------------------------
  # outgoing: what we serialise
  # ------------------------------------------------------------------

  describe "outgoing actor type" do
    # The emitted `type` and the ap_id's URL segment are two halves of one identity (the segment is
    # part of the ap_id), so they are asserted together and must never diverge.
    test "a local user emits Person, with a person ap_id segment" do
      user = Bonfire.Me.Fake.fake_user!()

      assert actor_type(user) == "Person"
      assert URIs.canonical_url(user) =~ ~r{/(person|actors)/}
    end

    test "RED: a local shared user labelled Service emits type Service" do
      user = Bonfire.Me.Fake.fake_user!()
      assert %Bonfire.Data.SharedUser{} = Bonfire.Me.SharedUsers.init_shared_user(user, "Service")

      assert actor_type(repo().maybe_preload(user, :shared_user, force: true)) == "Service",
             "the label records what kind of actor this is, so it must drive the emitted type"
    end

    test "RED: a remote shared user labelled Service emits type Service" do
      user = create_remote!("#{@remote_instance}/users/a_service")

      assert actor_type(user) == "Service",
             "the label records what the remote actually is, so it must drive the emitted type"
    end

    test "a local shared user with a non-AS2 label still emits Organization" do
      user = Bonfire.Me.Fake.fake_user!()
      assert %Bonfire.Data.SharedUser{} = Bonfire.Me.SharedUsers.init_shared_user(user, "Team")

      assert actor_type(repo().maybe_preload(user, :shared_user, force: true)) == "Organization",
             "a local team's own wording is not an AS2 type, so it federates as Organization"
    end
  end

  # ------------------------------------------------------------------
  # dispatch mechanics
  # ------------------------------------------------------------------

  describe "character_module/1" do
    test "resolves the known single actor types" do
      assert AdapterUtils.character_module("Person") == Bonfire.Me.Users
      assert AdapterUtils.character_module("Group") == Bonfire.Classify.Categories
    end

    test "returns nil (rather than raising) for an unknown type" do
      assert is_nil(AdapterUtils.character_module("NoSuchType"))
    end

    # Parked: list-valued `type` belongs to the places-as-actors work (Service + Place), not to the
    # group/Service scope. Raises FunctionClauseError today — there is no list clause.
    @tag :todo
    test "handles a list-valued type instead of raising" do
      result = AdapterUtils.character_module(["Place", "geojson:Feature"])
      assert is_nil(result) or is_atom(result)
    end

    @tag :todo
    test "resolves a list type by its first recognised member" do
      assert AdapterUtils.character_module(["Service", "Place"]) in [
               Bonfire.Me.SharedUsers,
               Bonfire.Geolocate.Geolocations
             ]
    end
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  # format_actor/1 returns a bare actor for a local user, but `{:ok, actor}` on the remote path (where it resolves the cached AP object), so unwrap before asserting on the type
  defp actor_type(user) do
    case Users.format_actor(user) do
      {:ok, actor} -> e(actor, :data, "type", nil)
      actor -> e(actor, :data, "type", nil)
    end
  end

  defp create_remote!(ap_id) do
    assert {:ok, character} = Adapter.maybe_create_remote_actor(%{"id" => ap_id})
    repo().maybe_preload(character, [:shared_user, :character])
  end

  defp typed_actor_json(ap_id, type) do
    username = ap_id |> String.split("/") |> List.last()

    Bonfire.Federate.ActivityPub.Simulate.actor_json("#{@remote_instance}/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => type,
      "preferredUsername" => username,
      "name" => "#{type} test actor",
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox",
      "url" => "#{@remote_instance}/@#{username}"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  defp fixture_json do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp fixture_actor(ap_id) do
    fixture_json()
    |> Map.merge(%{
      "id" => ap_id,
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  defp with_rewrite_config(config, fun) do
    previous = Application.get_env(:bonfire_federate_activitypub, :rewrite_actor_types)
    Application.put_env(:bonfire_federate_activitypub, :rewrite_actor_types, config)

    try do
      fun.()
    after
      Application.put_env(:bonfire_federate_activitypub, :rewrite_actor_types, previous)
    end
  end
end
