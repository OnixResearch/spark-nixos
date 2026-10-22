# spark-nixos

NixOS for NVIDIA GB10 hosts (DGX Spark, ASUS Ascent GX10) that run Kindling's cluster services.
It has two NixOS modules:

- `nixosModules.hardware`: the GB10 itself. NVIDIA's 7.0 kernel in 4 KiB and 64 KiB page builds,
  the NVIDIA driver, DGX OS's boot parameters, firmware updates through fwupd, ConnectX-7
  hot-plug, Podman with the NVIDIA container toolkit, and unlimited memlock for RDMA.
- `nixosModules.kindling`: Kindling's host services. mentatd, the spark agent and its
  diagnostics, port MTUs, and optionally the tty1 status screen, the hardware watchdog and
  dispram.

`nixosModules.default` imports both.

## Where it comes from

- [kindlingai/kindling-spark-os](https://github.com/kindlingai/kindling-spark-os) (AGPL-3.0) is a
  read-only Ubuntu root for GB10 boxes. The services module started as a NixOS port of its host
  services, on the `nixos-port` branch of
  [OnixResearch/kindling-spark-os](https://github.com/OnixResearch/kindling-spark-os), and this
  repository keeps that history. The scripts, the agent and dispram that the module runs are
  vendored from kindling-spark-os v0.9.8 in `vendor/kindling-spark-os`, with five small patches
  for NixOS in `patches/kindling-spark-os`.
- [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark) (MIT) runs NixOS on the
  Spark. The hardware module, the kernel configurations and the tools that generate them come
  from it, at c646a19. The hardware module keeps graham33's `hardware.dgx-spark` options.
- [straylight-software/nixos-dgx-spark](https://github.com/straylight-software/nixos-dgx-spark)
  (MIT) is a fork of graham33's from 2025-12-14. No files come from it, but the services module
  still works with it, and the VM test runs on its nixpkgs too.

See NOTICE for which files come from where, and under which licence.

## What has been tested

- The services module runs in two x86_64 VMs that form a cluster (`checks.<system>.vm`).
- A whole GB10 host, with the NVIDIA kernel and driver and every service, evaluates for the
  4 KiB and the 64 KiB kernel (`checks.<system>.hardware-eval`). The checks do not build the
  kernel.
- mentatd, the agent, py-spy and dispram build for aarch64.

Nothing here has run on a GB10 yet. dispram has not been validated on the NixOS driver, and no
firmware has been flashed from NixOS.

## Using it

Install NixOS on the box first, with
[graham33's USB image](https://github.com/graham33/nixos-dgx-spark#usb-boot-image). A Spark
on its factory firmware boots only DGX OS, so update the firmware from DGX OS before that, and
turn Secure Boot off to boot the installer. Keep the host's `hardware-configuration.nix`, boot
loader settings, users and `system.stateVersion`, and add spark-nixos to the host's flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    spark-nixos.url = "github:OnixResearch/spark-nixos";
    spark-nixos.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, spark-nixos, ... }: {
    nixosConfigurations.spark = nixpkgs.lib.nixosSystem {
      modules = [
        spark-nixos.nixosModules.default
        ./configuration.nix # the host's own configuration and hardware-configuration.nix
        {
          nixpkgs.hostPlatform = "aarch64-linux";
          hardware.dgx-spark.enable = true;
          services.kindling.enable = true;
          # services.kindling.connectxMtu = 4096; # only if the switches take MTU 4200
          # services.kindling.console.enable = true; # takes over tty1
        }
      ];
    };
  };
}
```

cache.nixos.org does not hold this NVIDIA kernel, so unless another cache has the same
derivation, the first build compiles it on the box. The hardware module leaves nixpkgs'
`cudaSupport` off, unlike graham33's: Kindling's models run in containers that bring their own
CUDA, and the host's other packages come from cache.nixos.org.

To keep graham33's or straylight-software's hardware module, import
`spark-nixos.nixosModules.kindling` with it instead of `nixosModules.default`. Never import two
hardware modules: they declare the same options. straylight-software's `main` has NVIDIA's 6.17
kernel and the 580.95.05 driver, and builds the kernel from `pkgs.linux_6_17`, which nixpkgs has
since removed. A host on it needs a nixpkgs from before then, such as
`github:NixOS/nixpkgs/45d3c39fc013ef15db3cf308a21fbd4b2d69a73d`. It does not enable fwupd.

Build the new generation with `sudo nixos-rebuild build --flake .#spark`, and after review
`sudo nixos-rebuild boot --flake .#spark`. Rolling back uses the boot menu's earlier
generations. After boot, check `systemctl status mentatd spark-agent spark-dmesg-snapshot.timer`,
`curl http://127.0.0.1:6380/status`, `curl http://127.0.0.1:8090/`, `nvidia-smi`, and the model
containers.

## The cluster

Put the cluster key outside the Nix store, in `/etc/spark/mentat.key` (mode 0400), and set
`MENTAT_SECRET_FILE=/etc/spark/mentat.key` in `/etc/spark/node.env`. Every node in a cluster
needs the same key. mentatd does not start without `/etc/spark/node.env`. An optional
`/etc/spark/agent.env` takes `MENTAT_ROUTER_URL` and `ALLOWED_SOURCES`.

The snapshot and the status screen list containers with the Docker CLI: on Docker's socket, or
on Podman's (`/run/podman/podman.sock`) when the host runs Podman and not Docker. The hardware
module runs Podman. Run one of the two, not both.

mentatd finds its peers by broadcast, and it announces only on interfaces that have a broadcast
address. NixOS's scripted networking adds static addresses
(`networking.interfaces.<name>.ipv4.addresses`) without one, so a box set up that way announces
nothing and never meshes. systemd-networkd (`networking.useNetworkd = true`) adds them with one,
and `ip -4 addr` shows it as `brd`. Without one, list the other boxes in `node.env`, as
`MENTAT_PEERS=192.168.1.12:6379,192.168.1.13:6379`.

mentatd announces every IPv4 interface that is up, except `docker*`, `veth*`, `br-*` and
`virbr*`. An address that every box has, such as Podman's `podman0` (10.88.0.1 by default) or a
VM's QEMU user network (10.0.2.15), then looks to the router like a way to reach any box, and can
lead it back to itself: in the VM test, the router ran spark2's agent tools on spark1. Name the
cluster's interfaces in `node.env` instead, as the VM test does with
`MENTAT_ANNOUNCE_IFACES=eno1,enp1s0f0np0`.

`services.kindling.connectxMtu` and `ethernetMtu` give each `en*` port its MTU when the port
appears, at boot or later, as a ConnectX port does when its cable goes in. On NetworkManager
hosts, the dispatcher sets it again whenever a profile comes up, and also kicks mentatd's health
check after a network change. Without NetworkManager, mentatd's own restart backoff, 2 to 60
seconds, stands in for that check.

NixOS's firewall is on, and closed to the cluster by default.
`services.kindling.openFirewall = true` opens what mentatd and the agent listen on, TCP 6379,
6380 and 8090 and UDP 6382, on **all** interfaces. A cluster needs more than that:

- The router must reach each model's announced endpoints, `MENTAT_OPENAI_API` and
  `MENTAT_MCP_API` (8000 and 9000 in mentat's examples). The recipe picks those ports.
- A model group that spans boxes runs NCCL's bootstrap, torch.distributed's rendezvous and
  vLLM's MessageQueue between them, on TCP ports picked at start. They use the boxes' fabric
  addresses when mentat placed the group on a fabric, and their LAN addresses otherwise.

So trust the links that carry that traffic and reach nothing but the cluster, such as the
ConnectX ports, and open the endpoint ports. `ip -br link` lists the ports. One cabled QSFP port
shows as two interfaces, and NCCL uses both:

```nix
networking.firewall.trustedInterfaces = [ "enp1s0f0np0" "enP2p1s0f0np0" ];
networking.firewall.allowedTCPPorts = [ 8000 9000 ]; # the recipes' endpoint ports
services.kindling.openFirewall = true;
```

A trusted interface accepts every port, so never trust one that reaches past the cluster. A
group that spans boxes over the LAN needs the LAN trusted too, which is only safe on a LAN that
holds nothing but the cluster. The agent serves host information without a login to the source
subnets it allows, so never expose port 8090 to the Internet.

`nixos-rebuild switch` leaves mentatd and the tty1 status screen running as they were.
Restarting mentatd on the box that heads a model group kills that group, and restarting the
status screen hangs up whoever logged in on tty1. A new mentatd takes over at the next boot, or
at a `systemctl restart mentatd` run when no model group would mind.

The hardware watchdog is off unless `services.kindling.watchdog.enable = true`. It can reset a
host when process creation fails. Turning it on turns systemd's runtime watchdog off, so only
one process owns `/dev/watchdog`.

## The driver

The hardware module runs nixpkgs' latest NVIDIA driver (615.78.08 at this flake's lock), as
graham33's does. NVIDIA supports only its DGX OS driver, R580, on the Spark, and
kindling-spark-os runs 580.178.04. R615 manages the GPU's memory itself by default (CDMM), and
graham33 found that a copy from memory-mapped safetensors to the GPU then runs at about 5 MB/s:
vLLM looks stuck at `Loading safetensors checkpoint shards: 0%`. So a recipe on a NixOS host
needs `--safetensors-load-strategy eager`, as it does on kindling-spark-os's 64k boxes.
[graham33's README](https://github.com/graham33/nixos-dgx-spark#nvidia-driver-memory-mode-cdmm)
shows how to put the driver back in NUMA mode, which is faster but still slow at that copy.

## The 64 KiB kernel

`hardware.dgx-spark.use64kKernel = true` builds NVIDIA's 64 KiB page kernel. The services module
then turns transparent huge pages off, as kindling-spark-os's 64k image does: with THP on,
`vm.min_free_kbytes` rose to about 5% of RAM. The kernel refuses a swap area made under 4 KiB
pages, so give it a swap file of its own. On 64k, a CUDA copy from a file-backed mmap hangs, so
vLLM needs `--safetensors-load-strategy eager`. See also NVIDIA's
[open-gpu-kernel-modules#1269](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1269)
on GPU faults with large allocations on 64 KiB pages.

## dispram

dispram lends the GB10's unused display carveout to CUDA. It is **off**: it depends on the
driver's resource-manager internals, and kindling-spark-os validated it on 580.178.04 only,
while the hardware module runs nixpkgs' latest driver. Only after validating the exact NixOS
driver and carveout on a box, pin the matching NVIDIA `open-gpu-kernel-modules` tree and turn it
on. For kindling-spark-os's validated driver **only**, that means adding
`ogkm = { url = "github:NVIDIA/open-gpu-kernel-modules/c8e699821c23e4335bf23330a54a23d15cfb95e9"; flake = false; };`
to the host flake's inputs, and:

```nix
services.kindling.dispram = {
  enable = true;
  validatedDriver = "580.178.04";
  ogkmVersion = "580.178.04";
  ogkmSource = ogkm.outPath;
};
```

Change **both** versions and the source together. The build fails unless the source's
`version.mk` names `ogkmVersion`, and the daemon checks `/proc/driver/nvidia/version` at runtime
and exits without lending on a mismatch. With `services.kindling.enable`, the module links the
client plugin at `/opt/kindling/dispram/python` and creates `/run/dispram`, the paths recipes
mount (see `vendor/kindling-spark-os/dispram/README.md`), so a recipe starts whether or not
dispramd runs. Without dispramd the plugin stands aside.

## Firmware updates

NVIDIA publishes the Spark's firmware to [LVFS](https://fwupd.org/) as UEFI capsules: the SoC
firmware (UEFI and GPU initialisation), the embedded controller, the USB-C power delivery
controller and the TPM. fwupd stages each capsule in `EFI/UpdateCapsule` on the EFI system
partition and sets the capsule bit in the `OsIndications` EFI variable, and the firmware applies
it on the next boot. ConnectX-7 and NVMe firmware are not offered on LVFS.

A Spark on its factory firmware boots only DGX OS, so take the first update there
(`sudo fwupdmgr refresh && sudo fwupdmgr update`). After that, NixOS can update itself. The
hardware module enables fwupd.

Check three things first. The last two make an update fail without any warning:

- `df -h /boot` shows about 60 MB free. fwupd wants twice the capsule plus 1 MB, and the SoC
  capsule is 30 MB. systemd-boot keeps every generation's kernel on that partition. If it is
  short, lower `boot.loader.systemd-boot.configurationLimit` and collect garbage. Without the
  room, fwupd refuses before it writes anything.
- `findmnt -no OPTIONS /sys/firmware/efi/efivars` starts with `rw`, as it does on NixOS by
  default. With it read-only, fwupd stages the capsules, reports success, and leaves
  `OsIndications` unset, so the firmware never looks at them.
- NixOS's entry comes first in `BootOrder` (`efibootmgr` lists it), or DGX OS and NixOS share
  one EFI system partition. UEFI firmware built on EDK2 looks for capsules only on the partition
  of the first active boot entry (`BootNext`, then `BootOrder`). Whether the Spark's firmware
  does the same has not been checked.

Then:

    sudo fwupdmgr refresh --force
    fwupdmgr get-updates
    sudo fwupdmgr update --no-reboot-check
    ls /boot/EFI/UpdateCapsule
    echo $(( 0x$(od -An -tx8 -j4 /sys/firmware/efi/efivars/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c | tr -d ' ') & 4 ))
    sudo systemctl reboot

`ls` lists one `fwupd-<guid>.cap` per update, and the `echo` prints `4`. Reboot through the
firmware: `systemctl kexec` skips it. A box applying SoC and EC capsules stays dark for about ten
minutes, so do not cut its power. Afterwards, `fwupdmgr get-devices` shows the new versions. An
embedded controller that still shows its old version can need a power cycle: shut down, unplug,
wait, and reconnect. If the screen asks for a UEFI administrator password during the capsule
update, stop: NVIDIA says that password cannot be reset and handles it through support.

In a VM that presented a Spark's ESRT entries, SMBIOS strings and capsule-on-disk support,
NixOS's fwupd (2.1.8, and 2.0.16 on straylight-software's nixpkgs) accepted NVIDIA's current LVFS
cabinets, staged each capsule byte for byte and set `OsIndications`.

## Checks

`nix flake check` runs these. `checks.<system>.<name>` builds one:

| Check | What it does |
|---|---|
| `vm` | Boots two NixOS VMs joined by a LAN and a fabric, with the firewall above. Checks that the daemons name themselves and mesh, that a router on one VM runs the other's agent tools, that the fabric passes what the LAN blocks, that ports get their MTU at boot and when they appear later, and that the snapshot, the status screen, the dispram mounts under Podman, the watchdog and a switch work. |
| `hardware-eval` | Evaluates a whole GB10 host for both kernels without building it. |
| `vendor` | Rebuilds `vendor/kindling-spark-os` from its recorded release and patches, and fails on any difference. |
| `pins` | Compares mentat, py-spy and dispram's OGKM pin with the vendored release's Dockerfile and default stack. |
| `kernel-config-tests` | The kernel configuration generator's tests. |
| `dispram` (aarch64) | Builds dispram against the default stack's OGKM headers. |

The VMs have no GPU, no GB10 kernel and no RDMA, so `nvidia-smi`, dispramd and the ConnectX MTU
path still need a box. Add `--override-input nixpkgs
github:NixOS/nixpkgs/45d3c39fc013ef15db3cf308a21fbd4b2d69a73d` to run the VM test on
straylight-software's nixpkgs. `nix run .#checks.x86_64-linux.vm.driverInteractive` starts the
same VMs from a Python prompt: `start_all()` boots them, and `spark1.shell_interact()` gives a
root shell.

## Keeping up

- **A kindling-spark-os release**: `nix run .#import-kindling -- v0.9.9` vendors it and applies
  the patches. A patch that no longer applies stops the import. Then `nix flake check`, and the
  `pins` check names any pin to follow: mentat's commit and hash in `nix/packages.nix`, with the
  release's `rust/Cargo.lock` copied to `nix/pkgs/mentat-Cargo.lock`, py-spy's wheels, or
  `dispramStack` in `flake.nix`.
- **A kernel**: change the tag, hash and version in `kernel-configs/nvidia-kernel-source.nix`,
  then run `nix run .#generate-kernel-config` and
  `nix run .#generate-kernel-config -- --flavour nvidia-64k` from the checkout's root. A nixpkgs
  bump can need the configs regenerated too. Build the kernel on an aarch64 machine before a box
  boots it.
- **A driver**: the hardware module takes nixpkgs' `nvidiaPackages.latest`. dispram stays off
  until a box validates it on that driver.

## Licence

spark-nixos is under the GNU Affero General Public License, version 3 (LICENSE), as
kindling-spark-os is. Files from graham33/nixos-dgx-spark keep its MIT licence
(LICENSES/MIT-nixos-dgx-spark.txt), and dispram's files keep theirs (NOTICE). A built system
holds NVIDIA's unfree driver and hot-plug helper, so never publish a built system or push one to
a public cache.
