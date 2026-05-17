"""Cloud Run Function that prunes old release artifacts from GCS.

Triggered weekly by Cloud Scheduler. Reads `versions.json` from the bucket,
computes a keep-set of release tags worth preserving, then deletes everything
under `releases/<tag>/`, `rust-libs/<tag>/`, `launcher/<tag>/`, and
`deltas/<tag>/` for tags NOT in the keep-set.

Keep-set composition:
  - `manifest.latest`                         (current live release)
  - last N tags by semver order               (recent history; N = KEEP_LAST)
  - any tag referenced by a `delta.from` field in the live manifest
    (a delta zpatch is useless without its base — never orphan it)

Environment:
  BUCKET                  — game-builds bucket name (required)
  KEEP_LAST               — extra tags to keep beyond latest (default 5)
  DRY_RUN                 — '1' to log without deleting (default '0')
  MANIFEST_OBJECT         — manifest path inside bucket (default versions.json)

The function does NOT touch:
  - versions.json / versions.json.sig
  - server-state.json
  - server-agent/, build inputs, anything outside the per-tag prefixes
"""

import json
import os
import re
from collections import defaultdict

import functions_framework
from google.cloud import storage

BUCKET = os.environ["BUCKET"]
KEEP_LAST = int(os.environ.get("KEEP_LAST", "5"))
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
MANIFEST_OBJECT = os.environ.get("MANIFEST_OBJECT", "versions.json")

# Each prefix holds per-tag directories that we own end-to-end. Touching
# anything outside this list is an explicit decision (e.g. server-state.json,
# the manifest itself).
PRUNABLE_PREFIXES = ("releases/", "rust-libs/", "launcher/", "deltas/")

# vX.Y.Z[-suffix] — same as init.gd's semver regex but matches the directory
# name, not a .pck filename. We use this to (1) parse tags out of object
# names and (2) sort them for "last N".
TAG_RE = re.compile(
    r"^v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?$"
)


def _semver_key(tag: str):
    """Sort key matching SemVer ordering well enough for our tags.

    Strips the leading `v`, splits on `.`, treats numeric components as ints
    so v0.1.10 sorts AFTER v0.1.9 (lex order would invert them). Pre-release
    suffixes sort before the matching release per the SemVer spec.
    """
    m = TAG_RE.match(tag)
    if not m:
        return (0, 0, 0, "")
    major, minor, patch, pre = m.groups()
    # No pre-release > any pre-release: encode missing pre as "~" which
    # sorts after digits and letters in ASCII.
    return (int(major), int(minor), int(patch), pre or "~")


def _load_manifest(client: storage.Client) -> dict:
    bucket = client.bucket(BUCKET)
    blob = bucket.blob(MANIFEST_OBJECT)
    raw = blob.download_as_bytes()
    return json.loads(raw)


def _collect_keep_set(manifest: dict) -> set[str]:
    versions = manifest.get("versions", {}) or {}
    all_tags = [t for t in versions.keys() if TAG_RE.match(t)]
    all_tags.sort(key=_semver_key, reverse=True)

    keep: set[str] = set()
    latest = manifest.get("latest")
    if isinstance(latest, str):
        keep.add(latest)
    keep.update(all_tags[:KEEP_LAST])

    # Any tag referenced as delta.from in the live manifest's components must
    # stay — the delta zpatch downloads can't be applied without their base.
    for version in versions.values():
        plats = (version or {}).get("platforms", {}) or {}
        for platform_entry in plats.values():
            for component in (platform_entry or {}).values():
                if not isinstance(component, dict):
                    continue
                delta = component.get("delta")
                if isinstance(delta, dict):
                    src = delta.get("from")
                    if isinstance(src, str):
                        keep.add(src)
    return keep


def _enumerate_tags(client: storage.Client) -> dict[str, set[str]]:
    """Map prefix → {tag, ...} actually present in the bucket."""
    bucket = client.bucket(BUCKET)
    by_prefix: dict[str, set[str]] = defaultdict(set)
    for prefix in PRUNABLE_PREFIXES:
        # delimiter='/' lists "subdirectories" via .prefixes; cheap and avoids
        # paging through every file when a single tag has thousands.
        iterator = client.list_blobs(bucket, prefix=prefix, delimiter="/")
        # Have to consume the iterator before .prefixes is populated.
        for _ in iterator:
            pass
        for sub in iterator.prefixes:
            # sub looks like "releases/v0.1.10/"
            tag = sub[len(prefix):].rstrip("/")
            if TAG_RE.match(tag):
                by_prefix[prefix].add(tag)
    return by_prefix


def _delete_tag(client: storage.Client, prefix: str, tag: str) -> int:
    """Delete every object under `<prefix><tag>/`. Returns deleted count."""
    bucket = client.bucket(BUCKET)
    full_prefix = f"{prefix}{tag}/"
    count = 0
    for blob in client.list_blobs(bucket, prefix=full_prefix):
        if DRY_RUN:
            print(f"[dry-run] would delete gs://{BUCKET}/{blob.name}")
        else:
            try:
                blob.delete()
            except Exception as e:
                # Continue on individual delete failure; surface in logs so we
                # don't silently mask a permissions regression.
                print(f"WARN: failed to delete gs://{BUCKET}/{blob.name}: {e}")
                continue
        count += 1
    return count


@functions_framework.http
def cleanup(_request):
    client = storage.Client()
    manifest = _load_manifest(client)
    keep = _collect_keep_set(manifest)
    present = _enumerate_tags(client)

    summary: dict[str, dict[str, int]] = {}
    total_deleted_objects = 0
    total_deleted_tags = 0

    for prefix, tags in present.items():
        per_prefix: dict[str, int] = {}
        for tag in sorted(tags, key=_semver_key):
            if tag in keep:
                continue
            deleted = _delete_tag(client, prefix, tag)
            per_prefix[tag] = deleted
            total_deleted_objects += deleted
            total_deleted_tags += 1
        if per_prefix:
            summary[prefix] = per_prefix

    return (
        json.dumps({
            "dry_run": DRY_RUN,
            "keep": sorted(keep, key=_semver_key, reverse=True),
            "deleted_tags": total_deleted_tags,
            "deleted_objects": total_deleted_objects,
            "by_prefix": summary,
        }, indent=2),
        200,
        {"Content-Type": "application/json"},
    )
