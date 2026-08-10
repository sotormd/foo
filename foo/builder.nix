{ config, pkgs }:

let
  inherit (pkgs) lib;

  inherit (config.kernel.packages) kernel;

  initrdBin = pkgs.buildEnv {
    name = "initrd-bin";
    paths = config.initrd.packages;
  };

  initrdInit = pkgs.writeTextFile {
    name = "initrd-init";
    text = ''
      #!${config.initrd.interpreter}

      export BOOTED_CLOSURE=${toplevel}

      ${config.initrd.commands}
    '';
    executable = true;
  };

  initrdModules = pkgs.makeModulesClosure {
    rootModules = config.initrd.modules;
    firmware = [ pkgs.emptyDirectory ];
    kernel = kernel.modules;
  };

  initrd = pkgs.makeInitrdNG {
    contents = [
      {
        source = initrdBin + "/bin";
        target = "/bin";
      }
      {
        source = initrdInit;
        target = "/init";
      }
      {
        source = initrdModules + "/lib/modules";
        target = "/lib/modules";
      }
    ];
  };

  uki = pkgs.runCommand "uki" { nativeBuildInputs = [ pkgs.systemdUkify ]; } ''
    ukify build \
      --linux ${kernel}/${kernel.target} \
      --uname ${config.kernel.packages.kernel.version} \
      --initrd ${initrd}/initrd \
      --cmdline "${builtins.concatStringsSep " " config.kernel.params}"} \
      --os-release "" \
      --output $out
  '';

  init = pkgs.writeTextFile {
    name = "init";
    text = config.init.commands;
    executable = true;
  };

  toplevel = pkgs.runCommand "foo-system" { } ''
    mkdir -p $out
    ln -s ${init} $out/init 
    ${lib.concatStringsSep "\n" (map (x: "ln -s ${x.source} $out/${x.name}") config.toplevel.paths)}
  '';

in
{
  inherit
    kernel
    initrd
    uki
    toplevel
    ;
}
