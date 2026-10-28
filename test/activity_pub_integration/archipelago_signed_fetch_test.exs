defmodule Bonfire.Federate.ActivityPub.ArchipelagoSignedFetchTest do
  @moduledoc """
  An instance in archipelago (allowlist-only) mode must not hand its public objects to servers outside its allowlist. A boost on an allowlisted server only carries the object's URI, so the server that wants the content fetches it from us: that fetch is where we refuse.

  Signature verification is faked the way the fork's controller tests do it (assign `valid_signature: true` and a `keyId` header), so these tests cover what we do with the identity a signature maps to, not the cryptography.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Actor
  alias Bonfire.Federate.ActivityPub.Instances
  alias Bonfire.Posts

  @allowed_actor "https://allowed.local/users/ann"
  @outside_actor "https://outside.local/users/otto"

  setup_all do
    mock_global(fn
      %{method: :get, url: @allowed_actor} ->
        json(Simulate.actor_json(@allowed_actor))

      %{method: :get, url: @outside_actor} ->
        json(Simulate.actor_json(@outside_actor))

      _ ->
        raise Tesla.Mock.Error, "Module request not mocked"
    end)
  end

  setup do
    Process.put(:federating, true)

    # these tests are about what the allowlist does, so make sure nothing else already requires signatures
    previous = Application.get_env(:activity_pub, :reject_unsigned)
    Application.put_env(:activity_pub, :reject_unsigned, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:activity_pub, :reject_unsigned),
        else: Application.put_env(:activity_pub, :reject_unsigned, previous)
    end)

    # both remote actors are known while the instance is still open, as they would be in practice
    {:ok, _} = Actor.get_cached_or_fetch(ap_id: @allowed_actor)
    {:ok, _} = Actor.get_cached_or_fetch(ap_id: @outside_actor)

    author = fake_user!()
    text = "archipelago fetch #{System.unique_integer([:positive])}"

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: text}},
        boundary: "public"
      )

    [post: post, text: text]
  end

  defp archipelago_with_allowed_instance! do
    Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, true)
    {:ok, _} = Instances.add_to_allowlist("allowed.local")
    :ok
  end

  defp fetch_object(post, signed_by \\ nil) do
    build_conn()
    |> put_req_header("accept", "application/activity+json")
    |> sign_as(signed_by)
    |> get("/pub/objects/#{post.id}")
  end

  defp sign_as(conn, nil), do: conn

  defp sign_as(conn, actor_url) do
    conn
    |> assign(:valid_signature, true)
    |> put_req_header("signature", "keyId=\"#{actor_url}\"")
  end

  test "control: an unsigned fetch gets the post while the instance is open", %{
    post: post,
    text: text
  } do
    conn = fetch_object(post)

    assert conn.status == 200
    assert conn.resp_body =~ text
  end

  test "an unsigned fetch is refused in archipelago mode", %{post: post, text: text} do
    archipelago_with_allowed_instance!()

    conn = fetch_object(post)

    assert conn.status == 401
    refute conn.resp_body =~ text
  end

  test "a fetch signed by an allowlisted server gets the post", %{post: post, text: text} do
    archipelago_with_allowed_instance!()

    conn = fetch_object(post, @allowed_actor)

    assert conn.status == 200
    assert conn.resp_body =~ text
  end

  # servers verify our signed fetches by reading this actor's public key, so it has to stay readable without a signature, or two archipelago instances could never verify each other
  test "the service actor can still be fetched unsigned in archipelago mode" do
    archipelago_with_allowed_instance!()

    path = URI.parse(ActivityPub.Utils.service_actor!().ap_id).path

    conn =
      build_conn()
      |> put_req_header("accept", "application/activity+json")
      |> get(path)

    assert conn.status == 200
  end

  test "a fetch signed by a server outside the allowlist is refused", %{post: post, text: text} do
    archipelago_with_allowed_instance!()

    conn = fetch_object(post, @outside_actor)

    assert conn.status == 403
    refute conn.resp_body =~ text
  end
end
