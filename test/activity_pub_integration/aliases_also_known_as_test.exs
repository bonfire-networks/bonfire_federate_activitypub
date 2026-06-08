defmodule Bonfire.Federate.ActivityPub.AliasesAlsoKnownAsTest do
  @moduledoc """
  Regression tests for AdapterUtils.also_known_as?/2 with stale migration aliases (issue #2029).

  When actor B has alsoKnownAs: [A], displaying B's profile shows A as an alias. The "Verified
  alias" badge calls AdapterUtils.also_known_as?(B, A_character). It should return true when:
  - A.alsoKnownAs contains B's AP ID
  - A.movedTo == B's AP ID  (normal Mastodon migration case)
  - B.alsoKnownAs contains A's AP ID
  It must NOT crash when actor data is missing or unreachable.
  """

  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock
  alias Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  defp actor_json(ap_id, extra \\ %{}) do
    base = Simulate.actor_json("https://mocked.local/users/karen")
    username = ap_id |> URI.parse() |> Map.get(:path) |> String.split("/") |> List.last()

    base
    |> Map.merge(%{
      "id" => ap_id,
      "preferredUsername" => username,
      "inbox" => ap_id <> "/inbox",
      "outbox" => ap_id <> "/outbox",
      "followers" => ap_id <> "/followers",
      "following" => ap_id <> "/following",
      "publicKey" => %{
        "id" => ap_id <> "#main-key",
        "owner" => ap_id,
        "publicKeyPem" => base["publicKey"]["publicKeyPem"]
      }
    })
    |> Map.merge(extra)
  end

  defp remote_actor(ap_id, extra \\ %{}) do
    json = actor_json(ap_id, extra)

    mock(fn %{method: :get, url: ^ap_id} -> json(json) end)

    {:ok, char} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(json)
    char
  end

  describe "AdapterUtils.also_known_as?/2 — verified alias badge" do
    test "returns false when no relationship exists between actors" do
      b = remote_actor("https://mocked.local/users/b_unrelated")
      a = remote_actor("https://mocked.local/users/a_unrelated")

      refute AdapterUtils.also_known_as?(b, a)
    end

    test "returns true when A.alsoKnownAs contains B (A claims B as successor)" do
      b_ap_id = "https://mocked.local/users/b_fwd"
      b = remote_actor(b_ap_id)
      a = remote_actor("https://mocked.local/users/a_fwd", %{"alsoKnownAs" => [b_ap_id]})

      assert AdapterUtils.also_known_as?(b, a)
    end

    test "returns true when A.movedTo == B (A confirmed migration to B — normal Mastodon case)" do
      b_ap_id = "https://mocked.local/users/b_movedto"
      b = remote_actor(b_ap_id)
      a = remote_actor("https://mocked.local/users/a_movedto", %{"movedTo" => b_ap_id})

      assert AdapterUtils.also_known_as?(b, a)
    end

    test "returns true when B.alsoKnownAs contains A (B claims A as past identity)" do
      a_ap_id = "https://mocked.local/users/a_claims"
      # Create a first so it's cached before b (b's alsoKnownAs triggers a fetch of a)
      a = remote_actor(a_ap_id)
      b = remote_actor("https://mocked.local/users/b_claims", %{"alsoKnownAs" => [a_ap_id]})

      assert AdapterUtils.also_known_as?(b, a)
    end

    test "returns false when A.movedTo points somewhere else" do
      b = remote_actor("https://mocked.local/users/b_wrong")

      a =
        remote_actor("https://mocked.local/users/a_wrong", %{
          "movedTo" => "https://mocked.local/users/other"
        })

      refute AdapterUtils.also_known_as?(b, a)
    end

    test "returns false gracefully when old actor is not in AP cache (stale pointer)" do
      b = remote_actor("https://mocked.local/users/b_nocache")
      ghost = %{id: Needle.ULID.generate()}

      result = AdapterUtils.also_known_as?(b, ghost)
      assert result == false or is_nil(result)
    end

    test "never makes HTTP requests — returns false without crashing when actors absent from cache" do
      # Override mock to raise on any HTTP attempt, proving also_known_as? is cache-only
      mock(fn _env -> raise "also_known_as? must not make HTTP requests" end)

      result =
        AdapterUtils.also_known_as?(
          "https://unknown.remote/users/nobody",
          %{id: Needle.ULID.generate()}
        )

      assert result == false or is_nil(result)
    end
  end
end
