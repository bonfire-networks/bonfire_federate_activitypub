defmodule Bonfire.API.MastoCompatible.InstanceAdapter do
  use Bonfire.Common.Config
  use Bonfire.Common.Localise

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
      "rules" => rules(),
      "registrations" => !Bonfire.Me.Accounts.instance_is_invite_only?(),
      "invites_enabled" => Bonfire.Me.Accounts.instance_is_invite_only?(),
      # TODO
      "approval_required" => false,
      "uri" => base_url,
      "version" =>
        "2.7.2 (compatible; Akkoma 3.9.3; #{app_name} #{Bonfire.Application.version()})",
      "source_url" => Bonfire.Application.repository(),
      # non-standard
      "federating" => !!ActivityPub.Config.federating?(),
      "configuration" => %{
        # nil when the endpoint has no streaming socket, so clients don't retry a 404
        "urls" => %{"streaming" => if(streaming_mounted?(), do: streaming_url(base_uri))},
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
          # the types built at boot from the tools found, as the uploaders accept them
          "supported_mime_types" => Config.get_ext(:bonfire_files, :all_allowed_media_types, []),
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

  def show(base_uri) do
    Map.merge(
      main(base_uri),
      %{
        "thumbnail" => icon_url(),
        "background_image" =>
          Bonfire.UI.Common.SEOImage.absolute_url(Config.get([:ui, :theme, :instance_image], nil)),
        "urls" => %{
          # always set: Ivory decodes it without a default
          "streaming_api" => streaming_url(base_uri)
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
  end

  def show_v2(base_uri) do
    main = main(base_uri)

    Map.merge(main, %{
      "thumbnail" => %{
        "url" => icon_url(),
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
  end

  @doc """
  The instance's community rules as Mastodon Rules, in the order /about shows them: numbered from 1, with the qualifier's label ("Not allowed") as the hint, or `""` for a rule without one (masto-instance-about decisions 1-3). Numbers change when an admin reorders the rules.
  """
  def rules do
    Bonfire.Common.Utils.maybe_apply(Bonfire.CommunityRules, :get_instance_rules_sections, [],
      fallback_return: []
    )
    |> Enum.flat_map(&(&1[:sections] || []))
    |> Enum.flat_map(&(&1[:rules] || []))
    |> Enum.with_index(1)
    |> Enum.map(fn {rule, position} ->
      %{
        "id" => to_string(position),
        "text" => rule[:name] || "",
        "hint" =>
          Bonfire.Common.Utils.maybe_apply(
            Bonfire.CommunityRules.Qualifier,
            :label,
            [rule[:qualifier]],
            fallback_return: ""
          )
      }
    end)
  end

  @doc """
  GET /api/v1/instance/extended_description: the code of conduct, rendered as /conduct renders it, or the same notice /conduct shows when the operators wrote none (masto-instance-about decision 4). Instance settings keep no timestamp, so `updated_at` is null.
  """
  def extended_description do
    conduct =
      case Config.get([:terms, :conduct]) do
        terms when terms in [nil, ""] ->
          l(
            "The instance operator(s) have not yet added a code of conduct. Please use your best judgment, and consult the [code of conduct of the Bonfire project](https://bonfirenetworks.org/conduct) as a reference."
          )

        terms ->
          terms
      end

    %{
      "updated_at" => nil,
      "content" =>
        conduct
        |> Bonfire.UI.Common.templated_or_remote_markdown()
        |> Phoenix.HTML.safe_to_string()
        # `rich/1` makes local links relative for LiveView navigation; an app needs them absolute
        |> Bonfire.Common.Text.prepare_links_for_remote_render(:html)
    }
  end

  @doc """
  Returns custom emojis available on this instance.
  GET /api/v1/custom_emojis
  """
  def custom_emojis() do
    # TODO: Implement actual emoji fetching from Bonfire.Files.EmojiUploader
    # For now, return empty array to indicate the endpoint exists but no custom emojis
    []
  end

  @doc "Whether the endpoint mounts the Mastodon streaming socket (fixed when the endpoint compiles)."
  def streaming_mounted? do
    endpoint = Bonfire.Common.Config.endpoint_module()

    Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :__sockets__, 0) and
      Enum.any?(
        endpoint.__sockets__(),
        &match?({_path, Bonfire.Notify.Web.MastoStreamingWebSocket, _opts}, &1)
      )
  end

  # Mastodon advertises the bare ws(s) origin; clients append /api/v1/streaming
  defp streaming_url(base_uri),
    do: base_uri |> Bonfire.Common.URIs.base_url() |> String.replace_prefix("http", "ws")

  # the spec wants a full URI; the theme config holds paths
  defp icon_url,
    do: Bonfire.UI.Common.SEOImage.absolute_url(Config.get([:ui, :theme, :instance_icon], nil))
end
