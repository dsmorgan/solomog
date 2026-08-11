#!/usr/bin/env python3
"""VM lifecycle tool for solomog vsphere clusters (snapshots + power).

Run via uv (a solomog setup.sh prerequisite) — never invoked directly:
    uv run --with pyvmomi --python 3.12 scripts/vsphere-snapshot.py <action> <vm> [<vm>...]

Why pyvmomi: vCenter 7.0.3 has no REST snapshot API, and the tofu provider can
create but not REVERT snapshots — while govc would add a new brew dependency.
uv gives us pyvmomi ephemerally, matching the repo's bundle-test pattern.

Actions (snapshot name: $SNAPSHOT_NAME, default "solomog-baseline"):
    take    (re)take the baseline on each VM: removes an existing one first,
            then snapshots WITHOUT memory (small/fast; disk-only, so revert is a
            clean cold boot — no suspend-image clock jump).
    revert  revert each VM to the baseline (current state is discarded; the VM
            lands powered off), then power everything back on.
    stop    graceful guest shutdown (open-vm-tools), hard power-off fallback
            after a timeout — pause the cluster, freeing host CPU/RAM.
    start   power on any VM that is not already running.
    status  one line per VM: power state + baseline presence/creation time.

Env: VSPHERE_SERVER / VSPHERE_USER / VSPHERE_PASSWORD from .env.
TLS: prefer VERIFIED connections — set VSPHERE_CACERT to a PEM bundle (the vCenter
     CA, or its self-signed cert) to keep verification; or give vCenter a real cert
     (Certwarden). VSPHERE_ALLOW_UNVERIFIED_SSL="true" is the explicit last resort
     (same opt-in the OpenTofu vsphere provider uses) and is ignored when
     VSPHERE_CACERT is set.
"""

import os
import ssl
import sys
import time

from pyVim.connect import Disconnect, SmartConnect
from pyVim.task import WaitForTask
from pyVmomi import vim

SNAP_NAME = os.environ.get("SNAPSHOT_NAME", "solomog-baseline")


def die(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def connect():
    host = os.environ.get("VSPHERE_SERVER") or die("VSPHERE_SERVER not set")
    user = os.environ.get("VSPHERE_USER") or die("VSPHERE_USER not set")
    pwd = os.environ.get("VSPHERE_PASSWORD") or die("VSPHERE_PASSWORD not set")
    cacert = os.environ.get("VSPHERE_CACERT", "")
    if cacert:
        ctx = ssl.create_default_context(cafile=cacert)  # verified, custom CA
    elif os.environ.get("VSPHERE_ALLOW_UNVERIFIED_SSL", "").lower() == "true":
        ctx = ssl._create_unverified_context()  # explicit opt-in only
    else:
        ctx = ssl.create_default_context()  # verified, system trust
    return SmartConnect(host=host, user=user, pwd=pwd, sslContext=ctx)


def find_vms(si, names):
    content = si.RetrieveContent()
    view = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True
    )
    by_name = {vm.name: vm for vm in view.view if vm.name in set(names)}
    view.Destroy()
    missing = [n for n in names if n not in by_name]
    if missing:
        die(f"VM(s) not found in vCenter: {', '.join(missing)}")
    return [by_name[n] for n in names]  # preserve caller order (server first)


def find_snap(root, name):
    for s in root:
        if s.name == name:
            return s
        found = find_snap(s.childSnapshotList, name)
        if found:
            return found
    return None


def baseline_of(vm):
    if vm.snapshot is None:
        return None
    return find_snap(vm.snapshot.rootSnapshotList, SNAP_NAME)


def do_take(vms):
    for vm in vms:
        existing = baseline_of(vm)
        if existing:
            print(f"    {vm.name}: replacing existing '{SNAP_NAME}'")
            WaitForTask(existing.snapshot.RemoveSnapshot_Task(removeChildren=True))
        print(f"    {vm.name}: snapshotting → '{SNAP_NAME}'")
        WaitForTask(
            vm.CreateSnapshot_Task(
                name=SNAP_NAME,
                description="solomog baseline (fresh k3s + MetalLB) for vsphere:reset",
                memory=False,
                quiesce=False,
            )
        )


def do_revert(vms):
    for vm in vms:
        snap = baseline_of(vm)
        if snap is None:
            die(
                f"{vm.name} has no '{SNAP_NAME}' snapshot — take one with: "
                "solomog vsphere:snapshot CLUSTER=<name> (or SNAPSHOT=true on create)"
            )
    for vm in vms:
        print(f"    {vm.name}: reverting to '{SNAP_NAME}'")
        WaitForTask(baseline_of(vm).snapshot.RevertToSnapshot_Task())
    for vm in vms:
        if vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOn:
            print(f"    {vm.name}: powering on")
            WaitForTask(vm.PowerOnVM_Task())


def do_stop(vms):
    off = vim.VirtualMachinePowerState.poweredOff
    for vm in vms:
        if vm.runtime.powerState == off:
            print(f"    {vm.name}: already powered off")
            continue
        try:
            vm.ShutdownGuest()  # async, graceful (needs open-vm-tools — present in our template)
            print(f"    {vm.name}: guest shutdown requested")
        except vim.fault.ToolsUnavailable:
            print(f"    {vm.name}: no tools — hard power off")
            WaitForTask(vm.PowerOffVM_Task())
    deadline = time.time() + 180
    while time.time() < deadline:
        if all(vm.runtime.powerState == off for vm in vms):
            break
        time.sleep(3)
    for vm in vms:
        if vm.runtime.powerState != off:
            print(f"    {vm.name}: shutdown timed out — hard power off")
            WaitForTask(vm.PowerOffVM_Task())
    print("    all VMs powered off")


def do_start(vms):
    for vm in vms:
        if vm.runtime.powerState == vim.VirtualMachinePowerState.poweredOn:
            print(f"    {vm.name}: already powered on")
        else:
            print(f"    {vm.name}: powering on")
            WaitForTask(vm.PowerOnVM_Task())


def do_status(vms):
    for vm in vms:
        snap = baseline_of(vm)
        when = snap.createTime.strftime("%Y-%m-%d %H:%M:%SZ") if snap else "—"
        has = "yes" if snap else "no"
        print(f"    {vm.name}\t{vm.runtime.powerState}\tbaseline={has}\t{when}")


def main():
    actions = {
        "take": do_take,
        "revert": do_revert,
        "stop": do_stop,
        "start": do_start,
        "status": do_status,
    }
    if len(sys.argv) < 3 or sys.argv[1] not in actions:
        die("usage: vsphere-snapshot.py <take|revert|stop|start|status> <vm-name> [<vm-name>...]")
    action, names = sys.argv[1], sys.argv[2:]
    si = connect()
    try:
        actions[action](find_vms(si, names))
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
