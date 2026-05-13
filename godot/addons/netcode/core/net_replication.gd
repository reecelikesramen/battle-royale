extends Node

# Registry that ties (schema_id, entity_id) -> NetPredictor for inbound packet
# routing and outbound iteration. Phase 6 uses a hard-coded schema_id=1 for the
# player; later phases will assign ids as schemas register.

signal entity_registered(schema_id: int, entity_id: int)
signal entity_unregistered(schema_id: int, entity_id: int)

var _schemas: Dictionary = {}             # int -> NetSchema
var _entities: Dictionary = {}            # Vector2i(schema_id, entity_id) -> NetPredictor


func _ready() -> void:
	if NetworkClient.has_signal("handle_net_state"):
		NetworkClient.handle_net_state.connect(_on_net_state)


func register_schema(schema_id: int, schema: NetSchema) -> void:
	_schemas[schema_id] = schema


func get_schema(schema_id: int) -> NetSchema:
	return _schemas.get(schema_id, null)


func register_entity(schema_id: int, entity_id: int, predictor) -> void:
	var key := Vector2i(schema_id, entity_id)
	_entities[key] = predictor
	entity_registered.emit(schema_id, entity_id)


func unregister_entity(schema_id: int, entity_id: int) -> void:
	var key := Vector2i(schema_id, entity_id)
	_entities.erase(key)
	entity_unregistered.emit(schema_id, entity_id)


func get_entity(schema_id: int, entity_id: int):
	return _entities.get(Vector2i(schema_id, entity_id), null)


# Iterates all predictors, yielding (schema_id, entity_id, predictor).
# Used by the server snapshot broadcast loop.
func iter_entities() -> Array:
	var out: Array = []
	for key in _entities:
		var k: Vector2i = key
		out.append([k.x, k.y, _entities[key]])
	return out


func _on_net_state(packet) -> void:
	var predictor = get_entity(packet.schema_id, packet.entity_id)
	if predictor == null:
		return
	predictor.handle_net_state_packet(packet)
