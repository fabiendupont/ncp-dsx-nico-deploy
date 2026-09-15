<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# End-to-End Test: NICo + KubeVirt + vbmc-rs + Metal3 on self-managed SNO

> **⚠️ UNVALIDATED**: This runbook covers the KubeVirt track which has not been
> recently validated against the current codebase. It is preserved for reference
> only. The actively maintained e2e runbook is
> [`docs/e2e-libvirt-openshift.md`](docs/e2e-libvirt-openshift.md).
> Credentials and passwords shown below (e.g. `nicolab`, `admin`) are lab
> placeholders only — **do not use in production**.

**Status:** design (not yet implemented). This document is the agreed
architecture and phased plan; the `make e2e-*` targets it references are
defined incrementally as each phase is built.

## Goal

Provision an OpenShift **worker node** end-to-end through the real NICo
hardware path — no physical servers — on a **self-managed Single-Node
OpenShift (SNO)** cluster running in a libvirt VM. A nested KubeVirt VM stands
in for the bare-metal host; `vbmc-rs` presents it as a Redfish BMC; NICo
discovers it, drives it to `Ready`, and (on tenant instance allocation)
PXE-installs **RHCOS + OpenShift worker ignition** so the VM joins the cluster;
Metal3 **adopts** the result as a `BareMetalHost`.

This is the hardware-backed sibling of
[`machine-a-tron-testing-guide.md`](machine-a-tron-testing-guide.md): it swaps
NICo's internal `bmc-mock` for **real KubeVirt VMs fronted by vbmc-rs**, and
extends past `Ready` into an actual node join and Metal3 reflection.

## Why SNO instead of CRC (platform decision, 2026-09-14)

CRC *is* single-node OpenShift under the hood — same OVN, same MCS firewall,
same components — but it is **packaged and frozen** for laptop use and is
explicitly not meant to gain nodes. The blockers hit during the CRC de-risk
spike were all CRC-packaging artifacts, not OpenShift limitations:

- `api-int.crc.testing` resolves to the `br-ex` address (192.168.127.2) from
  cluster context, not the machine-network node IP.
- The libvirt network is fixed and not meant to be extended; a second host on
  the machine L2 can't easily be placed.
- MCS (`22623/22624`) has `REJECT` rules — but **only in the FORWARD and OUTPUT
  chains, not INPUT**. A host sitting *on the machine network* and connecting to
  the node's machine IP directly (an INPUT-path connection) is allowed; the CRC
  spike only failed because the traffic was routed (FORWARD) or from the node's
  own OUTPUT path.

A self-managed SNO removes all three: **we own the machine network, DNS
(`api`/`api-int`/`*.apps`), and DHCP**, and worker expansion is a *documented,
supported* Red Hat procedure ("Adding worker nodes to single-node OpenShift").
The same MCS firewall exists, but on the machine-network INPUT path it behaves
as designed. Cost: install time and we run DNS/networking ourselves — cheap on
this host (32 cores, 125 GB, ~113 GB free; CRC already torn down).

**Worker model: (A) nested KubeVirt VMs + standalone vbmc-rs (KubeVirt API
backend).** The "bare-metal host" is a KubeVirt VM inside SNO; a standalone
vbmc-rs presents it as a Redfish BMC and drives power via the KubeVirt
subresource API (start/stop/restart). This is the only model that powers on a
*stopped* VM (see decision #5). (Rejected: the vbmc-rs sidecar+aggregator model —
per-VM libvirt sidecar in virt-launcher + aggregator — which can't list or start
a stopped VM; and host-libvirt sibling VMs, which diverge from the KubeVirt-native
shape. Sidecar hot-telemetry is folded into the future smart-hybrid,
fabiendupont/vbmc-rs#26.)

## Chain

```
KubeVirt VM  (blank disk + NICs on NICo provisioning L2 segments; nested in SNO)
   ▲ Redfish: power on/off/cycle (real), boot-override (accepted/echoed)
vbmc-rs  (standalone; KubeVirt API backend → start/stop/restart subresources)
   ▲ Redfish power/boot-order  +  PXE/iPXE + DHCP on provisioning L2
NICo site  (nico-api discovers via BMC → Scout discovery OS → Ready
            → tenant instance allocate w/ raw-iPXE OS = RHCOS + ignition
            → VM PXE-installs RHCOS → boots from disk → joins OpenShift)
   ▲ NICo REST API
machine-api-provider-nvidia  (BMH-sync controller, unchanged)
   ▼
Metal3 BareMetalHost  (ExternallyProvisioned: adoption/inventory only)
   ▼
OpenShift (SNO): new worker node registers, CSRs approved, worker joins
```

## Key design decisions (evidence-backed)

1. **NICo provisions; Metal3 adopts.** NICo owns OS deployment via its own
   PXE/iPXE + Redfish boot-order/power. The provider's BMH mapper hard-codes
   `ExternallyProvisioned: true` and sets no `spec.Image`
   (`machine-api-provider-nvidia .../baremetalhost/mapper.go:79`), i.e. the BMH
   is inventory, not a provisioning driver. Provider is used **as-is**.

2. **Provisioning is PXE/iPXE + Redfish boot-order — NOT virtual media.**
   NICo sets boot source via Redfish (`set_boot_override`,
   `change_boot_order`, targeting a NIC by MAC —
   `infra-controller/crates/redfish/src/libredfish/instrumented.rs:239-307`),
   power-cycles (`crates/machine-controller/src/redfish.rs`), and the host
   netboots NICo's iPXE server. Virtual media exists only in NICo's
   `crates/bmc-mock` test harness, not the production path.

3. **RHCOS worker join uses the raw-iPXE tenant OS variant.**
   `InstanceOperatingSystemConfig` (proto
   `rest-api/proto/core/src/v1/nico_nico.proto:3073`) is a `oneof` of
   `InlineIpxe` / `os_image_id` / `operating_system_id`, and the tenant path is
   OS-agnostic by design (`docs/glossary.md:30-36`). Use `InlineIpxe` pointing
   at the RHCOS live kernel/initramfs with `coreos.inst.*` +
   `ignition.config.url`. **Ignition rides in kernel args**, not the NICo
   `user_data` field (that field is cloud-init, which RHCOS ignores).

4. **vbmc-rs boot-override is a functional no-op — the VM's static bootOrder
   drives PXE.** vbmc-rs accepts/echoes a `Pxe` `BootSourceOverrideTarget`
   (`vbmc-rs src/redfish/systems.rs:446,655`) but no libvirt/KubeVirt backend
   acts on it (only the `Cd`+virtual-media path does, `power.rs:40`). NICo's
   real dependency — Redfish **power-cycle** — *is* implemented
   (`vm_boot`/`vm_reboot`). So: configure the KubeVirt VM's `bootOrder` with the
   **provisioning NIC first** (blank disk falls through to PXE anyway); NICo's
   ignored override + real power-cycle yields a netboot; once RHCOS is on disk,
   it boots from disk. No vbmc-rs code change required for v1. (Future
   enhancement: honor `Pxe`/`UefiTargetBootSourceOverride` in the libvirt
   backend — vbmc-rs is our repo, but out of scope here.)

5. **vbmc-rs KubeVirt API backend (not sidecar+aggregator).** A standalone
   vbmc-rs (`backend = "kube_virt"`) maps Redfish power to the KubeVirt
   subresource API (`virtualmachines/start|stop|restart`). This is the only model
   that can power on a **stopped** VM — the sidecar+aggregator model discovers
   only *ready virt-launcher pods*, and a stopped VM has no VMI/pod/libvirtd/
   domain, so it can't even list it. NICo/Metal3 need exactly a boot-from-off via
   Redfish, so the API backend is required. vbmc-rs firmware is synthetic and
   backend-independent, so RMS gets the same firmware surface as in sidecar mode;
   the sidecar's only edge — hot telemetry on *running* VMs — isn't consumed here.
   The smart-hybrid (aggregator doing API lifecycle **and** proxying to a sidecar
   when the VM is up) is tracked upstream: fabiendupont/vbmc-rs#26. Deployed
   CUDN-homed (nico-bmc, no ClusterIP), dual-homed like RMS: default net
   northbound (kube-apiserver subresource calls), nico-bmc southbound (BMC).

6. **Zero-DPU / HostInband mode.** Same host model machine-a-tron uses
   (`dpu_per_host_count = 0`, HostInband segment) so a NoDpu host can reach
   `Ready` and be allocated — no simulated/real DPU needed.

## SNO cluster & sizing

Host (measured 2026-09-14): 32 cores, 125 GB RAM (~113 GB free), CRC torn down.
Tooling present: `openshift-install` 4.20.8, `oc`/`kubectl` (`~/.local/bin`),
`virsh`/`virt-install`/`qemu-img`/`genisoimage`/`nmcli`, pull secret at
`~/pull-secret.json`.

| Component | Footprint | Notes |
|---|---|---|
| SNO VM | 16 vCPU / 40 GB / 120 GB disk | `host-passthrough` CPU for **nested virt** |
| CNV/KubeVirt | in-cluster | KVM-accelerated via nested virt |
| NICo cloud + site | in-cluster | REST/Temporal/PG + Core/Vault/NATS/PG |
| Metal3 (BMO/Ironic) | in-cluster | adoption only |
| Nested worker VM(s) | ~8 GB / 2–4 vCPU each | one to start |

Total comfortably under 113 GB. SNO's 40 GB is the practical floor for the full
NICo + CNV + Metal3 stack plus one worker VM; bump if a second worker is added.

## Networking design (now fully under our control)

A dedicated libvirt NAT network is the machine network; **we run its DNS and
DHCP** (libvirt's dnsmasq), so `api`/`api-int`/`*.apps` resolve to the SNO node
IP and there is no br-ex indirection.

- **Cluster / machine network** `nico-e2e` (proposed `192.168.130.0/24`):
  - SNO node: static `192.168.130.10` (MAC-reserved DHCP lease).
  - DNS records (libvirt dnsmasq): `api.sno.nico.test` →`.10`,
    `api-int.sno.nico.test` → `.10`, wildcard `*.apps.sno.nico.test` → `.10`
    (via `<dnsmasq:options>address=/apps.sno.nico.test/192.168.130.10`).
  - Base domain `nico.test`, cluster name `sno` (→ `sno.nico.test`).
- **NICo provisioning segment(s)** — VM provisioning NIC + `nico-dhcp` (Kea) +
  `nico-pxe` reachable on an OVN secondary network (NAD/CUDN) inside SNO, as in
  the machine-a-tron config (`oob`/`admin`/`host_inband`). Kea advertises
  DNS/NTP/provisioning (option 6) pointing at the real `nico-dns`/`nico-pxe`
  addresses (`helm/values/nico-core.yaml`).
- **BMC network** — vbmc-rs aggregator reachable at the BMC IP NICo expects
  (`ExpectedMachine.bmc_ip_address` / MAC → credential lookup); vbmc-rs's chart
  provisions a CUDN for its BMC net (`bmcNetwork.cudn`).
- **Worker node IP** — the nested worker VM gets an IP on the **cluster/machine
  network** (`192.168.130.0/24`) so the SNO control plane reaches kubelet:10250
  and MCS via the INPUT path. Bridge/macvlan onto the SNO VM's machine NIC, or a
  second libvirt network the worker VM also attaches to.

## SNO install (agent-based, Phase 0)

1. Create libvirt network `nico-e2e` with our DNS records + a MAC-reserved lease
   for the SNO node.
2. `install-config.yaml`: 1 control-plane replica, 0 compute, `platform: none`,
   `baseDomain: nico.test`, `metadata.name: sno`,
   `machineNetwork: 192.168.130.0/24`, `~/pull-secret.json`, SSH key.
3. `agent-config.yaml`: `rendezvousIP: 192.168.130.10`, host entry mapping the
   SNO VM MAC → `.10`.
4. `openshift-install agent create image` → `agent.x86_64.iso`.
5. `virt-install` the SNO VM (16 vCPU / 40 GB / 120 GB, `host-passthrough`, NIC
   on `nico-e2e` with the reserved MAC) booting the ISO.
6. `openshift-install agent wait-for install-complete`; export kubeconfig.

## Phased plan (each phase = Make target(s) + a runbook section)

| Phase | Target(s) | Outcome |
|---|---|---|
| 0. SNO + prereqs | `e2e-sno`, `e2e-prereqs` | SNO up (agent-based); CNV (KVM-accelerated) + CDI; Metal3 BMH CRD + BMO/Ironic (standalone) |
| 1. NICo cloud | (existing `deploy-all-cloud`) + post-deploy | Management plane up; org bootstrapped |
| 2. NICo site | (existing `deploy-all-site`, **no MAT**) | Site plane up, `siteConfig` for real hosts (zero-DPU/HostInband) |
| 3. Networks **(spike)** | `e2e-networks` | Secondary L2 (host_inband + BMC); prove VM↔nico-dhcp/pxe and NICo↔vbmc-rs reachability |
| 4. KubeVirt VM | `e2e-vms` | Blank-disk VM(s), provisioning NIC first in `bootOrder`, NICs on the segments |
| 5. vbmc-rs | `e2e-vbmc` | vbmc-rs (KubeVirt API backend) deployed, CUDN-homed on nico-bmc; Redfish BMC reachable; real power on/off/cycle drives the VM (start/stop/restart subresources) — **done** |
| 6. Discover→Ready | `e2e-run` / `e2e-status` | BMC IP sticky via IPAMClaim + one-way TLS on :8443 (`bmc_proxy=":8443"`) — **done**; then real-hardware `siteConfig` shipped, `ExpectedMachine` seeded (BMC IP/MAC/creds), NICo discovers → Scout → `Ready` |
| 7. Allocate + join | `e2e-allocate` | Tenant instance w/ `InlineIpxe`=RHCOS+ignition; VM installs, reboots, **joins as worker** (approve CSRs) |
| 8. Metal3 adopt | `e2e-verify` | Provider syncs `Ready` machine → `BareMetalHost` (ExternallyProvisioned); assert present |
| — | `e2e-clean` | Tear down VMs, vbmc-rs, networks, instance |

Existing cloud/site targets are reused verbatim; new `e2e-*` targets cover only
the SNO/KubeVirt/vbmc-rs/Metal3 additions and orchestration.

## Risk register & de-risking spikes

1. **Provisioning-network reachability (highest).** VM↔`nico-dhcp`/`nico-pxe`
   over OVN secondary L2 inside SNO. → **Spike in Phase 3** before building VMs:
   confirm DHCP offer + iPXE fetch reach the VM.
2. **RHCOS iPXE + ignition via kernel args.** Correct `coreos.inst.install_dev`,
   `coreos.live.rootfs_url`, `ignition.config.url` reachable from the VM. →
   Validate with a standalone iPXE boot before wiring NICo's `InlineIpxe`.
3. **Worker joining SNO.** Now the *supported* path (unlike CRC). We control
   machine-network DNS (`api-int` → node IP) and DHCP, so the worker reaches
   MCS on the INPUT path (`22623/22624` REJECT rules live only in FORWARD/OUTPUT).
   Expect manual CSR approval (`oc adm certificate approve`). If MCS is still
   unreachable, fall back to embedding full rendered-worker ignition (from the
   `rendered-worker-*` MachineConfig `.spec.config`, ign 3.5.0) in the VM's
   config-drive — validated as extractable during the CRC spike.
4. **vbmc-rs Redfish surface vs `libredfish` expectations.** NICo's exact wire
   calls live in external `libredfish` v0.47.3. vbmc-rs may need small Redfish
   fidelity fixes (BIOS attrs, boot-order read-back). → Capture NICo↔vbmc-rs
   Redfish traffic during Phase 6; fix vbmc-rs as needed (our repo).
5. **Nested virt performance/stability.** SNO in a VM running CNV which runs
   worker VMs = two nesting levels. `host-passthrough` CPU + `/dev/kvm` keep it
   accelerated; watch memory. → Confirmed KVM works nested on this host.

## What this does and does not cover

**Covers:** real BMC/Redfish discovery, credential rotation, BIOS config, NICo
`Ready`, real OS install over PXE/iPXE, an actual OpenShift worker join, and
Metal3 BMH adoption.

**Does not cover:** real DPUs reaching `Ready` (structural NICo limitation, see
MAT guide #1), physical switches/relay/OOB timing, Metal3 *provisioning* (it
adopts only, by design), or multi-node control-plane scale (single control-plane
node; we add worker nodes only).
