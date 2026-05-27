defmodule Bonfire.Federate.ActivityPub.AddToCircleByUriTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Allowlist

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  setup do
    # ensure open federation mode for this test process without touching DB settings
    Process.put(:federating, true)
    me = fake_user!()
    {:ok, circle} = Circles.get_or_create_stereotype_circle(me, :allow_them)
    {:ok, me: me, circle: circle}
  end

  test "adds a remote actor URL to a circle", %{me: me, circle: circle} do
    assert {:ok, actor} = AdapterUtils.add_to_circle_by_uri(@remote_actor, circle, me)
    assert Allowlist.is_allowlisted?(actor, current_user: me)
  end

  test "adds a remote actor URL even when user is in allowlist-only mode", %{
    me: me,
    circle: circle
  } do
    Bonfire.Federate.ActivityPub.set_allowlist_only(me, true)
    assert {:ok, _actor} = AdapterUtils.add_to_circle_by_uri(@remote_actor, circle, me)
  end

  test "adds a bare domain to a circle as an instance circle", %{me: me, circle: circle} do
    mock(fn
      %{method: :get, url: @remote_instance <> "/.well-known/nodeinfo"} ->
        json(%{
          "links" => [
            %{
              "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.1",
              "href" => @remote_instance <> "/nodeinfo/2.1"
            }
          ]
        })

      %{method: :get, url: @remote_instance <> "/nodeinfo/2.1"} ->
        json(%{"version" => "2.1", "software" => %{"name" => "test", "version" => "1.0"}})
    end)

    assert {:ok, instance_circle} = AdapterUtils.add_to_circle_by_uri("mocked.local", circle, me)
    assert Allowlist.is_allowlisted?(instance_circle, current_user: me)
  end
end
