extends Node

signal remote_choice_finished(index: int)

const OPENING_HAND_SIZE := 5
const HAND_LIMIT := 10
const BOARD_LIMIT := 7
const MANA_CAP := 10
const STARTING_HEALTH := 30
const CUSTOM_MINION_EFFECT := "custom_minion"

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
var scheduled_summons: Array = [[], []]
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
	_resolve_scheduled_summons(active_side)
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
		var played_definition: Dictionary = _definition(state)
		if str(played_definition.get("effect_id", "")) == CUSTOM_MINION_EFFECT:
			await _resolve_custom_minion_trigger(side, state, "battlecry")
	_broadcast_snapshot()


func _custom_effects(data: Dictionary, default_trigger: String) -> Array:
	var result: Array = []
	var values = data.get("effects", [])
	if values is Array:
		for value in values:
			if value is Dictionary:
				var effect: Dictionary = (value as Dictionary).duplicate(true)
				if not effect.has("trigger"):
					effect["trigger"] = default_trigger
				result.append(effect)
	if result.is_empty() and not str(data.get("effect", "")).is_empty():
		var legacy: Dictionary = data.duplicate(true)
		legacy.erase("effects")
		if not legacy.has("trigger"):
			legacy["trigger"] = default_trigger
		result.append(legacy)
	return result


func _effects_for_trigger(definition: Dictionary, trigger: String) -> Array:
	var result: Array = []
	var data_value = definition.get("effect_data", {})
	var data: Dictionary = data_value if data_value is Dictionary else {}
	var default_trigger := "cast" if int(definition.get("card_type", 0)) == 1 else "battlecry"
	for value in _custom_effects(data, default_trigger):
		if value is Dictionary and str((value as Dictionary).get("trigger", default_trigger)) == trigger:
			result.append((value as Dictionary).duplicate(true))
	return result


func _passes_state_filter(state: Dictionary, data: Dictionary) -> bool:
	var stat := str(data.get("filter_stat", "none"))
	if stat == "none":
		return true

	var value: int = int(state.get("current_attack", 0)) if stat == "attack" else int(state.get("current_health", 0))
	var threshold := int(data.get("filter_value", 0))
	match str(data.get("filter_compare", "less_than")):
		"less_than": return value < threshold
		"at_most": return value <= threshold
		"equal": return value == threshold
		"at_least": return value >= threshold
		"greater_than": return value > threshold
	return true


func _target_states(side: int, source_state: Dictionary, data: Dictionary) -> Array:
	var target_type := str(data.get("target", "none"))
	var candidates: Array = []

	match target_type:
		"friendly_minion", "all_friendly_minions":
			candidates = boards[side].duplicate()
		"all_other_friendly_minions":
			for value in boards[side]:
				if value is Dictionary:
					var candidate: Dictionary = value as Dictionary
					if int(candidate.get("network_id", 0)) != int(source_state.get("network_id", -1)):
						candidates.append(candidate)
		"enemy_minion":
			for value in boards[1 - side]:
				if value is Dictionary:
					var candidate: Dictionary = value as Dictionary
					if _visible_target(candidate):
						candidates.append(candidate)
		"all_enemy_minions":
			candidates = boards[1 - side].duplicate()
		"self":
			if not source_state.is_empty():
				candidates = [source_state]
		_:
			return []

	var filtered: Array = []
	for value in candidates:
		if value is Dictionary:
			var candidate: Dictionary = value as Dictionary
			if int(candidate.get("current_health", 0)) > 0 and _passes_state_filter(candidate, data):
				filtered.append(candidate)
	return filtered


func _target_uses_choice(target_type: String) -> bool:
	return target_type in ["friendly_minion", "enemy_minion"]


func _grant_state_keyword(state: Dictionary, keyword: String) -> void:
	var normalized := keyword.strip_edges().to_lower()
	if normalized.is_empty():
		return

	var runtime_value = state.get("runtime_keywords", [])
	var runtime: Array = runtime_value if runtime_value is Array else []
	if not runtime.has(normalized):
		runtime.append(normalized)
	state["runtime_keywords"] = runtime

	if normalized == "divine_shield":
		state["divine_shield_active"] = true
	elif normalized == "stealth":
		state["stealth_active"] = true


func _custom_effect_multiplier(side: int, scaling: String) -> int:
	match scaling:
		"other_friendly_minions":
			return maxi(0, boards[side].size() - 1)
		"friendly_minions":
			return boards[side].size()
		"enemy_minions":
			return boards[1 - side].size()
	return 1


func _apply_state_keyword_modifier(state: Dictionary, data: Dictionary) -> void:
	var keyword := str(data.get("keyword", ""))
	if not keyword.is_empty() and int(state.get("current_health", 0)) > 0:
		_grant_state_keyword(state, keyword)


func _apply_custom_effect(side: int, data: Dictionary, targets: Array) -> void:
	var effect_kind := str(data.get("effect", ""))
	var multiplier: int = _custom_effect_multiplier(side, str(data.get("scaling", "none")))

	match effect_kind:
		"buff":
			for value in targets:
				if value is Dictionary:
					var target: Dictionary = value as Dictionary
					var atk := int(data.get("attack", 0)) * multiplier
					var hp := int(data.get("health", 0)) * multiplier
					target["current_attack"] = int(target.get("current_attack", 0)) + atk
					target["max_health"] = int(target.get("max_health", 1)) + hp
					target["current_health"] = int(target.get("current_health", 1)) + hp
					_apply_state_keyword_modifier(target, data)
			await _resolve_deaths(side)
			await _resolve_deaths(1 - side)

		"set_stats":
			for value in targets:
				if value is Dictionary:
					var target: Dictionary = value as Dictionary
					target["current_attack"] = int(data.get("attack", 0))
					target["max_health"] = maxi(1, int(data.get("health", 1)))
					target["current_health"] = target["max_health"]
					target["temporary_attack"] = 0
					_apply_state_keyword_modifier(target, data)

		"keyword":
			for value in targets:
				if value is Dictionary:
					_apply_state_keyword_modifier(value as Dictionary, data)

		"damage":
			var amount := maxi(0, int(data.get("amount", 0)) * multiplier)
			for value in targets:
				if value is Dictionary:
					_take_damage(value as Dictionary, amount)
			await _resolve_deaths(side)
			await _resolve_deaths(1 - side)

		"heal":
			var amount := maxi(0, int(data.get("amount", 0)) * multiplier)
			for value in targets:
				if value is Dictionary:
					var target: Dictionary = value as Dictionary
					target["current_health"] = mini(
						int(target.get("max_health", 1)),
						int(target.get("current_health", 1)) + amount
					)

		"draw":
			for i in range(maxi(0, int(data.get("amount", 0)))):
				_draw_card(side)

		"summon":
			if str(data.get("timing", "immediate")) == "start_next_turn":
				scheduled_summons[side].append(data.duplicate(true))
			else:
				_summon_from_effect(side, data)


func _resolve_custom_minion_trigger(side: int, state: Dictionary, trigger: String) -> void:
	var definition: Dictionary = _definition(state)
	for value in _effects_for_trigger(definition, trigger):
		if not value is Dictionary:
			continue
		var data: Dictionary = value as Dictionary
		var target_type := str(data.get("target", "none"))
		var targets: Array = []
		if target_type != "none":
			var candidates: Array = _target_states(side, state, data)
			if _target_uses_choice(target_type):
				if candidates.is_empty():
					continue
				var choice: int = await _request_remote_choice(
					side,
					str(definition.get("card_name", "Choose a target")),
					candidates,
					false
				)
				if choice < 0 or choice >= candidates.size():
					continue
				targets = [candidates[choice]]
			else:
				targets = candidates
		await _apply_custom_effect(side, data, targets)


func _resolve_spell(side: int, state: Dictionary) -> bool:
	var definition: Dictionary = _definition(state)
	if bool(definition.get("is_coin", false)):
		mana[side] = mini(MANA_CAP, mana[side] + 1)
		return false
	if str(definition.get("effect_id", "")) != "custom_spell":
		return false

	var effects: Array = _effects_for_trigger(definition, "cast")
	if effects.is_empty():
		return false

	var target_sets: Array = []
	for value in effects:
		if not value is Dictionary:
			target_sets.append([])
			continue
		var data: Dictionary = value as Dictionary
		var target_type := str(data.get("target", "none"))
		if target_type == "none":
			target_sets.append([])
			continue
		var candidates: Array = _target_states(side, {}, data)
		if _target_uses_choice(target_type):
			if candidates.is_empty():
				return true
			var choice: int = await _request_remote_choice(
				side,
				str(definition.get("card_name", "Choose a target")),
				candidates,
				true
			)
			if choice < 0 or choice >= candidates.size():
				return true
			target_sets.append([candidates[choice]])
		else:
			target_sets.append(candidates)

	for i in range(effects.size()):
		if not effects[i] is Dictionary:
			continue
		var targets: Array = []
		if i < target_sets.size() and target_sets[i] is Array:
			targets = target_sets[i] as Array
		await _apply_custom_effect(side, effects[i] as Dictionary, targets)
	return false


func _summon_definition(effect_data: Dictionary) -> Dictionary:
	var record_value = effect_data.get("summon_card", {})
	if record_value is Dictionary and not (record_value as Dictionary).is_empty():
		return (record_value as Dictionary).duplicate(true)

	var summon_id := str(effect_data.get("summon_card_id", ""))
	if summon_id.is_empty():
		return {}

	for side in [0, 1]:
		for definition_value in decks[side]:
			if definition_value is Dictionary and str(definition_value.get("card_id", "")) == summon_id:
				return (definition_value as Dictionary).duplicate(true)
		for state_value in hands[side]:
			if state_value is Dictionary:
				var definition: Dictionary = _definition(state_value as Dictionary)
				if str(definition.get("card_id", "")) == summon_id:
					return definition.duplicate(true)
		for state_value in boards[side]:
			if state_value is Dictionary:
				var definition: Dictionary = _definition(state_value as Dictionary)
				if str(definition.get("card_id", "")) == summon_id:
					return definition.duplicate(true)
	return {}


func _summon_from_effect(side: int, effect_data: Dictionary) -> void:
	if side < 0 or side > 1:
		return
	var definition: Dictionary = _summon_definition(effect_data)
	if definition.is_empty() or int(definition.get("card_type", 0)) == 1:
		return
	var count: int = clampi(int(effect_data.get("summon_count", 1)), 1, BOARD_LIMIT)
	for i in range(count):
		if boards[side].size() >= BOARD_LIMIT:
			break
		boards[side].append(_new_card_state(definition))


func _resolve_scheduled_summons(side: int) -> void:
	if side < 0 or side > 1:
		return
	var pending: Array = scheduled_summons[side].duplicate(true)
	scheduled_summons[side].clear()
	for value in pending:
		if value is Dictionary:
			_summon_from_effect(side, value as Dictionary)


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
	await _resolve_deaths(side)
	await _resolve_deaths(defender_side)
	_broadcast_snapshot()


func _take_damage(state: Dictionary, amount: int) -> void:
	if amount <= 0:
		return
	if bool(state.get("divine_shield_active", false)):
		state["divine_shield_active"] = false
		return
	state["current_health"] = int(state.get("current_health", 0)) - amount


func _resolve_deaths(side: int) -> void:
	var dead: Array = []
	for i in range(boards[side].size() - 1, -1, -1):
		var state = boards[side][i]
		if state is Dictionary and int(state.get("current_health", 0)) <= 0:
			dead.append(state)
			fallen[side].append(_definition(state).duplicate(true))
			discard_count += 1
			boards[side].remove_at(i)

	for value in dead:
		if not value is Dictionary:
			continue
		var state: Dictionary = value as Dictionary
		var definition: Dictionary = _definition(state)
		if str(definition.get("effect_id", "")) == CUSTOM_MINION_EFFECT:
			await _resolve_custom_minion_trigger(side, state, "deathrattle")


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
