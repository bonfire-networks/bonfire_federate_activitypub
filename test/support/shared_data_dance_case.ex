defmodule Bonfire.Federate.ActivityPub.SharedDataDanceCase do
  use ExUnit.CaseTemplate
  import Tesla.Mock
  import Untangle
  import Bonfire.UI.Common.Testing.Helpers
  alias Bonfire.Common.TestInstanceRepo

  def a_fake_user!(name) do
    # repo().delete_all(ActivityPub.Object)
    user = fake_user!("#{name} #{Pointers.ULID.generate()}")

    [
      user: user,
      username: Bonfire.Me.Characters.display_username(user, true),
      canonical_url: Bonfire.Me.Characters.character_url(user),
      friendly_url: Bonfire.Common.URIs.base_url() <> Bonfire.Common.URIs.path(user)
    ]
  end

  def fake_remote!() do
    TestInstanceRepo.apply(fn -> a_fake_user!("Remote") end)
  end

  setup_all tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    on_exit(fn ->
      # this callback needs to checkout its own connection since it
      # runs in its own process
      # :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo())
      # Ecto.Adapters.SQL.Sandbox.mode(repo(), :auto)

      # Object.delete(actor1)
      # Object.delete(actor2)
      :ok
    end)

    [
      local: a_fake_user!("Local"),
      remote: fake_remote!()
    ]
  end
end
