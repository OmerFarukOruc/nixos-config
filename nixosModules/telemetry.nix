{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.telemetry;
  inherit (lib) mkOption types;

  stateDirectory = "/var/lib/opentelemetry-collector";
  journalctl = lib.getExe' pkgs.systemd "journalctl";

  resource =
    {
      service ? null,
      environment ? false,
    }:
    {
      attributes = [
        {
          key = "host.id";
          value = cfg.hostName;
          action = "upsert";
        }
        {
          key = "host.name";
          value = cfg.hostName;
          action = "insert";
        }
      ]
      ++ lib.optional environment {
        key = "deployment.environment.name";
        value = cfg.environment;
        action = "insert";
      }
      ++ lib.optional (service != null) {
        key = "service.name";
        value = service;
        action = "upsert";
      };
    };

  # Both journald receivers keep their cursor in the file store, so a restart
  # of the collector resumes without a gap or a repeat. `all` is needed
  # because journalctl returns a record over 4096 bytes as a null MESSAGE
  # without it.
  journald =
    extra:
    {
      journalctl_path = journalctl;
      all = true;
      storage = "file_storage/state";
      retry_on_failure = {
        enabled = true;
        max_elapsed_time = 0;
      };
    }
    // extra;

  exporter = maxElapsed: {
    inherit (cfg) endpoint;
    timeout = "5s";
    tls.insecure = cfg.insecure;
    retry_on_failure = {
      enabled = true;
      initial_interval = "5s";
      randomization_factor = 0.5;
      max_interval = "30s";
      max_elapsed_time = maxElapsed;
    };
    sending_queue = {
      enabled = true;
      storage = "file_storage/state";
      sizer = "bytes";
      queue_size = 268435456;
    };
  };

  userUnitMatches = lib.concatMap (unit: [
    { _SYSTEMD_USER_UNIT = unit; }
    { USER_UNIT = unit; }
  ]) cfg.journalUserUnits;

  unitReceivers =
    lib.optional (cfg.journalUnits != [ ]) "journald/units"
    ++ lib.optional (cfg.journalUserUnits != [ ]) "journald/user_units";

  agentProcessors = [
    "memory_limiter"
    "resource/agent"
    "resourcedetection"
    "batch"
  ];
in
{
  options.oruc.telemetry = {
    enable = lib.mkEnableOption "the collector and the audit daemon that report to the central OTLP endpoint";

    hostName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Value of host.name and host.id on every record.";
    };

    environment = mkOption {
      type = types.str;
      example = "development";
      description = "Value of deployment.environment.name on metrics and traces.";
    };

    endpoint = mkOption {
      type = types.str;
      example = "otlp.example.com:4317";
      description = "Host and port of the central OTLP gRPC endpoint.";
    };

    insecure = mkOption {
      type = types.bool;
      default = false;
      description = "Export without TLS. Only for an endpoint on loopback.";
    };

    localOtlpPort = mkOption {
      type = types.port;
      default = 4318;
      description = "Port of the OTLP HTTP receiver on 127.0.0.1, which host processes send to.";
    };

    filesystemMounts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "/tmp" ];
      description = ''
        Mount points that the collector reports even when they are virtual
        filesystems, such as a tmpfs. A path that is not a mount reports
        nothing.
      '';
    };

    journalUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "caddy.service" ];
      description = ''
        Units whose journal lines ship at priority info or above, from the end
        of the journal at the first start. Globs work. sshd and the audit
        records ship without this list.
      '';
    };

    journalUserUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "docker.service" ];
      description = ''
        User units, of any user, whose journal lines ship at priority info or
        above, from the end of the journal at the first start. A name is exact,
        and a glob matches nothing. The lines are the unit's own and the ones
        that the user's systemd writes about it, so a start limit that leaves
        the unit failed ships too. The lines carry `_SYSTEMD_USER_UNIT` or
        `USER_UNIT` and `_UID`.
      '';
    };

    unitsServiceName = mkOption {
      type = types.str;
      default = "infra-units";
      description = "Value of service.name on the lines of `journalUnits` and `journalUserUnits`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      settings = {
        extensions = {
          "file_storage/state" = {
            directory = stateDirectory;
            create_directory = true;
          };
          health_check.endpoint = "127.0.0.1:13133";
        };

        receivers = {
          "prometheus/collector".config.scrape_configs = [
            {
              job_name = "otel-agent";
              scrape_interval = "60s";
              static_configs = [ { targets = [ "127.0.0.1:8888" ]; } ];
            }
          ];
          "otlp/applications".protocols.http.endpoint = "127.0.0.1:${toString cfg.localOtlpPort}";
          hostmetrics = {
            collection_interval = "60s";
            scrapers = {
              cpu.metrics = {
                "system.cpu.logical.count".enabled = true;
                "system.cpu.utilization".enabled = true;
              };
              disk = { };
              filesystem.metrics."system.filesystem.utilization".enabled = true;
              load = { };
              memory.metrics."system.memory.utilization".enabled = true;
              network.exclude = {
                interfaces = [
                  "^veth"
                  "^br-"
                  "^docker"
                ];
                match_type = "regexp";
              };
              paging = { };
              processes = { };
              system = { };
            };
          };
          "hostmetrics/virtual_filesystems" = lib.mkIf (cfg.filesystemMounts != [ ]) {
            collection_interval = "60s";
            scrapers.filesystem = {
              include_virtual_filesystems = true;
              include_mount_points = {
                mount_points = cfg.filesystemMounts;
                match_type = "strict";
              };
              metrics."system.filesystem.utilization".enabled = true;
            };
          };
          "journald/audit" = journald {
            start_at = "beginning";
            priority = "debug";
            matches = [
              { _SYSTEMD_UNIT = "sshd.service"; }
              { SYSLOG_IDENTIFIER = "audisp-syslog"; }
            ];
          };
          "journald/units" = lib.mkIf (cfg.journalUnits != [ ]) (journald {
            start_at = "end";
            priority = "info";
            units = cfg.journalUnits;
          });
          "journald/user_units" = lib.mkIf (cfg.journalUserUnits != [ ]) (journald {
            start_at = "end";
            priority = "info";
            matches = userUnitMatches;
          });
        };

        processors = {
          memory_limiter = {
            check_interval = "1s";
            limit_mib = 384;
            spike_limit_mib = 64;
          };
          "filter/unread_metrics".metrics.exclude = {
            match_type = "regexp";
            metric_names = [
              "^otelcol_processor_batch_"
              "^otelcol_processor_(incoming|outgoing)_items"
              "^otelcol_scraper_"
              "^otelcol_process_(cpu|memory|runtime)_"
              "^otelcol_fileconsumer_"
              "^promhttp_metric_handler_errors"
              "^scrape_(series_added|duration_seconds|samples_scraped|samples_post_metric_relabeling)$"
            ];
          };
          "resource/agent" = resource { environment = true; };
          "resource/audit" = resource { service = "host-audit"; };
          "resource/units" = resource { service = cfg.unitsServiceName; };
          resourcedetection = {
            detectors = [
              "env"
              "system"
            ];
            override = false;
            timeout = "5s";
            system.hostname_sources = [ "os" ];
          };
          batch = {
            send_batch_size = 1024;
            timeout = "5s";
          };
          "batch/logs" = {
            send_batch_size = 256;
            timeout = "5s";
          };
        };

        exporters = {
          "otlp_grpc/central" = exporter "90m";
          "otlp_grpc/logs" = exporter 0;
        };

        service = {
          extensions = [
            "file_storage/state"
            "health_check"
          ];
          telemetry.metrics = {
            level = "normal";
            readers = [
              {
                pull.exporter.prometheus = {
                  host = "127.0.0.1";
                  port = 8888;
                  without_type_suffix = true;
                  without_units = true;
                };
              }
            ];
          };
          pipelines = {
            metrics = {
              receivers = [
                "prometheus/collector"
                "otlp/applications"
                "hostmetrics"
              ]
              ++ lib.optional (cfg.filesystemMounts != [ ]) "hostmetrics/virtual_filesystems";
              processors = [
                "memory_limiter"
                "filter/unread_metrics"
              ]
              ++ lib.tail agentProcessors;
              exporters = [ "otlp_grpc/central" ];
            };
            traces = {
              receivers = [ "otlp/applications" ];
              processors = agentProcessors;
              exporters = [ "otlp_grpc/central" ];
            };
            "logs/audit" = {
              receivers = [ "journald/audit" ];
              processors = [
                "memory_limiter"
                "resource/audit"
                "batch/logs"
              ];
              exporters = [ "otlp_grpc/logs" ];
            };
            "logs/units" = lib.mkIf (unitReceivers != [ ]) {
              receivers = unitReceivers;
              processors = [
                "memory_limiter"
                "resource/units"
                "batch/logs"
              ];
              exporters = [ "otlp_grpc/logs" ];
            };
          };
        };
      };
    };

    services.openssh.settings.LogLevel = "VERBOSE";

    systemd.sockets.systemd-journald-audit.wantedBy = lib.mkForce [ ];

    security.auditd = {
      enable = true;
      plugins.syslog.active = true;
    };

    security.audit = {
      backlogLimit = 8192;
      rules = lib.mkMerge [
        [
          "-a always,exit -F arch=b64 -F dir=/etc/systemd -F perm=wa -F key=unit-change"
          "-a always,exit -F arch=b64 -F path=/etc/sudoers -F perm=wa -F key=sudo-change"
          "-a always,exit -F arch=b64 -F dir=/etc/ssh -F perm=wa -F key=ssh-config"
          "-a always,exit -F arch=b64 -F dir=/etc/audit -F perm=wa -F key=audit-config"
          "-a always,exit -F arch=b64 -F path=/etc/passwd -F perm=wa -F key=identity"
          "-a always,exit -F arch=b64 -F path=/etc/shadow -F perm=wa -F key=identity"
          "-a always,exit -F arch=b64 -F path=/etc/group -F perm=wa -F key=identity"
          "-a always,exit -F arch=b64 -F dir=/etc -F perm=wa -F auid!=unset -F key=etc-change"
          "-a always,exit -F arch=b64 -F path=/run/wrappers/bin/sudo -F perm=x -F key=sudo-exec"
          "-a always,exit -F arch=b64 -F dir=/run/secrets.d -F perm=wa -F key=credstore"
          "-a always,exit -F arch=b64 -F dir=/run/secrets.d -F perm=r -F uid!=0 -F key=credstore"
        ]
        (lib.mkAfter [
          "-a always,exclude -F msgtype=NETFILTER_CFG -F auid=unset"
          "-a always,exclude -F msgtype=ANOM_PROMISCUOUS -F auid=unset"
          "-a always,exclude -F msgtype=BPF -F auid=unset"
        ])
      ];
    };

    systemd.services.audit-rules-nixos = {
      after = [ "suid-sgid-wrappers.service" ];
      restartTriggers = [ config.systemd.units."suid-sgid-wrappers.service".unit ];
    };
  };
}
