defmodule Bonfire.Federate.ActivityPub.AutocompleteMentionFederationTest do
  @moduledoc """
  bonfire-app#647: @-mention autocomplete should not suggest REMOTE actors this instance can't
  federate with (federation disabled / manual / allowlist-only-and-not-allowlisted), since
  mentioning them is useless. Covers both filter points in `Bonfire.Tag.Autocomplete`:
  `reject_unfederatable_mentions/3` (search-adapter path) and the `tag_hit_prepare/5` chokepoint
  (which also covers the DB-lookup fallback). Non-`@` prefixes and open federation are never filtered.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :ui

  import Tesla.Mock
  alias Bonfire.Tag.Autocomplete

  setup do
    Tesla.Mock.mock_global(fn env -> ActivityPub.Test.HttpRequestMock.request(env) end)
    Bonfire.Federate.ActivityPub.set_federating(:instance, true)

    on_exit(fn ->
      parent = self()

      Task.start(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Bonfire.Common.Repo, parent, self())
        Bonfire.Federate.ActivityPub.set_federating(:instance, true)
      end)
    end)

    local = fake_user!()
    {:ok, remote} = Bonfire.Federate.ActivityPub.Simulate.fake_remote_user()

    # the autocomplete loaders preload this; do the same so is_local? is accurate + query-free
    local = Bonfire.Common.Repo.maybe_preload(local, character: [:peered])
    remote = Bonfire.Common.Repo.maybe_preload(remote, character: [:peered])

    {:ok, local: local, remote: remote}
  end

  describe "reject_unfederatable_mentions/3 (search-adapter path)" do
    test "open federation keeps both local and remote @ suggestions", %{
      local: local,
      remote: remote
    } do
      results =
        Autocomplete.reject_unfederatable_mentions(
          [local, remote],
          "@",
          nil,
          Bonfire.Federate.ActivityPub.federation_mode(nil)
        )

      assert local in results
      assert remote in results
    end

    test "disabled federation drops the remote @ suggestion", %{local: local, remote: remote} do
      Bonfire.Federate.ActivityPub.set_federating(:instance, false)

      results =
        Autocomplete.reject_unfederatable_mentions(
          [local, remote],
          "@",
          nil,
          Bonfire.Federate.ActivityPub.federation_mode(nil)
        )

      assert local in results
      refute remote in results
    end

    test "allowlist-only drops a non-allowlisted remote @ suggestion", %{
      local: local,
      remote: remote
    } do
      Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, true)

      results =
        Autocomplete.reject_unfederatable_mentions(
          [local, remote],
          "@",
          nil,
          Bonfire.Federate.ActivityPub.federation_mode(nil)
        )

      assert local in results
      refute remote in results
    end

    test "non-@ prefix is never filtered, even with federation disabled", %{
      local: local,
      remote: remote
    } do
      Bonfire.Federate.ActivityPub.set_federating(:instance, false)

      results =
        Autocomplete.reject_unfederatable_mentions(
          [local, remote],
          "+",
          nil,
          Bonfire.Federate.ActivityPub.federation_mode(nil)
        )

      assert local in results
      assert remote in results
    end
  end

  describe "tag_hit_prepare/5 chokepoint (covers the DB-lookup fallback)" do
    test "drops a remote @ hit when the (precomputed) federation mode is disabled", %{
      remote: remote
    } do
      assert nil ==
               Autocomplete.tag_hit_prepare(remote, "k", "@", "tag_as", federation_mode: false)
    end

    test "keeps a remote @ hit when federation is open (no per-hit federation work)", %{
      remote: remote
    } do
      refute is_nil(
               Autocomplete.tag_hit_prepare(remote, "k", "@", "tag_as", federation_mode: true)
             )
    end
  end
end
