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

  # set up the mocks for two actors that reference each other, then create both. Needed for the
  # bidirectional cases, since a single Tesla mock/1 call replaces any previous one.
  defp remote_actor_pair(a_ap_id, a_extra, b_ap_id, b_extra) do
    a_json = actor_json(a_ap_id, a_extra)
    b_json = actor_json(b_ap_id, b_extra)

    mock(fn
      %{method: :get, url: ^a_ap_id} -> json(a_json)
      %{method: :get, url: ^b_ap_id} -> json(b_json)
    end)

    {:ok, a} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(a_json)
    {:ok, b} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(b_json)
    {a, b}
  end

  describe "AdapterUtils.also_known_as?/2 — verified alias badge (bidirectional, #2042)" do
    test "returns false when no relationship exists between actors" do
      b = remote_actor("https://mocked.local/users/b_unrelated")
      a = remote_actor("https://mocked.local/users/a_unrelated")

      refute AdapterUtils.also_known_as?(b, a)
    end

    # --- one-sided relationships must NOT verify (the heart of #2042) ---

    test "false when only A acknowledges B via A.alsoKnownAs (B doesn't acknowledge A back)" do
      b_ap_id = "https://mocked.local/users/b_fwd"
      b = remote_actor(b_ap_id)
      a = remote_actor("https://mocked.local/users/a_fwd", %{"alsoKnownAs" => [b_ap_id]})

      refute AdapterUtils.also_known_as?(b, a)
    end

    test "true when A.movedTo == B alone (migration is self-sufficient — set only post-handshake)" do
      b_ap_id = "https://mocked.local/users/b_movedto"
      b = remote_actor(b_ap_id)
      a = remote_actor("https://mocked.local/users/a_movedto", %{"movedTo" => b_ap_id})

      assert AdapterUtils.also_known_as?(b, a)
    end

    test "false when only B claims A via B.alsoKnownAs (A doesn't acknowledge back) — #2042" do
      # exactly what happens when you add any handle as an alias: it lands in your own
      # alsoKnownAs, which must NOT by itself produce a 'verified' badge
      a_ap_id = "https://mocked.local/users/a_claims"
      a = remote_actor(a_ap_id)
      b = remote_actor("https://mocked.local/users/b_claims", %{"alsoKnownAs" => [a_ap_id]})

      refute AdapterUtils.also_known_as?(b, a)
    end

    test "true when B.movedTo == A alone (migration is self-sufficient — set only post-handshake)" do
      a_ap_id = "https://mocked.local/users/a_nomove"
      a = remote_actor(a_ap_id)
      b = remote_actor("https://mocked.local/users/b_nomove", %{"movedTo" => a_ap_id})

      assert AdapterUtils.also_known_as?(b, a)
    end

    # --- bidirectional relationships verify (both sides acknowledge, via aKA and/or movedTo) ---

    test "true when both acknowledge via alsoKnownAs (mutual alias)" do
      a_ap_id = "https://mocked.local/users/a_bi"
      b_ap_id = "https://mocked.local/users/b_bi"

      {a, b} =
        remote_actor_pair(a_ap_id, %{"alsoKnownAs" => [b_ap_id]}, b_ap_id, %{
          "alsoKnownAs" => [a_ap_id]
        })

      assert AdapterUtils.also_known_as?(b, a)
    end

    test "true for migration A→B: A.movedTo == B AND B.alsoKnownAs contains A" do
      a_ap_id = "https://mocked.local/users/a_mig1"
      b_ap_id = "https://mocked.local/users/b_mig1"

      {a, b} =
        remote_actor_pair(a_ap_id, %{"movedTo" => b_ap_id}, b_ap_id, %{"alsoKnownAs" => [a_ap_id]})

      assert AdapterUtils.also_known_as?(b, a)
    end

    test "true for migration B→A: B.movedTo == A AND A.alsoKnownAs contains B" do
      a_ap_id = "https://mocked.local/users/a_mig2"
      b_ap_id = "https://mocked.local/users/b_mig2"

      {a, b} =
        remote_actor_pair(a_ap_id, %{"alsoKnownAs" => [b_ap_id]}, b_ap_id, %{"movedTo" => a_ap_id})

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
