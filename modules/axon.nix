{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.flakeModules ];

  flake.flakeModules.default =
    {
      config,
      inputs,
      lib,
      withSystem,
      ...
    }:
    {
      imports = [
        inputs.flake-parts.flakeModules.modules
        inputs.home-manager.flakeModules.home-manager
      ];

      options.axon =
        let
          moduleOption =
            description:
            lib.mkOption {
              type = lib.types.deferredModule;
              default = { };
              inherit description;
            };

          modulesSubmodule = lib.types.submodule {
            options = {
              darwin = moduleOption "nix-darwin module to apply to the host.";
              home = moduleOption "home-manager module to apply to the host.";
              nixos = moduleOption "NixOS module to apply to the host.";
            };
          };

          modulesOption =
            description:
            lib.mkOption {
              type = lib.types.listOf modulesSubmodule;
              default = [ ];
              inherit description;
            };

          userSubmodule = lib.types.submodule {
            options = {
              home = moduleOption "home-manager configuration for the user.";
              modules = modulesOption "Modules to apply to the user.";
            };
          };
        in
        {
          darwin = moduleOption "Global nix-darwin configurations.";
          home = moduleOption "Global home-manager configurations.";
          nixos = moduleOption "Global NixOS configurations.";

          homes = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  freeformType = lib.types.attrsOf lib.types.anything;

                  options = {
                    home = moduleOption "home-manager module to apply.";
                    modules = modulesOption "Modules to apply to the configuration.";

                    name = lib.mkOption {
                      type = lib.types.str;
                      default = name;
                      example = "jdoe";
                      description = "Name of the home configuration.";
                    };

                    system = lib.mkOption {
                      type = lib.types.enum lib.systems.flakeExposed;
                      example = "x86_64-linux";
                      description = "The system architecture of the host.";
                    };

                    tags = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      default = [ ];
                      example = [ "desktop" ];
                      description = "Tags of the home configuration.";
                    };
                  };
                }
              )
            );
            default = { };
            description = "Standalone home-manager configurations.";
          };

          hosts = lib.genAttrs [ "darwin" "nixos" ] (
            class:
            let
              className = if class == "darwin" then "nix-darwin" else "NixOS";
            in
            lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }:
                  {
                    freeformType = lib.types.attrsOf lib.types.anything;

                    options = {
                      ${class} = moduleOption "${className} configuration for the host.";
                      home = moduleOption "home-manager configuration for all users in the host.";
                      modules = modulesOption "Modules to apply to the host.";

                      name = lib.mkOption {
                        type = lib.types.str;
                        default = name;
                        example = "my-hostname";
                        description = "Name of the host.";
                      };

                      system = lib.mkOption {
                        type = lib.types.enum lib.systems.flakeExposed;
                        example = "x86_64-linux";
                        description = "The system architecture of the host.";
                      };

                      tags = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [ ];
                        example = [ "desktop" ];
                        description = "Tags of the host.";
                      };

                      users = lib.mkOption {
                        type = lib.types.attrsOf userSubmodule;
                        default = { };
                        description = "Per-user configurations for the host.";
                      };
                    };
                  }
                )
              );
              default = { };
              description = "Configurations for ${className} hosts.";
            }
          );

          users = lib.mkOption {
            type = lib.types.attrsOf userSubmodule;
            default = { };
            description = "Per-user global configurations.";
          };

          modules = lib.mkOption {
            type = lib.types.attrsOf modulesSubmodule;
            default = { };
            description = "Reusable modules that can be applied to hosts.";
          };

          perTag = lib.mkOption {
            type = lib.types.attrsOf modulesSubmodule;
            default = { };
            example = {
              desktop = {
                nixos.services.xserver.enable = true;
                home.programs.firefox.enable = true;
              };
            };
            description = "Modules to apply to hosts based on their tags.";
          };
        };

      config.flake =
        let
          cfg = config.axon;

          mkSystems =
            { builder, class }:
            lib.mapAttrs' (_: hostConfig: {
              inherit (hostConfig) name;

              value = withSystem hostConfig.system (
                { inputs', self', ... }:
                builder {
                  modules = [
                    inputs.home-manager."${class}Modules".home-manager
                    {
                      home-manager = {
                        extraSpecialArgs = { inherit hostConfig inputs' self'; };

                        users = builtins.mapAttrs (
                          userName: userConfig:
                          let
                            userGlobal = lib.optionalAttrs (cfg.users ? ${userName}) cfg.users.${userName};
                          in
                          {
                            imports = [
                              cfg.global.home
                            ]
                            ++ lib.optional (userGlobal ? home) userGlobal.home
                            ++ lib.optionals (userGlobal ? modules) (map (m: m.home) userGlobal.modules)
                            ++ [
                              hostConfig.home
                              userConfig.home
                            ]
                            ++ map (m: m.home) userConfig.modules
                            ++ lib.flatten (
                              map (tag: lib.optional (cfg.perTag ? ${tag}) cfg.perTag.${tag}.home) hostConfig.tags
                            );
                          }
                        ) hostConfig.users;
                      };

                      networking.hostName = lib.mkDefault hostConfig.name;
                      nixpkgs.hostPlatform = lib.mkDefault hostConfig.system;
                    }
                  ]
                  ++ [
                    cfg.global.${class}
                    hostConfig.${class}
                  ]
                  ++ map (m: m.${class}) hostConfig.modules
                  ++ lib.flatten (
                    map (tag: lib.optional (cfg.perTag ? ${tag}) cfg.perTag.${tag}.${class}) hostConfig.tags
                  );

                  specialArgs = { inherit hostConfig inputs' self'; };
                }
              );
            }) cfg.hosts.${class};
        in
        {
          darwinConfigurations = mkSystems {
            builder = inputs.nix-darwin.lib.darwinSystem;
            class = "darwin";
          };

          homeConfigurations = lib.mapAttrs' (_: homeConfig: {
            inherit (homeConfig) name;

            value = withSystem homeConfig.system (
              {
                inputs',
                pkgs,
                self',
                ...
              }:
              let
                userName = builtins.head (lib.splitString "@" homeConfig.name);
                userGlobal = lib.optionalAttrs (cfg.users ? ${userName}) cfg.users.${userName};
              in
              inputs.home-manager.lib.homeManagerConfiguration {
                extraSpecialArgs = { inherit homeConfig inputs' self'; };

                modules = [
                  cfg.global.home
                ]
                ++ lib.optional (userGlobal ? home) userGlobal.home
                ++ lib.optionals (userGlobal ? modules) (map (m: m.home) userGlobal.modules)
                ++ [ homeConfig.home ]
                ++ map (m: m.home) homeConfig.modules lib.flatten (
                  map (tag: lib.optional (cfg.perTag ? ${tag}) cfg.perTag.${tag}.home) homeConfig.tags
                );

                inherit pkgs;
              }
            );
          }) cfg.homes;

          modules = lib.genAttrs [ "darwin" "homeManager" "nixos" ] (
            name:
            builtins.mapAttrs (_: value: value.${if name == "homeManager" then "home" else name}) cfg.modules
          );

          nixosConfigurations = mkSystems {
            builder = inputs.nixpkgs.lib.nixosSystem;
            class = "nixos";
          };
        };
    };
}
