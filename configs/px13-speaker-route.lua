-- Managed by px13-audio-fix. Run with wpexec.
--
-- Sets the PX13 speaker route (the hardware volume behind the tuned sink) to
-- 100% and unmuted, and marks it for saving, so that WirePlumber restores it
-- after a restart. Works while the raw sink is hidden from clients, because
-- it goes through the card device, not the sink node.

local DEVICE = "alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
local ROUTE = "[Out] Speaker"
local VOLUME = 1.0

local function quit (status)
  if status ~= 0 then
    io.stderr:write ("px13-speaker-route: no active '" .. ROUTE .. "' route on " .. DEVICE .. "\n")
  end
  Core.quit ()
end

local om = ObjectManager {
  Interest {
    type = "device",
    Constraint { "device.name", "=", DEVICE },
  }
}

om:connect ("installed", function (om)
  local device = om:lookup ()
  if not device then
    quit (1)
    return
  end

  for p in device:iterate_params ("Route") do
    local route = p:parse ().properties
    if route.name == ROUTE and route.direction == "Output" then
      local current = route.props and route.props.properties or {}
      local channels = current.channelVolumes and #current.channelVolumes or 2
      local volumes = { "Spa:Float" }
      for i = 1, channels do
        volumes[i + 1] = VOLUME
      end
      print (string.format ("route %s: volumes %s -> %.2f, mute %s -> false",
        ROUTE, table.concat (current.channelVolumes or {}, ","), VOLUME,
        tostring (current.mute)))
      device:set_param ("Route", Pod.Object {
        "Spa:Pod:Object:Param:Route", "Route",
        index = route.index,
        device = route.device,
        props = Pod.Object {
          "Spa:Pod:Object:Param:Props", "Route",
          mute = false,
          channelVolumes = Pod.Array (volumes),
        },
        save = true,
      })
      Core.sync (function () quit (0) end)
      return
    end
  end
  quit (1)
end)

om:activate ()
