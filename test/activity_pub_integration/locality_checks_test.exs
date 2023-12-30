defmodule Bonfire.Federate.ActivityPub.LocalityChecksTest do
  use Bonfire.Federate.ActivityPub.DataCase

  alias Bonfire.Me.Fake
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Posts
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Boosts
  alias Bonfire.Messages

  alias ActivityPub.Federator.Workers.PublisherWorker

  # Maybe move this to adapter tests?
  describe "locality checks" do
    test "federates activities from local actors" do
      attrs = %{
        post_content: %{
          summary: "summary",
          name: "name",
          html_body: "<p>epic html message</p>"
        }
      }

      user = fake_user!()

      assert {:ok, post} =
               Posts.publish(
                 current_user: user,
                 post_attrs: attrs,
                 boundary: "public"
               )

      assert {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

      #  perform_job(PublisherWorker, %{
      #    "context_id" => post.id,
      #    "op" => "create",
      #    "user_id" => user.id
      #  })
    end
  end
end
