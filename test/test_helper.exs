Mimic.copy(ReqLLM)

Legion.Telemetry.attach_default_logger()

defmodule Legion.Test.Support.LegionAgentsMigration do
  use Ecto.Migration

  alias Legion.Store.Postgres.Migration

  @version 20_260_820_000_001

  def version, do: @version
  def up, do: Migration.up()
  def down, do: Migration.down()
end

# Shared connection and schema for the Legion.Store.Postgres database tests.
{:ok, _} =
  Legion.Test.Support.PostgresRepo.start_link(
    hostname: System.get_env("POSTGRES_HOST", "localhost"),
    port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
    username: System.get_env("POSTGRES_USER", "postgres"),
    password: System.get_env("POSTGRES_PASSWORD", "postgres"),
    database: System.get_env("POSTGRES_DB", "postgres"),
    log: false
  )

Ecto.Migrator.up(
  Legion.Test.Support.PostgresRepo,
  Legion.Test.Support.LegionAgentsMigration.version(),
  Legion.Test.Support.LegionAgentsMigration,
  log: false
)

ExUnit.start(exclude: [:integration])
