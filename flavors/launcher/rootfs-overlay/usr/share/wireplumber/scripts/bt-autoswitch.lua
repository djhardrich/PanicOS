-- Auto-switch the default audio sink to a Bluetooth output when it connects.
--
-- WirePlumber 0.5's priority-based selection only runs when the BT node is
-- already a SiLinkable session item, but the node starts in suspended state
-- and isn't promoted while it has no active links — a chicken-and-egg loop.
-- Writing directly to the "default.configured.audio.sink" metadata key breaks
-- the loop: find-selected-default-node gives it a +30000 priority boost on the
-- next rescan (which the session-item-added event triggers automatically).
--
-- On disconnect the node disappears, the configured key is cleared by
-- state-default-nodes.lua, and WirePlumber falls back to the next highest
-- priority sink via the normal priority selection path.

log = Log.open_topic("s-bt-autoswitch")

local metadata_om = ObjectManager {
  Interest { type = "metadata", Constraint { "metadata.name", "=", "default" } }
}

local node_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "=", "Audio/Sink" },
    Constraint { "node.name", "matches", "bluez_output.*" },
  }
}

node_om:connect("object-added", function(_, node)
  local name = node.properties["node.name"]
  local metadata = metadata_om:lookup()
  if not metadata then
    log:warning("default metadata not ready, cannot switch to " .. tostring(name))
    return
  end
  log:info("BT sink connected, switching default to " .. tostring(name))
  metadata:set(0, "default.configured.audio.sink", "Spa:String:JSON",
    Json.Object { name = name }:to_string())
end)

metadata_om:activate()
node_om:activate()
