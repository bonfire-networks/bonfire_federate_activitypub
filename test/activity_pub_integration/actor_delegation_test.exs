defmodule Bonfire.Federate.ActivityPub.ActorDelegationTest do
  @moduledoc """
  Delegated C2S posting: a remote system authenticated by HTTP signature publishes *as* a local actor, when `AP_DELEGATED_ACTORS` allowlists that signer for that actor.

  This is the host-app policy behind the lib's `maybe_delegated_user/2` callback, as the lib itself only knows "ask the adapter, deny by default" (see `ActivityPub.Web.C2SOutboxAuthzTest`).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.ActorDelegation

  @env "AP_DELEGATED_ACTORS"
  @remote_host "mocked.local"
  @remote_instance "https://" <> @remote_host
  @remote_actor @remote_instance <> "/users/karen"
  # another actor on the SAME host (Simulate only knows karen/kip/jo)
  @other_remote_actor @remote_instance <> "/users/kip"
  @content_type "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
  @source_id "https://mocked.local/event/7e57f6b1-8133-42f0-b196-8241bd847a6c"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      %{method: :get, url: @other_remote_actor} ->
        json(Simulate.actor_json(@other_remote_actor))

      # an instance-level actor, whose ap_id is the bare origin (as in the reported case)
      %{method: :get, url: @remote_instance} ->
        json(Simulate.actor_json(@remote_instance))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)
  end

  setup do
    Process.put(:federating, true)
    on_exit(fn -> System.delete_env(@env) end)
    :ok
  end

  describe "config parsing" do
    test "parses several actors, each with several signers" do
      System.put_env(
        @env,
        "bonfire:https://9.dev.bonfire.cafe,https://x.example/actors/alice;events:9.dev.bonfire.cafe"
      )

      assert ActorDelegation.config() == %{
               "bonfire" => ["https://9.dev.bonfire.cafe", "https://x.example/actors/alice"],
               "events" => ["9.dev.bonfire.cafe"]
             }
    end

    test "splits on the FIRST colon only, so signer URIs survive" do
      System.put_env(@env, "bonfire:https://9.dev.bonfire.cafe")
      assert ActorDelegation.allowed_signers("bonfire") == ["https://9.dev.bonfire.cafe"]
    end

    test "tolerates whitespace around delimiters" do
      System.put_env(
        @env,
        " bonfire : https://a.example , https://b.example ; events : c.example "
      )

      assert ActorDelegation.config() == %{
               "bonfire" => ["https://a.example", "https://b.example"],
               "events" => ["c.example"]
             }
    end

    test "skips a malformed entry with no separator, keeping the rest" do
      System.put_env(@env, "no_separator_here;bonfire:https://a.example")
      assert ActorDelegation.config() == %{"bonfire" => ["https://a.example"]}
    end

    test "is empty when unset" do
      System.delete_env(@env)
      assert ActorDelegation.config() == %{}
      assert ActorDelegation.allowed_signers("bonfire") == []
    end
  end

  describe "matching" do
    test "a bare hostname entry admits any actor on that host" do
      System.put_env(@env, "bonfire:#{@remote_host}")
      assert ActorDelegation.delegated?("bonfire", @remote_actor)
      assert ActorDelegation.delegated?("bonfire", @other_remote_actor)
      # including the instance actor, whose id is the bare origin
      assert ActorDelegation.delegated?("bonfire", @remote_instance)
    end

    test "an origin URL is an actor id, not a wildcard for its host" do
      System.put_env(@env, "bonfire:#{@remote_instance}")

      # it admits the instance actor itself...
      assert ActorDelegation.delegated?("bonfire", @remote_instance)

      # ...and nobody else on that host
      refute ActorDelegation.delegated?("bonfire", @remote_actor)
      refute ActorDelegation.delegated?("bonfire", @other_remote_actor)
    end

    test "an exact actor URI admits only that actor" do
      System.put_env(@env, "bonfire:#{@remote_actor}")
      assert ActorDelegation.delegated?("bonfire", @remote_actor)
      refute ActorDelegation.delegated?("bonfire", @other_remote_actor)
    end

    test "a signer allowlisted for one actor is not allowlisted for another" do
      System.put_env(@env, "bonfire:#{@remote_host}")
      refute ActorDelegation.delegated?("someone_else", @remote_actor)
    end

    test "nothing is delegated when unset" do
      System.delete_env(@env)
      refute ActorDelegation.delegated?("bonfire", @remote_actor)
    end
  end

  describe "matching cannot be spoofed by URL tricks" do
    setup do
      # the instance is allowlisted; every signer below is attacker-controlled
      System.put_env(@env, "bonfire:#{@remote_host}")
      :ok
    end

    test "a host that merely ends with the allowlisted one" do
      refute ActorDelegation.delegated?("bonfire", "https://evil-mocked.local/users/karen")
      refute ActorDelegation.delegated?("bonfire", "https://notmocked.local/users/karen")
    end

    test "a host that merely starts with the allowlisted one" do
      refute ActorDelegation.delegated?("bonfire", "https://mocked.local.evil.com/users/karen")
      refute ActorDelegation.delegated?("bonfire", "https://mocked.locale/users/karen")
    end

    test "the allowlisted host smuggled into userinfo" do
      refute ActorDelegation.delegated?("bonfire", "https://mocked.local@evil.com/users/karen")
      refute ActorDelegation.delegated?("bonfire", "https://user:mocked.local@evil.com/users/x")
    end

    test "the allowlisted host smuggled into the path, query or fragment" do
      refute ActorDelegation.delegated?("bonfire", "https://evil.com/mocked.local/users/karen")
      refute ActorDelegation.delegated?("bonfire", "https://evil.com/users/x?host=mocked.local")
      refute ActorDelegation.delegated?("bonfire", "https://evil.com/users/x#mocked.local")
    end

    test "a subdomain of the allowlisted host is not the allowlisted host" do
      refute ActorDelegation.delegated?("bonfire", "https://sub.mocked.local/users/karen")
    end

    test "a different port on the allowlisted host" do
      refute ActorDelegation.delegated?("bonfire", "https://mocked.local:8443/users/karen")
    end

    test "host matching ignores case, as DNS does" do
      assert ActorDelegation.delegated?("bonfire", "https://MOCKED.local/users/karen")
      assert ActorDelegation.delegated?("bonfire", "https://Mocked.Local/users/karen")
    end

    test "a signer that is not a URL at all" do
      refute ActorDelegation.delegated?("bonfire", "not a url")
      refute ActorDelegation.delegated?("bonfire", "")
      refute ActorDelegation.delegated?("bonfire", nil)
    end
  end

  describe "an exact actor entry cannot be spoofed by URL tricks" do
    setup do
      System.put_env(@env, "bonfire:#{@remote_actor}")
      :ok
    end

    test "a path that merely extends the allowlisted actor" do
      refute ActorDelegation.delegated?("bonfire", @remote_actor <> "2")
      refute ActorDelegation.delegated?("bonfire", @remote_actor <> "/../kip")
      refute ActorDelegation.delegated?("bonfire", @remote_actor <> "/sub")
    end

    test "a query or fragment appended to the allowlisted actor" do
      refute ActorDelegation.delegated?("bonfire", @remote_actor <> "?x=1")
      refute ActorDelegation.delegated?("bonfire", @remote_actor <> "#x")
    end

    test "the same path on a different host" do
      refute ActorDelegation.delegated?("bonfire", "https://evil.com/users/karen")
    end

    test "an exact entry does not admit the whole instance" do
      refute ActorDelegation.delegated?("bonfire", @remote_instance <> "/users/kip")
      refute ActorDelegation.delegated?("bonfire", @remote_instance)
    end
  end

  describe "a JSON document from a c2s client" do
    # Testing what this feature exists for: event software delivered a bare FEP-8a8e `Event` with no author, signed with its INSTANCE key (an actor whose ap_id is the bare origin). Sent to the inbox it was wrapped in a synthetic Create, found no actor, and fell back to a service actor.
    # Sent to the outbox with the signer delegated, it is published as the local actor instead.
    setup do
      user = fake_user!()
      username = user.character.username
      {:ok, local} = ActivityPub.Actor.get_cached(username: username)
      {:ok, instance_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_instance)

      {:ok,
       conn: build_conn(),
       user: user,
       username: username,
       local: local,
       instance_actor: instance_actor}
    end

    test "publishes as the local actor, keeping the source event page", %{
      conn: conn,
      username: username,
      local: local
    } do
      System.put_env(@env, "#{username}:#{@remote_instance}")

      conn = post_as(conn, @remote_instance, username, federated_event_doc())

      assert conn.status == 201
      resp = json_response(conn, 201)

      assert resp["actor"] == local.ap_id
      refute resp["actor"] == @remote_instance

      object = posted_object(conn)
      assert object.data["name"] == "test2"
      assert object.data["url"] == @source_id
      refute object.data["id"] == @source_id

      {:ok, activity} = ActivityPub.Object.get_cached(ap_id: resp["id"])
      assert activity.local
    end

    test "is refused when the instance is not delegated", %{conn: conn, username: username} do
      conn = post_as(conn, @remote_instance, username, federated_event_doc())

      assert conn.status == 403
    end

    # the shape actually delivered: no `actor`/`attributedTo`, authorship only implied by the signature, with organizers/location/tag alongside
    defp federated_event_doc do
      %{
        "@context" => [
          "https://www.w3.org/ns/activitystreams",
          "https://w3id.org/fep/8a8e",
          "https://schema.org",
          "https://purl.archive.org/miscellany"
        ],
        "type" => "Event",
        "id" => @source_id,
        "url" => @source_id,
        "name" => "test2",
        "content" => "fo bar",
        "startTime" => "2026-08-21T15:47:13Z",
        "timezone" => "Europe/Berlin",
        "eventStatus" => "EventScheduled",
        "displayEndTime" => "false",
        "joinMode" => "none",
        "location" => %{
          "type" => "Place",
          "id" => @remote_instance <> "/place/a5a7d0fe",
          "name" => "not published place",
          "address" => "",
          "latitude" => 48.784888,
          "longitude" => 9.177323
        },
        "organizers" => %{
          "totalItems" => 1,
          "items" => [
            %{"id" => @remote_instance <> "/group/08297b63", "name" => "group1", "content" => "…"}
          ]
        },
        "tag" => [
          %{
            "type" => "HashTag",
            "name" => "#foobar",
            "href" => @remote_instance <> "?tags=foobar"
          }
        ],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    end
  end

  describe "maybe_delegated_user/2 (the lib callback)" do
    setup do
      user = fake_user!()
      {:ok, local} = ActivityPub.Actor.get_cached(username: user.character.username)
      {:ok, remote} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, user: user, local: local, remote: remote}
    end

    test "returns the local user to publish as when allowlisted", %{
      user: user,
      local: local,
      remote: remote
    } do
      System.put_env(@env, "#{local.username}:#{@remote_host}")

      assert %{id: id} = Bonfire.Federate.ActivityPub.Adapter.maybe_delegated_user(local, remote)
      assert id == user.id
    end

    test "returns nil when not allowlisted", %{local: local, remote: remote} do
      refute Bonfire.Federate.ActivityPub.Adapter.maybe_delegated_user(local, remote)
    end
  end

  describe "posting through the outbox" do
    setup do
      user = fake_user!()
      username = user.character.username
      {:ok, local} = ActivityPub.Actor.get_cached(username: username)
      {:ok, remote} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, other_remote} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @other_remote_actor)

      # this ConnCase does not put a conn in the context (unlike the lib's)
      {:ok,
       conn: build_conn(),
       user: user,
       username: username,
       local: local,
       remote: remote,
       other_remote: other_remote}
    end

    defp event_doc(attrs \\ %{}) do
      Map.merge(
        %{
          "type" => "Event",
          "id" => @source_id,
          "name" => "test2",
          "content" => "fo bar",
          "startTime" => "2026-08-21T15:47:13Z",
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        },
        attrs
      )
    end

    defp post_as(conn, signer_ap_id, username, doc) do
      conn
      |> assign(:valid_signature, true)
      |> put_req_header("signature", "keyId=\"#{signer_ap_id}#main-key\"")
      |> put_req_header("content-type", @content_type)
      |> post("#{ActivityPub.Utils.ap_base_url()}/actors/#{username}/outbox", doc)
    end

    test "an allowlisted instance publishes as the local actor", %{
      conn: conn,
      username: username,
      local: local
    } do
      System.put_env(@env, "#{username}:#{@remote_host}")

      conn = post_as(conn, @remote_actor, username, event_doc())

      assert conn.status == 201
      resp = json_response(conn, 201)

      assert resp["actor"] == local.ap_id, "the activity must be authored by the local actor"
      refute resp["actor"] == @remote_actor

      {:ok, activity} = ActivityPub.Object.get_cached(ap_id: resp["id"])
      assert activity.local, "a delegated post is authored here, so it must be local"
    end

    test "creates a local object, so the post can appear in feeds", %{
      conn: conn,
      username: username,
      user: user
    } do
      System.put_env(@env, "#{username}:#{@remote_host}")

      conn = post_as(conn, @remote_actor, username, event_doc())
      assert conn.status == 201

      # the `ap_object` row alone is not a pointable and never reaches a feed — a
      # `Bonfire.Data.Social.APActivity` (or other pointable) has to exist and be linked
      object = posted_object(conn)

      assert object.pointer_id,
             "the AP object was stored but never linked to a local object"

      assert %Bonfire.Data.Social.APActivity{} =
               local = Bonfire.Common.Needles.get!(object.pointer_id, skip_boundary_check: true)

      assert local.json["type"] in ["Create", "Event"]

      assert %{edges: edges} = Bonfire.Social.FeedLoader.feed(:my, current_user: user)

      assert Enum.any?(edges, &(id(e(&1, :activity, :object, nil)) == object.pointer_id)),
             "the delegated post did not reach the actor's feed"
    end

    test "an allowlisted exact actor URI publishes as the local actor", %{
      conn: conn,
      username: username,
      local: local
    } do
      System.put_env(@env, "#{username}:#{@remote_actor}")

      conn = post_as(conn, @remote_actor, username, event_doc())

      assert json_response(conn, 201)["actor"] == local.ap_id
    end

    test "an exact actor URI does not admit another actor on the same host", %{
      conn: conn,
      username: username
    } do
      System.put_env(@env, "#{username}:#{@remote_actor}")

      conn = post_as(conn, @other_remote_actor, username, event_doc())

      assert conn.status == 403
    end

    test "an undelegated signer is refused", %{conn: conn, username: username} do
      conn = post_as(conn, @remote_actor, username, event_doc())

      assert conn.status == 403
    end

    test "mints a local id and keeps the source URL", %{conn: conn, username: username} do
      System.put_env(@env, "#{username}:#{@remote_host}")

      conn = post_as(conn, @remote_actor, username, event_doc())

      object = posted_object(conn)

      refute object.data["id"] == @source_id, "client-provided ids must be ignored per spec"
      assert String.starts_with?(object.data["id"], ActivityPub.Utils.ap_base_url())
      assert object.data["url"] == @source_id, "the source URL should survive as `url`"
    end

    test "replaces an author the source document declares, rather than refusing it", %{
      conn: conn,
      username: username,
      local: local
    } do
      System.put_env(@env, "#{username}:#{@remote_host}")

      # event software naturally attributes the object to its own actor — delegation means
      # "publish as this local actor", so that is ours to replace
      conn =
        post_as(
          conn,
          @remote_actor,
          username,
          event_doc(%{"attributedTo" => @remote_actor, "actor" => @remote_actor})
        )

      assert conn.status == 201
      assert json_response(conn, 201)["actor"] == local.ap_id
      assert posted_object(conn).data["attributedTo"] == local.ap_id
    end

    test "a non-delegated client still cannot claim another author", %{
      conn: conn,
      user: user,
      local: local
    } do
      conn =
        conn
        |> assign(:current_user, user)
        |> put_req_header("content-type", @content_type)
        |> post(
          "#{ActivityPub.Utils.ap_base_url()}/actors/#{local.username}/outbox",
          event_doc(%{"attributedTo" => @remote_actor})
        )

      assert conn.status == 403
    end

    test "does not overwrite a url the client supplied", %{conn: conn, username: username} do
      page = "https://mocked.local/events/human-readable-page"
      System.put_env(@env, "#{username}:#{@remote_host}")

      conn = post_as(conn, @remote_actor, username, event_doc(%{"url" => page}))

      assert posted_object(conn).data["url"] == page
    end

    # the Create's "object" comes back as a URI, so resolve the stored object to inspect it
    defp posted_object(conn) do
      resp = json_response(conn, 201)

      object_ap_id =
        case resp["object"] do
          %{"id" => id} -> id
          id when is_binary(id) -> id
        end

      {:ok, object} = ActivityPub.Object.get_cached(ap_id: object_ap_id)
      object
    end
  end
end
