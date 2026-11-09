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
  credentialsDirectory = "/run/credentials/opentelemetry-collector.service";
  watchCertificates = cfg.certificates != { };

  resource = {
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
      {
        key = "deployment.environment.name";
        value = cfg.environment;
        action = "insert";
      }
    ];
  };

  exporter = {
    inherit (cfg) endpoint;
    timeout = "5s";
    tls.insecure = cfg.insecure;
    retry_on_failure = {
      enabled = true;
      initial_interval = "5s";
      randomization_factor = 0.5;
      max_interval = "30s";
      max_elapsed_time = "90m";
    };
    sending_queue = {
      enabled = true;
      storage = "file_storage/state";
      sizer = "bytes";
      queue_size = 268435456;
    };
  };
in
{
  options.oruc.telemetry = {
    enable = lib.mkEnableOption "the collector that reports metrics to the central OTLP endpoint, and the audit daemon";

    hostName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Value of host.name and host.id on every record.";
    };

    environment = mkOption {
      type = types.str;
      example = "development";
      description = "Value of deployment.environment.name on metrics.";
    };

    endpoint = mkOption {
      type = types.str;
      example = "otlp.example.com:4317";
      description = "Host and port of the central OTLP gRPC endpoint.";
    };

    insecure = mkOption {
      type = types.bool;
      default = false;
      description = "Export without TLS. Only for an endpoint on loopback or inside a tailnet, where WireGuard encrypts the traffic.";
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

    certificates = mkOption {
      type = types.attrsOf types.path;
      default = { };
      example = {
        aws-agent = "/home/omer/.aws/rolesanywhere/leaf.pem";
      };
      description = ''
        PEM certificate files, by name, whose time to expiry the collector
        reports every hour as `tlscheck.time_left`. The collector reads a copy
        that systemd takes (`LoadCredential`). A missing file leaves an empty
        copy, so that receiver reports a scrape error while the other receivers
        run, and a change to a file reloads the copy without a restart.
      '';
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
          tls_check = lib.mkIf watchCertificates {
            collection_interval = "1h";
            targets = lib.mapAttrsToList (name: _: {
              file_path = "${credentialsDirectory}/${name}";
            }) cfg.certificates;
          };
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
          "resource/agent" = resource;
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
        };

        exporters = {
          "otlp_grpc/central" = exporter;
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
              ++ lib.optional (cfg.filesystemMounts != [ ]) "hostmetrics/virtual_filesystems"
              ++ lib.optional watchCertificates "tls_check";
              processors = [
                "memory_limiter"
                "filter/unread_metrics"
                "resource/agent"
                "resourcedetection"
                "batch"
              ];
              exporters = [ "otlp_grpc/central" ];
            };
          };
        };
      };
    };

    assertions = lib.mapAttrsToList (name: _: {
      assertion = builtins.match "[A-Za-z0-9_.-]+" name != null;
      message = "oruc.telemetry.certificates: the name ${name} must hold only letters, digits, '_', '.' and '-', because it becomes a credential name.";
    }) cfg.certificates;

    systemd.services.opentelemetry-collector.serviceConfig = lib.mkIf watchCertificates {
      SetCredential = map (name: "${name}:") (lib.attrNames cfg.certificates);
      LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.certificates;
      RefreshOnReload = "credentials";
    };

    systemd.paths.opentelemetry-collector-certificates = lib.mkIf watchCertificates {
      description = "Watch the certificates the collector reports";
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = lib.attrValues cfg.certificates;
    };

    systemd.services.opentelemetry-collector-certificates = lib.mkIf watchCertificates {
      description = "Reload the collector's copies of the changed certificates";
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe' config.systemd.package "systemctl"} try-reload-or-restart opentelemetry-collector.service";
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
        (lib.concatMap
          (
            rule:
            map (arch: "-a always,exit -F arch=${arch} ${rule}") [
              "b64"
              "b32"
            ]
          )
          [
            "-F dir=/etc/systemd -F perm=wa -F key=unit-change"
            "-F path=/etc/sudoers -F perm=wa -F key=sudo-change"
            "-F dir=/etc/ssh -F perm=wa -F key=ssh-config"
            "-F dir=/etc/audit -F perm=wa -F key=audit-config"
            "-F path=/etc/passwd -F perm=wa -F key=identity"
            "-F path=/etc/shadow -F perm=wa -F key=identity"
            "-F path=/etc/group -F perm=wa -F key=identity"
            "-F dir=/etc -F perm=wa -F auid!=unset -F key=etc-change"
            "-F path=${config.security.wrappers.sudo.source} -F perm=x -F key=sudo-exec"
            "-F dir=/run/secrets.d -F perm=wa -F key=credstore"
            "-F dir=/run/secrets.d -F perm=r -F uid!=0 -F key=credstore"
          ]
        )
        (lib.mkAfter [
          "-a always,exclude -F msgtype=NETFILTER_CFG -F auid=unset"
          "-a always,exclude -F msgtype=ANOM_PROMISCUOUS -F auid=unset"
          "-a always,exclude -F msgtype=BPF -F auid=unset"
        ])
      ];
    };
  };
}
