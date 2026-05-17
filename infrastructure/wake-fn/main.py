"""Cloud Run Function that starts the game server VM on demand.

Triggered by an HTTPS POST from the game's main menu "Wake server" button.
Returns 200 with a short JSON body. Optionally protected by a shared secret
in the `Authorization: Bearer <secret>` header (set WAKE_SECRET env var).

GET returns a read-only status used to colour the main-menu Wake button.
`running` is true only when the VM is RUNNING *and* the server-agent's
ready-state heartbeat (gs://$bucket/server-state.json) is fresh AND reports
the game has bound its UDP socket. Without the heartbeat check, the button
went green ~5s after wake even though the game needed 30-60s more to bind.
"""

import json
import logging
import os
import time

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from googleapiclient import discovery

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("wake")

PROJECT_ID = os.environ["PROJECT_ID"]
INSTANCE_NAME = os.environ.get("INSTANCE_NAME", "battle-royale-server")
ZONE = os.environ.get("INSTANCE_ZONE", "us-central1-a")
SHARED_SECRET = os.environ.get("WAKE_SECRET", "")
STATE_BUCKET = os.environ.get("STATE_BUCKET", "")
STATE_OBJECT = os.environ.get("STATE_OBJECT", "server-state.json")
# Heartbeat is written every 15s by the agent; allow 4x interval before we
# stop trusting it. A stale state ⇒ "not ready" so a crashed agent can't
# leave the button stuck green forever.
STATE_FRESH_SECS = int(os.environ.get("STATE_FRESH_SECS", "60"))


def _fetch_ready_state(session):
    """Return (ready: bool, version: str, sha: str, stale: bool).

    `ready` is False if the state object is missing, malformed, stale, or the
    agent reported the game isn't bound. `stale` distinguishes "agent just
    hasn't reported yet" from "agent reported not-ready" for debugging.

    Every failure path logs explicitly so Cloud Logging shows *why* the wake
    button stays yellow — the previous bare `except Exception: return stale`
    silently swallowed permission errors / parse failures, which left us
    chasing the symptom (state_stale=true with healthy GCS object) for hours.
    """
    if not STATE_BUCKET:
        log.warning("_fetch_ready_state: STATE_BUCKET env unset")
        return (False, "", "", True)
    # Cache-bust query string + Cache-Control request header. GCS sets
    # objects in public buckets to `cache-control: public, max-age=3600` by
    # default — the JSON API and GFE happily serve a 30+ min stale object
    # even though server-agent writes every 15s. The query string defeats
    # any URL-keyed CDN entry; the header asks any well-behaved intermediate
    # to revalidate. Proper fix is in server-agent (set the object's own
    # cacheControl metadata to no-cache via multipart upload) — this layer
    # makes wake-fn correct in the meantime and is harmless after that lands.
    url = (
        f"https://storage.googleapis.com/storage/v1/b/"
        f"{STATE_BUCKET}/o/{STATE_OBJECT}?alt=media&_t={int(time.time())}"
    )
    try:
        resp = session.get(
            url,
            timeout=5,
            headers={"Cache-Control": "no-cache, no-store, max-age=0"},
        )
    except Exception as e:
        log.exception("_fetch_ready_state: GCS GET raised: %s", e)
        return (False, "", "", True)
    if resp.status_code != 200:
        # 404 = agent hasn't written yet. 401/403 = SA permission drift.
        # 5xx = GCS hiccup. Log the body so the cause is in the journal.
        body_snippet = resp.text[:300] if resp.text else "<empty>"
        log.warning(
            "_fetch_ready_state: GCS GET %s returned %s body=%r",
            url, resp.status_code, body_snippet,
        )
        return (False, "", "", True)
    try:
        data = resp.json()
    except Exception as e:
        log.exception(
            "_fetch_ready_state: JSON parse failed: %s body=%r",
            e, resp.text[:300],
        )
        return (False, "", "", True)
    ts = int(data.get("ts", 0))
    age = int(time.time()) - ts
    stale = age > STATE_FRESH_SECS
    ready = bool(data.get("ready", False)) and not stale
    if stale:
        log.info(
            "_fetch_ready_state: stale heartbeat age=%ss > %ss",
            age, STATE_FRESH_SECS,
        )
    return (ready, data.get("version", ""), data.get("sha", ""), stale)


@functions_framework.http
def wake(request):
    if SHARED_SECRET:
        auth = request.headers.get("Authorization", "")
        if auth != f"Bearer {SHARED_SECRET}":
            return ("unauthorized\n", 401)

    credentials, _ = google.auth.default()
    compute = discovery.build("compute", "v1", credentials=credentials, cache_discovery=False)
    session = AuthorizedSession(credentials)

    instance = compute.instances().get(project=PROJECT_ID, zone=ZONE, instance=INSTANCE_NAME).execute()
    status = instance.get("status", "UNKNOWN")

    # GET = read-only status probe. Used by the main menu to colour the Wake
    # button without ever auto-starting the VM. Only POST actually starts.
    if request.method == "GET":
        ready, version, sha, stale = _fetch_ready_state(session)
        running = status == "RUNNING" and ready
        body = {
            "vm_status": status,
            "running": running,
            "ready": ready,
            "version": version,
            "sha": sha,
            "state_stale": stale,
        }
        return (json.dumps(body) + "\n", 200, {"Content-Type": "application/json"})

    if status == "RUNNING":
        # VM up but maybe not yet ready — surface the same shape so the client
        # can keep showing "starting" if needed.
        ready, _version, _sha, _stale = _fetch_ready_state(session)
        body = {
            "status": "already_running",
            "eta_seconds": 0 if ready else 30,
            "vm_status": status,
            "ready": ready,
        }
        return (json.dumps(body) + "\n", 200, {"Content-Type": "application/json"})

    compute.instances().start(project=PROJECT_ID, zone=ZONE, instance=INSTANCE_NAME).execute()
    body = {"status": "starting", "eta_seconds": 45, "vm_status": status}
    return (json.dumps(body) + "\n", 200, {"Content-Type": "application/json"})
