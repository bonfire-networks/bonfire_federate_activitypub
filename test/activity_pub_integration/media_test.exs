defmodule Bonfire.Federate.ActivityPub.MediaTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Posts
  # use Bonfire.Common.Repo

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "supports incoming" do
    test "pixelfed note with image" do
      data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      # |> debug("pxxx")

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
               |> repo().maybe_preload([:post_content, :media])

      assert post.__struct__ == Bonfire.Data.Social.Post
      # debug(post)
      assert is_binary(e(post, :post_content, :html_body, nil))

      assert match?(
               %{
                 media: [
                   %Bonfire.Files.Media{
                     path:
                       "https://pxscdn.com/public/m/_v2/411/7198ec0c0-99bc91/6CWmVqUJS5Rx/cXZwkROZAkUOQEidxDNxZYlezi5nRBBLy5f2YAm0.jpg"
                   }
                 ]
               },
               post
             )

      # assert doc =
      #          render_stateful(Bonfire.UI.Social.ActivityLive, %{
      #            id: "activity",
      #            object: post
      #          })

      # assert doc
      #        |> debug
    end

    test "peertube video object" do
      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, media} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert media.__struct__ == Bonfire.Files.Media

      assert media.path ==
               "https://peertube.linuxrocks.local/static/web-videos/39a9890f-a115-40c9-a8a4-c4d2d286ef27-1440.mp4"

      assert media.media_type == "video/mp4"

      assert {:ok, _} = Bonfire.Social.Objects.read(media.id)
    end

    test "non-public peertube video object" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      data =
        "../fixtures/peertube-video.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("to", recipient_actor)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, media} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert media.__struct__ == Bonfire.Files.Media

      assert media.path ==
               "https://peertube.linuxrocks.local/static/web-videos/39a9890f-a115-40c9-a8a4-c4d2d286ef27-1440.mp4"

      assert media.media_type == "video/mp4"

      assert {:error, _} = Bonfire.Social.Objects.read(media.id)
      assert {:ok, _} = Bonfire.Social.Objects.read(media.id, current_user: recipient)
    end

    test "funkwhale audio object" do
      data =
        "../fixtures/funkwhale_create_audio.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, media} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert media.__struct__ == Bonfire.Files.Media

      assert media.path ==
               "https://funkwhale.local/api/v1/listen/3901e5d8-0445-49d5-9711-e096cf32e515/?upload=42342395-0208-4fee-a38d-259a6dae0871&download=false"

      assert media.media_type == "audio/ogg"

      assert {:ok, _} = Bonfire.Social.Objects.read(media.id)
    end

    test "update activity with media changes - add primary image, remove one attachment, add another" do
      # First, create original post based on pixelfed fixture with 2 attachments
      second_image = %{
        "type" => "Document",
        "mediaType" => "image/png",
        "url" => "https://example.com/image2.png",
        "name" => "Second image"
      }

      original_data =
        "../fixtures/pixelfed-image.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("attachment", [
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://example.com/image1.jpg",
            "name" => "First image"
          },
          second_image
        ])

      {:ok, original} = ActivityPub.Federator.Transformer.handle_incoming(original_data)

      assert {:ok, original_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(original)
               |> repo().maybe_preload([:post_content, :media])

      # Verify original post has 2 attachments
      assert length(original_post.media) == 2
      original_urls = original_post.media |> Enum.map(& &1.path) |> Enum.sort()
      assert "https://example.com/image1.jpg" in original_urls
      assert "https://example.com/image2.png" in original_urls

      # Now create Update activity that:
      # - Adds a primary image
      # - Removes image1.jpg 
      # - Keeps image2.png
      # - Adds a new image3.gif

      initial_primary_image = %{
        "type" => "Document",
        "mediaType" => "image/jpeg",
        "url" => "https://example.com/primary.jpg",
        "name" => "Primary image"
      }

      third_image = %{
        "type" => "Document",
        "mediaType" => "image/gif",
        "url" => "https://example.com/image3.gif",
        "name" => "Third image"
      }

      updated_object =
        original_data
        |> Map.put("content", "Updated post with different media")
        |> Map.put("image", initial_primary_image)
        |> Map.put("attachment", [
          # Remove first image
          # Keep second image
          second_image,
          # Add new image
          third_image
        ])

      update_data = %{
        "type" => "Update",
        "id" => "#{original_data["id"]}/update",
        "actor" => original_data["attributedTo"],
        "object" => updated_object
      }

      {:ok, update} = ActivityPub.Federator.Transformer.handle_incoming(update_data)

      assert {:ok, updated_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(update)
               |> repo().maybe_preload([:post_content, :media])

      # Verify content was updated
      assert updated_post.post_content.html_body =~ "Updated post with different media"

      # Verify updated post has 3 attachments total (primary + 2 attachments)
      assert length(updated_post.media) == 3

      updated_urls = updated_post.media |> Enum.map(& &1.path)

      # Should have primary image
      assert "https://example.com/primary.jpg" in updated_urls

      # Should keep image2.png
      assert "https://example.com/image2.png" in updated_urls

      # Should have new image3.gif
      assert "https://example.com/image3.gif" in updated_urls

      # Should NOT have image1.jpg (removed)
      refute "https://example.com/image1.jpg" in updated_urls

      # Check which image is marked as primary
      {primary_image, other_images} = Bonfire.Files.split_primary_image(updated_post.media)
      assert primary_image.path == "https://example.com/primary.jpg"
      assert length(other_images) == 2

      # Third step: Replace the primary image with a *new* one

      fourth_image = %{
        "type" => "Document",
        "mediaType" => "image/gif",
        "url" => "https://example.com/image4.gif",
        "name" => "Fourth image"
      }

      second_update_object =
        updated_object
        |> Map.put("content", "New update with new image as primary")
        # Move image2 to primary
        |> Map.put("image", fourth_image)
        # Keep existing attachments
        |> Map.put("attachment", [
          initial_primary_image,
          third_image
        ])

      second_update_data = %{
        "type" => "Update",
        "id" => "#{original_data["id"]}/update2",
        "actor" => original_data["attributedTo"],
        "object" => second_update_object
      }

      {:ok, second_update} = ActivityPub.Federator.Transformer.handle_incoming(second_update_data)

      assert {:ok, final_post} =
               Bonfire.Federate.ActivityPub.Incoming.receive_activity(second_update)
               |> repo().maybe_preload([:post_content, :media])

      # Verify content was updated again
      assert final_post.post_content.html_body =~ "New update with new image as primary"

      # Verify final post still has 3 attachments 
      assert length(final_post.media) == 3

      final_urls = final_post.media |> Enum.map(& &1.path)

      # Check which image is marked as primary in the final update
      {primary_image, final_other_images} = Bonfire.Files.split_primary_image(final_post.media)
      assert primary_image.path == "https://example.com/image4.gif"

      # Verify the other images are now attachments
      final_other_urls = final_other_images |> Enum.map(& &1.path)
      # old primary still there as a normal attachment
      assert "https://example.com/primary.jpg" in final_other_urls
      # Should keep image3.gif as attachment
      assert "https://example.com/image3.gif" in final_other_urls

      # FIXME: Final step: Make the *existing* second_image the primary image (move from attachment to primary)
      # third_update_object = 
      #   second_update_data
      #   |> Map.put("content", "Final update with image2 as primary")
      #   |> Map.put("image", second_image)  # Move image2 to primary
      #     # Keep existing attachments
      #   |> Map.put("attachment", [
      #     initial_primary_image, 
      #     third_image,
      #     fourth_image
      #   ])

      # third_update_data = %{
      #   "type" => "Update",
      #   "id" => "#{original_data["id"]}/update2",
      #   "actor" => original_data["attributedTo"],
      #   "object" => third_update_object
      # }

      # {:ok, third_update} = ActivityPub.Federator.Transformer.handle_incoming(third_update_data)

      # assert {:ok, final_post} =
      #          Bonfire.Federate.ActivityPub.Incoming.receive_activity(third_update)
      #          |> repo().maybe_preload([:post_content, :media])

      #          # Verify content was updated again
      # assert final_post.post_content.html_body =~ "Final update with image2 as primary"

      # # Verify final post still has 3 attachments 
      # assert length(final_post.media) == 3

      # final_urls = final_post.media |> Enum.map(&(&1.path)) 

      # # Check which image is marked as primary in the final update
      # {primary_image, final_other_images} = Bonfire.Files.split_primary_image(final_post.media)
      # assert primary_image.path == "https://example.com/image2.png"
      # assert length(final_other_images) == 2

      # # Verify the other images are now attachments
      # final_other_urls = final_other_images |> Enum.map(&(&1.path)) 
      # # old primary still there as a normal attachment
      # assert "https://example.com/primary.jpg" in final_other_urls
      # # Should keep other images as attachment
      # assert "https://example.com/image3.gif" in final_other_urls
      # assert "https://example.com/image4.gif" in final_other_urls
    end
  end
end
