# GB10 hardware support, derived from graham33/nixos-dgx-spark's modules/dgx-spark.nix at
# c646a19 (MIT, see LICENSES/MIT-nixos-dgx-spark.txt). It keeps graham33's option names, so a
# host imports this module or graham33's, not both.
{ config
, lib
, pkgs
, ...
}:

with lib;

let
  cfg = config.hardware.dgx-spark;

  kernelSource = import ../../../kernel-configs/nvidia-kernel-source.nix;

  # NVIDIA's arm64 kernel comes in two Debian flavours: nvidia (4K pages,
  # what DGX OS ships on the Spark) and nvidia-64k (what it ships on
  # GB200/GB300).
  flavourSuffix = optionalString cfg.use64kKernel "-64k";

  dgxKernelConfig = import
    (
      ../../../kernel-configs + "/nvidia-dgx-spark-${kernelSource.nvidiaKernelVersion}${flavourSuffix}.nix"
    )
    { inherit lib; };

  # buildLinux directly rather than overriding nixpkgs' linux_7_0, which
  # throws now that kernel.org has marked 7.0 end-of-life. NVIDIA still
  # maintains its 7.0 branch, and src, version and config all come from here
  # anyway.
  nvidiaKernel = pkgs.linuxPackagesFor (
    # Scrub references to the `dev` output from the kernel image. Since
    # nixpkgs builds the kernel out of tree with the source unpacked into
    # `$dev/lib/modules/<version>/source`, kbuild passes compilers absolute
    # source paths. `-fmacro-prefix-map` remaps `__FILE__`, but GCC does not
    # apply any prefix map to the source locations it emits for UBSAN checks,
    # and NVIDIA's config enables UBSAN. Those strings land in the uncompressed
    # arm64 `Image`, making `out` reference `dev` while `dev` references `out`:
    # Nix rejects the cycle. Only UBSAN report file names are affected.
    #
    # The in-tree modules carry the same strings. They live in the separate
    # `modules` output, so there is no cycle, but every NixOS system would
    # pull the ~835 MB `dev` output into its closure. Those have to be
    # scrubbed before `modules_install`, which signs each module with
    # kmodigest: rewriting a signed module invalidates its signature. See
    # `keepModuleSignatures` for the other half.
    (pkgs.buildLinux {
      src = kernelSource.mkNvidiaKernelSource pkgs;
      version = "${kernelSource.nvidiaKernelVersion}-nvidia${flavourSuffix}";
      modDirVersion = kernelSource.nvidiaKernelVersion;
      # buildLinux takes no default patches; these are the ones nixpkgs applies
      # to its own kernels, pointing the kernel at NixOS's helper paths.
      kernelPatches = with pkgs.kernelPatches; [
        bridge_stp_helper
        request_key_helper
      ];
      extraMeta.branch = lib.versions.majorMinor kernelSource.nvidiaKernelVersion;

      ignoreConfigErrors = true;

      structuredExtraConfig =
        dgxKernelConfig
        // (with lib.kernel; {
          USB_STORAGE = yes;
          USB_UAS = yes;
          OVERLAY_FS = yes;

          UEVENT_HELPER = no;

          UBUNTU_HOST = no;

          # NVIDIA wants TCG_CRB=y and TCG_ARM_CRB_FFA=y. The baseline also ends
          # up with TCG_CRB=y, so the terse config omits it, but only because
          # IMA selects it later in the Kconfig walk: generate-config.pl first
          # answers TCG_CRB=m, then cannot answer y to TCG_ARM_CRB_FFA, which
          # depends on it. Answer TCG_CRB explicitly.
          TCG_CRB = yes;
        });
    }).overrideAttrs (old: keepModuleSignatures old // {
      preInstall = (old.preInstall or "") + ''
        find "$buildRoot" -name '*.ko' -print0 \
          | xargs -0 -r ${pkgs.removeReferencesTo}/bin/remove-references-to -t "$dev"
      '';
      postFixup = (old.postFixup or "") + ''
        find "$out" -type f -print0 \
          | xargs -0 -r ${pkgs.removeReferencesTo}/bin/remove-references-to -t "$dev"
      '';
    })
  );

  # `modules_install` strips each module and then signs it, appending a
  # kmodigest signature. stdenv's fixupPhase then strips `lib/` again, and
  # strip rewrites the ELF file and drops the appended signature, so every
  # module ends up unsigned. That would make lockdown or `module.sig_enforce`
  # reject them. Stock nixpkgs kernels escape this only because they compress
  # their modules (MODULE_COMPRESS_ALL), and strip skips compressed files;
  # NVIDIA's config leaves them uncompressed. The modules are already
  # stripped, so excluding them from the second pass loses nothing.
  keepModuleSignatures = old: {
    stripExclude = (old.stripExclude or [ ]) ++ [ "*.ko" ];
  };

  # Strip embedded references to the kernel `-dev` output from .ko files. The
  # nvidia kernel-modules build (nixpkgs PR #498612) declares
  # `allowedReferences = [ ]` on the module derivation, but the .ko files end
  # up with __FILE__-derived header paths in `.rodata.str1.8` that point into
  # the kernel-dev store path, so the closure check fails. Run
  # remove-references-to over the built modules to scrub them, before
  # `modules_install` signs them, for the same reason as the kernel's own
  # modules above.
  #
  # Every kernel leaves these strings behind, stock nixpkgs ones included.
  # nixpkgs' common config sets MODULE_COMPRESS_ALL with XZ, though, and
  # compression hides the store hashes from Nix's reference scanner. NVIDIA's
  # config picks zstd and leaves MODULE_COMPRESS_ALL off, so these modules
  # are installed uncompressed and the references become visible.
  scrubKernelDevRefs = drv:
    drv.overrideAttrs (old: keepModuleSignatures old // {
      preInstall = (old.preInstall or "") + ''
        find . -name '*.ko' -print0 \
          | xargs -0 -r ${pkgs.removeReferencesTo}/bin/remove-references-to \
              -t ${config.boot.kernelPackages.kernel.dev}
      '';
    });
in
{
  imports = [ ./connectx7.nix ];

  options.hardware.dgx-spark = {
    enable = mkEnableOption "DGX Spark hardware support";

    useNvidiaKernel = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to use the NVIDIA kernel instead of the standard NixOS kernel";
    };

    use64kKernel = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Build the NVIDIA kernel with 64K pages (NVIDIA's `nvidia-64k` flavour)
        instead of 4K. This can cut TLB pressure for large-memory GPU
        workloads.

        DGX OS ships the 4K flavour on the Spark and 64K only on GB200/GB300.
        kindling-spark-os runs Ubuntu's 64K build on GB10 boxes, but this
        NixOS build of it is untested there. 64K pages also disable 32-bit
        compatibility (no AArch32 binaries); the kernel refuses a swap area
        made under 4K pages, such as DGX OS's /swap.img, so give 64K its own
        swap file rather than re-making one DGX OS still uses; and prebuilt
        binaries that assume 4K pages, such as a bundled jemalloc built for
        4K or x86 emulators like FEX/box64, may fail. On kindling-spark-os's
        64K boxes a CUDA copy from a file-backed mmap hangs, so vLLM needs
        `--safetensors-load-strategy eager`. With 64K pages, transparent huge
        pages raised vm.min_free_kbytes to about 5% of RAM there, and
        services.kindling turns them off on this kernel.
      '';
    };

    cppcAutonomousMode = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable CPPC autonomous selection mode (`cppc_cpufreq.auto_sel_mode=1`).

        On the GB10, without autonomous CPPC the memory fabric never enters
        autonomous performance management, which cripples single-thread memory
        bandwidth (~3x lower) and llama.cpp prompt-processing (~4% lower) vs
        stock DGX OS. Stock DGX OS boots with autonomous mode enabled; the
        NVIDIA `-next` kernel ships the driver support but defaults it off, so
        it must be enabled explicitly.

        Requires the NVIDIA kernel (`useNvidiaKernel = true`), whose cppc_cpufreq
        driver carries the autonomous-mode series.
      '';
    };

    gpuClockCap = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 2300;
      description = ''
        Cap the GPU clock at this many MHz, with
        `nvidia-smi --lock-gpu-clocks=0,<cap>`, applied at boot by the
        `gpu-clock-cap` service. `null` (the default) leaves the clock alone;
        the GB10 boosts to about 3000 MHz.

        Under long sustained loads some Sparks overheat until the embedded
        controller cuts the power with no warning, below the kernel's own
        thermal trip. Owners report that a cap of 2200-2300 MHz stops it, and
        it costs less than it might seem: a heat-soaked GPU throttles to about
        that clock anyway. Locking the clock is the only lever there is, as
        the GB10 does not support power limits (`nvidia-smi -pl`).

        `systemctl stop gpu-clock-cap` lifts the cap until the next start or
        boot.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.use64kKernel -> cfg.useNvidiaKernel;
        message = "hardware.dgx-spark.use64kKernel requires hardware.dgx-spark.useNvidiaKernel.";
      }
      {
        # The system76-power daemon resets the Spark during boot on the NVIDIA
        # 7.0 kernel (#145). The COSMIC module enables it by default unless
        # power-profiles-daemon or tuned is enabled.
        assertion = cfg.useNvidiaKernel -> !config.hardware.system76.power-daemon.enable;
        message = ''
          hardware.system76.power-daemon breaks boot on the DGX Spark NVIDIA kernel
          (https://github.com/graham33/nixos-dgx-spark/issues/145). With COSMIC, set
          services.power-profiles-daemon.enable = true; otherwise set
          hardware.system76.power-daemon.enable = false.
        '';
      }
    ];

    boot.kernelPackages = if cfg.useNvidiaKernel then nvidiaKernel else pkgs.linuxPackages_latest;

    boot.kernelParams = [
      "console=tty1"
      # Module-autoload kill switches for rarely needed attack surface that
      # has recently produced local privilege escalations:
      #
      #   algif_aead  — CVE-2026-31431 "Copy Fail" (AF_ALG AEAD local privesc)
      #   esp4, esp6  — CVE-2026-43284 / CVE-2026-43500 "Dirty Frag"
      #   rxrpc       — CVE-2026-43284 / CVE-2026-43500 "Dirty Frag"
      #
      # The pinned NVIDIA kernel carries the fixes for all three, so this is
      # defence in depth against the next bug there. The cost is that IPsec
      # ESP and AF_RXRPC are unavailable.
      #
      # Each of these modules is requested by name from a kernel subsystem
      # (AF_ALG, xfrm_user, AF_RXRPC respectively), bypassing modprobe alias
      # blacklists. `module_blacklist=` is a kernel-level kill switch:
      # request_module() refuses to invoke modprobe at all, so this is
      # robust against both autoload (e.g. socket(AF_ALG)+bind("aead")) and
      # explicit `modprobe`. NB: `boot.blacklistedKernelModules` alone is
      # NOT sufficient — modprobe's `blacklist` directive only blocks
      # alias-based autoloads, and these kernel paths request the module
      # by name (after dash/underscore normalisation), bypassing it.
      # Requires a reboot to apply.
      "module_blacklist=algif_aead,esp4,esp6,rxrpc"

      # The remaining parameters mirror what DGX OS puts on the Spark's
      # command line, each shipped as its own nvidia-spark-* package in
      # NVIDIA's BaseOS apt repository.
      #
      # nvidia-spark-grub-pci: clamp every device to the lowest Max Payload
      # Size supported across the PCIe bus.
      "pci=pcie_bus_safe"
      # nvidia-spark-initcall-bl: keep the Tegra CBB (control backbone) error
      # driver, which binds to the GB10's fabrics over ACPI, from initialising.
      "initcall_blacklist=tegra234_cbb_init"
      # nvidia-spark-grub-kho: disable Kexec HandOver. NVIDIA's 7.0 config sets
      # KEXEC_HANDOVER_ENABLE_DEFAULT with CMA_SIZE_MBYTES=0, which leaves the
      # KHO scratch area as unaccounted MIGRATE_CMA memory; long-term pins
      # such as ibv_reg_mr then fail with ENOMEM under memory pressure,
      # breaking NCCL and RoCE.
      "kho=off"
    ] ++ lib.optional (cfg.useNvidiaKernel && cfg.cppcAutonomousMode) "cppc_cpufreq.auto_sel_mode=1";

    boot.blacklistedKernelModules = [
      "nouveau"
      "r8169"
      "coresight_etm4x"
    ];

    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia = {
      modesetting.enable = true;
      open = true;
      nvidiaPersistenced = true;
      nvidiaSettings = true;
      # Apply scrubKernelDevRefs to the .open / .mod kernel module variants —
      # bypass boot.kernelPackages.apply (which chains another `.extend` and
      # re-evaluates `nvidiaPackages` through the makeExtensible fixed point,
      # discarding any overrides we'd put on the kernel package set itself).
      #
      # `latest`, as in graham33's module: the driver's CUDA version must be at
      # least a container's toolkit version, or the driver cannot JIT its PTX
      # (minor version compatibility does not cover PTX JIT). graham33 runs it
      # on the Spark with this kernel. NVIDIA only supports its DGX OS driver
      # (R580) on the Spark, which kindling-spark-os's stacks pin.
      package =
        let
          driver = config.boot.kernelPackages.nvidiaPackages.latest;
        in
        driver
        // {
          open = scrubKernelDevRefs driver.open;
          mod = scrubKernelDevRefs driver.mod;
        };
    };

    hardware.enableRedistributableFirmware = true;

    # The NVIDIA driver and the hot-plug helper are unfree. Kindling's models run
    # in containers that bring their own CUDA, so unlike graham33's module this
    # one leaves nixpkgs' cudaSupport off: apart from the NVIDIA kernel and its
    # driver modules, the host's packages come from cache.nixos.org. A host that
    # builds CUDA software itself sets nixpkgs.config.cudaSupport and
    # cudaCapabilities = [ "12.0" "12.1" ].
    nixpkgs.config.allowUnfree = true;

    # No Podman and no NVIDIA container toolkit, unlike graham33's module: Kindling's models run
    # in NixOS containers (services.kindling.models), which share the host's store and driver.
    # A host that still runs recipes' OCI images sets virtualisation.podman.enable and
    # hardware.nvidia-container-toolkit.enable.

    # RDMA over the ConnectX ports needs to pin the memory it registers, and
    # the NixOS default memlock ceiling of 8 MB is far too low: ibv_reg_mr
    # fails and UCX floods the log with "Cannot allocate memory ... Please set
    # max locked memory (ulimit -l) to 'unlimited'", which then looks like a
    # network fault further up. Stock DGX OS sets a limit of roughly the whole
    # of RAM, so without this a Spark pair is asymmetric and multi-node runs
    # fail on the NixOS side only. Note the *hard* limit matters -- an
    # unprivileged `ulimit -l` cannot raise it.
    security.pam.loginLimits = [
      { domain = "*"; type = "soft"; item = "memlock"; value = "unlimited"; }
      { domain = "*"; type = "hard"; item = "memlock"; value = "unlimited"; }
    ];

    environment.systemPackages = with pkgs; [
      nvtopPackages.nvidia
      iperf3
      ethtool
      rdma-core
    ];

    # The clock lock lives in the driver's per-GPU state, which is lost if the
    # driver lets the GPU go: nvidia-persistenced keeps it initialised, and
    # partOf re-applies the lock whenever that restarts (e.g. on a driver
    # update).
    systemd.services.gpu-clock-cap = mkIf (cfg.gpuClockCap != null) (
      let
        nvidia-smi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
        persistenced = optional config.hardware.nvidia.nvidiaPersistenced "nvidia-persistenced.service";
      in
      {
        description = "Cap the GPU clock at ${toString cfg.gpuClockCap} MHz";
        wantedBy = [ "multi-user.target" ];
        after = persistenced;
        requires = persistenced;
        partOf = persistenced;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${nvidia-smi} --lock-gpu-clocks=0,${toString cfg.gpuClockCap}";
          ExecStop = "${nvidia-smi} --reset-gpu-clocks";
        };
      }
    );

    services.fwupd.enable = true;
  };
}
