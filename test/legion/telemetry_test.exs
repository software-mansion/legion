defmodule Legion.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  describe "handle_event/4" do
    test "logs warning for unknown events instead of crashing" do
      log =
        capture_log([level: :warning], fn ->
          Legion.Telemetry.handle_event(
            [:legion, :unknown, :event],
            %{},
            %{},
            level: :info
          )
        end)

      assert log =~ "unhandled event"
    end
  end
end
