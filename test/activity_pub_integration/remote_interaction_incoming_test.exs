defmodule Bonfire.Federate.ActivityPub.RemoteInteractionIncomingTest do
  @moduledoc """
  A visitor whose account is on this instance arrives from another server's comments widget to reply to an object this instance hasn't seen yet. The instance must fetch it, whether it was handed the object's ActivityPub id or a page that points at it with `<link rel="alternate" type="application/activity+json">`, instead of answering "Remote actor or object not found".
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation
  import Tesla.Mock

  @actor "https://mocked.local/users/karen"
  @page_id "https://mocked.local/objects/an-article-page"
  @html_page "https://blog.mocked.local/an-article/"

  setup do
    page = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => @page_id,
      "type" => "Page",
      "actor" => @actor,
      "attributedTo" => @actor,
      "name" => "An article",
      "url" => @html_page,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    mock_global(fn
      %{method: :get, url: @actor} ->
        json(Simulate.actor_json(@actor))

      %{method: :get, url: @page_id} ->
        json(page)

      %{method: :get, url: @html_page} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body:
            ~s(<html><head><link rel="alternate" type="application/activity+json" href="#{@page_id}"></head><body>An article</body></html>)
        }

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "given the object's ActivityPub id, it is fetched and the visitor is redirected to it" do
    conn = get(build_conn(), "/pub/remote_interaction?acct=#{URI.encode_www_form(@page_id)}")

    assert conn.status in [301, 302], "got #{conn.status}: #{conn.resp_body}"
  end

  test "given a page carrying an alternate ActivityPub link, the link is followed" do
    conn = get(build_conn(), "/pub/remote_interaction?acct=#{URI.encode_www_form(@html_page)}")

    assert conn.status in [301, 302], "got #{conn.status}: #{conn.resp_body}"
  end
end
