let
  sources = import ./sources.nix;
  pkgs = import (fetchTarball {
    url = "https://github.com/nixos/nixpkgs/archive/${sources.nixpkgs.commit}.tar.gz";
    sha256 = "sha256-8fsyqeO+mJqvIzeO4xIpgJe/f7MTbbVTEC6RT6WSXNs=";
  }) { system = "x86_64-linux"; };

  inherit (pkgs) lib;

  buildFoo = import ./build-foo.nix;

  makePATH = packages: lib.concatStringsSep ":" (map (x: "${x}/bin") packages);

  loadModules = modules: lib.concatStringsSep "\n" (map (x: "modprobe \"${x}\"") modules);

  modules = {
    initrd = [
      "ahci"
      "sd_mod"
      "ext4"
      "vfat"
      "nls_cp437"
      "nls_iso8859-1"
    ];
    init = [
      "erofs"
      "overlay"
    ];
  };

  wrappers = {
    modprobe = pkgs.writeShellScriptBin "modprobe" ''
      export MODPROBE_OPTIONS='-d /run/foo-system/kernel-modules'
      ${pkgs.kmod}/bin/modprobe "$@"
    '';
  };

  etcHostname = pkgs.writeTextFile {
    name = "etc-hostname";
    text = ''
      foo
    '';
    destination = "/hostname";
  };

  etcNsswitchConf = pkgs.writeTextFile {
    name = "etc-nsswitch-conf";
    text = ''
      passwd:    files
      group:     files
      shadow:    files

      hosts:     files dns
      networks:  files

      ethers:    files
      services:  files
      protocols: files
      rpc:       files

      subuid:    files
      subgid:    files
    '';
    destination = "/nsswitch.conf";
  };

  etcOsRelease = pkgs.writeTextFile {
    name = "etc-os-release";
    text = ''
      ID=foo
      NAME=foo
      DEFAULT_HOSTNAME=foo
      PRETTY_NAME="foo ${config.version}"
      VENDOR_NAME=foo
      VERSION="${config.version}"
      VERSION_ID="${config.version}"
    '';
    destination = "/os-release";
  };

  etcProfile = pkgs.writeTextFile {
    name = "etc-profile";
    text = ''
      export PATH=/run/foo-system/sw/bin
      export PS1="\n\[\033[1;32m\]\w %\[\033[0m\] "
    '';
    destination = "/profile";
  };

  etc = pkgs.symlinkJoin {
    name = "etc";
    paths = [
      etcHostname
      etcNsswitchConf
      etcOsRelease
      etcProfile
    ];
  };

  etcErofs = pkgs.runCommand "etc-erofs" { nativeBuildInputs = [ pkgs.erofs-utils ]; } ''
    mkdir -p etc

    cp -r ${etc}/* etc/

    mkfs.erofs \
      -zlz4hc \
      $out \
      etc
  '';

  passwd = pkgs.writeText "etc-passwd" ''
    root:x:0:0:System administrator:/root:/run/foo-system/sw/bin/bash
    foo:x:1000:1000:Standard user:/home/foo:/run/foo-system/sw/bin/bash
    nobody:x:65534:65534:Unprivileged account (don't use!):/var/empty:/run/foo-system/sw/bin/nologin
  '';

  group = pkgs.writeText "etc-group" ''
    root:x:0:
    wheel:x:1:foo
    tty:x:3:
    shadow:x:318:
    foo:x:1000:
    nogroup:x:65534:
  '';

  # user: foo  ; password: foo
  # user: root ; password: root
  shadow = pkgs.writeText "etc-shadow-default" ''
    root:$6$miCeoFcigmVhZ0HR$5fM9is80q/wYAMs0TWrw6tmM3FoIIeL0eprPSL2wRd/apIEWd0K1jxCspRQVwbxOKC/ykHBDdWs0cSvwfwbgK1:1::::::
    foo:$6$G7hka6E6pPmHnhQH$QgY/sSCFzEnW17vmdG0kkJb4Eve/sh6lQg/K8OcsKFfWVaTWwdFjBExwFvhhfvvki1ZYUHJo7v.IFOFFNBHgJ.:1::::::
    nobody:!:1::::::
  '';

  # 1. reap zombies
  # 2. handle poweroff
  stub = pkgs.stdenv.mkDerivation {
    pname = "stub";
    version = "0";

    dontUnpack = true;

    src = pkgs.writeText "stub.c" ''
      #include <signal.h>
      #include <sys/reboot.h>
      #include <unistd.h>

      void term(int sig)
      {
          reboot(RB_POWER_OFF);
      }

      int main()
      {
          signal(SIGCHLD, SIG_IGN);
          signal(SIGTERM, term);

          for (;;)
              pause();
      }
    '';

    buildPhase = ''
      $CC $src -O2 -o stub
    '';

    installPhase = ''
      cp stub $out
    '';
  };

  config = {
    version = "0.0.1-a";
    toplevel.paths = [
      {
        source = pkgs.buildEnv {
          name = "software";
          paths = [

            pkgs.coreutils
            pkgs.util-linux
            pkgs.binutils
            pkgs.gnugrep
            pkgs.getent
            pkgs.shadow
            pkgs.which
            pkgs.bashInteractive
            pkgs.ncurses

            pkgs.fastfetch
            pkgs.tmux

            wrappers.modprobe

          ];
        };
        name = "sw";
      }
      {
        source = etcErofs;
        name = "etc";
      }
      {
        source = config.kernel.packages.kernel.modules;
        name = "kernel-modules";
      }
      {
        source = pkgs.writeTextFile {
          name = "activate";
          text = ''
            #!${lib.getExe pkgs.bash}

            set -euo pipefail

            export PATH="${
              makePATH [
                pkgs.coreutils
                pkgs.util-linux
                pkgs.gnugrep
                pkgs.hostname
                wrappers.modprobe
              ]
            }"

            # create and mount filesystems
            # if not already mounted
            mount_if_not_mounted() {
                src="$1"
                dst="$2"
                shift 2

                if ! grep -qs " $dst " /proc/self/mountinfo; then
                    mkdir -p "$dst"
                    mount "$@" "$src" "$dst"
                fi
            }

            # create and move mounts
            move_mount() {
                src="$1"
                dst="$2"

                if ! grep -qs " $dst " /proc/self/mountinfo; then
                    mkdir -p "$dst"
                    mount --move "$src" "$dst"
                else
                    mount --move --beneath "$src" "$dst"
                    umount --lazy --recursive "$dst"
                fi
            }

            echo activate: mounting basic filesystems

            # mount basic filesystems
            mount_if_not_mounted devtmpfs /dev -o 'nosuid,strictatime,mode=755,size=5%' -t devtmpfs
            mount_if_not_mounted devpts /dev/pts -o 'nosuid,noexec,mode=620,ptmxmode=0666,gid=3' -t devpts
            mount_if_not_mounted tmpfs /dev/shm -o 'nosuid,nodev,strictatime,mode=1777,size=50%' -t tmpfs
            mount_if_not_mounted proc /proc -o 'nosuid,noexec,nodev' -t proc
            mount_if_not_mounted tmpfs /run -o 'nosuid,nodev,strictatime,mode=755,size=25%' -t tmpfs
            mount_if_not_mounted sysfs /sys -o 'nosuid,noexec,nodev' -t sysfs
            mount_if_not_mounted tmpfs /tmp -o 'nosuid,noexec,nodev' -t tmpfs

            echo activate: linking system closure

            # link system closure
            ln -sfn "$closure" /run/foo-system

            echo activate: loading kernel modules

            ${loadModules modules.init}
            cat "${lib.getExe wrappers.modprobe}" > /proc/sys/kernel/modprobe

            echo activate: setting up etc

            # etc lowerdir
            # /run/etc.next/.lower should be free after the mount --move from last time
            mount_if_not_mounted /run/foo-system/etc /run/etc.next/.lower -t erofs

            # move lowerdir
            move_mount /run/etc.next/.lower /run/etc/.lower

            # we dont want to replace current upper changes
            mount_if_not_mounted tmpfs /run/etc/.rw -t tmpfs
            mkdir -p /run/etc/.rw/{upper,work}

            # final overlay
            # /run/etc.next/.overlay should be free after the mount --move from last time
            #
            # overlayfs will warn about using upperdir,workdir on two mounts
            # this is fine because previous overlay is unmounted shortly afterwards
            mount_if_not_mounted overlay /run/etc.next/.overlay -o lowerdir=/run/etc/.lower,upperdir=/run/etc/.rw/upper,workdir=/run/etc/.rw/work -t overlay

            # move overlay
            move_mount /run/etc.next/.overlay /etc

            echo activate: setting up users

            # shadow 
            if [ -f /secrets/shadow ]; then 
                cat /secrets/shadow > /etc/shadow
            else
                # use default shadow file if secret is not found
                cat ${shadow} > /etc/shadow 
            fi

            # users and groups
            cat ${passwd} > /etc/passwd
            cat ${group} > /etc/group

            # permissions and ownership
            chmod 644 /etc/passwd
            chmod 644 /etc/group
            chmod 640 /etc/shadow
            chown root:root /etc/passwd
            chown root:root /etc/group
            chown root:shadow /etc/shadow

            # create user homes
            mkdir -p /root
            chown root:root /root
            chmod 700 /root
            mkdir -p /home/foo
            chown foo:foo /home/foo
            chmod 700 /home/foo

            echo activate: setting up hostname

            # set system hostname
            hostname $(cat /etc/hostname)
          '';
          executable = true;
        };
        name = "activate";
      }
    ];
    kernel = {
      packages = pkgs.linuxPackages;
      params = [
        "console=ttyS0"
        "earlycon=uart8250,io,0x3f8,115200"
        "quiet"
        "loglevel=0"
      ];
    };
    initrd = {
      modules = modules.initrd;
      interpreter = "/bin/sh";
      packages = [ pkgs.busybox ];
      commands = ''
        printf '\033[0m\033[39;49m\033[H\033[2J'
        printf '\033[2J\033[H\033[0m\033[1;32m--initrd--\033[0m\n'

        echo initrd: mounting basic filesystems
        mkdir -p /proc /sys /dev
        mount -t proc proc /proc
        mount -t sysfs sysfs /sys
        mount -t devtmpfs devtmpfs /dev

        echo initrd: load kernel modules
        ${loadModules modules.initrd}

        echo initrd: finding real root
        find_label() {
          label="$1"

          for dev in /dev/*; do
              blkid "$dev" 2>/dev/null | grep -q "LABEL=\"$label\"" && {
                  echo "$dev"
                  return
              }
          done
        }
        boot=$(find_label FOO-ESP)
        root=$(find_label FOO-ROOT)

        echo initrd: mounting real root
        mkdir -p /root
        mount -t ext4 "$root" /root
        mkdir -p /root/boot
        mount -t vfat "$boot" /root/boot

        echo initrd: switching to real root
        exec switch_root /root "$BOOTED_CLOSURE/init"
      '';
    };
    init = {
      commands = ''
        #!${lib.getExe' pkgs.busybox "sh"}

        export PATH="${makePATH [ pkgs.busybox ]}"

        printf '\033[0m\033[1;32m--init--\033[0m\n'

        echo init: starting activation
        (
            # run activate with only $closure
            env -i closure="$BOOTED_CLOSURE" "$BOOTED_CLOSURE/activate"
        )

        echo init: starting getty
        setsid -c getty -l login 115200 ttyS0 &

        exec ${stub}
      '';
    };
  };
in
buildFoo { inherit config pkgs; }
