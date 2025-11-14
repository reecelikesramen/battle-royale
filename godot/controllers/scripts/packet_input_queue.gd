#class_name PacketInputQueue extends RefCounted
#
#class TimestampedPacket:
	#var delta: float = 0.0
	#var timestamp_us: int = 0
	#var packet: Object = null
	#func _init(delta: float, timestamp_us: int, packet: Object) -> void:
		#self.delta = delta
		#self.timestamp_us = timestamp_us
		#self.packet = packet
#
#const MAX_FRAMES_PER_TICK := 4
#const MAX_QUEUE_SIZE := 64
#
#var _queue: Array[int] = []
#var _packets: Dictionary[int, TimestampedPacket] = {}
#var _last_sequence_id: int = -1
#var _last_received_timestamp_us: int = -1
#var _last_packet: Object = null
#
#
#func enqueue(sequence_id: int, timestamp_us: int, packet: Object) -> void:
	## discard out of sequence or duplicate packets
	#if !PacketSequence.is_newer(sequence_id, _last_sequence_id):
		#return
	#if _packets.has(sequence_id):
		#return
#
	#var delta := 0.0
	#if _last_received_timestamp_us >= 0:
		##assert(timestamp_us > _last_received_timestamp_us, "Timestamp is not newer")
		#var diff_us: int = max(1, timestamp_us - _last_received_timestamp_us)
		#delta = float(diff_us) / 1000_000.0
	#else:
		#delta = 1.0 / Engine.get_physics_ticks_per_second()
	#_last_received_timestamp_us = timestamp_us
#
	#var insert_index := _queue.size()
	#for i in range(_queue.size()):
		#if PacketSequence.is_newer(_queue[i], sequence_id):
			#insert_index = i
			#break
	#_queue.insert(insert_index, sequence_id)
	#while _queue.size() > MAX_QUEUE_SIZE:
		#_queue.remove_at(0)
#
	#_packets[sequence_id] = TimestampedPacket.new(delta, timestamp_us, packet)
#
#func consume(now_us: int) -> Array[TimestampedPacket]:
	#if _queue.is_empty():
		#if _last_packet == null: return []
		#var new_delta := float(max(1, now_us - _last_received_timestamp_us)) / 1000_000.0
		#return [TimestampedPacket.new(new_delta, _last_received_timestamp_us, _last_packet)]
#
	#var packets_remaining := MAX_FRAMES_PER_TICK
	#var packets: Array[TimestampedPacket] = []
	#while packets_remaining > 0 and !_queue.is_empty():
		#var next_sequence_id := _queue[0]
		#packets_remaining -= 1
		#_last_packet = _packets[next_sequence_id].packet
		#packets.push_back(_packets[next_sequence_id])
		#_queue.remove_at(0)
		#_packets.erase(next_sequence_id)
#
	#return packets
#
#
#func size() -> int:
	#return _queue.size()
#
#
#func is_empty() -> bool:
	#return _queue.is_empty()
