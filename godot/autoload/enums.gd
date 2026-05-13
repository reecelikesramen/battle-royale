extends Node

enum IntegrationContext { VISUAL, GAME }

# Phase 9b: integer topic ids dispatched through NetReliableHub. Values are
# arbitrary but stable across builds; appending is safe, renumbering breaks
# any in-flight reliable RPCs from older binaries. 0 is reserved.
enum ReliableTopic { CHAT = 1 }
