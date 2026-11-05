defmodule Legion.Test.Support.SandboxRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :legion,
    adapter: Ecto.Adapters.Postgres
end
