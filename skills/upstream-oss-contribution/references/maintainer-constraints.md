# Reading a maintainer's design constraint out of an issue thread

Worked example: democratic-csi issue #536, `NodeUnstageVolume` leaving
orphaned iSCSI sessions. Useful as a template for how a stated constraint
should reshape a patch.

## The defect

`NodeUnstageVolume` in `src/driver/index.js` identifies which iSCSI session to
log out of by matching the **local block device name** against
`session.attached_scsi_devices.host.devices[].attached_scsi_disk`:

```javascript
is_attached_to_session =
  session.attached_scsi_devices.host.devices.some(
    (device) => device.attached_scsi_disk == parent_block_device.name
  );

if (is_attached_to_session) {
  // logout + deleteNodeDBEntry happen ONLY inside this block
}
```

When the backing zvol is destroyed (or the network severed) *before*
`NodeUnstageVolume` runs, `/dev/sdX` is gone, nothing matches, the loop
completes without logging out, and `iscsid` retries the login forever:

```
Unable to locate Target IQN: iqn.…:pvc-… in Storage Node
iSCSI Login negotiation failed.
```

## The naive fix, and why it is wrong

Obvious approach: fall back to the IQN from `volume_context` and log out of
that target. The maintainer had already ruled this out in the thread:

> One challenge here is a perhaps overly broad assumption that we only ever
> have 1 lun per iqn/portal. […] the `node-manual` driver can be used to
> connect to multiple volumes on the same target which could result in bad
> behavior

So an unconditional logout-by-IQN would tear down volumes still in use by
other pods. The constraint is not negotiable and is not obvious from the code
alone — it only exists in the thread.

## The shape that respects it

Track whether the device-based match ever succeeded; only if it did not, fall
back to the IQN — and **skip any target with more than one attached LUN**:

```javascript
if (!matched_session_by_device) {
  const volume_context = await driver.getDerivedVolumeContext(call);
  const iqn = _.get(volume_context, "iqn");
  if (iqn) {
    for (const session of await iscsi.iscsiadm.getSessionsDetails()) {
      if (session.target != iqn) continue;
      const luns = _.get(session, "attached_scsi_devices.host.devices", []).length;
      if (luns > 1) {
        driver.ctx.logger.warn(`refusing orphaned session logout, target has ${luns} luns: ${iqn}`);
        continue;
      }
      // logout + deleteNodeDBEntry
    }
  }
}
```

## Reusing what already exists

`getDerivedVolumeContext(call)` was already in the codebase and already called
from three other node-side methods — CSI does not pass `volume_context` to
`NodeUnstageVolume`, and this helper is how the project recovers it (memory
cache, then the Kubernetes PV, then `driver.options._private`). Finding it
avoided inventing a parallel mechanism and kept the diff small.

Confirm helper signatures against source rather than assuming, e.g.
`GeneralUtils.retry(retries, retriesDelay, code, options)` — argument order
matters and the wrong guess compiles fine.

## What could not be verified

- `npm test` is `echo "Error: no test specified" && exit 1`; there is no
  `tests/` directory. Adding a bespoke test file would have introduced a
  pattern the project does not use.
- CI is 12 `csi-sanity` jobs on **self-hosted runners** against real
  Synology/TrueNAS/ZFS hardware with maintainer-held secrets. They do not run
  on fork PRs.

Verified locally instead: `node --check src/driver/index.js`, helper signatures
read from source, and the decision logic exercised against simulated session
shapes (single-LUN, multi-LUN, wrong target, missing IQN, no attached devices).
The PR body should say exactly this — and should not imply more.
