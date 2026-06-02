defmodule Bonfire.Federate.ActivityPub.SharedDataDanceCase do
  use ExUnit.CaseTemplate
  import Tesla.Mock
  import Untangle
  import ExUnit.Assertions
  import Bonfire.UI.Common.Testing.Helpers
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Federate.ActivityPub, as: Federation
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Boundaries.Blocks
  alias Bonfire.Boundaries.Allowlist
  alias Bonfire.Common.Settings
  alias Bonfire.Common.URIs

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest

      import Bonfire.UI.Common.Testing.Helpers

      import Phoenix.LiveViewTest
      # import Bonfire.Federate.ActivityPub.ConnCase
      import Bonfire.Federate.ActivityPub.Test.ConnHelpers

      use Bonfire.Common.Utils

      alias Bonfire.Federate.ActivityPub.Simulate
      use Bonfire.Common.Config

      # The default endpoint for testing
      @endpoint Application.compile_env!(:bonfire, :endpoint_module)
    end
  end

  setup_all tags do
    info("Start with a DanceTest")

    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    on_exit(fn ->
      info("Done with a DanceTest")
      ActivityPub.Utils.cache_clear()

      # this callback needs to checkout its own connection since it
      # runs in its own process
      # :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
      # Ecto.Adapters.SQL.Sandbox.mode(repo(), :auto)

      # Object.delete(actor1)
      # Object.delete(actor2)
      :ok
    end)

    ActivityPub.Utils.cache_clear()
    # Reset federation mode to open (guard against stale DB state from interrupted test runs)
    Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, false)

    # Bonfire.Common.Repo.config()
    # |> Keyword.take([:name, :database, :hostname, :port, :username])
    # |> debug("LOCAL DB CONFIG")

    # TestInstanceRepo.config()
    # |> Keyword.take([:name, :database, :hostname, :port, :username])
    # |> debug("REMOTE DB CONFIG")

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()
      Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, false)

      if !Bonfire.Boundaries.Circles.exists?(Bonfire.Boundaries.Circles.get_id!(:local)) do
        info("Seems boundary fixtures are missing on test instance, running now")
        Bonfire.Boundaries.Scaffold.insert()
      end
    end)

    # Set a known password for the test user
    test_password = "test_password_123"

    [
      local: fancy_fake_user!("Local", credential: %{password: test_password}),
      remote: fancy_fake_user_on_test_instance(credential: %{password: test_password}),
      test_password: test_password
    ]
  end

  # -----------------------------------------------------------------------
  # Shared helpers for the archipelago/allowlist dance tests
  # -----------------------------------------------------------------------

  def clean_slate(context) do
    do_clean_slate(context[:local][:user], context[:remote][:canonical_url])

    TestInstanceRepo.apply(fn ->
      do_clean_slate(context[:remote][:user], context[:local][:canonical_url])
    end)

    :ok
  end

  def do_clean_slate(local, remote) do
    Federation.set_allowlist_only(:instance, false)

    local =
      Bonfire.Common.Utils.current_user(
        Settings.put([:activity_pub, :user_federating], true, current_user: local)
      )

    ActivityPub.Utils.cache_clear()

    {:ok, remote_user_on_local} =
      AdapterUtils.get_by_url_ap_id_or_username(remote)

    Blocks.unblock(local, remote_user_on_local)
    Blocks.unblock(remote_user_on_local, local)
    Follows.unfollow(local, remote_user_on_local)

    # unallow anything we may have allowed at user level
    Allowlist.unallow(remote_user_on_local, local)

    remote_host = URIs.base_domain(remote)

    with {:ok, instance_circle} <- Instances.get_or_create_instance_circle(remote_host) do
      Allowlist.unallow(instance_circle)
    end
  end

  def get_remote_on_local(context) do
    {:ok, user} =
      AdapterUtils.get_by_url_ap_id_or_username(context[:remote][:canonical_url])

    user
  end

  def get_local_on_remote(context) do
    TestInstanceRepo.apply(fn ->
      {:ok, user} =
        AdapterUtils.get_by_url_ap_id_or_username(context[:local][:canonical_url])

      user
    end)
  end

  def remote_host(context), do: URIs.base_domain(context[:remote][:canonical_url])

  def allowlist_remote_instance(context) do
    {:ok, instance_circle} = Instances.get_or_create_instance_circle(remote_host(context))
    assert {:ok, _} = Allowlist.allow(instance_circle)
    instance_circle
  end

  def allowlist_remote_actor(context, local_user) do
    bob_remote_on_local = get_remote_on_local(context)
    assert {:ok, _} = Allowlist.allow(bob_remote_on_local, local_user)
    bob_remote_on_local
  end

  def set_user_allowlist_only(user) do
    Bonfire.Common.Utils.current_user(
      Settings.put([:activity_pub, :user_federating], :allowlist_only, current_user: user)
    )
  end
end
