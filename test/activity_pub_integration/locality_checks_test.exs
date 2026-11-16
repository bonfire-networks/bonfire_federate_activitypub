defmodule Bonfire.Federate.ActivityPub.LocalityChecksTest do
  use Bonfire.Federate.ActivityPub.DataCase
  use Repatch.ExUnit

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Posts
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Boosts
  alias Bonfire.Messages

  alias ActivityPub.Federator.Workers.PublisherWorker

  import Phoenix.ConnTest
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  setup do
    Process.put(:federating, true)
    :ok
  end

  # Maybe move this to adapter tests?
  describe "locality checks" do
    test "federates activities from local actors" do
      attrs = %{
        post_content: %{
          summary: "summary",
          html_body: "<p>epic html message</p>"
        }
      }

      user = fake_user!()

      assert {:ok, post} =
               Posts.publish(
                 current_user: user,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      #  perform_job(PublisherWorker, %{
      #    "context_id" => post.id,
      #    "op" => "create",
      #    "user_id" => user.id
      #  })
    end
  end

  # an actor document is only believed from the host its id names: one served from elsewhere claiming someone else's id must change nothing we hold about them, whether they are ours or a remote we have cached
  describe "actor documents served from another host" do
    @evil_url "https://evil.local/x"
    @remote_actor "https://mocked.local/users/karen"

    test "cannot take over a local user" do
      user = fake_user!()
      {:ok, local_actor} = ActivityPub.Actor.get_cached(pointer: user)
      local_ap_id = local_actor.ap_id
      # a new user has no keys until they first federate
      {:ok, _} = ActivityPub.Safety.Keys.ensure_keys_present(local_actor)
      ActivityPub.Utils.cache_clear()
      {:ok, own_key} = ActivityPub.Safety.Keys.get_public_key_for_ap_id(local_ap_id)

      attacker_key = attacker_public_key()
      spoofed = spoofed_actor_json(local_ap_id, user.character.username, attacker_key)

      mock_recording_fetches(%{@evil_url => spoofed})

      # the fetcher itself, since a guest's `refetch_profile` event is refused before any fetch: the attacker's URL has to be asked for, or this proves nothing
      assert {:error, :local_id_claimed} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(@evil_url)

      assert_received {:fetched, @evil_url}

      ActivityPub.Utils.cache_clear()

      assert {:ok, ^own_key} = ActivityPub.Safety.Keys.get_public_key_for_ap_id(local_ap_id)

      assert {:ok, actor} = ActivityPub.Actor.get_cached(ap_id: local_ap_id)
      refute actor.data["name"] == "spoofed"

      assert {:error, :not_found} = ActivityPub.Object.get_uncached(ap_id: local_ap_id)
    end

    test "cannot replace a cached remote actor's key or profile" do
      Tesla.Mock.mock(fn
        %{method: :get, url: @remote_actor} -> Tesla.Mock.json(Simulate.actor_json(@remote_actor))
        _ -> %Tesla.Env{status: 404, body: ""}
      end)

      assert {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
      {:ok, original_key} = ActivityPub.Safety.Keys.get_public_key_for_ap_id(@remote_actor)

      attacker_key = attacker_public_key()
      spoofed = spoofed_actor_json(@remote_actor, "karen", attacker_key)

      # its own host is down: the spoofed document cannot be confirmed from where its id says it lives
      mock_recording_fetches(%{@evil_url => spoofed})

      assert {:error, "Containment error"} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(@evil_url)

      assert_received {:fetched, @evil_url}

      # its own host serves the real document: that is what is taken, never the spoofed one
      mock_recording_fetches(%{
        @evil_url => spoofed,
        @remote_actor => Simulate.actor_json(@remote_actor)
      })

      assert {:ok, %{"id" => @remote_actor} = taken} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(@evil_url)

      assert_received {:fetched, @evil_url}
      refute taken["name"] == "spoofed"
      refute taken["publicKey"]["publicKeyPem"] == attacker_key

      ActivityPub.Utils.cache_clear()

      assert {:ok, ^original_key} =
               ActivityPub.Safety.Keys.get_public_key_for_ap_id(@remote_actor)

      assert {:ok, actor} = ActivityPub.Actor.get_cached(ap_id: @remote_actor)
      refute actor.data["name"] == "spoofed"
    end

    test "a document from the host its id names is taken (control)" do
      good_url = "https://good.local/users/zed"
      mock_recording_fetches(%{good_url => Simulate.actor_json(good_url, "zed")})

      assert {:ok, %{"id" => ^good_url}} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(good_url)

      assert_received {:fetched, ^good_url}
    end
  end

  # an `Undo` of a `Delete` brings an actor back only when its origin serves that same actor again, not another one under the address
  describe "Undo of the Delete of an actor" do
    @restored_actor "https://mocked.local/users/restored"
    @someone_else "https://mocked.local/users/someone_else"

    # what the origin answers for the actor's address, switched as the test goes on
    defp origin_serves(document) do
      Tesla.Mock.mock(fn
        %{method: :get, url: @restored_actor} ->
          case document do
            nil -> %Tesla.Env{status: 410, body: ""}
            document -> Tesla.Mock.json(document)
          end

        _ ->
          %Tesla.Env{status: 404, body: ""}
      end)
    end

    defp delete_then_undo do
      origin_serves(Simulate.actor_json(@restored_actor, "restored"))
      assert {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @restored_actor)
      # our own copy of it, which is what a restoring brings back
      assert {:ok, _} = Bonfire.Me.Users.by_ap_id(@restored_actor)

      test_pid = self()

      Repatch.patch(
        Bonfire.Federate.ActivityPub.Adapter,
        :undelete_remote_actor,
        [mode: :shared],
        fn ap_id ->
          send(test_pid, {:undeleted, ap_id})
          Repatch.real(Bonfire.Federate.ActivityPub.Adapter.undelete_remote_actor(ap_id))
        end
      )

      # the origin deletes it: it stops serving it, which is what makes the deletion believed
      origin_serves(nil)

      delete = %{
        "id" => @restored_actor <> "#delete",
        "type" => "Delete",
        "actor" => @restored_actor,
        "object" => @restored_actor,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }

      assert {:ok, _} = ActivityPub.Federator.Transformer.handle_incoming(delete)

      %{
        "id" => @restored_actor <> "#undo",
        "type" => "Undo",
        "actor" => @restored_actor,
        "object" => delete,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    end

    # the restoring itself is checked where the adapter does it; here what counts is whether it is asked for
    test "control: the origin serving the same actor again has our copy restored" do
      undo = delete_then_undo()
      origin_serves(Simulate.actor_json(@restored_actor, "restored"))

      ActivityPub.Federator.Transformer.handle_incoming(undo)
      assert_received {:undeleted, @restored_actor}
    end

    test "the origin serving another actor under the address does not restore it" do
      undo = delete_then_undo()
      origin_serves(Simulate.actor_json(@someone_else, "restored"))

      refute match?({:ok, _}, ActivityPub.Federator.Transformer.handle_incoming(undo))
      refute_received {:undeleted, _}
    end
  end

  # serves each url's document, 404 for the rest, and tells the test which urls were asked for
  defp mock_recording_fetches(documents) do
    test = self()

    Tesla.Mock.mock(fn
      %{method: :get, url: url} ->
        send(test, {:fetched, url})

        case documents do
          %{^url => document} -> Tesla.Mock.json(document)
          _ -> %Tesla.Env{status: 404, body: ""}
        end

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  defp spoofed_actor_json(claimed_id, username, public_key_pem) do
    Simulate.actor_json(claimed_id, username)
    |> Map.put("name", "spoofed")
    |> put_in(["publicKey", "publicKeyPem"], public_key_pem)
  end

  defp attacker_public_key do
    {:ok, private_pem} = ActivityPub.Safety.Keys.generate_rsa_pem()
    {:ok, _, public_key} = ActivityPub.Safety.Keys.keypair_from_pem(private_pem)

    [:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)]
    |> :public_key.pem_encode()
  end
end
