extends Node

signal remote_choice_finished(index: int)

const OPENING_HAND_SIZE := 5
const HAND_LIMIT := 10
const BOARD_LIMIT := 7
const MANA_CAP := 10
const STARTING_HEALTH := 30

var decks: Array = [[], []]
var hands: Array = [[], []]
var boards: Array = [[], []]
var hero_health: Array[int] = [STARTING_HEALTH, STARTING_HEALTH]
var max_mana: Array[int] = [0, 0]
var mana: Array[int] = [0, 0]
var spell_discount: Array[int] = [0, 0]
var fallen: Array = [[], []]
var discard_count := 0
var active_side := 0
var turn_number := 1
var side_zero_turns_started := 0
var game_over := false
var winner_side := -1
var next_network_id := 1
var ready_peers: Dictionary = {}
var pending_choice_token := 0
var pending_choice_peer := 0
var next_choice_token := 1


func _ready() -> void:
	if not NetworkSession.is_server():
		queue_free()
		return
	decks[0] = NetworkSession.deck_records_for_side(0)
	decks[1] = NetworkSession.deck_records_for_side(1)
	decks[0].shuffle()
	decks[1].shuffle()
	active_side = NetworkSession.first_side


@rpc("any_peer", "call_remote", "reliable")
func _network_client_game_ready() -> void:
	if not NetworkSession.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkSession.side_for_peer(sender) < 0:
		return
	ready_peers[sender] = true
	if ready_peers.size() >= 2 and hands[0].is_empty() and hands[1].is_empty():
		_start_match()


func _start_match() -> void:
	for side in [0, 1]:
		for i in range(OPENING_HAND_SIZE):
			if side != active_side and i == OPENING_HAND_SIZE - 1:
				_draw_card(side, _coin_record())
			else:
				_draw_card(side)

	max_mana[active_side] = 1
	mana[active_side] = 1
	max_mana[1 - active_side] = 0
	mana[1 - active_side] = 0
	side_zero_turns_started = 1 if active_side == 0 else 0
	turn_number = 1
	_broadcast_snapshot()


func _coin_record() -> Dictionary:
	return {
		"card_id": "",
		"card_name": "The Coin",
		"card_type": 1,
		"mana_cost": 0,
		"attack": 0,
		"health": 1,
		"show_artwork": false,
		"description": "+1 mana this turn.",
		"is_coin": true,
		"tribe": "",
		"effect_id": "",
		"effect_data": {},
		"keywords": [],
	}


func _new_card_state(definition: Dictionary) -> Dictionary:
	var keyword_value = definition.get("keywords", [])
	var keywords: Array = keyword_value if keyword_value is Array else []
	var attack := int(definition.get("attack", 0))
	var health := maxi(1, int(definition.get("health", 1)))
	var state := {
		"network_id": next_network_id,
		"definition": definition.duplicate(true),
		"current_attack": attack,
		"current_health": health,
		"max_health": health,
		"runtime_keywords": keywords.duplicate(),
		"divine_shield_active": keywords.has("divine_shield"),
		"stealth_active": keywords.has("stealth"),
		"summoned_this_turn": true,
		"attack_ready": false,
		"temporary_attack": 0,
		"attack_vulnerability": 0,
	}
	next_network_id += 1
	return state


func _draw_card(side: int, forced_definition: Dictionary = {}) -> void:
	var definition: Dictionary
	if not forced_definition.is_empty():
		definition = forced_definition.duplicate(true)
	else:
		if decks[side].is_empty():
			return
		var value = decks[side].pop_back()
		if not value is Dictionary:
			return
		definition = (value as Dictionary).duplicate(true)
	if hands[side].size() >= HAND_LIMIT:
		return
	hands[side].append(_new_card_state(definition))


func _card_cost(state: Dictionary, side: int) -> int:
	var definition: Dictionary = state.get("definition", {})
	var base := int(definition.get("mana_cost", 0))
	var is_spell := int(definition.get("card_type", 0)) == 1 or bool(definition.get("is_coin", false))
	return maxi(0, base - (spell_discount[side] if is_spell else 0))


func _find_card(cards: Array, network_id: int) -> Dictionary:
	for value in cards:
		if value is Dictionary and int(value.get("network_id", 0)) == network_id:
			return value
	return {}


func _find_card_index(cards: Array, network_id: int) -> int:
	for i in range(cards.size()):
		var value = cards[i]
		if value is Dictionary and int(value.get("network_id", 0)) == network_id:
			return i
	return -1


func _definition(state: Dictionary) -> Dictionary:
	var value = state.get("definition", {})
	return value if value is Dictionary else {}


func _is_spell(state: Dictionary) -> bool:
	var definition := _definition(state)
	return int(definition.get("card_type", 0)) == 1 or bool(definition.get("is_coin", false))


func _has_keyword(state: Dictionary, keyword: String) -> bool:
	var runtime = state.get("runtime_keywords", [])
	return runtime is Array and runtime.has(keyword)


func _visible_target(state: Dictionary) -> bool:
	return not bool(state.get("stealth_active", false))


func _taunts(side: int) -> Array:
	var result: Array = []
	for state in boards[side]:
		if state is Dictionary and int(state.get("current_health", 0)) > 0 and _visible_target(state) and _has_keyword(state, "taunt"):
			result.append(state)
	return result


@rpc("any_peer", "call_remote", "reliable")
func _request_network_end_turn() -> void:
	if game_over:
		return
	var side := NetworkSession.side_for_peer(multiplayer.get_remote_sender_id())
	if side < 0 or side != active_side:
		_broadcast_snapshot()
		return

	for state in boards[side]:
		if state is Dictionary:
			state["attack_ready"] = false
			state["current_attack"] = int(state.get("current_attack", 0)) - int(state.get("temporary_attack", 0))
			state["temporary_attack"] = 0
			state["attack_vulnerability"] = 0

	active_side = 1 - active_side
	max_mana[active_side] = mini(max_mana[active_side] + 1, MANA_CAP)
	mana[active_side] = max_mana[active_side]
	if active_side == 0:
		side_zero_turns_started += 1
		turn_number = maxi(1, side_zero_turns_started)
	if max_mana[active_side] > 1:
		_draw_card(active_side)
	for state in boards[active_side]:
		if state is Dictionary:
			state["summoned_this_turn"] = false
			state["attack_ready"] = int(state.get("current_attack", 0)) > 0
	_broadcast_snapshot()


@rpc("any_peer", "call_remote", "reliable")
func _request_network_play_card(network_id: int, insertion_index: int) -> void:
	if game_over:
		return
	var side := NetworkSession.side_for_peer(multiplayer.get_remote_sender_id())
	if side < 0 or side != active_side:
		_broadcast_snapshot()
		return
	var index := _find_card_index(hands[side], network_id)
	if index < 0:
		_broadcast_snapshot()
		return
	var state: Dictionary = hands[side][index]
	var cost := _card_cost(state, side)
	if cost > mana[side]:
		_broadcast_snapshot()
		return

	if _is_spell(state):
		var cancelled := await _resolve_spell(side, state)
		if cancelled:
			_broadcast_snapshot()
			return
		mana[side] -= cost
		spell_discount[side] = 0
		hands[side].remove_at(index)
		discard_count += 1
	else:
		if boards[side].size() >= BOARD_LIMIT:
			_broadcast_snapshot()
			return
		mana[side] -= cost
		hands[side].remove_at(index)
		state["summoned_this_turn"] = true
		state["attack_ready"] = false
		var insert_at := clampi(insertion_index, 0, boards[side].size())
		boards[side].insert(insert_at, state)
	_broadcast_snapshot()


func _resolve_spell(side: int, state: Dictionary) -> bool:
	var definition := _definition(state)
	if bool(definition.get("is_coin", false)):
		mana[side] = mini(MANA_CAP, mana[side] + 1)
		return false
	if str(definition.get("effect_id", "")) != "custom_spell":
		return false
	var data_value = definition.get("effect_data", {})
	var data: Dictionary = data_value if data_value is Dictionary else {}
	var effect_kind := str(data.get("effect", ""))
	var target_type := str(data.get("target", "none"))
	var target_side := side
	var candidates: Array = []
	if target_type == "friendly_minion":
		target_side = side
		candidates = boards[side].duplicate()
	elif target_type == "enemy_minion":
		target_side = 1 - side
		for candidate in boards[target_side]:
			if candidate is Dictionary and _visible_target(candidate):
				candidates.append(candidate)

	var target: Dictionary = {}
	if target_type != "none":
		if candidates.is_empty():
			return true
		var choice := await _request_remote_choice(side, str(definition.get("card_name", "Choose a target")), candidates, true)
		if choice < 0 or choice >= candidates.size():
			return true
		target = candidates[choice]

	var multiplier := _custom_spell_multiplier(side, target_type, target, str(data.get("scaling", "none")))
	match effect_kind:
		"buff":
			if target.is_empty():
				return true
			var atk := int(data.get("attack", 0)) * multiplier
			var hp := int(data.get("health", 0)) * multiplier
			target["current_attack"] = int(target.get("current_attack", 0)) + atk
			target["max_health"] = int(target.get("max_health", 1)) + hp
			target["current_health"] = int(target.get("current_health", 1)) + hp
		"damage":
			if target.is_empty():
				return true
			_take_damage(target, maxi(0, int(data.get("amount", 0)) * multiplier))
			_resolve_deaths(target_side)
		"heal":
			if target.is_empty():
				return true
			var amount := maxi(0, int(data.get("amount", 0)) * multiplier)
			target["current_health"] = mini(int(target.get("max_health", 1)), int(target.get("current_health", 1)) + amount)
		"draw":
			for i in range(maxi(0, int(data.get("amount", 0)))):
				_draw_card(side)
	return false


func _custom_spell_multiplier(side: int, target_type: String, target: Dictionary, scaling: String) -> int:
	match scaling:
		"other_friendly_minions":
			var count: int = boards[side].size()
			if target_type == "friendly_minion" and not target.is_empty():
				count -= 1
			return maxi(0, count)
		"friendly_minions":
			return boards[side].size()
		"enemy_minions":
			return boards[1 - side].size()
	return 1


func _request_remote_choice(side: int, prompt: String, options: Array, cancellable: bool) -> int:
	var peer_id := NetworkSession.peer_for_side(side)
	if peer_id <= 1:
		return -1
	var payload: Array = []
	for state in options:
		if state is Dictionary:
			payload.append({
				"definition": _definition(state).duplicate(true),
				"attack": int(state.get("current_attack", 0)),
				"health": int(state.get("current_health", 0)),
			})
	var token := next_choice_token
	next_choice_token += 1
	pending_choice_token = token
	pending_choice_peer = peer_id
	_show_network_choice.rpc_id(peer_id, token, prompt, payload, cancellable)
	var selected: int = await remote_choice_finished
	pending_choice_token = 0
	pending_choice_peer = 0
	return selected


@rpc("authority", "call_remote", "reliable")
func _show_network_choice(_token: int, _prompt: String, _options: Array, _cancellable: bool) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable")
func _submit_network_choice(token: int, index: int) -> void:
	if multiplayer.get_remote_sender_id() != pending_choice_peer or token != pending_choice_token:
		return
	remote_choice_finished.emit(index)


@rpc("any_peer", "call_remote", "reliable")
func _request_network_attack(source_id: int, target_id: int, target_is_hero: bool) -> void:
	if game_over:
		return
	var side := NetworkSession.side_for_peer(multiplayer.get_remote_sender_id())
	if side < 0 or side != active_side:
		_broadcast_snapshot()
		return
	var source := _find_card(boards[side], source_id)
	if source.is_empty() or not bool(source.get("attack_ready", false)) or int(source.get("current_health", 0)) <= 0 or int(source.get("current_attack", 0)) <= 0:
		_broadcast_snapshot()
		return

	var defender_side := 1 - side
	var taunts := _taunts(defender_side)
	if target_is_hero:
		if not taunts.is_empty() or bool(source.get("summoned_this_turn", true)):
			_broadcast_snapshot()
			return
		source["attack_ready"] = false
		source["stealth_active"] = false
		hero_health[defender_side] = maxi(0, hero_health[defender_side] - int(source.get("current_attack", 0)))
		if hero_health[defender_side] <= 0:
			game_over = true
			winner_side = side
		_broadcast_snapshot()
		return

	var target := _find_card(boards[defender_side], target_id)
	if target.is_empty() or int(target.get("current_health", 0)) <= 0 or not _visible_target(target):
		_broadcast_snapshot()
		return
	if not taunts.is_empty() and not _has_keyword(target, "taunt"):
		_broadcast_snapshot()
		return

	source["attack_ready"] = false
	source["stealth_active"] = false
	var outgoing := maxi(0, int(source.get("current_attack", 0))) + int(target.get("attack_vulnerability", 0))
	var incoming := maxi(0, int(target.get("current_attack", 0))) + int(source.get("attack_vulnerability", 0))
	_take_damage(target, outgoing)
	_take_damage(source, incoming)
	_resolve_deaths(side)
	_resolve_deaths(defender_side)
	_broadcast_snapshot()


func _take_damage(state: Dictionary, amount: int) -> void:
	if amount <= 0:
		return
	if bool(state.get("divine_shield_active", false)):
		state["divine_shield_active"] = false
		return
	state["current_health"] = int(state.get("current_health", 0)) - amount


func _resolve_deaths(side: int) -> void:
	for i in range(boards[side].size() - 1, -1, -1):
		var state = boards[side][i]
		if state is Dictionary and int(state.get("current_health", 0)) <= 0:
			fallen[side].append(_definition(state).duplicate(true))
			discard_count += 1
			boards[side].remove_at(i)


func _broadcast_snapshot() -> void:
	for side in [0, 1]:
		var peer_id := NetworkSession.peer_for_side(side)
		if peer_id > 1:
			_apply_network_snapshot.rpc_id(peer_id, _snapshot_for_side(side))


func _snapshot_for_side(side: int) -> Dictionary:
	return {
		"active_side": active_side,
		"turn_number": turn_number,
		"local_mana": mana[side],
		"local_max_mana": max_mana[side],
		"opponent_mana": mana[1 - side],
		"opponent_max_mana": max_mana[1 - side],
		"local_deck_count": decks[side].size(),
		"opponent_deck_count": decks[1 - side].size(),
		"local_hand": hands[side].duplicate(true),
		"opponent_hand_count": hands[1 - side].size(),
		"local_board": boards[side].duplicate(true),
		"opponent_board": boards[1 - side].duplicate(true),
		"local_hero_health": hero_health[side],
		"opponent_hero_health": hero_health[1 - side],
		"discard_count": discard_count,
		"spell_discount_local": spell_discount[side],
		"spell_discount_opponent": spell_discount[1 - side],
		"fallen_local": fallen[side].duplicate(true),
		"fallen_opponent": fallen[1 - side].duplicate(true),
		"game_over": game_over,
		"winner_side": winner_side,
	}


@rpc("authority", "call_remote", "reliable")
func _apply_network_snapshot(_snapshot: Dictionary) -> void:
	pass
