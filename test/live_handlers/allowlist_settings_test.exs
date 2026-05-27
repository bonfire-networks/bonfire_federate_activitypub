defmodule Bonfire.Federate.ActivityPub.AllowlistSettingsTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :ui
  import Tesla.Mock

  alias Bonfire.Common.Settings

  @remote_actor "https://mocked.local/users/karen"

  setup do
    account = fake_account!()
    me = fake_user!(account)
    conn = conn(user: me, account: account)
    {:ok, conn: conn, me: me, account: account}
  end

  describe "user federation mode setting" do
    setup do
      Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, false)
      :ok
    end

    test "user can switch to allowlist-only mode and manage link appears", %{conn: conn} do
      conn
      |> visit("/settings/user/safety")
      |> within("form[data-scope=federation_mode]", fn c ->
        choose(c, "Archipelago: Only federate with instances and actors you explicitly allow")
      end)
      |> assert_has("a", text: "Manage my federation allowlist")
    end

    test "user can switch back to open mode from allowlist-only", %{conn: conn, me: me} do
      Settings.put([:activity_pub, :user_federating], :allowlist_only, current_user: me)

      conn
      |> visit("/settings/user/safety")
      |> within("form[data-scope=federation_mode]", fn c ->
        choose(c, "Automatic: Push activities to the fediverse, and accept remote activities")
      end)
      |> refute_has("a", text: "Manage my federation allowlist")
    end
  end

  describe "allowlist page" do
    test "user can visit their allowlist page", %{conn: conn} do
      conn
      |> visit("/allowlisted")
      |> assert_has("div", text: "Federation Archipelago")
    end

    test "user can add a remote actor to their allowlist", %{conn: conn} do
      mock(fn
        %{method: :get, url: @remote_actor} -> json(Simulate.actor_json(@remote_actor))
      end)

      conn
      |> visit("/allowlisted")
      |> within("form#add_members_by_uri", fn session ->
        session
        |> fill_in("Actor URL, domain, or @handle@domain", with: @remote_actor)
        |> click_button("Add")
      end)
      |> assert_has("li", text: "karen")
      |> refute_has("li", text: "Unknown")
    end

    test "user can add a bare domain to their allowlist", %{conn: conn} do
      mock(fn
        %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
          json(%{
            "links" => [
              %{
                "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.1",
                "href" => "https://mocked.local/nodeinfo/2.1"
              }
            ]
          })

        %{method: :get, url: "https://mocked.local/nodeinfo/2.1"} ->
          json(%{"version" => "2.1", "software" => %{"name" => "test", "version" => "1.0"}})
      end)

      conn
      |> visit("/allowlisted")
      |> within("form#add_members_by_uri", fn session ->
        session
        |> fill_in("Actor URL, domain, or @handle@domain", with: "mocked.local")
        |> click_button("Add")
      end)
      |> assert_has("li", text: "mocked.local")
    end
  end

  describe "instance allowlist-only mode overrides user settings" do
    setup do
      Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, true)
      :ok
    end

    setup do
      on_exit(fn ->
        parent = self()

        Task.start(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Bonfire.Common.Repo, parent, self())
          Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, false)
        end)
      end)

      :ok
    end

    test "user safety settings hides Automatic option when instance is in archipelago mode",
         %{conn: conn} do
      conn
      |> visit("/settings/user/safety")
      |> refute_has("label", text: "Automatic")
    end

    test "footer impressum shows 'Archipelago federation enabled' when instance is in allowlist mode",
         %{conn: conn} do
      conn
      |> visit("/settings/user/safety")
      |> assert_has("div", text: "Archipelago federation enabled")
    end

    test "regular user can view instance allowlist in read-only mode", %{conn: conn} do
      conn
      |> visit("/settings/instance/remote_allow_list")
      |> assert_has("div", text: "Instance Federation Archipelago")
      |> refute_has("form#add_members_by_uri")
    end
  end
end
