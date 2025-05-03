defmodule Bonfire.API.MastoCompatible.InstanceController do
  use Bonfire.UI.Common.Web, :controller
  use Bonfire.Common.Config

  defp main(base_uri) do
    app_name = Bonfire.Application.name() |> String.capitalize()
    # instance = Application.get_env(:activity_pub, :instance)
    base_url = Bonfire.Common.URIs.base_url(base_uri)

    %{
      "title" => Config.get([:ui, :theme, :instance_name], nil) || "An instance of #{app_name}",
      "domain" => Map.get(base_uri, :host),
      "short_description" => Config.get([:ui, :theme, :instance_tagline], nil),
      "description" => Config.get([:ui, :theme, :instance_description], nil),
      "email" => "no-reply@no-reply.net",

      # TODO
      "languages" => [
        "en"
      ],
      # TODO
      "rules" => [],
      "registrations" => !Bonfire.Me.Accounts.instance_is_invite_only?(),
      # TODO
      "invites_enabled" => false,
      # TODO
      "approval_required" => false,
      "uri" => base_url,
      "version" =>
        "2.7.2 (compatible; Akkoma 3.9.3; #{app_name} #{Bonfire.Application.version()})",
      "source_url" => Bonfire.Application.repository(),
      # non-standard
      "federating" => ActivityPub.Config.federating?(),
      "configuration" => %{
        "urls" =>
          %{
            # "streaming"=> "wss://#{base_url}"
          },
        "vapid" => %{
          "public_key" => nil
        },
        "accounts" => %{
          "max_featured_tags" => 10,
          "max_pinned_statuses" => 4
        },
        "statuses" => %{
          "max_characters" => 500_000,
          "max_media_attachments" => 20,
          "characters_reserved_per_url" => 3
        },
        "media_attachments" => %{
          #  TODO
          "supported_mime_types" => [
            "image/jpeg",
            "image/png",
            "image/gif",
            "image/heic",
            "image/heif",
            "image/webp",
            "video/webm",
            "video/mp4",
            "video/quicktime",
            "video/ogg",
            "audio/wave",
            "audio/wav",
            "audio/x-wav",
            "audio/x-pn-wave",
            "audio/vnd.wave",
            "audio/ogg",
            "audio/vorbis",
            "audio/mpeg",
            "audio/mp3",
            "audio/webm",
            "audio/flac",
            "audio/aac",
            "audio/m4a",
            "audio/x-m4a",
            "audio/mp4",
            "audio/3gpp",
            "video/x-ms-asf"
          ],
          "image_size_limit" => 10_485_760,
          "image_matrix_limit" => 16_777_216,
          "video_size_limit" => 41_943_040,
          "video_frame_rate_limit" => 60,
          "video_matrix_limit" => 2_304_000
        },
        "polls" => %{
          "max_options" => 100,
          "max_characters_per_option" => 50_000,
          "min_expiration" => 60,
          "max_expiration" => 31_536_000
        },
        "translation" => %{
          # TODO
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
end
