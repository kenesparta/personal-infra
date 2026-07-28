"""Weekly Lightsail snapshot: create one, then prune to the newest KEEP.

spec §5.8 — runs in AWS so no credential lands on the host (G5). The prune
filters strictly by SNAPSHOT_PREFIX so hand-made snapshots (pre-harden-*, …)
are never candidates (G20).
"""

import os
from datetime import datetime, timezone

import boto3


def handler(event, context):
    ls = boto3.client("lightsail")
    instance = os.environ["INSTANCE_NAME"]
    prefix = os.environ["SNAPSHOT_PREFIX"]
    keep = int(os.environ["KEEP"])

    created = f"{prefix}{datetime.now(timezone.utc):%Y-%m-%d}"
    ls.create_instance_snapshot(instanceName=instance, instanceSnapshotName=created)

    snaps, token = [], None
    while True:
        page = ls.get_instance_snapshots(**({"pageToken": token} if token else {}))
        snaps += [
            s
            for s in page["instanceSnapshots"]
            if s["fromInstanceName"] == instance and s["name"].startswith(prefix)
        ]
        token = page.get("nextPageToken")
        if not token:
            break

    stale = sorted(snaps, key=lambda s: s["createdAt"], reverse=True)[keep:]
    for s in stale:
        ls.delete_instance_snapshot(instanceSnapshotName=s["name"])

    return {"created": created, "pruned": [s["name"] for s in stale]}
