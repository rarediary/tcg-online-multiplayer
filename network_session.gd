extends Node

signal session_ended(message: String)

enum Mode { OFFLINE, CLIENT, SERVER }

const DEFAULT_SERVER_PORT := 10000
const GAME_SCENE := "res://server_game.tscn"

var mode: Mode = Mode.OFFLINE
var first_side := 0
var match_loading := false
var side_peers: Array[int] = [0, 0]
var side_deck_records: Array = [[], []]
var peer_sides: Dictionary = {}
var _server_resetting := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	var error := start_dedicated_server(_server_port_from_environment())
	if error != OK:
		push_error("Could not start dedicated multiplayer server: %s" % error_string(error))
		get_tree().quit(1)


func _server_port_from_environment() -> int:
	var value := OS.get_environment("PORT").strip_edges()
	if value.is_valid_int():
		return clampi(int(value), 1024, 65535)
	return DEFAULT_SERVER_PORT


func is_active() -> bool:
	return mode != Mode.OFFLINE and multiplayer.multiplayer_peer != null


func is_server() -> bool:
	return mode == Mode.SERVER and multiplayer.is_server()


func is_client() -> bool:
	return false


func start_dedicated_server(port: int = DEFAULT_SERVER_PORT) -> Error:
	_reset_server_match_state()
	var peer := WebSocketMultiplayerPeer.new()
	var error := peer.create_server(port, "0.0.0.0")
	if error != OK:
		return error
	mode = Mode.SERVER
	multiplayer.multiplayer_peer = peer
	print("TCG dedicated WebSocket server listening on 0.0.0.0:%d" % port)
	return OK


func peer_for_side(side: int) -> int:
	if side < 0 or side > 1:
		return 0
	return side_peers[side]


func side_for_peer(peer_id: int) -> int:
	return int(peer_sides.get(peer_id, -1))


func has_both_players() -> bool:
	return side_peers[0] > 1 and side_peers[1] > 1


func deck_records_for_side(side: int) -> Array:
	if side < 0 or side > 1:
		return []
	return (side_deck_records[side] as Array).duplicate(true)


func _on_peer_connected(id: int) -> void:
	print("Player peer %d connected." % id)


func _on_peer_disconnected(id: int) -> void:
	if _server_resetting or not peer_sides.has(id):
		return
	var disconnected_side := side_for_peer(id)
	print("Player peer %d (side %d) disconnected." % [id, disconnected_side])
	if match_loading or _server_is_in_game_scene():
		_server_abort_match("The other player disconnected.", id)
	else:
		_clear_server_side(disconnected_side)


@rpc("any_peer", "call_remote", "unreliable")
func _keepalive() -> void:
	pass


@rpc("any_peer", "call_remote", "reliable")
func _submit_client_deck(records: Array) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		return
	if match_loading:
		_reject_match.rpc_id(sender, "A match is already in progress. Try again shortly.")
		return

	var clean_records: Array = []
	for value in records:
		if value is Dictionary:
			var record := (value as Dictionary).duplicate(true)
			if str(record.get("card_name", "")).is_empty():
				continue
			clean_records.append(record)
			if clean_records.size() >= 30:
				break
	if clean_records.size() < 5:
		_reject_match.rpc_id(sender, "Your deck has fewer than 5 cards.")
		return

	var side := side_for_peer(sender)
	if side < 0:
		side = 0 if side_peers[0] == 0 else (1 if side_peers[1] == 0 else -1)
	if side < 0:
		_reject_match.rpc_id(sender, "This server already has two players.")
		return

	side_peers[side] = sender
	peer_sides[sender] = side
	side_deck_records[side] = clean_records
	_assign_side.rpc_id(sender, side)

	if not has_both_players():
		_lobby_status.rpc_id(sender, "Connected. Waiting for another player...")
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	first_side = rng.randi_range(0, 1)
	match_loading = true
	for peer_id in side_peers:
		if peer_id > 1:
			_lobby_status.rpc_id(peer_id, "Opponent found. Starting match...")
	_begin_match.rpc_id(side_peers[0], first_side, side_peers[0], side_peers[1])
	_begin_match.rpc_id(side_peers[1], first_side, side_peers[0], side_peers[1])
	var error := get_tree().change_scene_to_file(GAME_SCENE)
	if error != OK:
		push_error("Could not open dedicated server game scene: %s" % error_string(error))
		_server_abort_match("The match server could not start the game.")


@rpc("authority", "call_remote", "reliable")
func _assign_side(_side: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func _lobby_status(_message: String) -> void:
	pass


@rpc("authority", "call_local", "reliable")
func _begin_match(_starting_side: int, _side_zero_peer: int, _side_one_peer: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func _reject_match(_message: String) -> void:
	pass


@rpc("authority", "call_remote", "reliable")
func _server_session_ended(_message: String) -> void:
	pass


func reset_after_match(message: String = "Match ended.") -> void:
	if not is_server() or _server_resetting:
		return
	_server_resetting = true
	for peer_id in side_peers:
		if peer_id > 1:
			_server_session_ended.rpc_id(peer_id, message)
	_reset_server_match_state()
	_server_resetting = false


func _server_abort_match(message: String, disconnected_peer: int = 0) -> void:
	if not is_server() or _server_resetting:
		return
	_server_resetting = true
	for peer_id in side_peers:
		if peer_id > 1 and peer_id != disconnected_peer:
			_server_session_ended.rpc_id(peer_id, message)
	_reset_server_match_state()
	_server_resetting = false
	if _server_is_in_game_scene():
		get_tree().change_scene_to_file(GAME_SCENE)


func _reset_server_match_state() -> void:
	side_peers = [0, 0]
	side_deck_records = [[], []]
	peer_sides.clear()
	first_side = 0
	match_loading = false


func _clear_server_side(side: int) -> void:
	if side < 0 or side > 1:
		return
	var peer_id := side_peers[side]
	if peer_id > 1:
		peer_sides.erase(peer_id)
	side_peers[side] = 0
	side_deck_records[side] = []


func _server_is_in_game_scene() -> bool:
	return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == GAME_SCENE
