extends Node
#
# Server-only autoload. Every REPORT_INTERVAL_S seconds, writes the current
# connected player count to Cloud Monitoring as the custom metric
# `custom.googleapis.com/battle_royale/players_connected`.
#
# Auth uses the metadata-server access token, so this only works when running
# on a GCE VM whose service account has `roles/monitoring.metricWriter`
# (battle-royale-server SA, see infrastructure/terraform/server.tf).
#
# On non-server builds and outside GCP this autoload is a no-op.

const REPORT_INTERVAL_S := 30.0

const METADATA_HOST := "http://metadata.google.internal"
const TOKEN_PATH := "/computeMetadata/v1/instance/service-accounts/default/token"
const PROJECT_PATH := "/computeMetadata/v1/project/project-id"
const INSTANCE_ID_PATH := "/computeMetadata/v1/instance/id"
const INSTANCE_NAME_PATH := "/computeMetadata/v1/instance/name"
const ZONE_PATH := "/computeMetadata/v1/instance/zone"

var _enabled := false
var _project_id := ""
var _instance_id := ""
var _instance_name := ""
var _zone := ""
var _access_token := ""
var _token_expires_at := 0.0
var _http: HTTPRequest

func _ready() -> void:
	if not NetSession.is_dedicated_server:
		return
	_http = HTTPRequest.new()
	add_child(_http)

	if await _bootstrap_metadata():
		_enabled = true
		var t := Timer.new()
		t.wait_time = REPORT_INTERVAL_S
		t.autostart = true
		t.timeout.connect(_on_tick)
		add_child(t)
	else:
		# Not on GCE (probably a local dev server). Quietly stand down.
		queue_free()

func _bootstrap_metadata() -> bool:
	var project = await _metadata_get(PROJECT_PATH)
	var inst_id = await _metadata_get(INSTANCE_ID_PATH)
	var name = await _metadata_get(INSTANCE_NAME_PATH)
	var zone_full = await _metadata_get(ZONE_PATH)
	if project.is_empty() or inst_id.is_empty() or zone_full.is_empty():
		return false
	_project_id = project
	_instance_id = inst_id
	_instance_name = name
	# zone metadata is "projects/<num>/zones/<zone>"; strip prefix
	var parts := zone_full.split("/")
	_zone = parts[parts.size() - 1]
	return true

func _metadata_get(path: String) -> String:
	# Synchronous-ish: HTTPRequest is async; for one-shot bootstrap we await.
	var headers := PackedStringArray(["Metadata-Flavor: Google"])
	var err = _http.request(METADATA_HOST + path, headers)
	if err != OK:
		return ""
	var result = await _http.request_completed
	# result: [result_code, response_code, headers, body: PackedByteArray]
	if result[1] != 200:
		return ""
	return (result[3] as PackedByteArray).get_string_from_utf8().strip_edges()

func _refresh_token() -> bool:
	var headers := PackedStringArray(["Metadata-Flavor: Google"])
	var err = _http.request(METADATA_HOST + TOKEN_PATH, headers)
	if err != OK:
		return false
	var result = await _http.request_completed
	if result[1] != 200:
		return false
	var body := (result[3] as PackedByteArray).get_string_from_utf8()
	var json := JSON.new()
	if json.parse(body) != OK:
		return false
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY or not data.has("access_token"):
		return false
	_access_token = data["access_token"]
	# expires_in is seconds from now; renew 60s early.
	_token_expires_at = Time.get_unix_time_from_system() + float(data.get("expires_in", 0)) - 60.0
	return true

func _on_tick() -> void:
	if not _enabled:
		return
	if Time.get_unix_time_from_system() >= _token_expires_at:
		if not await _refresh_token():
			push_warning("metrics: token refresh failed")
			return

	var players := _current_player_count()
	var ok := await _post_metric(players)
	if not ok:
		push_warning("metrics: post failed (players=%d)" % players)

func _current_player_count() -> int:
	# NetServer (registered as an autoload) tracks connected peers in its
	# peer_ids array. Direct .size() — `Engine.has_singleton` does NOT
	# detect autoloads, and there's no get_connected_player_count helper
	# on NetServer.
	if NetServer == null:
		return 0
	return NetServer.peer_ids.size()

func _post_metric(players: int) -> bool:
	var now_rfc3339 := Time.get_datetime_string_from_system(true).replace(" ", "T") + "Z"
	var payload := {
		"timeSeries": [
			{
				"metric": {
					"type": "custom.googleapis.com/battle_royale/players_connected",
				},
				"resource": {
					"type": "gce_instance",
					"labels": {
						# Numeric instance id, required by the gce_instance
						# monitored resource schema — NOT the instance name.
						"instance_id": _instance_id,
						"zone": _zone,
						"project_id": _project_id,
					},
				},
				"points": [
					{
						"interval": {"endTime": now_rfc3339},
						"value": {"int64Value": str(players)},
					}
				],
			}
		]
	}
	var url := "https://monitoring.googleapis.com/v3/projects/%s/timeSeries" % _project_id
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + _access_token,
	])
	var err = _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		return false
	var result = await _http.request_completed
	return result[1] == 200
