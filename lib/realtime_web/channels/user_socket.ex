defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket
  use Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.PostgresCdc
  alias Realtime.Tenants

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.RealtimeChannel.Logging
  ## Channels
  channel "realtime:*", RealtimeChannel

  @default_log_level :error

  @impl true
  def id(%{assigns: %{tenant: tenant}}), do: subscribers_id(tenant)

  @spec subscribers_id(String.t()) :: String.t()
  def subscribers_id(tenant), do: "user_socket:" <> tenant

  @impl true
  def connect(params, socket, opts) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = opts

      {:ok, external_id} = Database.get_external_id(host)
      Logger.metadata(external_id: external_id, project: external_id)
      Logger.put_process_level(self(), :error)

      token = access_token(params, headers)

      with %Tenant{
             jwt_secret: jwt_secret,
             jwt_jwks: jwt_jwks,
             postgres_cdc_default: postgres_cdc_default,
             suspend: false
           } = tenant <- Tenants.Cache.get_tenant_by_external_id(external_id),
           token when is_binary(token) <- token,
           jwt_secret_dec <- Crypto.decrypt!(jwt_secret),
           {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec, jwt_jwks),
           {:ok, postgres_cdc_module} <- PostgresCdc.driver(postgres_cdc_default) do
        %Tenant{
          extensions: extensions,
          max_concurrent_users: max_conn_users,
          max_events_per_second: max_events_per_second,
          max_bytes_per_second: max_bytes_per_second,
          max_joins_per_second: max_joins_per_second,
          max_channels_per_client: max_channels_per_client,
          postgres_cdc_default: postgres_cdc_default
        } = tenant

        assigns = %RealtimeChannel.Assigns{
          claims: claims,
          jwt_secret: jwt_secret,
          jwt_jwks: jwt_jwks,
          limits: %{
            max_concurrent_users: max_conn_users,
            max_events_per_second: max_events_per_second,
            max_bytes_per_second: max_bytes_per_second,
            max_joins_per_second: max_joins_per_second,
            max_channels_per_client: max_channels_per_client
          },
          postgres_extension: PostgresCdc.filter_settings(postgres_cdc_default, extensions),
          postgres_cdc_module: postgres_cdc_module,
          tenant: external_id,
          log_level: log_level(params),
          tenant_token: token,
          headers: opts.x_headers
        }

        assigns = Map.from_struct(assigns)

        {:ok, assign(socket, assigns)}
      else
        nil ->
          log_error("TenantNotFound", "Tenant not found: #{external_id}")
          {:error, :tenant_not_found}

        %Tenant{suspend: true} ->
          Logging.log_error_message(:error, "RealtimeDisabledForTenant", "Realtime disabled for this tenant")
          {:error, :tenant_suspended}

        {:error, :expired_token, msg} ->
          Logging.log_error_with_token_metadata("InvalidJWTToken", msg, token)
          {:error, :expired_token}

        {:error, :missing_claims} ->
          Logging.log_error_with_token_metadata("InvalidJWTToken", "Fields `role` and `exp` are required in JWT", token)
          {:error, :missing_claims}

        {:error, :token_malformed} ->
          log_error("MalformedJWT", "The token provided is not a valid JWT")
          {:error, :token_malformed}

        error ->
          log_error("ErrorConnectingToWebsocket", error)
          error
      end
    end
  end

  defp access_token(params, headers) do
    case :proplists.lookup("x-api-key", headers) do
      :none -> Map.get(params, "apikey")
      {"x-api-key", token} -> token
    end
  end

  defp log_level(params) do
    case Map.get(params, "log_level") do
      level when level in ["info", "warning", "error"] -> String.to_existing_atom(level)
      _ -> @default_log_level
    end
  end
end
