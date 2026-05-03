@tool
class_name GameManifestExporter
extends RefCounted

const OUTPUT_PATH := "res://exports/gameManifest.json"


static func export_manifest() -> void:
	# Make sure registry is fully loaded
	HumanizerRegistry.load_all()

	var manifest := {
		"version": _read_version(),
		"generatedAt": Time.get_datetime_string_from_system(),
		"equipment": _export_equipment(),
		"featurePresets": _export_feature_presets(),
		"overlays": _export_overlays(),
		"shapekeys": _export_shapekeys(),
		"slots": _collect_equipment_slots(),
		"featureSlots": _collect_feature_slots(),
		"colorNames": ["Skin", "Hair", "Eyes", "Eyebrows"],
	}

	var dir_path := OUTPUT_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var json_string := JSON.stringify(manifest, "\t", false)
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("GameManifestExporter: Failed to open %s for writing" % OUTPUT_PATH)
		return

	file.store_string(json_string)
	file.close()

	# Print summary
	var equip_count = manifest["equipment"].size()
	var preset_count = manifest["featurePresets"].size()
	var overlay_count = manifest["overlays"].size()
	var shapekey_count = manifest["shapekeys"].size()
	var slot_count = manifest["slots"].size()

	print("GameManifestExporter: Exported to %s" % OUTPUT_PATH)
	print("  Version: %s" % manifest["version"])
	print("  Equipment: %d" % equip_count)
	print("  Feature Presets: %d" % preset_count)
	print("  Overlays: %d" % overlay_count)
	print("  Shapekeys: %d" % shapekey_count)
	print("  Slots: %d" % slot_count)


# Reads version from a dedicated file so you can bump it independently.
# Falls back to "0.0.0" if the file doesn't exist yet.
static func _read_version() -> String:
	var version_path := "res://exports/manifest_version.txt"
	if FileAccess.file_exists(version_path):
		var file := FileAccess.open(version_path, FileAccess.READ)
		var version := file.get_as_text().strip_edges()
		file.close()
		return version
	return "0.0.0"


# Equipment

static func _export_equipment() -> Dictionary:
	var result := {}

	for equip_name in HumanizerRegistry.equipment:
		var equip: HumanizerEquipmentType = HumanizerRegistry.equipment[equip_name]

		# Collect valid material names from the textures dictionary
		# Build materials with per-material unlock status
		var materials := {}
		if equip.textures != null:
			var locked_mats: PackedStringArray = equip.get("locked_materials") if equip.get("locked_materials") != null else PackedStringArray()
			for mat_name in equip.textures:
				var is_locked = mat_name in locked_mats
				materials[mat_name] = {
					"defaultUnlocked": not is_locked,
				}


		# Collect overlay IDs attached to this equipment
		var overlay_ids := []
		if equip.overlays != null:
			for overlay_id in equip.overlays:
				overlay_ids.append(overlay_id)

		# Normalize gender to array
		var gender_tags := _normalize_gender(equip.gender)

		result[equip_name] = {
			"slots": equip.slots,
			"gender": gender_tags,
			"materials": materials,
			"overlayIds": overlay_ids,
			"defaultUnlocked": equip.default_unlocked,
		}

	return result


# Feature Presets

static func _export_feature_presets() -> Dictionary:
	var result := {}

	for preset_id in HumanizerRegistry.target_presets:
		var preset: TargetPreset = HumanizerRegistry.target_presets[preset_id]

		var gender_tags := _normalize_gender(preset.gender)

		var overlay_ids := []
		if preset.overlays != null:
			for overlay_name in preset.overlays:
				overlay_ids.append(overlay_name)

		# Export the target shapekey values this preset sets
		var targets := {}
		if preset.targets != null:
			for key in preset.targets:
				if preset.targets[key] > 0.0:
					targets[key] = preset.targets[key]

		result[preset_id] = {
			"slot": preset.slot,
			"gender": gender_tags,
			"overlays": overlay_ids,
			"targets": targets,
		}

	return result


# Overlays

static func _export_overlays() -> Dictionary:
	var result := {}

	# Overlays are attached per-equipment-type.
	# Walk all equipment and collect unique overlays.
	for equip_name in HumanizerRegistry.equipment:
		var equip: HumanizerEquipmentType = HumanizerRegistry.equipment[equip_name]
		if equip.overlays == null:
			continue

		for overlay_id in equip.overlays:

			# Skip if already exported
			if result.has(overlay_id):
				continue

			var gender_tags := _normalize_gender(equip.gender)
			var slot := equip.slots[0] if equip.slots.size() > 0 else "Body"

			result[overlay_id] = {
				"slot": slot,
				"gender": gender_tags,
				"equipmentSource": equip_name,
			}

	# Also collect overlays referenced by feature presets
	for preset_id in HumanizerRegistry.target_presets:
		var preset: TargetPreset = HumanizerRegistry.target_presets[preset_id]
		if preset.overlays == null:
			continue

		for overlay in preset.overlays:
			if result.has(overlay):
				continue

			var gender_tags := _normalize_gender(preset.gender)

			result[overlay] = {
				"slot": "Body",
				"gender": gender_tags,
				"presetSource": preset_id,
			}

	return result


# Shapekeys

static func _export_shapekeys() -> Dictionary:
	var result := {}

	# Collect every shapekey name referenced across all feature presets.
	# This gives us the full set of valid target names.
	var all_keys := {}

	for preset_id in HumanizerRegistry.target_presets:
		var preset: TargetPreset = HumanizerRegistry.target_presets[preset_id]
		if preset.targets == null:
			continue
		for key in preset.targets:
			all_keys[key] = true

	# Also load a default config to pick up shapekeys that aren't
	# in any preset but are still valid (height, weight, muscle, gender, etc.)
	var default_configs := [
		"res://resources/data/default_male_recipe.json",
		"res://resources/data/default_female_recipe.json",
	]

	for config_path in default_configs:
		if not FileAccess.file_exists(config_path):
			continue
		var text := FileAccess.open(config_path, FileAccess.READ).get_as_text()
		var data = JSON.parse_string(text)
		if data != null and typeof(data) == TYPE_DICTIONARY and data.has("shapekeys"):
			for key in data["shapekeys"]:
				all_keys[key] = true

	# Build the shapekey entries with reasonable default ranges.
	# Most shapekeys operate in [0.0, 1.0], but some computed macro
	# targets can go slightly negative or above 1.0.
	for key in all_keys:
		var min_val := 0.0
		var max_val := 1.0
		
		if key == "height":
			min_val = 0.4
			max_val = 0.55
		elif key == "weight":
			min_val = 0.3
			max_val = 0.6

		result[key] = {
			"min": min_val,
			"max": max_val,
		}

	return result


# Slots

static func _collect_equipment_slots() -> Array:
	var slots := {}
	for equip_name in HumanizerRegistry.equipment:
		var equip: HumanizerEquipmentType = HumanizerRegistry.equipment[equip_name]
		for slot in equip.slots:
			slots[slot] = true
	return slots.keys()


static func _collect_feature_slots() -> Array:
	var slots := {}
	for preset_id in HumanizerRegistry.target_presets:
		var preset: TargetPreset = HumanizerRegistry.target_presets[preset_id]
		slots[preset.slot] = true
	return slots.keys()


# ── Helpers ──────────────────────────────────────────────────────────────

static func _normalize_gender(gender_value) -> Array:
	if gender_value == null:
		return ["male", "female"]
	var gender_string := str(gender_value).to_lower()
	match gender_string:
		"male":
			return ["male"]
		"female":
			return ["female"]
		"general", "":
			return ["general"]
		_:
			return ["general"]
