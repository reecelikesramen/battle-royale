extends Node

# Phase 9b: integer topic ids dispatched through NetReliableHub. Values are
# arbitrary but stable across builds; appending is safe, renumbering breaks
# any in-flight reliable RPCs from older binaries. 0 is reserved.
enum ReliableTopic { CHAT = 1, THROW_GRENADE = 2, HIT_CONFIRM = 3, SHOT_FIRED = 4, PLAYER_DIED = 5, PLAYER_RESPAWN = 6 }
