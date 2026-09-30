extends Node
# Autoload updater manager. Runs in Lobby before connecting to rooms.
# Windows updates install the verified single-file client installer.
# Other platforms retain the resource-pack update path.
#
# The exported project version identifies the installed client release.

signal update_checking()
signal update_progress(percent: float)
signal update_completed()
signal update_failed(reason: String)

const MANIFEST_URL := "https://bloxity-9xk2.onrender.com/client/version.json"
const PCK_DOWNLOAD_URL := "https://bloxity-9xk2.onrender.com/client/BloxityClient.pck"
const DEBUG_BOOT := false

## Overall watchdog for one check_for_updates() run (manifest fetch and,
## if needed, the pck download). Lobby's join is now gated entirely on
## update_completed firing -- see lobby.gd's _start_game_flow() -- so an
## HTTPRequest that never calls back (dead DNS, a connection that hangs
## instead of erroring, a stalled download) used to leave is_updating
## true forever with the player stuck on "Checking for game updates..."
## and no join ever attempted. This timer guarantees update_completed
## always fires one way or another.
const UPDATE_TIMEOUT_SEC := 15.0
const INSTALLER_TIMEOUT_SEC := 600.0

var _http_request: HTTPRequest
var _timeout_timer: Timer
var current_version: String = "1.0.0"
var target_version: String = ""
var _expected_sha256 := ""
var _pending_installer_path := ""
var _pending_installer_sha256 := ""
var is_updating: bool = false


func _ready() -> void:
	current_version = String(ProjectSettings.get_setting("application/config/version", current_version))
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_timeout_timer = Timer.new()
	_timeout_timer.one_shot = true
	_timeout_timer.timeout.connect(_on_update_timeout)
	add_child(_timeout_timer)


func check_for_updates() -> void:
	if is_updating:
		return
	is_updating = true
	update_checking.emit()
	_timeout_timer.start(UPDATE_TIMEOUT_SEC)

	_http_request.request_completed.connect(_on_manifest_received, CONNECT_ONE_SHOT)
	var headers := PackedStringArray([
		"User-Agent: BloxityClient/" + current_version,
		"Cache-Control: no-cache, no-store, must-revalidate",
		"Pragma: no-cache"
	])
	# Cache buster query string to avoid CDN/HTTP caching
	var cache_buster := "?t=" + str(Time.get_ticks_msec())
	var err := _http_request.request(MANIFEST_URL + cache_buster, headers)
	if err != OK:
		is_updating = false
		_timeout_timer.stop()
		if _http_request.request_completed.is_connected(_on_manifest_received):
			_http_request.request_completed.disconnect(_on_manifest_received)
		update_completed.emit() # Continue to game even if manifest check fails


func _on_manifest_received(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if DEBUG_BOOT:
		print("[BOOT t=%d] AutoUpdater._on_manifest_received result=%d code=%d" % [Time.get_ticks_msec(), result, response_code])
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		is_updating = false
		_timeout_timer.stop()
		update_completed.emit()
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		is_updating = false
		_timeout_timer.stop()
		update_completed.emit()
		return

	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		_fail_update("Update manifest must be a JSON object.")
		return
	var remote_version: String = data.get("version", "1.0.0")
	var installer_url := String(data.get("client_update_url", ""))
	var installer_sha256 := String(data.get("client_sha256", "")).to_lower()
	_expected_sha256 = String(data.get("sha256", data.get("pck_sha256", ""))).to_lower()
	var custom_pck_url: String = data.get("game_update_url", "")
	
	var download_target_url := PCK_DOWNLOAD_URL
	if custom_pck_url != "":
		if custom_pck_url.begins_with("http://") or custom_pck_url.begins_with("https://"):
			download_target_url = custom_pck_url
		else:
			download_target_url = "https://bloxity-9xk2.onrender.com" + custom_pck_url

	if remote_version != current_version:
		if OS.get_name() == "Windows" and not installer_url.is_empty():
			if not _is_sha256(installer_sha256):
				_fail_update("Update manifest is missing a valid client installer checksum.")
				return
			if not installer_url.begins_with("https://bloxity-9xk2.onrender.com/client/windows/BloxityClientInstaller.exe"):
				_fail_update("Client installer URL is not an approved release URL.")
				return
			target_version = remote_version
			_download_client_installer(installer_url, installer_sha256)
			return
		if not _is_sha256(_expected_sha256):
			_fail_update("Update manifest is missing a valid sha256 checksum.")
			return
		target_version = remote_version
		# Leave _timeout_timer running -- it still covers the pack download
		# that's about to start, restarted with a fresh budget in
		# _download_pack() below.
		_download_pack(download_target_url)
	else:
		is_updating = false
		_timeout_timer.stop()
		update_completed.emit()


func _download_client_installer(url: String, expected_sha256: String) -> void:
	_timeout_timer.start(INSTALLER_TIMEOUT_SEC)
	_pending_installer_path = OS.get_temp_dir().path_join("BloxityClientSetup-%s.exe" % target_version)
	_pending_installer_sha256 = expected_sha256
	_cleanup_temp(_pending_installer_path)
	_http_request.download_file = _pending_installer_path
	_http_request.request_completed.connect(_on_client_installer_downloaded, CONNECT_ONE_SHOT)
	var headers := PackedStringArray([
		"User-Agent: BloxityClient/" + current_version,
		"Cache-Control: no-cache, no-store, must-revalidate",
		"Pragma: no-cache"
	])
	var separator := "&" if url.contains("?") else "?"
	var err := _http_request.request(url + separator + "t=" + str(Time.get_ticks_msec()), headers)
	if err != OK:
		if _http_request.request_completed.is_connected(_on_client_installer_downloaded):
			_http_request.request_completed.disconnect(_on_client_installer_downloaded)
		_http_request.download_file = ""
		_cleanup_temp(_pending_installer_path)
		_fail_update("Could not start client installer download (err=%d)." % err)


func _on_client_installer_downloaded(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_http_request.download_file = ""
	_timeout_timer.stop()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200 or not FileAccess.file_exists(_pending_installer_path):
		_cleanup_temp(_pending_installer_path)
		_fail_update("Client installer download failed (HTTP %d)." % response_code)
		return
	var file := FileAccess.open(_pending_installer_path, FileAccess.READ)
	if file == null or file.get_length() <= 0:
		_cleanup_temp(_pending_installer_path)
		_fail_update("Downloaded client installer is empty or unreadable.")
		return
	file.close()
	if FileAccess.get_sha256(_pending_installer_path).to_lower() != _pending_installer_sha256:
		_cleanup_temp(_pending_installer_path)
		_fail_update("Client installer checksum mismatch; update rejected.")
		return

	var installer_args := PackedStringArray([
		"/VERYSILENT",
		"/SUPPRESSMSGBOXES",
		"/NORESTART",
		"/CLOSEAPPLICATIONS"
	])
	var join_uri := _get_launch_uri()
	if not join_uri.is_empty():
		installer_args.append("/JOINURI=" + join_uri)
	var installer_pid := OS.create_process(_pending_installer_path, installer_args)
	if installer_pid <= 0:
		_cleanup_temp(_pending_installer_path)
		_fail_update("Verified client installer could not be started.")
		return
	print("[Bloxity Updater] Starting verified client installer for version %s." % target_version)
	is_updating = false
	get_tree().quit()


func _get_launch_uri() -> String:
	for argument in OS.get_cmdline_args():
		if argument.begins_with("bloxity://"):
			return argument
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("bloxity://"):
			return argument
	return ""


func _download_pack(url: String) -> void:
	# Fresh budget for the download phase, separate from whatever was left
	# over from the manifest fetch -- a pck download is a bigger transfer
	# and deserves its own full window rather than racing the leftover
	# time from the request that preceded it.
	_timeout_timer.start(UPDATE_TIMEOUT_SEC)
	var temp_save_path := _install_pck_path() + ".tmp"
	_http_request.download_file = temp_save_path
	_http_request.request_completed.connect(_on_pack_downloaded, CONNECT_ONE_SHOT)
	var headers := PackedStringArray([
		"User-Agent: BloxityClient/" + current_version,
		"Cache-Control: no-cache, no-store, must-revalidate",
		"Pragma: no-cache"
	])
	var cache_buster := "?t=" + str(Time.get_ticks_msec())
	var err := _http_request.request(url + cache_buster, headers)
	if err != OK:
		_http_request.request_completed.disconnect(_on_pack_downloaded)
		_http_request.download_file = ""
		_cleanup_temp(temp_save_path)
		_fail_update("Could not start client update download (err=%d)." % err)


## Where Godot loads the resource pack from automatically at boot differs
## by platform:
## - Windows/Linux: a .pck sitting next to the executable, sharing its
##   exact filename (e.g. "BloxityClient.exe" -> "BloxityClient.pck").
## - macOS: NOT next to the raw Mach-O binary inside Contents/MacOS/ --
##   Godot's mac export template places (and loads) the pck from inside
##   the app bundle's Resources folder, named after the PROJECT's
##   application/config/name setting ("Bloxity Client.pck", with
##   whatever spacing/casing that setting has) -- NOT after whatever the
##   .app/executable itself is named in the export preset. These two
##   names can legitimately differ (ours do: "BloxityClient.app" vs
##   "Bloxity Client.pck"), so deriving the pck filename from
##   OS.get_executable_path() on macOS silently writes to the wrong
##   filename -- the download "succeeds" but next launch keeps loading
##   the untouched original pck, with no error anywhere.
##
## NOTE: deliberately NOT calling OS.get_bundle_resource_dir() -- it's a
## macOS/iOS-only API that doesn't exist in the Windows/Linux builds of
## the engine at all, and GDScript resolves method calls at parse time
## regardless of which branch of an if they're in, so referencing it
## anywhere in a script that also ships on Windows/Linux fails to even
## compile there (this bit us once already). Instead we derive the
## Resources folder purely from string/path math on the known bundle
## layout: .../AppName.app/Contents/MacOS/AppName -> go up one level
## from the executable's directory, then into "Resources".
func _install_pck_path() -> String:
	if OS.get_name() == "macOS":
		var pck_name: String = String(ProjectSettings.get_setting("application/config/name", "")) + ".pck"
		var macos_dir := OS.get_executable_path().get_base_dir() # .../Contents/MacOS
		var contents_dir := macos_dir.get_base_dir() # .../Contents
		return contents_dir.path_join("Resources").path_join(pck_name)
	return OS.get_executable_path().get_basename() + ".pck"


func _on_pack_downloaded(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	is_updating = false
	_timeout_timer.stop()
	var final_save_path := _install_pck_path()
	var temp_save_path := final_save_path + ".tmp"

	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		# Check that file size is valid (>0 bytes) before replacing existing pack
		if FileAccess.file_exists(temp_save_path):
			var file := FileAccess.open(temp_save_path, FileAccess.READ)
			if file and file.get_length() > 0:
				var actual_sha256 := FileAccess.get_sha256(temp_save_path).to_lower()
				file.close()
				if actual_sha256 != _expected_sha256:
					_cleanup_temp(temp_save_path)
					_fail_update("Client update checksum mismatch; update rejected.")
					return
				var success := ProjectSettings.load_resource_pack(temp_save_path, false)
				if success:
					var backup_path := final_save_path + ".previous"
					_cleanup_temp(backup_path)
					var had_previous := FileAccess.file_exists(final_save_path)
					if had_previous:
						var backup_error := DirAccess.rename_absolute(final_save_path, backup_path)
						if backup_error != OK:
							push_error("[Bloxity Updater] Could not preserve installed pack (err=%d)." % backup_error)
							_cleanup_temp(temp_save_path)
							update_completed.emit()
							return
					var rename_error := DirAccess.rename_absolute(temp_save_path, final_save_path)
					if rename_error != OK:
						if had_previous:
							DirAccess.rename_absolute(backup_path, final_save_path)
						push_error("[Bloxity Updater] Could not install verified pack (err=%d)." % rename_error)
						_cleanup_temp(temp_save_path)
						update_completed.emit()
						return
					_cleanup_temp(backup_path)
					# In-memory only for the rest of this session (e.g. for the
					# User-Agent header on the next request) -- deliberately not
					# persisted to disk, since next launch should always check
					# the website fresh rather than trust a remembered version.
					if target_version != "":
						current_version = target_version
					print("[Bloxity Updater] Replaced install pck at %s" % final_save_path)
			else:
				if FileAccess.file_exists(temp_save_path):
					DirAccess.remove_absolute(temp_save_path)
	else:
		if FileAccess.file_exists(temp_save_path):
			DirAccess.remove_absolute(temp_save_path)
	
	update_completed.emit()


## Fires if a check_for_updates() run (manifest fetch or pck download)
## hasn't called back within UPDATE_TIMEOUT_SEC. Cancels whatever's still
## in flight and fails open into the game, exactly like the other
## error paths above -- an update check is a nice-to-have, never a
## reason to strand the player on the lobby screen.
func _on_update_timeout() -> void:
	if not is_updating:
		return # Already resolved normally; nothing to do.

	print("[Bloxity Updater] Timed out waiting for update check; continuing without it.")

	# Disconnect first so a completion that sneaks in right as we cancel
	# doesn't also fire _on_manifest_received/_on_pack_downloaded and emit
	# update_completed a second time.
	if _http_request.request_completed.is_connected(_on_manifest_received):
		_http_request.request_completed.disconnect(_on_manifest_received)
	if _http_request.request_completed.is_connected(_on_pack_downloaded):
		_http_request.request_completed.disconnect(_on_pack_downloaded)
	if _http_request.request_completed.is_connected(_on_client_installer_downloaded):
		_http_request.request_completed.disconnect(_on_client_installer_downloaded)
	_http_request.cancel_request()
	_http_request.download_file = ""
	_cleanup_temp(_install_pck_path() + ".tmp")
	if not _pending_installer_path.is_empty():
		_cleanup_temp(_pending_installer_path)

	is_updating = false
	update_failed.emit("Update check timed out")
	update_completed.emit()


func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if not (character in "0123456789abcdef"):
			return false
	return true


func _cleanup_temp(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _fail_update(reason: String) -> void:
	if _timeout_timer:
		_timeout_timer.stop()
	is_updating = false
	update_failed.emit(reason)
	push_warning("[Bloxity Updater] %s" % reason)
	update_completed.emit()
