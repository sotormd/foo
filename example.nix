let
  sources = import ./sources.nix;

  pkgs = import (fetchTarball {
    url = "https://github.com/nixos/nixpkgs/archive/${sources.nixpkgs.commit}.tar.gz";
    sha256 = sources.nixpkgs.hash;
  }) { system = "x86_64-linux"; };

  sotormd-nixos-packages-list =
    (import
      "${
        (fetchTarball {
          url = "https://github.com/sotormd/nixos/archive/${sources.sotormd-nixos.commit}.tar.gz";
          sha256 = sources.sotormd-nixos.hash;
        })
      }/modules/core/packages/system.nix"
      {
        inherit pkgs;
        inherit (pkgs) lib;
      }
    ).environment.systemPackages;

  inherit (pkgs) lib;

  buildFoo = import ./build-foo.nix;

  config = {
    version = "0.0.1-a";
    toplevel.paths = [
      {
        source = software;
        name = "sw";
      }
      {
        source = etcErofs;
        name = "etc";
      }
      {
        source = activate;
        name = "activate";
      }
      {
        source = pkgs.makeModulesClosure {
          rootModules = modules.init;
          firmware = [ pkgs.emptyDirectory ];
          kernel = config.kernel.packages.kernel.modules;
        };
        name = "kernel-modules";
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
      commands = initrdCommands;
    };
    init = {
      commands = initCommands;
    };
  };

  makePATH = packages: lib.concatStringsSep ":" (map (x: "${x}/bin") packages);

  loadModules = modules: lib.concatStringsSep "\n" (map (x: "modprobe \"${x}\"") modules);

  sh = lib.getExe' pkgs.busybox "sh";

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

  initrdCommands = ''
    printf '\033[0m\033[39;49m\033[H\033[2J'
    printf '\033[2J\033[H\033[0m\033[1;32m--initrd--\033[0m\n'

    echo initrd: creating basic filesystems
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

  initCommands = ''
    #!${sh}

    export PATH="${makePATH [ pkgs.busybox ]}"

    printf '\033[0m\033[1;32m--init--\033[0m\n'

    echo init: starting activation
    env -i closure="$BOOTED_CLOSURE" "$BOOTED_CLOSURE/activate"
    ln -sfn "$BOOTED_CLOSURE" /run/booted-system

    echo init: starting nix-daemon
    mkdir -p /var/services/nix-daemon
    env -i ${nixDaemon} >/var/services/nix-daemon/stdout 2>/var/services/nix-daemon/stderr &

    echo init: starting getty
    mkdir -p /var/services/getty
    env -i  ${getty} >/var/services/getty/stdout 2>/var/services/getty/stderr &

    exec ${stub}
  '';

  activate = pkgs.writeScript "activate" ''
    #!${sh}

    umask 0022

    # we use features that busybox doesn't have
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

    echo activate: creating basic filesystems

    # mount basic filesystems
    mount_if_not_mounted devtmpfs /dev -o 'nosuid,strictatime,mode=755,size=5%' -t devtmpfs
    mount_if_not_mounted devpts /dev/pts -o 'nosuid,noexec,mode=620,ptmxmode=0666,gid=3' -t devpts
    mount_if_not_mounted tmpfs /dev/shm -o 'nosuid,nodev,strictatime,mode=1777,size=50%' -t tmpfs
    mount_if_not_mounted proc /proc -o 'nosuid,noexec,nodev' -t proc
    mount_if_not_mounted tmpfs /run -o 'nosuid,nodev,strictatime,mode=755,size=25%' -t tmpfs
    mount_if_not_mounted sysfs /sys -o 'nosuid,noexec,nodev' -t sysfs
    mount_if_not_mounted tmpfs /tmp -o 'nosuid,noexec,nodev' -t tmpfs

    # create basic filesystems
    mkdir -p /var/tmp /var/empty /var/services
    chmod 1777 /var/tmp
    chmod 755 /var/empty
    chmod 750 /var/services

    echo activate: linking system closure

    # link system closure
    ln -sfn "$closure" /run/current-system

    echo activate: loading kernel modules

    ${loadModules modules.init}
    cat "${lib.getExe wrappers.modprobe}" > /proc/sys/kernel/modprobe

    echo activate: setting up etc

    # etc lowerdir
    # /run/etc.next/.lower should be free after the mount --move from last time
    mount_if_not_mounted /run/current-system/etc /run/etc.next/.lower -t erofs

    # move lowerdir
    move_mount /run/etc.next/.lower /run/etc/.lower

    # we dont want to replace current upper changes
    mount_if_not_mounted tmpfs /run/etc/.rw -t tmpfs
    mkdir -p /run/etc/.rw/upper
    mkdir -p /run/etc/.rw/work

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

  software = pkgs.buildEnv {
    name = "software";
    paths = [

      nixPackage

      pkgs.fastfetch
      pkgs.tmux

      (lib.hiPrio wrappers.modprobe) # sotormd-nixos provides pkgs.kmod
      wrappers.poweroff

    ]
    ++ sotormd-nixos-packages-list;
  };

  wrappers = {
    modprobe = pkgs.writeScriptBin "modprobe" ''
      #!${sh}

      export MODPROBE_OPTIONS='-d /run/current-system/kernel-modules'
      ${pkgs.kmod}/bin/modprobe "$@"
    '';
    poweroff = pkgs.writeScriptBin "poweroff" ''
      #!${sh}

      ${pkgs.util-linux}/bin/kill -TERM 1
    '';
  };

  # nix package manager implementation
  nixPackage = pkgs.lix;

  # nix package manager configuration
  nixConf = pkgs.writeTextFile {
    name = "etc-nix-conf";
    text = ''
      accept-flake-config = false
      allow-import-from-derivation = false
      allowed-users = @wheel
      auto-optimise-store = true
      builders = 
      cores = 0
      experimental-features = nix-command flakes
      flake-registry = 
      max-jobs = auto
      require-sigs = true
      sandbox = true
      sandbox-fallback = false
      substituters = https://cache.nixos.org/
      system-features = nixos-test benchmark big-parallel kvm
      trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      trusted-substituters = 
      trusted-users = root
      use-xdg-base-directories = true
      warn-dirty = false
    '';
    destination = "/nix/nix.conf";
  };

  # nix daemon script
  nixDaemon = pkgs.writeScript "nix-daemon" ''
    #!${sh}

    export PATH="${
      makePATH [
        nixPackage
        pkgs.busybox
      ]
    }"

    # disk image creates /nix/.registration
    # we need to load the db using this
    if [ -f /nix/.registration ]; then
      nix-store --load-db < /nix/.registration && rm /nix/.registration
    fi

    # start the nix daemon
    exec nix-daemon

  '';

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
      export TERM=linux
      export PATH=/run/current-system/sw/bin
      export PS1="\n\[\033[1;32m\]\w %\[\033[0m\] "

      umask 0077
    '';
    destination = "/profile";
  };

  etc = pkgs.symlinkJoin {
    name = "etc";
    paths = [
      nixConf
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
    root:x:0:0:System administrator:/root:/run/current-system/sw/bin/bash
    foo:x:1000:1000:Standard user:/home/foo:/run/current-system/sw/bin/bash
    nobody:x:65534:65534:Unprivileged account (don't use!):/var/empty:/run/current-system/sw/bin/nologin
    nixbld1:x:30001:30000:Nix build user 1:/var/empty:/run/current-system/sw/bin/nologin
    nixbld2:x:30002:30000:Nix build user 2:/var/empty:/run/current-system/sw/bin/nologin
    nixbld3:x:30003:30000:Nix build user 3:/var/empty:/run/current-system/sw/bin/nologin
    nixbld4:x:30004:30000:Nix build user 4:/var/empty:/run/current-system/sw/bin/nologin
    nixbld5:x:30005:30000:Nix build user 5:/var/empty:/run/current-system/sw/bin/nologin
    nixbld6:x:30006:30000:Nix build user 6:/var/empty:/run/current-system/sw/bin/nologin
    nixbld7:x:30007:30000:Nix build user 7:/var/empty:/run/current-system/sw/bin/nologin
    nixbld8:x:30008:30000:Nix build user 8:/var/empty:/run/current-system/sw/bin/nologin
    nixbld9:x:30009:30000:Nix build user 9:/var/empty:/run/current-system/sw/bin/nologin
    nixbld10:x:30010:30000:Nix build user 10:/var/empty:/run/current-system/sw/bin/nologin
    nixbld11:x:30011:30000:Nix build user 11:/var/empty:/run/current-system/sw/bin/nologin
    nixbld12:x:30012:30000:Nix build user 12:/var/empty:/run/current-system/sw/bin/nologin
    nixbld13:x:30013:30000:Nix build user 13:/var/empty:/run/current-system/sw/bin/nologin
    nixbld14:x:30014:30000:Nix build user 14:/var/empty:/run/current-system/sw/bin/nologin
    nixbld15:x:30015:30000:Nix build user 15:/var/empty:/run/current-system/sw/bin/nologin
    nixbld16:x:30016:30000:Nix build user 16:/var/empty:/run/current-system/sw/bin/nologin
    nixbld17:x:30017:30000:Nix build user 17:/var/empty:/run/current-system/sw/bin/nologin
    nixbld18:x:30018:30000:Nix build user 18:/var/empty:/run/current-system/sw/bin/nologin
    nixbld19:x:30019:30000:Nix build user 19:/var/empty:/run/current-system/sw/bin/nologin
    nixbld20:x:30020:30000:Nix build user 20:/var/empty:/run/current-system/sw/bin/nologin
    nixbld21:x:30021:30000:Nix build user 21:/var/empty:/run/current-system/sw/bin/nologin
    nixbld22:x:30022:30000:Nix build user 22:/var/empty:/run/current-system/sw/bin/nologin
    nixbld23:x:30023:30000:Nix build user 23:/var/empty:/run/current-system/sw/bin/nologin
    nixbld24:x:30024:30000:Nix build user 24:/var/empty:/run/current-system/sw/bin/nologin
    nixbld25:x:30025:30000:Nix build user 25:/var/empty:/run/current-system/sw/bin/nologin
    nixbld26:x:30026:30000:Nix build user 26:/var/empty:/run/current-system/sw/bin/nologin
    nixbld27:x:30027:30000:Nix build user 27:/var/empty:/run/current-system/sw/bin/nologin
    nixbld28:x:30028:30000:Nix build user 28:/var/empty:/run/current-system/sw/bin/nologin
    nixbld29:x:30029:30000:Nix build user 29:/var/empty:/run/current-system/sw/bin/nologin
    nixbld30:x:30030:30000:Nix build user 30:/var/empty:/run/current-system/sw/bin/nologin
    nixbld31:x:30031:30000:Nix build user 31:/var/empty:/run/current-system/sw/bin/nologin
    nixbld32:x:30032:30000:Nix build user 32:/var/empty:/run/current-system/sw/bin/nologin
  '';

  group = pkgs.writeText "etc-group" ''
    root:x:0:
    wheel:x:1:foo
    tty:x:3:
    shadow:x:318:
    foo:x:1000:
    nogroup:x:65534:
    nixbld:x:30000:nixbld1,nixbld10,nixbld11,nixbld12,nixbld13,nixbld14,nixbld15,nixbld16,nixbld17,nixbld18,nixbld19,nixbld2,nixbld20,nixbld21,nixbld22,nixbld23,nixbld24,nixbld25,nixbld26,nixbld27,nixbld28,nixbld29,nixbld3,nixbld30,nixbld31,nixbld32,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8,nixbld9
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

  # getty for logins
  # using busybox getty and login because
  # the ones from util-linux and shadow use PAM
  # we dont use PAM
  getty = pkgs.writeScript "getty" ''
    #!${sh}

    export PATH="${makePATH [ pkgs.busybox ]}"

    while true; do
        setsid -c getty -l login 115200 ttyS0
    done
  '';

in
buildFoo { inherit config pkgs; }
