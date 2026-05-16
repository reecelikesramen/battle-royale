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
import os
import time

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from googleapiclient import discovery

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
    """
    if not STATE_BUCKET:
        return (False, "", "", True)
    url = f"https://storage.googleapis.com/storage/v1/b/{STATE_BUCKET}/o/{STATE_OBJECT}?alt=media"
    try:
        resp = session.get(url, timeout=5)
    except Exception:
        return (False, "", "", True)
    if resp.status_code != 200:
        # 404 = agent hasn't written yet (fresh VM or first deploy).
        return (False, "", "", True)
    try:
        data = resp.json()
    except Exception:
        return (False, "", "", True)
    ts = int(data.get("ts", 0))
    age = int(time.time()) - ts
    stale = age > STATE_FRESH_SECS
    ready = bool(data.get("ready", False)) and not stale
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
