import Config

if config_env() == :test do
  # This is needed for `Jason` source code to be stored during the compilation
  config :legion, :extra_source_modules, [Jason]

  # Spans go to the exporter each test installs with
  # `:otel_simple_processor.set_exporter/2`; nothing leaves the VM.
  config :opentelemetry, traces_exporter: :none, span_processor: :simple
end
