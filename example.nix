let
  sources = import ./sources.nix;

  pkgs = import (fetchTarball {
    url = "https://github.com/nixos/nixpkgs/archive/${sources.nixpkgs.commit}.tar.gz";
    sha256 = sources.nixpkgs.hash;
  }) { system = "x86_64-linux"; };

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
        "ipv6.disable=1"
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

  # create a PATH from nix packages
  makePATH = packages: lib.concatStringsSep ":" (map (x: "${x}/bin") packages);
  busyboxPATH = extra: "export PATH=\"${makePATH (extra ++ [ pkgs.busybox ])}\"";

  # load kernel modules using modprobe
  # should use wrapped modprobe from PATH
  loadModules = modules: lib.concatStringsSep "\n" (map (x: "modprobe \"${x}\"") modules);

  # sh for most scripts
  sh = lib.getExe' pkgs.busybox "sh";

  # kernel modules that we need
  # adding things here will add it to respective makeModulesClosure
  # and also import them using loadModules
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

      # required for /etc
      "erofs"
      "overlay"

      # required for networking
      "virtio"
      "virtio_net"
      "virtio_pci"
      "af_packet"

    ];
  };

  # commands to run in initrd
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

    # tmpfs rootfs
    mkdir -p /root
    mount -t tmpfs tmpfs /root

    # persistent disk
    mkdir -p /root/persist
    mount -t ext4 "$root" /root/persist

    # boot
    mkdir -p /root/boot
    mount -t vfat "$boot" /root/boot

    # nix store
    mkdir -p /root/nix
    mount -o bind /root/persist/nix /root/nix
    mount -o bind /root/nix/store /root/nix/store
    mount -o remount,ro,bind,nosuid,nodev /root/nix/store

    # home
    mkdir -p /root/persist/home
    mkdir -p /root/home
    mount -o bind,nosuid,nodev /root/persist/home /root/home

    # var
    mkdir -p /root/persist/var
    mkdir -p /root/var
    mount -o bind,nosuid,nodev /root/persist/var /root/var

    echo initrd: switching to real root
    exec switch_root /root "$BOOTED_CLOSURE/init"
  '';

  # commands to run as PID 1 (init)
  initCommands = ''
    #!${sh}

    ${busyboxPATH [ ]}

    printf '\033[0m\033[1;32m--init--\033[0m\n'

    if [ -z "$BOOTED_CLOSURE" ]; then
        echo init: initrd did not provide BOOTED_CLOSURE >&2
        exit 1
    fi

    if ! [ -d "$BOOTED_CLOSURE" ]; then
        echo init: unable to find BOOTED_CLOSURE "$BOOTED_CLOSURE" >&2
        exit 1
    fi

    echo init: starting activation

    env -i closure="$BOOTED_CLOSURE" "$BOOTED_CLOSURE/activate"
    ln -sfn "$BOOTED_CLOSURE" /run/booted-system
    unset BOOTED_CLOSURE

    echo init: starting networking
    env -i ${networking} >/dev/null 2>&1 &

    echo init: starting nix-daemon
    mkdir -p /var/services/nix-daemon
    env -i ${nixDaemon} >/var/services/nix-daemon/stdout 2>/var/services/nix-daemon/stderr &

    echo init: starting getty
    env -i  ${getty} >/dev/null 2>&1 &

    exec ${stub}
  '';

  # system generation activation
  # this should be possible to re-run during runtime
  # handles
  # 1. creating basic filesystems (idempotent)
  # 2. link system closure (atomic, idempotent)
  # 3. mounting erofs /etc (atomic, idempotent) while keeping runtime state
  # 4. creating passwd/group/shadow (idempotent)
  # 5. setting up hostname (idempotent)
  activate = pkgs.writeScript "activate" ''
    #!${sh}

    umask 0022

    # we use features that busybox doesn't have
    ${busyboxPATH [
      pkgs.util-linux # busybox mount/umount doesn't have --beneath/--recursive
      wrappers.modprobe # wrapped modprobe to look for modules in the right place
    ]}

    if [ "$(id -u)" -ne 0 ]; then
        echo "activate: must be run as root" >&2
        exit 1
    fi

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
    if [ -f /persist/secrets/shadow ]; then 
        cat /persist/secrets/shadow > /etc/shadow
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

  fooRebuild = pkgs.writeScriptBin "foo-rebuild" ''
    #!${sh}

    set -e

    ${busyboxPATH [ nixPackage ]}

    if [ "$(id -u)" -ne 0 ]; then
        echo "rebuild: must be run as root" >&2
        exit 1
    fi

    if [ -z "$FOO_CONFIG" ]; then
        echo "environment variable FOO_CONFIG unset" >&2
        exit 1
    fi

    if ! [ -f "$FOO_CONFIG" ]; then
        echo "unable to find FOO_CONFIG $FOO_CONFIG" >&2
        exit 1
    fi

    current=$(readlink /nix/var/nix/profiles/foo/system | awk -F- '{ print $2 }')
    echo rebuild: current generation "$current" is at "$(realpath /nix/var/nix/profiles/foo/system)"

    echo rebuild: building system closure
    closure=$(nix build -f "$FOO_CONFIG" build.toplevel --no-link --print-out-paths)

    echo rebuild: building uki
    uki=$(nix build -f "$FOO_CONFIG" build.uki --no-link --print-out-paths)

    echo rebuild: adding generation to profile
    nix-env --profile /nix/var/nix/profiles/foo/system --set "$closure"
    number=$(readlink /nix/var/nix/profiles/foo/system | awk -F- '{ print $2 }')

    echo rebuild: installing bootloader

    base=$(mktemp -d)
    cp "$uki" "$base/uki"
    mv "$base/uki" "/boot/EFI/Linux/foo-generation-$number.efi"

    cat > "/boot/loader/entries/foo-generation-$number.conf" <<EOF
    title   foo generation $number
    efi     /EFI/Linux/foo-generation-$number.efi
    EOF

    rm -rf "$base"

    echo rebuild: starting activation
    env -i closure="$closure" "$closure/activate"

    echo rebuild: new generation "$number" is at "$closure"
  '';

  # software to include in system closure
  # basically the same as nixos /run/current-system/sw
  software = pkgs.buildEnv {
    name = "software";
    paths = [

      nixPackage
      fooRebuild

      pkgs.git

      pkgs.fastfetch
      pkgs.tmux

      (lib.hiPrio wrappers.modprobe) # busybox provides modprobe
      wrappers.poweroff

      pkgs.busybox

    ];
  };

  # wrapped packages
  wrappers = {
    modprobe = pkgs.writeScriptBin "modprobe" ''
      #!${sh}

      export MODPROBE_OPTIONS='-d /run/current-system/kernel-modules'
      ${pkgs.kmod}/bin/modprobe "$@"
    '';
    poweroff = pkgs.writeScriptBin "poweroff" ''
      #!${sh}

      ${busyboxPATH [ ]}

      kill -TERM 1
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
      ssl-cert-file = /etc/ssl/certs/ca-bundle.crt
    '';
    destination = "/nix/nix.conf";
  };

  # nix daemon script
  nixDaemon = pkgs.writeScript "nix-daemon" ''
    #!${sh}

    ${busyboxPATH [ nixPackage ]}

    # load nix database
    # disk image creates /nix/.registration
    if [ -f /nix/.registration ]; then
        nix-store --load-db < /nix/.registration && rm /nix/.registration
    fi

    # system generations
    if ! [ -f /nix/var/nix/profiles/foo ]; then
        mkdir -p /nix/var/nix/profiles/foo
    fi
    nix-env --profile /nix/var/nix/profiles/foo/system --set "$(readlink /run/current-system)"

    # start the nix daemon
    exec unshare -m sh -c '
        mount -o remount,rw,bind,nosuid,nodev /nix/store
        exec nix-daemon
    '
  '';

  # networking script
  networking = pkgs.writeScript "networking" ''
    #!${sh}

    ${busyboxPATH [ ]}

    ip link set eth0 up
    udhcpc -i eth0
  '';

  # /etc/hostname hostname
  # this is loaded using hostname
  etcHostname = pkgs.writeTextFile {
    name = "etc-hostname";
    text = ''
      foo
    '';
    destination = "/hostname";
  };

  # nsswitch config
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

  # os-release!
  etcOsRelease = pkgs.writeTextFile {
    name = "etc-os-release";
    text = ''
      ID=foo
      NAME=foo
      PRETTY_NAME=foo
      VENDOR_NAME=foo
    '';
    destination = "/os-release";
  };

  # this is loaded when a user logs in
  # PATH can be set to just /run/current-system/sw/bin
  etcProfile = pkgs.writeTextFile {
    name = "etc-profile";
    text = ''
      export PATH=/run/current-system/sw/bin
      export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt

      export TERM=linux

      if [ "$USER" == "root" ]; then
          PROMPT_COLOR="1;31m"
          PROMPT_SYMBOL="#"
      else
          PROMPT_COLOR="1;32m"
          PROMPT_SYMBOL='%'
      fi

      PS1="\n\[\033[$PROMPT_COLOR\]\w $PROMPT_SYMBOL\[\033[0m\] "

      umask 0077
    '';
    destination = "/profile";
  };

  # ssl certs
  etcSsl = pkgs.runCommand "etc-ssl" { } ''
    ln -sf "${pkgs.cacert}/etc" $out
  '';

  # final etc tree
  etc = pkgs.symlinkJoin {
    name = "etc";
    paths = [
      nixConf
      etcHostname
      etcNsswitchConf
      etcOsRelease
      etcProfile
      etcSsl
    ];
  };

  # erofs etc image
  etcErofs = pkgs.runCommand "etc-erofs" { nativeBuildInputs = [ pkgs.erofs-utils ]; } ''
    mkdir -p etc

    cp -r ${etc}/* etc/

    mkfs.erofs \
      -zlz4hc \
      $out \
      etc
  '';

  # /etc/passwd
  # this is loaded separately
  passwd = pkgs.writeText "etc-passwd" ''
    root:x:0:0:System administrator:/root:/run/current-system/sw/bin/ash
    foo:x:1000:1000:Standard user:/home/foo:/run/current-system/sw/bin/ash
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

  # /etc/group
  # this is loaded separately
  group = pkgs.writeText "etc-group" ''
    root:x:0:
    wheel:x:1:foo
    tty:x:3:
    shadow:x:318:
    foo:x:1000:
    nogroup:x:65534:
    nixbld:x:30000:nixbld1,nixbld10,nixbld11,nixbld12,nixbld13,nixbld14,nixbld15,nixbld16,nixbld17,nixbld18,nixbld19,nixbld2,nixbld20,nixbld21,nixbld22,nixbld23,nixbld24,nixbld25,nixbld26,nixbld27,nixbld28,nixbld29,nixbld3,nixbld30,nixbld31,nixbld32,nixbld4,nixbld5,nixbld6,nixbld7,nixbld8,nixbld9
  '';

  # default /etc/shadow
  # this is loaded separately
  # this is used ONLY If /secrets/shadow doesn't exist
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

    ${busyboxPATH [ ]}

    while true; do
        setsid -c getty -l login 115200 ttyS0
    done
  '';

  # the foo build outputs
  foo = buildFoo { inherit config pkgs; };

  # dism image bootloader configuration
  loaderConf = pkgs.writeText "loader-conf" ''
    timeout 5
  '';

  # disk image bootloader entry
  loaderEntry = pkgs.writeText "foo-generation-1.conf" ''
    title   foo generation 1
    efi     /EFI/Linux/foo-generation-1.efi
  '';

  closure = pkgs.closureInfo {
    rootPaths = [ foo.build.toplevel ];
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
        CopyFiles=${foo.build.uki}:/EFI/Linux/foo-generation-1.efi
        CopyFiles=${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi:/EFI/BOOT/BOOTX64.EFI
        CopyFiles=${loaderConf}:/loader/loader.conf
        CopyFiles=${loaderEntry}:/loader/entries/foo-generation-1.conf
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
          --size=5G \
          --definitions=repart.d \
          $out
      '';
in
# our build outputs
lib.recursiveUpdate foo { build = { inherit diskImage; }; }
