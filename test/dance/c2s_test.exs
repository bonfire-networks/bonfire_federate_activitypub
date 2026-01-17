Code.require_file("../../../bonfire_open_id/test/support/oidc_dance.ex", __DIR__)

defmodule Bonfire.Federate.ActivityPub.Dance.C2STest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.OpenID.OIDCDance
  alias Bonfire.Me.Fake
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  import Bonfire.Common.Config, only: [repo: 0]
  import Untangle

  @openid_scope "openid profile email offline_access"

  @tag :test_instance
  test "can authenticate and Create a public Note and the Like it, all via C2S API", context do
    # Use the remote user (on secondary instance, port 4002)
    assert user = context[:remote][:user]
    assert username = e(user, :character, :username, nil)
    # assert email = e(user, :account, :email, :email_address, nil)
    assert password = context[:test_password]

    # All endpoints should point to the secondary instance (port 4002)
    base_url = "http://localhost:4002"
    discovery_uri = base_url <> "/.well-known/openid-configuration"

    {:ok, discovery_doc} =
      OIDCDance.verify_discovery_document(discovery_uri, base_url)
      |> debug("C2S Test - Discovery Document Fetch")

    {:ok, registration_endpoint} =
      OIDCDance.get_registration_endpoint(discovery_uri)
      |> debug("C2S Test - Registration Endpoint Fetch")

    redirect_uri = base_url <> "/auth/callback"

    {client_id, client_secret, _registration_access_token, _registration_client_uri} =
      OIDCDance.perform_dynamic_registration(Req.new(), registration_endpoint, redirect_uri)
      |> debug("C2S Test - Dynamic Client Registration")

    req = Req.new()

    # Password grant to get access token
    assert token_endpoint = discovery_doc["token_endpoint"]

    {:ok, access_token} =
      OIDCDance.exchange_password_for_tokens(
        req,
        token_endpoint,
        client_id,
        client_secret,
        username,
        password,
        @openid_scope
      )
      |> debug("C2S Test - Password Grant Token Exchange")

    # Fetch actor JSON to get outbox URL (on remote instance)
    actor_url = base_url <> "/@" <> username

    {:ok, %{status: 200, body: actor_body}} =
      Req.get(
        req,
        url: actor_url,
        headers: [{"accept", "application/activity+json"}]
      )
      |> debug("C2S Test - Fetch Actor JSON")

    actor_json = Jason.decode!(actor_body)

    assert outbox_url = actor_json["outbox"]
    assert is_binary(outbox_url)

    # Act: POST a bare Note to the outbox (on remote instance)
    note_content = "Hello from C2S test at #{DateTime.utc_now()}"

    note = %{
      "type" => "Note",
      "content" => note_content,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    {:ok, %{status: 201, body: create_activity}} =
      Req.post(
        req,
        url: outbox_url,
        headers: [
          {"authorization", "Bearer #{access_token}"},
          {"content-type", "application/activity+json"},
          {"accept", "application/activity+json"}
        ],
        json: note
      )
      |> debug("C2S Test - Create Note via Outbox")

    assert create_activity["type"] == "Create"

    created_note = create_activity["object"]

    created_note =
      if is_binary(created_note) do
        # If the created_note is a URL string, fetch the Note JSON from that URL
        {:ok, %{status: 200, body: fetched_note}} =
          Req.get(
            req,
            url: created_note,
            headers: [{"accept", "application/activity+json"}]
          )
          |> debug("C2S Test - Fetch Created Note by URL")

        Jason.decode!(fetched_note)
      else
        created_note
      end

    # Assert: response contains expected fields
    assert created_note["type"] == "Note"
    assert created_note["content"] =~ note_content
    assert created_note["id"]

    # # FIXME? refetch activity to double check
    # {:ok, %{status: 200, body: fetched_activity}} =
    #     Req.get(
    #       req,
    #       url: create_activity["id"],
    #       headers: [{"accept", "application/activity+json"}]
    #     )
    #     |> debug("C2S Test - Fetch Create Activity by URL")

    # fetched_activity =  Jason.decode!(fetched_activity)

    # assert create_activity == fetched_activity

    # Verify via DB: check the Note exists in the database (on remote instance)
    remote_post =
      TestInstanceRepo.apply(fn ->
        assert {:ok, object} =
                 AdapterUtils.get_by_url_ap_id_or_username(created_note["id"])
                 |> repo().maybe_preload(:post_content)

        assert object.post_content.html_body =~ note_content

        assert Bonfire.Federate.ActivityPub.AdapterUtils.is_local?(object)

        object
      end)

    assert {:ok, object} =
             AdapterUtils.get_by_url_ap_id_or_username(created_note["id"])
             |> repo().maybe_preload(:post_content)

    assert object.post_content.html_body =~ note_content

    refute Bonfire.Federate.ActivityPub.AdapterUtils.is_local?(object)

    # C2S: Like the created Note via outbox
    like_activity = %{
      "type" => "Like",
      "object" => created_note["id"]
    }

    {:ok, %{status: 201, body: like_response}} =
      Req.post(
        req,
        url: outbox_url,
        headers: [
          {"authorization", "Bearer #{access_token}"},
          {"content-type", "application/activity+json"},
          {"accept", "application/activity+json"}
        ],
        json: like_activity
      )
      |> debug("C2S Test - Like Note via Outbox")

    assert like_response["type"] == "Like"
    assert like_response["object"] == created_note["id"]
    assert like_response["id"]

    TestInstanceRepo.apply(fn ->
      Bonfire.Social.Likes.liked?(user, remote_post)
    end)
  end
end
