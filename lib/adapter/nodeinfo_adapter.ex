defmodule Bonfire.Federate.ActivityPub.NodeinfoAdapter do
  @behaviour Nodeinfo.Adapter
  alias Bonfire.Common.Config

  def base_url() do
    Bonfire.Common.URIs.base_url()
  end

  def user_count() do
    # FIXME
    1
  end

  def gather_nodeinfo_data() do
    instance = Application.get_env(:activity_pub, :instance)

    %Nodeinfo{
      app_name: Bonfire.Application.name() |> String.downcase(),
      app_version: Bonfire.Application.version(),
      open_registrations: Config.get([Bonfire.Me.Users, :public_registration]),
      user_count: user_count(),
      node_name: instance[:name],
      node_description: instance[:description],
      federating: instance[:federating],
      app_repository: Bonfire.Application.repository()
    }
  end
end
