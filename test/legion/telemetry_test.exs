defmodule Legion.TelemetryTest do
  use ExUnit.Case

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

  describe "capture_context/0" do
    # Agents on nodes running an earlier Legion accept only requests without
    # a context, so none is sent when there is nothing to carry.
    test "is nil without an OpenTelemetry context" do
      assert Legion.Telemetry.capture_context() == nil
    end

    test "returns the current context when there is one" do
      ctx = OpenTelemetry.Ctx.set_value(%{}, :key, :value)
      token = OpenTelemetry.Ctx.attach(ctx)

      assert Legion.Telemetry.capture_context() == ctx

      OpenTelemetry.Ctx.detach(token)
    end
  end
end
