{
  commonLib,
  customConfig,
  cardanoConfig,
  nixTools
}:

let
  pkgs = commonLib.pkgs;
  connect = let
    walletConfigFile = ../custom-wallet-config.nix;
    walletConfig = if builtins.pathExists walletConfigFile then import walletConfigFile else {};
    in
      args: pkgs.callPackage ./launch/connect-to-cluster (args // {
        inherit cardanoConfig;
        inherit (nixTools.nix-tools.cexes.cardano-wallet) cardano-node;
        inherit (nixTools.nix-tools.cexes.cardano-sl-explorer) cardano-explorer;
        inherit (nixTools.nix-tools.cexes.cardano-sl-tools) cardano-x509-certificates;
      } // walletConfig);

  demoCluster = pkgs.callPackage ./launch/demo-cluster {
    inherit cardanoConfig;
    inherit (nixTools.nix-tools.cexes.cardano-sl-cluster) cardano-sl-cluster-demo cardano-sl-cluster-prepare-environment;
    inherit (nixTools.nix-tools.cexes.cardano-wallet) cardano-node;
  };
in {
  # connect function required for acceptanceTests
  inherit connect;
  connectScripts = commonLib.forEnvironments ({ environment, ... }:
  {
    wallet = connect { inherit environment; };
    explorer = connect { inherit environment; executable = "explorer"; };
    proposal-ui = pkgs.callPackage ./launch/proposal-ui {
      inherit cardanoConfig environment;
      inherit (nixTools.nix-tools.cexes.cardano-sl-script-runner) testcases;
    };

  });
  inherit demoCluster;
  demo-function = { disableClientAuth, numImportedWallets, runWallet, customConfigurationFile }: demoCluster.override {
    inherit disableClientAuth numImportedWallets runWallet customConfigurationFile;
  };
  dockerImages = let
    build = args: pkgs.callPackage ./docker.nix ({
      inherit cardanoConfig connect;
      inherit (nixTools.nix-tools.cexes.cardano-sl-node) cardano-node-simple;
    } // args);
    makeDockerImage = { environment, ...}:
      build { inherit environment; } // {
        wallet   = build { inherit environment; type = "wallet"; };
        explorer = build { inherit environment; type = "explorer"; };
        node     = build { inherit environment; type = "node"; };
      };
  in commonLib.forEnvironments makeDockerImage;
}
