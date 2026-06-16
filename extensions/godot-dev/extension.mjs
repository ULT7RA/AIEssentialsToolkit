// Extension: godot-dev
// Claude Bridge for Godot — screenshot, scene inspect, property edit, run/stop, parse check
// Talks to Claude Bridge EditorPlugin HTTP server on port 7777

import { joinSession } from "@github/copilot-sdk/extension";
import { readFileSync, existsSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { execFile } from "node:child_process";

const GODOT_PORT = 7777;
const GAME_PORT = 7778;
const GODOT_HOST = "127.0.0.1";
const GODOT_URL = `http://${GODOT_HOST}:${GODOT_PORT}`;
const GAME_URL = `http://${GODOT_HOST}:${GAME_PORT}`;

async function godotRequest(path, body = null) {
    const method = body ? "POST" : "GET";
    const bodyStr = body ? JSON.stringify(body) : "";
    const headers = {
        "Content-Type": "application/json",
    };
    if (body) {
        headers["Content-Length"] = Buffer.byteLength(bodyStr).toString();
    }
    try {
        const res = await fetch(`${GODOT_URL}${path}`, {
            method,
            headers,
            body: body ? bodyStr : undefined,
            signal: AbortSignal.timeout(10000),
        });
        const text = await res.text();
        let parsed;
        try {
            parsed = JSON.parse(text);
        } catch {
            parsed = { raw: text };
        }
        if (!res.ok) {
            parsed.httpError = `HTTP ${res.status} ${res.statusText}`;
        }
        return parsed;
    } catch (err) {
        return { error: `Connection failed: ${err.message}. Is Godot editor running with Claude Bridge plugin enabled on port ${GODOT_PORT}?` };
    }
}

// Screenshot helper — saves to temp dir and returns path for view tool
function getScreenshotDir() {
    try {
        const dir = join(process.env.TEMP || process.env.TMP || "C:\\Temp", "godot_screenshots");
        if (!existsSync(dir)) {
            mkdirSync(dir, { recursive: true });
        }
        return dir;
    } catch (e) {
        // Fallback to CWD
        const dir = join(process.cwd(), "godot_screenshots");
        if (!existsSync(dir)) {
            mkdirSync(dir, { recursive: true });
        }
        return dir;
    }
}

const session = await joinSession({
    hooks: {
        onSessionStart: async () => {
            await session.log("Godot Dev Bridge loaded — tools available for screenshot, scene inspect, run/stop, parse check");
        },
    },
    tools: [
        {
            name: "godot_ping",
            description: "Check if Godot editor is running and Claude Bridge plugin is active. Use this to verify connection before other tools.",
            parameters: { type: "object", properties: {} },
            skipPermission: true,
            handler: async () => {
                const result = await godotRequest("/ping");
                return JSON.stringify(result);
            },
        },
        {
            name: "godot_screenshot",
            description: "Take a screenshot of the Godot editor viewport. Returns the file path to the saved PNG which you can then view with the view tool. Use this after every visual change to verify it looks correct.",
            parameters: {
                type: "object",
                properties: {
                    name: {
                        type: "string",
                        description: "Optional name for the screenshot file (e.g. 'menu_v1', 'button_fix'). Defaults to timestamp.",
                    },
                },
            },
            skipPermission: true,
            handler: async (args = {}) => {
                let result = await godotRequest("/screenshot");
                if (result.error) {
                    return { textResultForLlm: JSON.stringify(result), resultType: "failure" };
                }
                // If game is running, editor redirects us to the game server
                if (result.redirect === "game") {
                    try {
                        const gameRes = await fetch(`${GAME_URL}/screenshot`, {
                            signal: AbortSignal.timeout(5000),
                        });
                        const gameText = await gameRes.text();
                        try { result = JSON.parse(gameText); } catch { result = { error: gameText }; }
                    } catch (err) {
                        return { textResultForLlm: JSON.stringify({ error: `Game server not responding on port ${GAME_PORT}: ${err.message}. Game may still be loading.` }), resultType: "failure" };
                    }
                    if (result.error) {
                        return { textResultForLlm: JSON.stringify(result), resultType: "failure" };
                    }
                }
                let srcPath = result.path ? result.path.replace(/\//g, "\\") : null;
                if (!srcPath || !existsSync(srcPath)) {
                    // Brief poll in case of write delay
                    for (let i = 0; i < 5 && srcPath && !existsSync(srcPath); i++) {
                        await new Promise(r => setTimeout(r, 100));
                    }
                }
                if (!srcPath || !existsSync(srcPath)) {
                    return { textResultForLlm: JSON.stringify({ error: "Screenshot file not found", path: srcPath, serverResult: result }), resultType: "failure" };
                }
                try {
                    const ssDir = getScreenshotDir();
                    const safeName = (args.name || `ss_${Date.now()}`).replace(/[<>:"/\\|?*]/g, "_").substring(0, 80);
                    const destPath = join(ssDir, `${safeName}.png`);
                    const data = readFileSync(srcPath);
                    writeFileSync(destPath, data);
                    return JSON.stringify({
                        success: true,
                        path: destPath,
                        size: data.length,
                        message: `Screenshot saved. Use the view tool on: ${destPath}`,
                    });
                } catch (e) {
                    // Fallback: just return the original path
                    return JSON.stringify({
                        success: true,
                        path: srcPath,
                        message: `Screenshot at: ${srcPath}. Use the view tool on this path.`,
                        copyError: e.message,
                    });
                }
            },
        },
        {
            name: "godot_scene_tree",
            description: "Get the full scene tree of the currently edited scene in the Godot editor. Shows all nodes, their types, and hierarchy.",
            parameters: { type: "object", properties: {} },
            skipPermission: true,
            handler: async () => {
                const result = await godotRequest("/scene/tree");
                return JSON.stringify(result, null, 2);
            },
        },
        {
            name: "godot_node_info",
            description: "Get detailed info about a specific node in the edited scene — all properties and their current values.",
            parameters: {
                type: "object",
                properties: {
                    path: {
                        type: "string",
                        description: "Node path relative to scene root (e.g. 'ButtonContainer/StartButton', 'HD2DCamera')",
                    },
                },
                required: ["path"],
            },
            skipPermission: true,
            handler: async (args) => {
                const result = await godotRequest("/scene/node", { path: args.path });
                return JSON.stringify(result, null, 2);
            },
        },
        {
            name: "godot_set_property",
            description: "Set a property on a node in the edited scene. Changes take effect immediately in the editor.",
            parameters: {
                type: "object",
                properties: {
                    path: {
                        type: "string",
                        description: "Node path relative to scene root",
                    },
                    property: {
                        type: "string",
                        description: "Property name to set (e.g. 'position', 'visible', 'modulate')",
                    },
                    value: {
                        description: "Value to set the property to",
                    },
                },
                required: ["path", "property", "value"],
            },
            handler: async (args) => {
                const result = await godotRequest("/scene/set", {
                    path: args.path,
                    property: args.property,
                    value: args.value,
                });
                return JSON.stringify(result);
            },
        },
        {
            name: "godot_run",
            description: "Run the game from the Godot editor (equivalent to pressing F5/Play).",
            parameters: { type: "object", properties: {} },
            handler: async () => {
                const result = await godotRequest("/run");
                return JSON.stringify(result);
            },
        },
        {
            name: "godot_stop",
            description: "Stop the running game in the Godot editor.",
            parameters: { type: "object", properties: {} },
            handler: async () => {
                const result = await godotRequest("/stop");
                return JSON.stringify(result);
            },
        },
        {
            name: "godot_parse_check",
            description: "Check all GDScript files for parse/compile errors. Returns list of scripts with errors. Use this after editing .gd files to verify no syntax issues.",
            parameters: { type: "object", properties: {} },
            skipPermission: true,
            handler: async () => {
                const result = await godotRequest("/parse");
                return JSON.stringify(result, null, 2);
            },
        },
    ],
});
