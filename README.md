# AI Essentials Toolkit for Godot 4

Give AI coding assistants **eyes and hands** inside the Godot editor. Screenshots, scene inspection, property editing, game control, and script validation — all via a simple HTTP API.

Works with **any AI tool** that can make HTTP requests: Claude, ChatGPT, GitHub Copilot, Cursor, or your own scripts.

## Features

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/ping` | GET | Check connection, engine version, game state |
| `/screenshot` | GET | Capture editor viewport (auto-redirects to game when running) |
| `/screenshot/editor` | GET | Always capture editor 3D viewport |
| `/scene/tree` | GET | Full scene node hierarchy |
| `/scene/node` | POST | Get all properties of a node |
| `/scene/set` | POST | Set a node property in the editor |
| `/run` | POST | Run the main scene (F5) |
| `/stop` | POST | Stop the running game |
| `/parse` | GET | Check all GDScript files for errors |

### Two Servers

- **Editor Server** (port 7777) — Runs as an EditorPlugin, always available when the editor is open
- **Game Server** (port 7778) — Runs as an autoload inside the game, captures the actual game viewport

## Installation

### From Godot Asset Library
1. Open Godot → AssetLib tab → Search "AI Essentials Toolkit" → Install

### From GitHub
1. Download/clone this repo
2. Copy the `addons/ai_essentials_toolkit/` folder into your project's `addons/` directory
3. Go to **Project → Project Settings → Plugins** and enable "AI Essentials Toolkit"
4. Add the game server autoload: **Project → Project Settings → Autoload** → Add `addons/ai_essentials_toolkit/game_server.gd` with name `AIToolkitGameServer`

## Usage

### Quick Test
With the editor open and plugin enabled, run:
```bash
curl http://localhost:7777/ping
```

### Screenshot
```bash
curl http://localhost:7777/screenshot
# Returns: {"path": "C:/Users/.../ai_toolkit_screenshot.png", "source": "editor_3d_viewport"}
```

### Scene Inspection
```bash
curl http://localhost:7777/scene/tree
# Returns full node hierarchy

curl -X POST http://localhost:7777/scene/node -d '{"path": "Camera3D"}'
# Returns all properties of the node
```

### Set Property
```bash
curl -X POST http://localhost:7777/scene/set -d '{"path": "Camera3D", "property": "fov", "value": 90}'
```

### Game Control
```bash
curl -X POST http://localhost:7777/run    # Start game
curl -X POST http://localhost:7777/stop   # Stop game
```

### Game Screenshot (while game is running)
```bash
curl http://localhost:7778/screenshot
# Returns: {"path": "...", "source": "running_game"}
```

### Parse Check
```bash
curl http://localhost:7777/parse
# Returns: {"total_scripts": 40, "errors": [], "ok": true}
```

## Integration Examples

### With Claude CLI / Copilot CLI
The toolkit includes a ready-made CLI extension. Copy `extensions/godot-dev/extension.mjs` to your Copilot extensions directory:
```
~/.copilot/extensions/godot-dev/extension.mjs
```

### With Any AI Tool
Any tool that can call HTTP endpoints can use this. Point it at `http://localhost:7777` and use the endpoints above.

### With Python
```python
import requests, json

# Take screenshot
r = requests.get("http://localhost:7777/screenshot")
data = r.json()
print(f"Screenshot at: {data['path']}")

# Get scene tree
r = requests.get("http://localhost:7777/scene/tree")
print(r.json()["tree"])
```

## Requirements

- Godot 4.4+
- No external dependencies

## License

MIT License — see [LICENSE](LICENSE)
