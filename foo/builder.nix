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

  toplevel = pkgs.runCommand "foo-system-${config.version}" { } ''
    mkdir -p $out
    ln -s ${init} $out/init 
    ${lib.concatStringsSep "\n" (map (x: "ln -s ${x.source} $out/${x.name}") config.toplevel.paths)}
  '';

  loaderConf = pkgs.writeText "loader-conf" ''
    timeout 5
  '';

  loaderEntry = pkgs.writeText "foo.conf" ''
    title   foo
    efi     /EFI/Linux/foo-${config.version}.efi
  '';

  closure = pkgs.closureInfo {
    rootPaths = [ toplevel ];
  };

  diskImage =
    pkgs.runCommand "foo.raw"
      {
        nativeBuildInputs = [
          pkgs.systemd
          pkgs.fakeroot
          pkgs.dosfstools
          pkgs.e2fsprogs
          pkgs.mtools
        ];
      }
      ''
        mkdir -p repart.d

        cat > repart.d/00-esp.conf <<EOF
        [Partition]
        Type=esp
        Format=vfat
        SizeMinBytes=200M
        SizeMaxBytes=200M
        Label=FOO-ESP
        CopyFiles=${uki}:/EFI/Linux/foo-${config.version}.efi
        CopyFiles=${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi:/EFI/BOOT/BOOTX64.EFI
        CopyFiles=${loaderConf}:/loader/loader.conf
        CopyFiles=${loaderEntry}:/loader/entries/foo.conf
        EOF

        cat > repart.d/10-root.conf <<EOF
        [Partition]
        Type=root-x86-64
        Format=ext4
        Label=FOO-ROOT
        CopyFiles=${closure}/registration:/nix/.registration
        EOF

        for path in $(cat ${closure}/store-paths); do
          echo "CopyFiles=$path:/nix/store/''${path#/nix/store/}" >> repart.d/10-root.conf
        done

        fakeroot systemd-repart \
          --empty=create \
          --size=1G \
          --definitions=repart.d \
          $out
      '';

in
{
  inherit
    kernel
    initrd
    uki
    toplevel
    diskImage
    ;
}
