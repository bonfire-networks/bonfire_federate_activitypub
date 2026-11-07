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

  # the user returned by the settings update, as the one passed in doesn't carry the new mode
  defp allowlist_only_user(user) do
    current_user(
      Bonfire.Common.Settings.put([:activity_pub, :user_federating], :allowlist_only,
        current_user: user
      )
    )
  end

  test "adds a remote actor URL to a circle", %{me: me, circle: circle} do
    assert {:ok, actor} = AdapterUtils.add_to_circle_by_uri(@remote_actor, circle, me)
    assert Allowlist.is_allowlisted?(actor, current_user: me)
  end

  test "adds a remote actor URL even when user is in allowlist-only mode", %{
    me: me,
    circle: circle
  } do
    # Bonfire.Federate.ActivityPub.set_allowlist_only(me, true)
    me = allowlist_only_user(me)
    assert {:ok, _actor} = AdapterUtils.add_to_circle_by_uri(@remote_actor, circle, me)
  end

  test "adds a not yet fetched remote actor to the allowlist circle when user is really in allowlist-only mode",
       %{me: me, circle: circle} do
    remote_actor = @remote_instance <> "/users/jo"
    mock(fn %{method: :get, url: ^remote_actor} -> json(Simulate.actor_json(remote_actor)) end)

    me = allowlist_only_user(me)

    assert {:ok, actor} = AdapterUtils.add_to_circle_by_uri(remote_actor, circle, me)
    assert Allowlist.is_allowlisted?(actor, current_user: me)
  end

  test "does not resolve a non-allowlisted remote actor into an ordinary circle when user is in allowlist-only mode",
       %{me: me} do
    # an actor no other test in this file fetches, so it can't already be cached and has to be fetched
    remote_actor = @remote_instance <> "/users/kip"
    mock(fn %{method: :get, url: ^remote_actor} -> json(Simulate.actor_json(remote_actor)) end)

    me = allowlist_only_user(me)

    {:ok, ordinary_circle} = Circles.create(me, %{named: %{name: "friends"}})

    assert {:error, _} = AdapterUtils.add_to_circle_by_uri(remote_actor, ordinary_circle, me)

    case AdapterUtils.get_character_by_ap_id(remote_actor) do
      {:ok, actor} -> refute Circles.is_encircled_by?(actor, ordinary_circle)
      _ -> :not_fetched
    end
  end

  test "does not add an already known, non-allowlisted remote actor to an ordinary circle when user is in allowlist-only mode",
       %{me: me} do
    remote_actor = "https://other.local/users/dave"
    mock(fn %{method: :get, url: ^remote_actor} -> json(Simulate.actor_json(remote_actor)) end)

    # known to the instance before the user goes allowlist-only, so resolving it needs no fetch
    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: remote_actor)
    {:ok, known_actor} = AdapterUtils.get_character_by_ap_id(remote_actor)

    me = allowlist_only_user(me)
    refute Allowlist.is_allowlisted?(known_actor, current_user: me)

    {:ok, ordinary_circle} = Circles.create(me, %{named: %{name: "friends"}})

    assert {:error, _} = AdapterUtils.add_to_circle_by_uri(remote_actor, ordinary_circle, me)
    refute Circles.is_encircled_by?(known_actor, ordinary_circle)
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
