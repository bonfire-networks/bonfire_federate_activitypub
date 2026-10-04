defmodule Bonfire.Federate.ActivityPub.FederationAllowedTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub, as: Federation
  alias Bonfire.Federate.ActivityPub.Instances

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  describe "federation_allowed?/2 open mode" do
    test "allows any remote URI when open" do
      assert Federation.federation_allowed?(@remote_actor)
    end

    test "allows remote URI for instance not in DB" do
      assert Federation.federation_allowed?("https://unknown.example/users/bob")
    end
  end

  describe "federation_allowed?/2 allowlist-only mode" do
    setup do
      Process.put(:federating, :allowlist_only)
      :ok
    end

    test "rejects non-allowlisted URI" do
      refute Federation.federation_allowed?(@remote_actor)
    end

    test "allows URI whose instance is allowlisted" do
      Instances.add_to_allowlist("mocked.local")
      assert Federation.federation_allowed?(@remote_actor)
    end

    test "rejects URI even if allowlisted when also blocked" do
      Instances.add_to_allowlist("mocked.local")
      {:ok, peer} = Instances.get_or_create(@remote_actor)
      Bonfire.Boundaries.Blocks.block(peer, :total, :instance_wide)

      refute Federation.federation_allowed?(@remote_actor)
    end
  end

  describe "federation_allowed?/2 allowlist-only mode — actor-level allowlist" do
    test "allows URI when specific actor is allowlisted (domain not allowlisted)" do
      # fetch actor while open so Peered record is created, then switch to allowlist mode
      {:ok, _actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, :instance_wide)

      Process.put(:federating, :allowlist_only)
      assert Federation.federation_allowed?(@remote_actor)
    end

    test "rejects URI when only a different actor on the same instance is allowlisted" do
      other_actor = @remote_instance <> "/users/other"
      {:ok, _actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)
      Bonfire.Boundaries.Allowlist.allow(peered, :instance_wide)

      Process.put(:federating, :allowlist_only)
      refute Federation.federation_allowed?(other_actor)
    end
  end

  describe "block checks with no current user" do
    # Every unauthenticated incoming activity checks blocks with no user in scope, so the per-user
    # side of `Blocks.is_blocked?/3` gets `nil`. That is an ordinary case, not unexpected input, and
    # must not log as one — it fired twice per delivery. Asserting the return value alone cannot see
    # this: it was always correct, which is why the noise went unnoticed.
    # NOTE: keep the refuted phrase out of the test NAME — this suite logs a "test … started" line
    # containing the name, which `capture_log` would then match, failing for its own title.
    test "does not warn about unmatched input" do
      # the actor must be KNOWN (have a Peered record) to reach the per-actor block check at all —
      # an unknown URI takes an earlier fallback path and never gets there
      {:ok, _actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, _peered} = Bonfire.Federate.ActivityPub.Peered.get_by_uri(@remote_actor)

      # Pin the level rather than inheriting it: the line asserted below is logged at `info`, and CI
      # runs with `TEST_LOG_LEVEL: notice`, which filters it out and leaves `capture_log` empty —
      # failing the guard for a reason that has nothing to do with what's under test.
      previous_level = Logger.level()
      Logger.configure(level: :info)

      log =
        try do
          ExUnit.CaptureLog.capture_log(fn ->
            assert Federation.federation_allowed?(@remote_actor)
          end)
        after
          Logger.configure(level: previous_level)
        end

      # the block checks ran (this can't pass by never getting there)
      assert log =~ "federation_allowed?"
      refute log =~ "no pattern" <> " found"
    end
  end

  describe "federation_allowed?/2 disabled" do
    test "rejects all URIs when federation disabled" do
      Process.put(:federating, false)
      refute Federation.federation_allowed?(@remote_actor)
    end
  end

  # The federation HTTP client checks the lists itself on every request, so no AP-related fetch can skip them. The HTTP adapter is mocked and reports every request it gets, so a refused fetch is one the mock never got.
  describe "AP-related fetches respect the block/allow lists" do
    setup do
      test_pid = self()

      Tesla.Mock.mock(fn env ->
        send(test_pid, {:hit, env.url})
        %Tesla.Env{status: 200, headers: [{"content-type", "text/html"}], body: "<html></html>"}
      end)

      :ok
    end

    defp block_instance! do
      {:ok, peer} = Instances.get_or_create(@remote_actor)
      Bonfire.Boundaries.Blocks.block(peer, :total, :instance_wide)
    end

    test "an unblocked instance is fetched from" do
      assert {:ok, %{status: 200}} = ActivityPub.Federator.HTTP.get(@remote_instance <> "/page")
      assert_received {:hit, _}
    end

    test "a blocked instance is never fetched from, with no options passed" do
      block_instance!()

      assert {:error, :not_allowed} = ActivityPub.Federator.HTTP.get(@remote_instance <> "/page")
      refute_received {:hit, _}
    end

    test "in allowlist-only mode, an instance that isn't allowlisted is never fetched from" do
      Process.put(:federating, :allowlist_only)

      assert {:error, :not_allowed} = ActivityPub.Federator.HTTP.get(@remote_instance <> "/page")
      refute_received {:hit, _}
    end

    test "a user's own block of an instance applies to fetches made for them, and not for others" do
      user = fake_user!()
      {:ok, peer} = Instances.get_or_create(@remote_actor)
      Bonfire.Boundaries.Blocks.block(peer, :total, current_user: user)

      ActivityPub.Federator.Fetcher.fetch_object_from_id(@remote_instance <> "/objects/1",
        current_user: user
      )

      refute_received {:hit, _}

      ActivityPub.Federator.Fetcher.fetch_object_from_id(@remote_instance <> "/objects/1",
        current_user: fake_user!()
      )

      assert_received {:hit, _}
    end

    test "a link preview of a blocked instance's URL doesn't fall back to fetching it as a plain web page" do
      block_instance!()

      refute match?({:ok, _, _}, Bonfire.Files.Media.ap_aware_fetch(@remote_instance <> "/page"))
      refute_received {:hit, _}
    end
  end
end
