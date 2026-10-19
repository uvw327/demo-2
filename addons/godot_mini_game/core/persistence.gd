@tool
extends RefCounted
## Persists the MiniGameExport Dock UI state in a project-local file so that
## opening the editor a second time does not require re-entering App ID,
## platform, orientation, preset, output directory, and timeout.
##
## The state file lives at `res://.minigame/export.cfg`. A sibling
## `.gdignore` keeps the Godot importer and the Web/pck exporter from
## treating it as project resources, so it never lands inside an exported
## game. The live file is project-local by default (see the project
## `.gitignore`); only `.gdignore` and `export.cfg.example` are tracked. Copy
## the example and commit it if a team wants to share AppID, platform,
## preset, and output directory.
##
## Failure-open policy: a missing or unreadable file returns an empty state;
## a write failure pushes a warning but never blocks an export. UI
## preferences are an experience concern, not a security boundary, so the
## module never rejects an export over a persistence error.
##
## This file is intentionally versionless: `ConfigFile` tolerates missing or
## extra keys, and every field is re-validated against live project data
## (preset names, output-dir safety) on load. That avoids adding a fifth
## version axis to the project.
##
## All state is held in `static var` so the `static func` helpers can read
## and write it without needing a live instance. The Dock script reaches
## these functions through a `const` preload, the same pattern used by
## `exporter.gd` for `OutputGuard`.

const CONFIG_DIR := "res://.minigame"
const CONFIG_FILE := "res://.minigame/export.cfg"
const EXAMPLE_FILE := "res://.minigame/export.cfg.example"

## Test/CI seam: when set, the load/save/ensure functions use these paths
## instead of the `res://.minigame/` defaults, so a test can point the
## persistence module at a temporary directory. Empty by default, which
## keeps production behavior unchanged.
static var _override_config_dir := ""
static var _override_config_file := ""

## Last load error message; empty when the last load succeeded or the file
## did not exist. Read by the Dock to surface a yellow warning.
static var load_error := ""

const SECTION := "export"

const KEY_PLATFORM := "platform"
const KEY_APPID := "appid"
const KEY_ORIENTATION := "orientation"
const KEY_PRESET := "preset"
const KEY_OUTPUT_DIR := "output_dir"
const KEY_TIMEOUT := "timeout_seconds"

## Defaults mirror `export_dock.tscn` / `export_dock.gd` so a fresh project
## behaves exactly as it did before persistence existed.
const DEFAULT_TIMEOUT_SECONDS := 600.0
const SUPPORTED_PLATFORMS: PackedStringArray = ["wechat", "douyin", "tiktok"]
const SUPPORTED_ORIENTATIONS: PackedStringArray = ["portrait", "landscape"]


## Reads and normalizes the persisted state. The returned dictionary always
## contains every field; entries that are missing, empty, or invalid fall
## back to their default. `output_dir` is returned as a **project-relative**
## path when possible; callers that need an absolute path should resolve it
## with `resolve_output_dir()` and re-validate with `Exporter`.
static func load_project_state() -> Dictionary:
	var state := _defaults()
	load_error = ""
	var config_file := _resolve_config_file()
	if not FileAccess.file_exists(config_file):
		return state
	var file := ConfigFile.new()
	var err := file.load(config_file)
	if err != OK:
		load_error = "cannot read %s: %s" % [config_file, error_string(err)]
		push_warning("Godot Mini Game: %s" % load_error)
		return state

	var platform_value: Variant = file.get_value(SECTION, KEY_PLATFORM, "")
	var appid_value: Variant = file.get_value(SECTION, KEY_APPID, "")
	var orientation_value: Variant = file.get_value(SECTION, KEY_ORIENTATION, "")
	var preset_value: Variant = file.get_value(SECTION, KEY_PRESET, "")
	var output_dir_value: Variant = file.get_value(SECTION, KEY_OUTPUT_DIR, "")
	var timeout_value: Variant = file.get_value(SECTION, KEY_TIMEOUT, DEFAULT_TIMEOUT_SECONDS)

	state.platform = str(platform_value) if _is_known_platform(platform_value) else state.platform
	state.appid = str(appid_value).strip_edges()
	state.orientation = str(orientation_value) if _is_known_orientation(orientation_value) else state.orientation
	state.preset = str(preset_value).strip_edges()
	state.output_dir = str(output_dir_value).strip_edges()
	state.timeout_seconds = _normalize_timeout(timeout_value)
	return state


## Resolves the persisted `output_dir` field to an absolute path. A value
## that is already absolute is returned as-is; a project-relative value is
## joined against `project_root`. The stored relative form uses forward
## slashes (the separator Godot's path APIs use on every platform), so it
## resolves cleanly without any per-platform re-mangling. The caller is
## expected to re-validate the result with `OutputGuard.inspect` before
## handing it to the exporter.
static func resolve_output_dir(persisted_value: String, project_root: String) -> String:
	var text := persisted_value.strip_edges()
	if text.is_empty():
		return ""
	if text.is_absolute_path():
		return text.simplify_path()
	if project_root.is_empty():
		return ""
	return project_root.simplify_path().path_join(_to_unix(text))


## Writes the dock state to disk. Safe to call after a successful export or
## whenever the UI changes. A write failure is reported but does not raise.
##
## `state` may contain extra keys; only the six known fields are written.
## `output_dir` is expected to be **project-relative** when it lies outside
## the project root; callers should normalize before saving.
static func save_project_state(state: Dictionary) -> Error:
	var cfg := ConfigFile.new()
	var write_err: Error = OK
	write_err = _set_value(cfg, KEY_PLATFORM, _as_string(state.get(KEY_PLATFORM, "")))
	if write_err != OK:
		return write_err
	write_err = _set_value(cfg, KEY_APPID, _as_string(state.get(KEY_APPID, "")))
	if write_err != OK:
		return write_err
	write_err = _set_value(cfg, KEY_ORIENTATION, _as_string(state.get(KEY_ORIENTATION, "")))
	if write_err != OK:
		return write_err
	write_err = _set_value(cfg, KEY_PRESET, _as_string(state.get(KEY_PRESET, "")))
	if write_err != OK:
		return write_err
	write_err = _set_value(cfg, KEY_OUTPUT_DIR, _as_string(state.get(KEY_OUTPUT_DIR, "")))
	if write_err != OK:
		return write_err
	write_err = _set_value(cfg, KEY_TIMEOUT, _normalize_timeout(state.get(KEY_TIMEOUT, DEFAULT_TIMEOUT_SECONDS)))
	if write_err != OK:
		return write_err
	var config_file := _resolve_config_file()
	# `ConfigFile.save` opens the target for writing; it does not create missing
	# parent folders. A brand-new project, or one whose `.minigame/` folder was
	# deleted by hand, therefore needs the directory created first. The call is
	# a no-op when the folder already exists.
	DirAccess.make_dir_recursive_absolute(config_file.get_base_dir())
	var save_err := cfg.save(config_file)
	if save_err != OK:
		push_warning("Godot Mini Game: cannot write %s: %s" % [config_file, error_string(save_err)])
	return save_err


## Normalizes an output path for storage in the config file.
##
## - If the path is inside the project root it is returned as a
##   project-relative path (portable across machines).
## - If the path is outside the project root it is returned as an absolute
##   path (faithful to the user's original selection).
##
## `OutputGuard` rejects output directories inside the project, so in
## practice the persisted value is almost always an absolute path; the
## project-relative form exists only for the rare case where a user keeps
## output inside the project tree and disables the guard.
static func relativize_output_dir(absolute_path: String, project_root: String) -> String:
	var candidate := absolute_path.strip_edges()
	if candidate.is_empty() or project_root.strip_edges().is_empty():
		return candidate
	var norm_candidate := _to_unix(candidate.simplify_path())
	var project := _to_unix(project_root.simplify_path())
	if norm_candidate.begins_with(project + "/"):
		return norm_candidate.trim_prefix(project + "/")
	return absolute_path.strip_edges()


## Creates `.minigame/.gdignore` and `.minigame/export.cfg.example` if they
## are missing. Call this from `export_dock.gd::_ready()` so a fresh
## project does not have to create them by hand.
static func ensure_project_files() -> void:
	var config_dir := _resolve_config_dir()
	var example_file := _resolve_example_file()
	DirAccess.make_dir_recursive_absolute(config_dir)
	if not FileAccess.file_exists(config_dir.path_join(".gdignore")):
		var gdignore := FileAccess.open(config_dir.path_join(".gdignore"), FileAccess.WRITE)
		if gdignore:
			gdignore.store_string(
				"Keep Godot's importer and exporter away from the plugin's persistent export config.\n"
			)
			gdignore.close()
	if not FileAccess.file_exists(example_file):
		var example := FileAccess.open(example_file, FileAccess.WRITE)
		if example:
			example.store_string(
				"; Godot Mini Game export configuration example\n"
				+ "; Copy to `.minigame/export.cfg` to persist dock settings.\n\n"
				+ "[export]\n"
				+ "platform=\"\"\nappid=\"\"\norientation=\"\"\npreset=\"\"\noutput_dir=\"\"\ntimeout_seconds=600.0\n"
			)
			example.close()


## Sets the file paths used by load/save/ensure. Call from tests to point
## the module at a temporary directory; pass two empty strings to restore
## the default `res://.minigame/` locations.
static func set_test_paths(config_dir: String, config_file: String) -> void:
	_override_config_dir = config_dir.strip_edges()
	_override_config_file = config_file.strip_edges()


static func _resolve_config_dir() -> String:
	return _override_config_dir if not _override_config_dir.is_empty() else CONFIG_DIR


static func _resolve_config_file() -> String:
	return _override_config_file if not _override_config_file.is_empty() else CONFIG_FILE


static func _resolve_example_file() -> String:
	return (
		_resolve_config_dir().path_join("export.cfg.example")
		if not _override_config_dir.is_empty()
		else EXAMPLE_FILE
	)


static func _defaults() -> Dictionary:
	return {
		KEY_PLATFORM: "",
		KEY_APPID: "",
		KEY_ORIENTATION: "",
		KEY_PRESET: "",
		KEY_OUTPUT_DIR: "",
		KEY_TIMEOUT: DEFAULT_TIMEOUT_SECONDS,
	}


static func _as_string(value: Variant) -> String:
	return "" if value == null else str(value)


static func _normalize_timeout(value: Variant) -> float:
	var result := float(value) if value is int or value is float else DEFAULT_TIMEOUT_SECONDS
	return result if is_finite(result) and result > 0.0 else DEFAULT_TIMEOUT_SECONDS


static func _is_known_platform(value: Variant) -> bool:
	var text := _as_string(value)
	return text in SUPPORTED_PLATFORMS


static func _is_known_orientation(value: Variant) -> bool:
	var text := _as_string(value)
	return text in SUPPORTED_ORIENTATIONS


static func _set_value(cfg: ConfigFile, key: String, value: Variant) -> Error:
	cfg.set_value(SECTION, key, value)
	return OK


## Path helpers ────────────────────────────────────────────────────────
##
## `relativize_output_dir` and `resolve_output_dir` exchange a
## project-relative form that always uses forward slashes so the config
## file stays portable regardless of which platform wrote it. Forward
## slashes are the separator Godot's path APIs (`path_join`,
## `simplify_path`, `FileAccess`, `DirAccess`) understand on every
## platform, including Windows, so the only conversion needed is
## backslash → forward slash when normalizing input that may have come
## from a Windows-only API.


## Returns a forward-slash form of `value` with the drive prefix (if
## present) and the leading separator preserved. A Windows absolute path
## `C:\a\b` becomes `C:/a/b`; a POSIX absolute path `/a/b` is unchanged;
## a relative path `a\b` becomes `a/b`.
static func _to_unix(value: String) -> String:
	return value.replace("\\", "/")
