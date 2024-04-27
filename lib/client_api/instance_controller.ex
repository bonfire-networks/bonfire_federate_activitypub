defmodule Bonfire.API.MastoCompatible.InstanceController do
  use Bonfire.UI.Common.Web, :controller
  alias Bonfire.Common.Config

  def show(conn, _) do
    app_name = Bonfire.Application.name()
    instance = Application.get_env(:activity_pub, :instance)
    base_url = Bonfire.Common.URIs.base_url()

    json(conn, %{
      "title" => Config.get([:ui, :theme, :instance_name], nil) || "An instance of #{app_name}",
      "description" => Config.get([:ui, :theme, :instance_description], nil),
      "email" => "no-reply@no-reply.net",
      "thumbnail" => Config.get([:ui, :theme, :instance_icon], nil),
      "background_image" => Config.get([:ui, :theme, :instance_image], nil),
      "avatar_upload_limit" => 0,
      "background_upload_limit" => 0,
      "banner_upload_limit" => 0,
      "upload_limit" => 0,
      # TODO
      "languages" => [
        "en"
      ],
      "max_toot_chars" => 500_000,
      "poll_limits" => %{
        "max_expiration" => 31_536_000,
        "max_option_chars" => 500_000,
        "max_options" => 100,
        "min_expiration" => 0
      },
      "registrations" => !Bonfire.Me.Accounts.instance_is_invite_only?(),
      "stats" => %{
        "domain_count" => 1,
        # TODO
        "status_count" => 1,
        "user_count" => Bonfire.Me.Users.maybe_count()
      },
      "uri" => base_url,
      "urls" => %{
        # TODO
        "streaming_api" => "wss://#{base_url}"
      },
      "version" => "2.7.2 (compatible; #{app_name} #{Bonfire.Application.version()})",
      # non-standard
      "federating" => ActivityPub.Config.federating?(),
      # non-standard
      "app_repository" => Bonfire.Application.repository()
    })
  end
end
