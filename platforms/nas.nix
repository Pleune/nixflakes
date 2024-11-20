{
  pkgs,
  lib,
  config,
  private,
  ...
}:
{
  imports =
    let
      sriov-modules = builtins.fetchGit {
        url = "https://github.com/cyberus-technology/nixos-sriov";
        rev = "6bfcad7698afebbfead331826ee77f0b970603ed";
      };
    in
    [ "${sriov-modules}/sriov.nix" ];

  virtualisation.cyberus.intel-graphics-sriov.enable = lib.mkIf (config.specialisation != { }) true;
  specialisation = {
    no-intel-kernel.configuration = {
      virtualisation.cyberus.intel-graphics-sriov.enable = false;
    };
  };

  fileSystems = {
    "/" = {
      device = "rpool/nixos/root";
      fsType = "zfs";
    };

    "/nix" = {
      device = "rpool/nixos/nix";
      fsType = "zfs";
    };

    "/var" = {
      device = "rpool/nixos/var";
      fsType = "zfs";
    };

    "/home" = {
      device = "rpool/nixos/home";
      fsType = "zfs";
    };

    "/boot1" = {
      device = "/dev/disk/by-id/wwn-0x5000cca253d71f50-part1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/boot2" = {
      device = "/dev/disk/by-id/wwn-0x5000cca253f76ff9-part1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/boot3" = {
      device = "/dev/disk/by-id/wwn-0x5000cca270dfca44-part1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/boot4" = {
      device = "/dev/disk/by-id/wwn-0x5000cca270e00217-part1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/boot5" = {
      device = "/dev/disk/by-id/wwn-0x5000cca270f2d976-part1";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };

    "/scratch" = {
      device = "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_4TB_S6BCNG0R205730P-part1";
      fsType = "ext4";
    };
  };

  # scratch is ssd
  services.fstrim.enable = true;

  swapDevices = [
    {
      device = "/dev/disk/by-partuuid/97838506-80f6-471a-bf5f-dce949dfdd6e";
    }
  ];

  boot = {
    zfs.extraPools = [ "rpool" ];
    initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "thunderbolt"
      "nvme"
      "usbhid"
      "sd_mod"
    ];
    kernelModules = [ "kvm-intel" ];
    initrd.systemd.enable = true;

    loader.grub = {
      enable = true;
      efiInstallAsRemovable = true;
      efiSupport = true;
      zfsSupport = true;
      mirroredBoots = [
        {
          devices = [ "nodev" ];
          path = "/boot1";
        }
        {
          devices = [ "nodev" ];
          path = "/boot2";
        }
        {
          devices = [ "nodev" ];
          path = "/boot3";
        }
        {
          devices = [ "nodev" ];
          path = "/boot4";
        }
        {
          devices = [ "nodev" ];
          path = "/boot5";
        }
      ];
    };

    loader.efi.canTouchEfiVariables = false;

    supportedFilesystems = [ "zfs" "ext4" ];
    zfs.forceImportRoot = false;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  nixpkgs = {
    hostPlatform = lib.mkDefault "x86_64-linux";
    flake = {
      setFlakeRegistry = false;
      setNixPath = false;
    };
  };

  time.timeZone = "America/Detroit";
  i18n.defaultLocale = "en_US.UTF-8";

  security.rtkit.enable = true;

  services = {
    openssh.enable = true;
    grafana = {
      enable = true;
      settings.server = {
        http_addr = "0.0.0.0";
        http_port = 2342;
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://localhost:${toString config.services.prometheus.port}";
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}";
          }
        ];
      };
    };

    loki = {
      enable = true;
      configuration = {
        server.http_listen_port = 3030;
        server.http_listen_address = "::1";
        auth_enabled = false;

        ingester = {
          lifecycler = {
            address = "localhost";
            ring = {
              kvstore = {
                store = "inmemory";
              };
              replication_factor = 1;
            };
          };
          chunk_idle_period = "1h";
          max_chunk_age = "1h";
          chunk_target_size = 999999;
          chunk_retain_period = "30s";
        };

        schema_config = {
          configs = [
            {
              from = "2022-06-06";
              store = "boltdb-shipper";
              object_store = "filesystem";
              schema = "v11";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
        };

        storage_config = {
          boltdb_shipper = {
            active_index_directory = "/var/lib/loki/boltdb-shipper-active";
            cache_location = "/var/lib/loki/boltdb-shipper-cache";
            cache_ttl = "24h";
          };

          filesystem = {
            directory = "/var/lib/loki/chunks";
          };
        };

        limits_config = {
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
          allow_structured_metadata = false;
        };

        table_manager = {
          retention_deletes_enabled = false;
          retention_period = "0s";
        };

        compactor = {
          working_directory = "/var/lib/loki";
          compactor_ring = {
            kvstore = {
              store = "inmemory";
            };
          };
        };
      };
      # user, group, dataDir, extraFlags, (configFile)
    };

    prometheus = {
      enable = true;
      exporters = {
        node = {
          enable = true;
          port = 9100;
          enabledCollectors = [
            "logind"
            "systemd"
          ];
          disabledCollectors = [
            "textfile"
          ];
          openFirewall = true;
        };
        zfs = {
          enable = true;
          port = 9101;
          openFirewall = true;
        };
      };
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ];
            }
          ];
        }
        {
          job_name = "zfs";
          static_configs = [
            {
              targets = [ "localhost:${toString config.services.prometheus.exporters.zfs.port}" ];
            }
          ];
        }
      ];

    };
    promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 3031;
          grpc_listen_port = 0;
        };
        positions = {
          filename = "/tmp/positions.yaml";
        };
        clients = [
          {
            url = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
          }
        ];
        scrape_configs = [
          {
            job_name = "journal";
            journal = {
              max_age = "12h";
              labels = {
                job = "systemd-journal";
                host = config.networking.hostName;
              };
            };
            relabel_configs = [
              {
                source_labels = [ "__journal__systemd_unit" ];
                target_label = "unit";
              }
            ];
          }
        ];
      };
    };

    zfs = {
      autoScrub.enable = true;
    };
  };

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    softDaemonRestart = true;
    preseed = {
      config = {
        "core.https_address" = "0.0.0.0:8443";
        "loki.api.url" = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}";
      };
      profiles = [
        {
          name = "default";
          description = "bridged";
          devices = {
            eth0 = {
              name = "eth0";
              parent = "br0";
              type = "nic";
              nictype = "bridged";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
              size = "100GiB";
            };
          };
          config = {
            "limits.cpu" = 2;
            "limits.memory" = "1GiB";
          };
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "zfs";
          config = {
            source = "rpool/incus";
          };
        }
      ];
    };
  };
  systemd.services.incus.serviceConfig.TimeoutStopUSec = "1000s";

  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  systemd.network = {
    enable = true;

    netdevs = {
      "br0" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br0";
        };
      };
    };

    networks = {
      "enp58s0" = {
        matchConfig.Name = "enp58s0";
        networkConfig.Bridge = "br0";
        linkConfig.RequiredForOnline = "enslaved";
      };
      "br0" = {
        matchConfig.Name = "br0";
        networkConfig = {
          DHCP = "ipv4";
          IPv6AcceptRA = true;
        };
        linkConfig.RequiredForOnline = "carrier";
      };
    };
  };

  systemd.services.loki.after = [ "network-online.target" ];
  systemd.services.loki.wants = [ "network-online.target" ];

  system.stateVersion = lib.mkForce "24.11"; # Did you read the comment?

  networking = {
    useDHCP = false;
    hostId = "177ad6ac";
    nftables.enable = true;
    firewall.allowedTCPPorts = [
      8443 # Incus
      config.services.prometheus.port
      config.services.grafana.settings.server.http_port
    ];
    firewall.trustedInterfaces = [ "br0" ];
  };

  nixflakes.agenix.enable = true;
  age.secrets."rustic.toml".file = "${private.secrets}/nas_backup_rustic_config.age";
  age.secrets."rustic_warmup".file = "${private.secrets}/nas_backup_rustic_warmup.age";

  environment.systemPackages = with pkgs; [
    awscli2 # needed for rustic warmup
  ];

  systemd.services."incus-backup@" = {
    description = "Backup the incus system %I to s3";
    after = [
      "network-online.target"
      "incus.service"
    ];
    wants = [
      "network-online.target"
      "incus.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        let
          backup = pkgs.writeShellScript "backup-incus" ''
            if [[ -z "$1" ]]; then
              echo "No name supplied"
              exit 1
            fi
            echo "stopping if needed..."
            if ${config.virtualisation.incus.package}/bin/incus stop $1; then
              WAS_RUNNING=true
              echo "stopped."
            fi
            FNAME="$1.tar"
            FNAME_TMP="/tmp/incus-export-$(${pkgs.coreutils}/bin/date '+%Y-%m-%d_%H-%M-%S')-$FNAME"
            echo "exporting to $FNAME_TMP..."
            ${config.virtualisation.incus.package}/bin/incus export $1 "$FNAME_TMP" -v --compression none --instance-only
            if [ "$WAS_RUNNING" = "true" ]; then
              echo "starting..."
              ${config.virtualisation.incus.package}/bin/incus start $1
              echo "started."
            fi
            echo "backing up..."
            ${pkgs.rustic}/bin/rustic -P /run/agenix/rustic backup "$FNAME_TMP" --as-path "$FNAME" --tag "incus-export" --label "incus-export-$1"
            echo "cleaning up..."
            rm "$FNAME_TMP"
          '';
        in
        [
          "${backup} %I"
        ];
    };
  };

  # don't load user config
  nixflakes.home-manager.enable = false;
}
