defmodule Bonfire.Federate.ActivityPub.Dance.ProofsTest do
  @moduledoc """
  FEP-8b32 across a real federation: how the receiving instance stores what the other instance sent (the `authenticated` column of `ap_object`).

    * a post FETCHED by its id is `fetched`
    * a post DELIVERED with a valid HTTP signature is `http_signature`, like the `Create` around it, whether or not it carries a proof: the proof is only looked at when the HTTP signature cannot be relied on
    * a post DELIVERED with no valid HTTP signature and a proof is `integrity_proof`, which is how a forwarded copy is authenticated
    * a post DELIVERED with neither is vouched for by nobody

  Both instances run in one VM, so the `sign_object_integrity_proofs` setting and the patch that takes the HTTP signature off are the sender's and the receiver's alike; they only change what is SENT.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false
  use Repatch.ExUnit

  @moduletag :test_instance

  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias ActivityPub.Federator.APPublisher
  alias ActivityPub.Object
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows

  # {name, sent with an HTTP signature, sent with a proof, the post as stored, the `Create` as stored}
  @deliveries [
    {"HTTP signature, no proof", true, false, :http_signature, :http_signature},
    {"HTTP signature and proof", true, true, :http_signature, :http_signature},
    {"proof, no HTTP signature", false, true, :integrity_proof, :integrity_proof},
    {"neither", false, false, :fetched, :fetched}
  ]

  setup context do
    orig = Application.get_env(:activity_pub, :sign_object_integrity_proofs)

    clean_slate(context)

    on_exit(fn ->
      if is_nil(orig),
        do: Application.delete_env(:activity_pub, :sign_object_integrity_proofs),
        else: Application.put_env(:activity_pub, :sign_object_integrity_proofs, orig)
    end)
  end

  defp sign_proofs(on?),
    do: Application.put_env(:activity_pub, :sign_object_integrity_proofs, on?)

  # deliveries go out as they would to a host we have no actor for: with a digest, and no signature
  defp no_http_signatures do
    Repatch.patch(APPublisher, :sign_and_publish_one, [mode: :shared], fn _actor, params ->
      APPublisher.publish_one_unsigned(params)
    end)
  end

  defp publish_public(user, text) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: text}},
        boundary: "public"
      )

    Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)
  end

  # how the receiving instance stored the object with this id
  defp stored_authentication(ap_id) do
    TestInstanceRepo.apply(fn ->
      assert {:ok, %Object{authenticated: authenticated}} = Object.get_cached(ap_id: ap_id)
      authenticated
    end)
  end

  # the same for the `Create` that delivered it
  defp stored_activity_authentication(object_ap_id) do
    TestInstanceRepo.apply(fn ->
      assert %Object{authenticated: authenticated} =
               Object.get_activity_for_object_ap_id(object_ap_id)

      authenticated
    end)
  end

  @tag :test_instance
  test "a post fetched by its id is stored as fetched", _context do
    # not followed by the remote user, so nothing is delivered
    other = fancy_fake_user!("Local2")[:user]
    sign_proofs(true)

    canonical_url = publish_public(other, "fetched, not delivered")

    TestInstanceRepo.apply(fn ->
      assert {:ok, _post} = AdapterUtils.get_by_url_ap_id_or_username(canonical_url)
    end)

    assert stored_authentication(canonical_url) == :fetched
  end

  for {name, http_signed?, proofs?, post_authenticated, create_authenticated} <- @deliveries do
    @tag :test_instance
    @tag http_signed?: http_signed?
    @tag proofs?: proofs?
    @tag post_authenticated: post_authenticated
    @tag create_authenticated: create_authenticated
    test "a post delivered with #{name} is stored as #{post_authenticated}", context do
      user = context[:local][:user]

      # the remote user follows, so what the local user posts is delivered to its inbox
      TestInstanceRepo.apply(fn ->
        assert {:ok, local_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])

        assert {:ok, _follow} = Follows.follow(context[:remote][:user], local_on_remote)
      end)

      sign_proofs(context[:proofs?])
      if !context[:http_signed?], do: no_http_signatures()

      url = publish_public(user, "delivered with #{unquote(name)}")

      assert stored_authentication(url) == context[:post_authenticated]
      assert stored_activity_authentication(url) == context[:create_authenticated]
    end
  end
end
