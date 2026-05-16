"""Cloud Run Function that starts the game server VM on demand.

Triggered by an HTTPS POST from the game's main menu "Wake server" button.
Returns 200 with a short JSON body. Optionally protected by a shared secret
in the `Authorization: Bearer <secret>` header (set WAKE_SECRET env var).
"""

import json
import os

import functions_framework
import google.auth
from googleapiclient import discovery

PROJECT_ID = os.environ["PROJECT_ID"]
INSTANCE_NAME = os.environ.get("INSTANCE_NAME", "battle-royale-server")
ZONE = os.environ.get("INSTANCE_ZONE", "us-central1-a")
SHARED_SECRET = os.environ.get("WAKE_SECRET", "")


@functions_framework.http
def wake(request):
    if SHARED_SECRET:
        auth = request.headers.get("Authorization", "")
        if auth != f"Bearer {SHARED_SECRET}":
            return ("unauthorized\n", 401)

    credentials, _ = google.auth.default()
    compute = discovery.build("compute", "v1", credentials=credentials, cache_discovery=False)

    instance = compute.instances().get(project=PROJECT_ID, zone=ZONE, instance=INSTANCE_NAME).execute()
    status = instance.get("status", "UNKNOWN")

    # GET = read-only status probe. Used by the main menu to colour the Wake
    # button without ever auto-starting the VM. Only POST actually starts.
    if request.method == "GET":
        body = {"vm_status": status, "running": status == "RUNNING"}
        return (json.dumps(body) + "\n", 200, {"Content-Type": "application/json"})

    if status == "RUNNING":
        body = {"status": "already_running", "eta_seconds": 0, "vm_status": status}
        return (json.dumps(body) + "\n", 200, {"Content-Type": "application/json"})

    compute.instances().start(project=PROJECT_ID, zone=ZONE, instance=INSTANCE_NAME).execute()
    body = {"status": "starting", "eta_seconds": 45, "vm_status": status}
    return (json.dumps(body) + "\n", 200, {"Content-Type": "application/json"})
