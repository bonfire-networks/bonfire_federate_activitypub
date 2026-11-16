defmodule Bonfire.Federate.ActivityPub.HTTPSignatureCoverageTest do
  @moduledoc """
  What an HTTP signature on a delivery has to cover for it to vouch for the delivery. A signature that covers only the `date` says nothing about the body, so it can be put on any body; one with no `Date` header, or an old one, can be replayed whenever. Such a delivery is not taken as made by the signer.

  The deliveries are real: signed with `HTTPSignatures.sign` by a throwaway RSA key that the sender's actor document carries, and posted as raw JSON to `/pub/shared_inbox`, so the signature, the digest of the body and the date are all checked by the plugs of the inbox. The queued jobs are run, and what each delivery did is read from whether the post it carried is held as vouched for by the HTTP signature (`authenticated: :http_signature`). The control signs `(request-target) host date digest`, as the servers we federate with do, and is stored.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Tests.ObanHelpers

  @public "https://www.w3.org/ns/activitystreams#Public"
  @host "localhost"
  @path "/pub/shared_inbox"

  setup do
    n = System.unique_integer([:positive])
    signer = "https://sig#{n}.local/users/sam"

    {:ok, pem} = ActivityPub.Safety.Keys.generate_rsa_pem()
    {:ok, private_key, public_key} = ActivityPub.Safety.Keys.keypair_from_pem(pem)

    public_key_pem =
      :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)
      |> then(&:public_key.pem_encode([&1]))

    actor =
      Simulate.actor_json(signer, "sam", %{
        "publicKey" => %{
          "id" => signer <> "#main-key",
          "owner" => signer,
          "publicKeyPem" => public_key_pem
        }
      })

    mock(fn
      %{method: :get, url: ^signer} -> json(actor)
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
    end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: signer)

    %{signer: signer, private_key: private_key, n: n}
  end

  # a `Create` of a post by the signer, as JSON text
  defp create(signer, n) do
    note_id =
      "#{String.replace(signer, "/users/sam", "")}/notes/#{n}-#{System.unique_integer([:positive])}"

    json =
      Jason.encode!(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => note_id <> "/activity",
        "type" => "Create",
        "actor" => signer,
        "to" => [@public],
        "object" => %{
          "id" => note_id,
          "type" => "Note",
          "attributedTo" => signer,
          "content" => "signed #{n}",
          "to" => [@public]
        }
      })

    {note_id, json}
  end

  defp digest(body), do: "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body))

  defp http_date(seconds_ago \\ 0),
    do:
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

  # posts `body` with `headers` (a list of {name, value}), signing the ones named in `signed` with the key
  defp deliver(ctx, body, headers, signed) do
    to_sign =
      for {name, value} <- headers, name in signed, into: %{} do
        {String.to_atom(name), value}
      end

    to_sign = Map.put(to_sign, :"(request-target)", "post #{@path}")

    to_sign =
      if "(request-target)" in signed, do: to_sign, else: Map.delete(to_sign, :"(request-target)")

    signature =
      HTTPSignatures.sign(ctx.private_key, ctx.signer <> "#main-key", to_sign)

    # a test conn has no `host` header (Plug keeps it in `conn.host`), a real request does
    conn =
      Enum.reduce(headers, build_conn(), fn
        {"host", value}, conn ->
          %{conn | host: value, req_headers: [{"host", value} | conn.req_headers]}

        {name, value}, conn ->
          put_req_header(conn, name, value)
      end)
      |> put_req_header("signature", signature)
      |> put_req_header("content-type", "application/activity+json")
      |> post(@path, body)

    ObanHelpers.perform_all()
    conn
  end

  # whether the post is held as vouched for by the HTTP signature of the delivery. A delivery that nothing vouches for can still be held (as `:unverified`), so being held says nothing about the signature.
  defp held?(id),
    do: match?({:ok, %{authenticated: :http_signature}}, ActivityPub.Object.get_cached(ap_id: id))

  test "control: a signature over the request target, host, date and digest vouches for the delivery",
       ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver(
      ctx,
      body,
      [{"host", @host}, {"date", http_date()}, {"digest", digest(body)}],
      ["(request-target)", "host", "date", "digest"]
    )

    assert held?(note_id), "a delivery signed over all of it was not taken"
  end

  test "a signature over the date only does not vouch for the body", ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver(
      ctx,
      body,
      [{"host", @host}, {"date", http_date()}, {"digest", digest(body)}],
      ["date"]
    )

    refute held?(note_id), "a body that its signature does not cover was taken as the signer's"
  end

  test "a signature over the request target and the date, but not the digest, does not vouch for the body",
       ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver(
      ctx,
      body,
      [{"host", @host}, {"date", http_date()}, {"digest", digest(body)}],
      ["(request-target)", "host", "date"]
    )

    refute held?(note_id), "a body that its signature does not cover was taken as the signer's"
  end

  test "a delivery with no Date header does not vouch for itself", ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver(
      ctx,
      body,
      [{"host", @host}, {"digest", digest(body)}],
      ["(request-target)", "host", "digest"]
    )

    refute held?(note_id), "a delivery that could be replayed at any time was taken"
  end

  test "a delivery with a stale Date is not taken", ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver(
      ctx,
      body,
      [{"host", @host}, {"date", http_date(2 * 24 * 60 * 60)}, {"digest", digest(body)}],
      ["(request-target)", "host", "date", "digest"]
    )

    refute held?(note_id), "a delivery signed two days ago was taken"
  end

  test "control: a signature as Lemmy makes it (hs2019, no created, with content-type) vouches for the delivery",
       ctx do
    {note_id, body} = create(ctx.signer, ctx.n)
    date = http_date()

    to_sign = %{
      "(request-target)": "post #{@path}",
      "content-type": "application/activity+json",
      date: date,
      digest: digest(body),
      host: @host
    }

    signature =
      HTTPSignatures.sign(ctx.private_key, ctx.signer <> "#main-key", to_sign)
      |> String.replace(~s(algorithm="rsa-sha256"), ~s(algorithm="hs2019"))

    conn =
      %{build_conn() | host: @host, req_headers: [{"host", @host}]}
      |> put_req_header("date", date)
      |> put_req_header("digest", digest(body))
      |> put_req_header("signature", signature)
      |> put_req_header("content-type", "application/activity+json")
      |> post(@path, body)

    ObanHelpers.perform_all()
    assert conn.status in [200, 202]
    assert held?(note_id), "a delivery signed as Lemmy signs was not taken"
  end

  # an RFC 9421 delivery, with `Content-Digest` only (no `Digest`), as NodeBB sends it. `components` are the covered ones, `created` the creation time of the signature (nil leaves it out of the parameters)
  defp deliver_9421(ctx, body, components, created) do
    base = ActivityPub.Web.base_uri()
    date = http_date()
    content_digest = "sha-256=:" <> Base.encode64(:crypto.hash(:sha256, body)) <> ":"

    values = %{
      "@method" => "POST",
      "@scheme" => base.scheme || "https",
      "@authority" => ActivityPub.Utils.authority(base),
      "@path" => @path,
      "content-digest" => content_digest,
      "content-type" => "application/activity+json",
      "date" => date
    }

    {sig_input, sig} =
      HTTPSignatures.RFC9421.sign(ctx.private_key, ctx.signer <> "#main-key", values,
        components: components,
        created: created || 0
      )

    sig_input =
      if created,
        do: sig_input,
        else: String.replace(sig_input, ";created=0", "")

    conn =
      %{build_conn() | host: @host, req_headers: [{"host", @host}]}
      |> put_req_header("date", date)
      |> put_req_header("content-digest", content_digest)
      |> put_req_header("signature-input", sig_input)
      |> put_req_header("signature", sig)
      |> put_req_header("content-type", "application/activity+json")
      |> post(@path, body)

    ObanHelpers.perform_all()
    conn
  end

  test "control: an RFC 9421 signature as NodeBB makes it vouches for the delivery", ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver_9421(
      ctx,
      body,
      ["@method", "@authority", "@target-uri", "content-type", "content-digest", "date"],
      System.os_time(:second)
    )

    assert held?(note_id), "an RFC 9421 delivery signed over all of it was not taken"
  end

  test "an RFC 9421 signature that does not cover the content digest does not vouch for the body",
       ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver_9421(ctx, body, ["@method", "@target-uri", "date"], System.os_time(:second))

    refute held?(note_id), "a body that its signature does not cover was taken as the signer's"
  end

  test "an RFC 9421 signature with no created time does not vouch for itself", ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver_9421(ctx, body, ["@method", "@target-uri", "content-digest"], nil)

    refute held?(note_id), "a delivery that could be replayed at any time was taken"
  end

  test "an RFC 9421 signature with a stale created time is not taken", ctx do
    {note_id, body} = create(ctx.signer, ctx.n)

    deliver_9421(
      ctx,
      body,
      ["@method", "@target-uri", "content-digest"],
      System.os_time(:second) - 2 * 24 * 60 * 60
    )

    refute held?(note_id), "a delivery signed two days ago was taken"
  end
end
