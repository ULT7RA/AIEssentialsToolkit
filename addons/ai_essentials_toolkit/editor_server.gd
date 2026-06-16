@tool
extends EditorPlugin

## AI Essentials Toolkit — Editor HTTP Server
## Gives AI coding assistants eyes and hands inside Godot.
## Runs on http://127.0.0.1:7777 (editor) with a companion game server on :7778.
## Works with any AI tool that can make HTTP requests.
##
## Endpoints:
##   GET  /ping              — Check connection, engine version, game running state
##   GET  /screenshot        — Capture editor viewport (or redirect to game server)
##   GET  /screenshot/editor — Always capture editor 3D viewport
##   GET  /scene/tree        — Dump full scene node hierarchy
##   POST /scene/node        — Get all properties of a node {path: "NodePath"}
##   POST /scene/set         — Set a node property {path, property, value}
##   POST /run               — Run the main scene (F5)
##   POST /stop              — Stop the running game
##   GET  /parse             — Check all GDScript files for errors

var server: TCPServer
var port: int = 7777
var game_port: int = 7778
var clients: Array[Dictionary] = []
const MAX_CLIENTS := 10
const MAX_REQUEST_SIZE := 65536
const CLIENT_TIMEOUT := 10.0

func _enter_tree() -> void:
	server = TCPServer.new()
	var err := server.listen(port, "127.0.0.1")
	if err != OK:
		push_error("AI Essentials: Failed to listen on port %d: %s" % [port, error_string(err)])
		return
	print("AI Essentials Toolkit: Editor server on http://127.0.0.1:%d" % port)
	set_process(true)

func _exit_tree() -> void:
	if server:
		server.stop()
	for c in clients:
		var peer: StreamPeerTCP = c["peer"]
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
	clients.clear()

func _process(delta: float) -> void:
	if not server or not server.is_listening():
		return
	var accepted := 0
	while server.is_connection_available() and accepted < 3:
		if clients.size() >= MAX_CLIENTS:
			var peer := server.take_connection()
			if peer:
				peer.disconnect_from_host()
			break
		var peer := server.take_connection()
		if peer:
			clients.append({"peer": peer, "buffer": "", "time": 0.0})
			accepted += 1

	var to_remove := []
	for i in range(clients.size()):
		var client: Dictionary = clients[i]
		var peer: StreamPeerTCP = client["peer"]
		peer.poll()
		client["time"] += delta
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			to_remove.append(i)
			continue
		if client["time"] > CLIENT_TIMEOUT:
			peer.disconnect_from_host()
			to_remove.append(i)
			continue
		if peer.get_available_bytes() > 0:
			var chunk := peer.get_utf8_string(peer.get_available_bytes())
			client["buffer"] += chunk
			if client["buffer"].length() > MAX_REQUEST_SIZE:
				_send(peer, 413, '{"error":"request too large"}')
				peer.disconnect_from_host()
				to_remove.append(i)
				continue
		var buf: String = client["buffer"]
		if buf.find("\r\n\r\n") >= 0:
			var header_end := buf.find("\r\n\r\n")
			var headers_str := buf.substr(0, header_end)
			var body_raw := buf.substr(header_end + 4)
			var content_length := 0
			for line in headers_str.split("\r\n"):
				if line.to_lower().begins_with("content-length:"):
					content_length = int(line.split(":")[1].strip_edges())
			if body_raw.to_utf8_buffer().size() >= content_length:
				_handle_http(peer, buf)
				peer.disconnect_from_host()
				to_remove.append(i)
	to_remove.reverse()
	for idx in to_remove:
		if idx < clients.size():
			clients.remove_at(idx)

func _handle_http(peer: StreamPeerTCP, raw: String) -> void:
	var header_end := raw.find("\r\n\r\n")
	var headers_str := raw.substr(0, header_end) if header_end >= 0 else raw
	var lines := headers_str.split("\r\n")
	if lines.size() == 0:
		_send(peer, 400, '{"error":"empty request"}')
		return
	var parts := lines[0].split(" ")
	if parts.size() < 2:
		_send(peer, 400, '{"error":"malformed request"}')
		return
	var path := parts[1]
	var body := raw.substr(header_end + 4) if header_end >= 0 else ""
	var response := _route(path, body)
	_send(peer, response["code"], response["body"])

func _route(path: String, body: String) -> Dictionary:
	match path:
		"/ping":
			return _ok({"status": "ok", "toolkit": "AI Essentials Toolkit", "version": "1.0.0", "engine": "Godot %s" % Engine.get_version_info()["string"], "playing": EditorInterface.is_playing_scene(), "game_port": game_port})
		"/screenshot":
			return _handle_screenshot()
		"/screenshot/editor":
			return _handle_editor_screenshot()
		"/scene/tree":
			return _handle_scene_tree()
		"/scene/node":
			return _handle_node_info(body)
		"/scene/set":
			return _handle_set_property(body)
		"/run":
			return _handle_run()
		"/stop":
			return _handle_stop()
		"/parse":
			return _handle_parse_check()
		_:
			return _err(404, "unknown endpoint: " + path)

# --- Helpers ---

func _ok(data: Dictionary) -> Dictionary:
	return {"code": 200, "body": JSON.stringify(data)}

func _err(code: int, message: String) -> Dictionary:
	return {"code": code, "body": JSON.stringify({"error": message})}

func _parse_body(body: String) -> Variant:
	var json := JSON.new()
	if json.parse(body) != OK:
		return null
	if typeof(json.data) != TYPE_DICTIONARY:
		return null
	return json.data

# --- Endpoints ---

func _handle_screenshot() -> Dictionary:
	if EditorInterface.is_playing_scene():
		return _ok({"redirect": "game", "port": game_port, "message": "Game running. Hit http://127.0.0.1:%d/screenshot" % game_port})
	return _handle_editor_screenshot()

func _handle_editor_screenshot() -> Dictionary:
	var save_path := ProjectSettings.globalize_path("user://ai_toolkit_screenshot.png")
	var vp := EditorInterface.get_editor_viewport_3d()
	if vp:
		var img := vp.get_texture().get_image()
		if img:
			var err := img.save_png(save_path)
			if err == OK:
				return _ok({"path": save_path, "source": "editor_3d_viewport"})
			return _err(500, "save_png failed: %d" % err)
	return _err(500, "could not capture viewport")

func _handle_scene_tree() -> Dictionary:
	var edited := EditorInterface.get_edited_scene_root()
	if not edited:
		return _ok({"tree": "no scene open"})
	return _ok({"scene": edited.scene_file_path, "tree": _dump_tree(edited, 0)})

func _dump_tree(node: Node, depth: int) -> String:
	var indent := "  ".repeat(depth)
	var result := "%s%s (%s)" % [indent, node.name, node.get_class()]
	for child in node.get_children():
		result += "\n" + _dump_tree(child, depth + 1)
	return result

func _handle_node_info(body: String) -> Dictionary:
	var data = _parse_body(body)
	if data == null:
		return _err(400, "invalid json body")
	var edited := EditorInterface.get_edited_scene_root()
	if not edited:
		return _err(400, "no scene open")
	var node := edited.get_node_or_null(NodePath(data.get("path", "")))
	if not node:
		return _err(404, "node not found: " + str(data.get("path", "")))
	var props := {}
	for prop in node.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("_") or pname == "script":
			continue
		props[pname] = str(node.get(pname))
	return _ok({"node": data.get("path", ""), "class": node.get_class(), "properties": props})

func _handle_set_property(body: String) -> Dictionary:
	var data = _parse_body(body)
	if data == null:
		return _err(400, "invalid json body")
	var edited := EditorInterface.get_edited_scene_root()
	if not edited:
		return _err(400, "no scene open")
	var node := edited.get_node_or_null(NodePath(data.get("path", "")))
	if not node:
		return _err(404, "node not found: " + str(data.get("path", "")))
	var prop_name: String = data.get("property", "")
	var found := false
	for prop in node.get_property_list():
		if prop["name"] == prop_name:
			found = true
			break
	if not found:
		return _err(400, "property not found: " + prop_name)
	node.set(prop_name, data.get("value"))
	return _ok({"ok": true, "property": prop_name, "value": str(node.get(prop_name))})

func _handle_run() -> Dictionary:
	EditorInterface.play_main_scene()
	return _ok({"ok": true, "action": "play_main_scene"})

func _handle_stop() -> Dictionary:
	EditorInterface.stop_playing_scene()
	return _ok({"ok": true, "action": "stop"})

func _handle_parse_check() -> Dictionary:
	var errors := []
	var total := 0
	var scripts := _find_all_scripts("res://")
	total = scripts.size()
	for script_path in scripts:
		var script: GDScript = ResourceLoader.load(script_path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
		if script == null:
			errors.append({"file": script_path, "error": "failed to load (parse error)"})
	return _ok({"total_scripts": total, "errors": errors, "ok": errors.size() == 0})

func _find_all_scripts(dir_path: String) -> Array:
	var results := []
	var dir := DirAccess.open(dir_path)
	if not dir:
		return results
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with(".") or file_name == "addons":
			file_name = dir.get_next()
			continue
		var full_path := dir_path.path_join(file_name)
		if dir.current_is_dir():
			results.append_array(_find_all_scripts(full_path))
		elif file_name.ends_with(".gd"):
			results.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()
	return results

func _send(peer: StreamPeerTCP, code: int, body: String) -> void:
	var status := "OK"
	match code:
		400: status = "Bad Request"
		404: status = "Not Found"
		413: status = "Payload Too Large"
		500: status = "Internal Server Error"
	var body_bytes := body.to_utf8_buffer()
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, status, body_bytes.size()]
	peer.put_data(header.to_utf8_buffer())
	peer.put_data(body_bytes)
