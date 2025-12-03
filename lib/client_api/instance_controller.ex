defmodule Bonfire.API.MastoCompatible.InstanceController do
  use Bonfire.UI.Common.Web, :controller
  use Bonfire.Common.Config

  # Mastodon API instance configuration limits
  @max_featured_tags 1
  @max_pinned_statuses 1
  @max_status_chars 500_000
  @max_media_attachments 20
  @chars_reserved_per_url 3
  @image_matrix_limit 16_777_216
  @video_matrix_limit 2_304_000
  @video_frame_rate_limit 60
  @poll_max_options 100
  @poll_max_chars_per_option 50_000
  @poll_min_expiration 60
  @poll_max_expiration 31_536_000

  defp main(base_uri) do
    app_name = Bonfire.Application.name_and_flavour() |> String.capitalize()
    # instance = Application.get_env(:activity_pub, :instance)
    base_url = Bonfire.Common.URIs.base_url(base_uri)

    %{
      "title" => Config.get([:ui, :theme, :instance_name], nil) || "An instance of #{app_name}",
      "domain" => Map.get(base_uri, :host),
      "short_description" => Config.get([:ui, :theme, :instance_tagline], nil),
      "description" => Config.get([:ui, :theme, :instance_description], nil),
      "email" => "no-reply@no-reply.net",
      "languages" => Bonfire.Common.Localise.known_locales(),
      # TODO
      "rules" => [],
      "registrations" => !Bonfire.Me.Accounts.instance_is_invite_only?(),
      "invites_enabled" => Bonfire.Me.Accounts.instance_is_invite_only?(),
      # TODO
      "approval_required" => false,
      "uri" => base_url,
      "version" =>
        "2.7.2 (compatible; Akkoma 3.9.3; #{app_name} #{Bonfire.Application.version()})",
      "source_url" => Bonfire.Application.repository(),
      # non-standard
      "federating" => ActivityPub.Config.federating?() || false,
      "configuration" => %{
        "urls" =>
          %{
            # "streaming"=> "wss://#{base_url}"
          },
        "vapid" => %{
          # TODO
          "public_key" => nil
        },
        "accounts" => %{
          "max_featured_tags" => @max_featured_tags,
          "max_pinned_statuses" => @max_pinned_statuses
        },
        "statuses" => %{
          "max_characters" => @max_status_chars,
          "max_media_attachments" => @max_media_attachments,
          "characters_reserved_per_url" => @chars_reserved_per_url
        },
        "media_attachments" => %{
          "supported_mime_types" => Bonfire.Files.MimeTypes.supported_media() |> Map.keys(),
          "image_size_limit" => Bonfire.Files.ImageUploader.max_file_size(),
          "video_size_limit" => Bonfire.Files.VideoUploader.max_file_size(),
          "image_matrix_limit" => @image_matrix_limit,
          "video_matrix_limit" => @video_matrix_limit,
          "video_frame_rate_limit" => @video_frame_rate_limit
        },
        "polls" => %{
          "max_options" => @poll_max_options,
          "max_characters_per_option" => @poll_max_chars_per_option,
          "min_expiration" => @poll_min_expiration,
          "max_expiration" => @poll_max_expiration
        },
        "translation" => %{
          "enabled" => false
        }
      }
    }
  end

  def show(conn, _) do
    base_uri = Bonfire.Common.URIs.base_uri(conn)
    # base_url = Bonfire.Common.URIs.base_url(base_uri)

    json(
      conn,
      Map.merge(
        main(base_uri),
        %{
          "thumbnail" => Config.get([:ui, :theme, :instance_icon], nil),
          "background_image" => Config.get([:ui, :theme, :instance_image], nil),
          "urls" => %{
            # TODO
            # "wss://#{base_url}"
            "streaming_api" => nil
          },
          "poll_limits" => %{
            "max_expiration" => 31_536_000,
            "max_option_chars" => 50_000,
            "max_options" => 100,
            "min_expiration" => 60
          },
          "max_toot_chars" => 500_000,
          "avatar_upload_limit" => 0,
          "background_upload_limit" => 0,
          "banner_upload_limit" => 0,
          "upload_limit" => 0,
          "stats" => %{
            "domain_count" => 1,
            # TODO
            "status_count" => 1,
            "user_count" => Bonfire.Me.Users.maybe_count()
          }
        }
      )
    )
  end

  def show_v2(conn, _) do
    main = main(Bonfire.Common.URIs.base_uri(conn))

    json(
      conn,
      Map.merge(main, %{
        "thumbnail" => %{
          "url" => Config.get([:ui, :theme, :instance_icon], nil),
          # "blurhash"=> # TODO
          "versions" => %{}
        },
        "registrations" => %{
          "enabled" => main["registrations"],
          "approval_required" => false,
          "message" => nil
        },
        "contact" => %{
          "email" => main["email"],
          "account" => nil
        },
        "usage" => %{
          "users" => %{"active_month" => Bonfire.Me.Users.maybe_count()}
        }
      })
    )
  end

  @doc """
  Returns custom emojis available on this instance.
  GET /api/v1/custom_emojis
  """
  def custom_emojis(conn, _params) do
    # TODO: Implement actual emoji fetching from Bonfire.Files.EmojiUploader
    # For now, return empty array to indicate the endpoint exists but no custom emojis
    json(conn, [])
  end
end
