extends RefCounted

const PATH := "res://catalog/catalog.json"
static var version := ""
static var cards: Dictionary = {}
static var error_message := ""

static func load_catalog() -> bool:
	if not version.is_empty():
		return true
	if not FileAccess.file_exists(PATH):
		error_message = "Missing published card catalog."
		return false
	var data = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not data is Dictionary or int(data.get("schema", 0)) != 1 or not data.get("cards") is Array:
		error_message = "Unsupported card catalog schema."
		return false
	var normalized = JSON.parse_string(JSON.stringify(data.cards, "", true))
	var expected := JSON.stringify(normalized, "", true).sha256_text()
	if str(data.get("version", "")) != expected or data.cards.is_empty():
		error_message = "Invalid card catalog checksum or empty catalog."
		return false
	var indexed := {}
	for value in data.cards:
		if not value is Dictionary:
			error_message = "Invalid card record."
			return false
		var id := str(value.get("id", ""))
		if id.is_empty() or indexed.has(id):
			error_message = "Missing or duplicate card ID: " + id
			return false
		indexed[id] = {
			"card_id": id, "card_name": str(value.get("name", "")),
			"card_type": int(value.get("type", 0)), "mana_cost": int(value.get("mana", 0)),
			"attack": int(value.get("attack", 0)), "health": int(value.get("health", 1)),
			"show_artwork": bool(value.get("show_artwork", false)),
			"draftable": bool(value.get("draftable", true)), "is_coin": false,
			"description": str(value.get("description", "")), "tribe": str(value.get("tribe", "")),
			"effect_id": str(value.get("effect", "")),
			"effect_data": value.get("effect_data", {}).duplicate(true),
			"keywords": value.get("keywords", []).duplicate(),
		}
	cards = indexed
	version = expected
	return true

static func get_card(id: String) -> Dictionary:
	return cards.get(id, {}).duplicate(true)

static func validate_deck(records: Array) -> Dictionary:
	var clean: Array = []
	if records.size() < 5 or records.size() > 30:
		return {"error": "Your multiplayer deck must contain 5 to 30 cards.", "records": clean}
	for value in records:
		if not value is Dictionary or str(value.get("catalog_version", "")) != version or version.is_empty():
			return {"error": "Card catalog mismatch. Both players and the server need the same release.", "records": clean}
		var card := get_card(str(value.get("card_id", "")))
		if card.is_empty() or not bool(card.get("draftable", true)):
			return {"error": "Your deck contains an unknown or non-deckable card.", "records": clean}
		# Never accept gameplay definitions from a player.
		clean.append(card)
	return {"error": "", "records": clean}
