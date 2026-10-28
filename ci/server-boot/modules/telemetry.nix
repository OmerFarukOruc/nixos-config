# The telemetry of the test machine exports to a sink on loopback instead of the
# central endpoint. The sink is a
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
    endpoint = lib.mkForce "127.0.0.1:4317";
    insecure = true;
    journalUnits = [ "telemetry-unit-probe.service" ];
    journalUserUnits = [ "telemetry-user-probe.service" ];
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

  # A user unit of oruc, started by the check. The prefix of each line sets its
  # journal priority: 6 is info and ships, 7 is debug and does not.
  systemd.user.services.telemetry-user-probe.serviceConfig = {
    Type = "oneshot";
    ExecStart = [
      "${pkgs.coreutils}/bin/echo <6>telemetry-user-probe-info"
      "${pkgs.coreutils}/bin/echo <7>telemetry-user-probe-debug"
    ];
  };

  environment.systemPackages = [ pkgs.curl ];
}
