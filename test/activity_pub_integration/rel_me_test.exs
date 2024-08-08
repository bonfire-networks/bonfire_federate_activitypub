# defmodule Bonfire.Federate.ActivityPub.RelMeTest do
#  # NOTE: see also `Unfurl.RelMeTest`
#   use Bonfire.Federate.ActivityPub.ConnCase, async: false
#   import Tesla.Mock
#   import Untangle
#   alias Bonfire.Posts
#   use Bonfire.Common.Repo

#   @remote_instance "https://mocked.local"
#   @remote_actor @remote_instance <> "/users/karen"

#   setup_all do
#     Tesla.Mock.mock_global(fn
#       %{method: :get, url: @remote_actor} ->
#         json(Simulate.actor_json(@remote_actor))

#       %{method: :get, url: url} ->
#         get(url, nil, nil, nil)
#       _ ->
#         raise Tesla.Mock.Error, "Request not mocked"
#     end)
#     |> IO.inspect(label: "setup done")

#     :ok
#   end

#   def get("http://example.com/rel_me/anchor", _, _, _) do
#     {:ok, %Tesla.Env{status: 200, body: ("../fixtures/rel_me_anchor.html") |> Path.expand(__DIR__)
#       |> File.read!()}}
#   end

#   def get("http://example.com/rel_me/anchor_nofollow", _, _, _) do
#     {:ok, %Tesla.Env{status: 200, body: ("../fixtures/rel_me_anchor_nofollow.html") |> Path.expand(__DIR__)
#       |> File.read!()}}
#   end

#   def get("http://example.com/rel_me/link", _, _, _) do
#     {:ok, %Tesla.Env{status: 200, body: ("../fixtures/rel_me_link.html") |> Path.expand(__DIR__)
#       |> File.read!()}}
#   end

#   def get("http://example.com/rel_me/null", _, _, _) do
#     {:ok, %Tesla.Env{status: 200, body: ("../fixtures/rel_me_null.html") |> Path.expand(__DIR__)
#       |> File.read!()}}
#   end
#   def get(_, _, _, _) do
#         raise Tesla.Mock.Error, "Request not mocked"
#   end

# describe "rel_me" do
#   # test "Adds rel=me on linkbacked urls" do
#   #     user = insert(:user, ap_id: "https://social.example.org/users/test")

#   #     bio = "http://example.com/rel_me/null"
#   #     expected_text = "<a href=\"#{bio}\">#{bio}</a>"
#   #     assert expected_text == User.parse_bio(bio, user)

#   #     bio = "http://example.com/rel_me/link"
#   #     expected_text = "<a href=\"#{bio}\" rel=\"me\">#{bio}</a>"
#   #     assert expected_text == User.parse_bio(bio, user)

#   #     bio = "http://example.com/rel_me/anchor"
#   #     expected_text = "<a href=\"#{bio}\" rel=\"me\">#{bio}</a>"
#   #     assert expected_text == User.parse_bio(bio, user)
#   #   end

#   # test "maybe_put_rel_me/2" do
#   #   profile_urls = ["https://social.example.org/users/test"]
#   #   attr = "me"

#   #   assert Pleroma.Web.RelMe.maybe_put_rel_me("http://example.com/rel_me/null", profile_urls) ==
#   #            {:error, {:could_not_verify, "http://example.com/rel_me/null", {:link_match, false}}}

#   #   assert {:error, {:could_not_fetch, "http://example.com/rel_me/error", _}} =
#   #            Pleroma.Web.RelMe.maybe_put_rel_me("http://example.com/rel_me/error", profile_urls)

#   #   assert Pleroma.Web.RelMe.maybe_put_rel_me("http://example.com/rel_me/anchor", profile_urls) ==
#   #            attr

#   #   assert Pleroma.Web.RelMe.maybe_put_rel_me(
#   #            "http://example.com/rel_me/anchor_nofollow",
#   #            profile_urls
#   #          ) == attr

#   #   assert Pleroma.Web.RelMe.maybe_put_rel_me("http://example.com/rel_me/link", profile_urls) ==
#   #            attr
#   # end
#   end  

# end
