# The telemetry of the test machine exports to a sink on loopback instead of the
# central endpoint (the endpoint value is in ../secrets.yaml). The sink is a
# second collector that writes the logs and metrics it receives to files, one
# JSON document per line. ../checks/10-telemetry.py reads them.
{ lib, pkgs, ... }:
let
  sinkConfig = (pkgs.formats.yaml { }).generate "telemetry-sink.yaml" {
    receivers.otlp.protocols.grpc.endpoint = "127.0.0.1:4317";
    exporters = {
      "file/logs".path = "/var/lib/telemetry-sink/logs.json";
      "file/metrics".path = "/var/lib/telemetry-sink/metrics.json";
    };
    service = {
      telemetry.metrics.level = "none";
      pipelines = {
        logs = {
          receivers = [ "otlp" ];
          exporters = [ "file/logs" ];
        };
        metrics = {
          receivers = [ "otlp" ];
          exporters = [ "file/metrics" ];
        };
      };
    };
  };
in
{
  oruc.telemetry = {
    insecure = true;
    journalUnits = [ "telemetry-unit-probe.service" ];
  };

  systemd.services.telemetry-sink = {
    wantedBy = [ "multi-user.target" ];
    before = [ "opentelemetry-collector.service" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.opentelemetry-collector-contrib} --config=file:${sinkConfig}";
      DynamicUser = true;
      StateDirectory = "telemetry-sink";
    };
  };

  # A unit whose lines the journalUnits receiver ships, started by the check.
  systemd.services.telemetry-unit-probe.serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.coreutils}/bin/echo telemetry-unit-probe-line";
  };

  environment.systemPackages = [ pkgs.curl ];
}
