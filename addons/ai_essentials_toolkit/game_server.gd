extends Node

## AI Essentials Toolkit — Game Runtime Server
## Runs inside the GAME process on port 7778.
## Add this as an autoload to enable game viewport screenshots.
##
## Endpoints:
##   GET /ping        — Check game is running, current scene
##   GET /screenshot  — Capture game viewport as PNG

var server: TCPServer
var port: int = 7778
var clients: Array[Dictionary] = []
const MAX_CLIENTS := 5
const CLIENT_TIMEOUT := 5.0

func _ready() -> void:
	server = TCPServer.new()
	var err := server.listen(port, "127.0.0.1")
	if err != OK:
		push_warning("AI Essentials: Game server failed on port %d" % port)
		return

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
			client["buffer"] += peer.get_utf8_string(peer.get_available_bytes())
		if client["buffer"].find("\r\n\r\n") >= 0:
			_handle(peer, client["buffer"])
			peer.disconnect_from_host()
			to_remove.append(i)
	to_remove.reverse()
	for idx in to_remove:
		if idx < clients.size():
			clients.remove_at(idx)

func _handle(peer: StreamPeerTCP, raw: String) -> void:
	var header_end := raw.find("\r\n\r\n")
	var headers_str := raw.substr(0, header_end) if header_end >= 0 else raw
	var lines := headers_str.split("\r\n")
	if lines.size() == 0:
		_send(peer, 400, '{"error":"empty"}')
		return
	var parts := lines[0].split(" ")
	if parts.size() < 2:
		_send(peer, 400, '{"error":"malformed"}')
		return
	match parts[1]:
		"/ping":
			var scene_path := ""
			if get_tree().current_scene:
				scene_path = get_tree().current_scene.scene_file_path
			_send(peer, 200, JSON.stringify({"status": "ok", "source": "game", "scene": scene_path}))
		"/screenshot":
			_screenshot(peer)
		_:
			_send(peer, 404, JSON.stringify({"error": "unknown endpoint"}))

func _screenshot(peer: StreamPeerTCP) -> void:
	var img := get_viewport().get_texture().get_image()
	if not img:
		_send(peer, 500, '{"error":"could not get viewport image"}')
		return
	var save_path := ProjectSettings.globalize_path("user://ai_toolkit_game_screenshot.png")
	var err := img.save_png(save_path)
	if err != OK:
		_send(peer, 500, '{"error":"save_png failed"}')
		return
	_send(peer, 200, JSON.stringify({"path": save_path, "source": "running_game"}))

func _send(peer: StreamPeerTCP, code: int, body: String) -> void:
	var status := "OK"
	match code:
		400: status = "Bad Request"
		404: status = "Not Found"
		500: status = "Internal Server Error"
	var body_bytes := body.to_utf8_buffer()
	var header := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, status, body_bytes.size()]
	peer.put_data(header.to_utf8_buffer())
	peer.put_data(body_bytes)
