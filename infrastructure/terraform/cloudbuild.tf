#
# Cloud Build trigger.
#
# Current state (pre-Sprint 1): builds are submitted via `gcloud builds submit`
# from .github/workflows/godot-google-ci.yml — no persistent trigger exists in
# GCP. We keep that flow for now (no trigger resource defined here) so this
# sprint is a pure import of existing state.
#
# Future migration option: replace the manual gcloud submit with a
# `google_cloudbuild_trigger` connected to the GitHub repo via Cloud Build
# Connection. Tracked separately; not in scope for Sprint 1.
#
# This file is a placeholder so the intent is documented and we don't add a
# resource that wouldn't have anything to import.
