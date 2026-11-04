defmodule Bonfire.Federate.ActivityPub.SignedFetchPublicActorsTest do
  @moduledoc """
  With "Require authentication from federated servers" on, in its default meaning (`reject_unsigned: true`), a public group or person can still be fetched without a signature, and gets the same actor document a signed fetch gets. Servers that don't sign their fetches (eg. Lemmy before 1.0) can then find our groups and read the keys that verify what we send them. A hidden actor, and every post, activity and collection, still need a signature. With `reject_unsigned: :all` everything needs one, actors too.

  Signature verification is faked the way the fork's controller tests do it (assign `valid_signature: true` and a `keyId` header), so these tests cover what the gate lets through, not the cryptography.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Common.Settings

  @moduletag :federation

  import Tesla.Mock

  alias Bonfire.Common.URIs
  alias Bonfire.Posts

  @signer "https://signer.local/users/sig"

  setup_all do
    mock_global(fn
      %{method: :get, url: @signer} -> json(Simulate.actor_json(@signer, "sig"))
      _ -> raise Tesla.Mock.Error, "Module request not mocked"
    end)
  end

  setup do
    previous = Application.get_env(:activity_pub, :reject_unsigned)
    Application.put_env(:activity_pub, :reject_unsigned, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:activity_pub, :reject_unsigned),
        else: Application.put_env(:activity_pub, :reject_unsigned, previous)
    end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @signer)

    :ok
  end

  defp fetch(path, signed_by \\ nil) do
    build_conn()
    |> put_req_header("accept", "application/activity+json")
    |> sign_as(signed_by)
    |> get(path)
  end

  defp sign_as(conn, nil), do: conn

  defp sign_as(conn, actor_url) do
    conn
    |> assign(:valid_signature, true)
    |> put_req_header("signature", "keyId=\"#{actor_url}\"")
  end

  defp ap_path(object), do: URI.parse(URIs.canonical_url(object, preload_if_needed: true)).path

  defp public_group!,
    do: Bonfire.Classify.Simulate.fake_group!(fake_user!(), %{visibility: "global"})

  # the full document: what a signed fetch gets, with what Lemmy shows of a group or person
  defp assert_full_actor(conn, type) do
    assert conn.status == 200
    doc = Jason.decode!(conn.resp_body)

    assert doc["type"] == type
    assert is_binary(doc["preferredUsername"])
    assert is_binary(doc["inbox"])
    assert is_binary(doc["outbox"])
    assert is_binary(doc["name"])
    assert is_binary(doc["followers"])
    assert doc["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    doc
  end

  describe "with signatures required except for public actors" do
    test "an unsigned fetch of a public group gets the same full actor a signed fetch gets" do
      path = ap_path(public_group!())

      signed = fetch(path, @signer) |> assert_full_actor("Group")
      unsigned = fetch(path) |> assert_full_actor("Group")

      # `updated` is when the document was generated, so differs between the two fetches
      assert Map.delete(unsigned, "updated") == Map.delete(signed, "updated")
    end

    test "an unsigned fetch of a public person gets the same full actor a signed fetch gets" do
      path = ap_path(fake_user!())

      signed = fetch(path, @signer) |> assert_full_actor("Person")
      unsigned = fetch(path) |> assert_full_actor("Person")

      # `updated` is when the document was generated, so differs between the two fetches
      assert Map.delete(unsigned, "updated") == Map.delete(signed, "updated")
    end

    test "an unsigned fetch of a group that doesn't federate is refused" do
      group =
        Bonfire.Classify.Simulate.fake_group!(fake_user!(), %{
          membership: "open",
          visibility: "nonfederated",
          participation: "anyone"
        })

      assert fetch(ap_path(group)).status == 401
    end

    test "an unsigned fetch of a person who doesn't federate is refused" do
      me = fake_user!()
      me = current_user(Settings.put([:activity_pub, :user_federating], false, current_user: me))

      assert fetch(ap_path(me)).status == 401
    end

    test "an unsigned fetch of a public post is still refused" do
      author = fake_user!()
      text = "public post #{System.unique_integer([:positive])}"

      {:ok, post} =
        Posts.publish(
          current_user: author,
          post_attrs: %{post_content: %{html_body: text}},
          boundary: "public"
        )

      # the positive first: a signed fetch of it does get it
      signed = fetch("/pub/objects/#{post.id}", @signer)
      assert signed.status == 200
      assert signed.resp_body =~ text

      conn = fetch("/pub/objects/#{post.id}")
      assert conn.status == 401
      refute conn.resp_body =~ text
    end

    test "an unsigned fetch of a public group's outbox is still refused" do
      assert fetch(ap_path(public_group!()) <> "/outbox").status == 401
    end
  end

  describe "with signatures required for everything" do
    setup do
      Application.put_env(:activity_pub, :reject_unsigned, :all)
      :ok
    end

    test "an unsigned fetch of a public group is refused" do
      assert fetch(ap_path(public_group!())).status == 401
    end

    test "an unsigned fetch of a public person is refused" do
      assert fetch(ap_path(fake_user!())).status == 401
    end

    test "control: a signed fetch of a public group gets it" do
      fetch(ap_path(public_group!()), @signer) |> assert_full_actor("Group")
    end
  end
end
