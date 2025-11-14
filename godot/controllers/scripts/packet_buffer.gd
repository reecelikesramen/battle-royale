#class_name PacketBuffer extends RefCounted
#
#class TimestampedPacket:
	#var timestamp_us: int = 0
	#var packet: Variant = null
#
	#func _init(timestamp_us: int, packet: Variant) -> void:
		#self.timestamp_us = timestamp_us
		#self.packet = packet
#
#const MAX_BUFFER_SIZE := 8
#const MAX_DELAY_US := 150000
#const MIN_DELAY_US := 33000
#
#var _buffer: Array[TimestampedPacket] = []
#
#var buffer_delay_us: int = 0
#
#
#func append(timestamp_us: int, packet: Variant) -> void:
	#if _buffer.size() == 1:
		#var last_timestamp := _buffer[-1].timestamp_us
		#if timestamp_us <= last_timestamp:
			#return
#
	#_buffer.push_back(TimestampedPacket.new(timestamp_us, packet))
#
	#if _buffer.size() >= 2:
		#var delta := _buffer[-1].timestamp_us - _buffer[-2].timestamp_us
		#assert(delta > 0, "Delta is not positive")
		#buffer_delay_us = clamp(delta, MIN_DELAY_US, MAX_DELAY_US)
#
	#while _buffer.size() > MAX_BUFFER_SIZE:
		#_buffer.remove_at(0)
#
#
#func consume(now_us: int) -> Array[TimestampedPacket]:
	#if _buffer.size() < 2:
		#return _buffer
	#
	#var target_time := now_us - buffer_delay_us
#
	#while _buffer.size() >= 3 and target_time > _buffer[1].timestamp_us:
		#_buffer.remove_at(0)
#
	#return _buffer
