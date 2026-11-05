defmodule Bonfire.Federate.ActivityPub.MbinOwnPostUITest do
  @moduledoc """
  A post made here into an Mbin magazine shows on our copy of the magazine's page. Mbin sends its `Announce` of a post to every follower but the server the post came from, so the post can't wait for that `Announce` to reach the page, as it does for Lemmy. The backend half is in `threadiverse_interop_test.exs` ("a post made here into a community hosted elsewhere").
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures

  @magazine "https://mbin.local/m/testing"

  setup do
    # what an earlier test learned about the same made-up host must not answer for this one
    ActivityPub.Instances.delete_host_cache("mbin.local", :software)
    actor = fixture("mbin", "magazine_actor.json")

    mock(fn
      %{method: :get, url: @magazine} ->
        json(actor)

      %{method: :get, url: "https://mbin.local/.well-known/nodeinfo"} ->
        json(%{
          "links" => [
            %{
              "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
              "href" => "https://mbin.local/nodeinfo/2.0"
            }
          ]
        })

      %{method: :get, url: "https://mbin.local/nodeinfo/2.0"} = env ->
        %Tesla.Env{env | status: 200, body: Jason.encode!(%{"software" => %{"name" => "mbin"}})}

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, group} =
      Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{"id" => @magazine})

    account = fake_account!()
    me = fake_user!(account)

    {:ok, group: group, me: me, conn: conn(user: me, account: account)}
  end

  test "a post made here into an Mbin magazine is on its page here", %{
    group: group,
    me: me,
    conn: conn
  } do
    Bonfire.Classify.Simulate.fake_post_in_group!(me, group, "<p>made here for the magazine</p>")

    conn
    |> visit(Bonfire.Common.URIs.path(group))
    |> wait_async()
    |> assert_has("article", text: "made here for the magazine")
  end
end
