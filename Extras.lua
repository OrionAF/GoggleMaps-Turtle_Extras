-- Companion addon for GoggleMaps/Turtle. Vanilla 1.12 Lua.

local _G = getfenv(0)

local function isFunc(f) return type(f) == "function" end

-- Wait until GoggleMaps is available; robust bootstrap
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

local function TryInit()
  local GMglobal = _G.GoggleMaps
  if not GMglobal or GMglobal._Extras_Initialized then return end
  -- Wait until core subsystems are present
  if not (GMglobal.Map and GMglobal.Hotspots and GMglobal.Overlay and GMglobal.Utils) then return end
  local GM = GMglobal
  local Extras = {}

  -- Central state for Extras
  Extras.state = {
    selectedMapId = nil,
    clickQuery = false,
    frames = {},
    fileZones = {},
    sessionEdits = {},
    customSpots = {},
    undoStack = {}
  }

  -- Utility: unified printing
  function Extras:Print(fmt, a,b,c,d,e,f,g,h,i,j)
    local title = (GetAddOnMetadata(GM.name, "Title") or GM.name or "GoggleMaps")
    local msg = fmt
    if a ~= nil then msg = string.format(fmt or "", a,b,c,d,e,f,g,h,i,j) end
    (_G.DEFAULT_CHAT_FRAME or { AddMessage = function() end }):AddMessage(title .. ": |r" .. (msg or ""))
  end

  -- Utility: frame-relative cursor position (scale-corrected)
  local function CursorPosIn(frame)
    local scale = frame:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx = cx / scale; cy = cy / scale
    local l = frame:GetLeft(); local t = frame:GetTop()
    return cx - l, t - cy
  end

  local function nearlyEqual(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return math.abs(a - b) < 0.0001
  end

  -- Utility: throttle any target method by Hz and/or a state key
  -- changedFn(target) should return a string key representing state; if nil, only time is used
  function Extras:WrapThrottle(target, methodName, hz, changedFn)
    if not target or not target[methodName] or target["_Extras_Thr_" .. methodName] then return end
    local orig = target[methodName]
    local interval = (hz and hz > 0) and (1 / hz) or 0
    local lastT, lastKey = 0, nil
    target[methodName] = function(self)
      local now = GetTime and GetTime() or 0
      local key = changedFn and changedFn(self)
      local changed = (key ~= nil and key ~= lastKey)
      if changed or (interval == 0) or (now - lastT) >= interval then
        lastT, lastKey = now, key or lastKey
        return orig(self)
      end
    end
    target["_Extras_Thr_" .. methodName] = true
  end

  -- Utility: rebuild hotspots and refresh UI
  function Extras:RebuildHotspotsAndUI()
    self:LoadFileHotspots(); self:RebuildSessionSpots(); self:RefreshEditorList()
  end

  -- Selection helpers
  function Extras:GetSelectedMapId()
    return self.state.selectedMapId or self._selectedMapId
  end
  function Extras:SetSelectedMapId(mapId)
    self.state.selectedMapId = mapId; self._selectedMapId = mapId
  end
  function Extras:IsClickQuery() return self.state.clickQuery or self._clickQuery end
  function Extras:SetClickQuery(v) self.state.clickQuery = v and true or false; self._clickQuery = self.state.clickQuery end

  function Extras:SelectZone(mapId, reason, opts)
    if not mapId then return end
    local suppress = opts and opts.suppressOverlay
    local force = opts and opts.force
    local mapFrame, overlayFrame, wasMapVisible, wasOverlayVisible
    if suppress then
      mapFrame = GM.frame
      overlayFrame = GM.Overlay and GM.Overlay.frame
      wasMapVisible = mapFrame and mapFrame:IsVisible()
      wasOverlayVisible = overlayFrame and overlayFrame:IsVisible()
    end
    local Map = GM.Map
    local current = self:GetSelectedMapId() or (Map and Map.mapId)
    if current and mapId == current and not force then
      if suppress then
        if mapFrame and not wasMapVisible and mapFrame:IsVisible() then mapFrame:Hide() end
        if overlayFrame and not wasOverlayVisible and overlayFrame:IsVisible() then overlayFrame:Hide() end
      end
      return
    end
    self:SetSelectedMapId(mapId)
    if Map then Map.mapId = mapId end
    -- Allow map API calls during our own selection change
    local old = self._allowMapChange; self._allowMapChange = true
    if isFunc(GM.Utils.setCurrentMap) then GM.Utils.setCurrentMap(mapId, reason or "Extras select") end
    self._lastSelectTs = GetTime and GetTime() or 0
    self._allowMapChange = old
    if GM.Overlay then
      GM.Overlay:AddMapIdToZonesToDraw(Map and Map.realMapId or mapId)
      GM.Overlay:AddMapIdToZonesToDraw(mapId)
    end
    if _G.pfMap and _G.pfMap.UpdateNodes then
      _G.pfMap:UpdateNodes()
    end
    if suppress then
      if mapFrame and not wasMapVisible and mapFrame:IsVisible() then mapFrame:Hide() end
      if overlayFrame and not wasOverlayVisible and overlayFrame:IsVisible() then overlayFrame:Hide() end
    end
  end

  function Extras:ClearSelection(reason)
    local Map = GM.Map
    local realId = Map and Map.realMapId
    self:SetSelectedMapId(nil)
    if Map then Map.mapId = realId end
    if isFunc(GM.Utils.setCurrentMap) then GM.Utils.setCurrentMap(realId, reason or "Extras clear") end
    if GM.Overlay and realId then
      GM.Overlay:AddMapIdToZonesToDraw(realId)
    end
    if _G.pfMap and _G.pfMap.UpdateNodes then _G.pfMap:UpdateNodes() end
  end

  function Extras:RefreshCurrentMap(reason)
    local mapId = self:GetSelectedMapId()
    if not mapId and GM.Map then
      mapId = GM.Map.mapId or GM.Map.realMapId
    end
    if not mapId then return end
    self:SelectZone(mapId, reason or "Extras refresh", { force = true })
  end

  -- SavedVars bucket
  -- In-memory only (no SavedVariables persisted)
  GM.ExtrasDB = GM.ExtrasDB or { editor = { enabled = false } }

  ----------------------------------------------------------------------
  -- 1) Full-map toggle and no auto-open
  ----------------------------------------------------------------------
  if GM and GM.Toggle and not GM._Extras_OriginalToggle then
    GM._Extras_OriginalToggle = GM.Toggle
    function GM:Toggle()
      -- Open full map when closed; hide when open
      if not self.frame or not self.frame:IsVisible() then
        self.isMini = false
        if _G.GoggleMapsDB then _G.GoggleMapsDB.isMini = false end
        if isFunc(self.RestoreSizeAndPosition) then self:RestoreSizeAndPosition() end
        self.frame:Show()
      else
        self.frame:Hide()
      end
    end
  end

  -- Hide on login (in case base opens it)
  if GM and GM.frame and GM.frame:IsVisible() then GM.frame:Hide() end

  ----------------------------------------------------------------------
  -- Debug gating and quiet toggle-off
  ----------------------------------------------------------------------
  if GM and GM.ToggleDebug and not GM._Extras_ToggleDebugWrapped then
    GM._Extras_ToggleDebugWrapped = true
    function GM:ToggleDebug()
      self.DEBUG_MODE = not self.DEBUG_MODE
      GoggleMapsDB.DEBUG_MODE = self.DEBUG_MODE
      if self.DEBUG_MODE then
        Utils.debug("Debug mode ON")
        if self.debugFrame then self.debugFrame:Show() end
      else
        if self.debugFrame then self.debugFrame:Hide() end
      end
    end
  end

  -- Suppress noisy non-debug logs like map change reason when debug is off
  if GM and GM.Utils and GM.Utils.log and not GM.Utils._Extras_LogWrapped then
    GM.Utils._Extras_LogWrapped = true
    local origLog = GM.Utils.log
    function GM.Utils.log(msg, a,b,c,d,e,f,g,h,i,j)
      if type(msg) == "string" then
        if string.find(msg, "Map change reason:", 1, true) and not GM.DEBUG_MODE then
          return
        end
      end
      return origLog(msg, a,b,c,d,e,f,g,h,i,j)
    end
  end

  ----------------------------------------------------------------------
  -- 2) Slash command wrapper (/gmaps ...)
  ----------------------------------------------------------------------
  local devEnabled = false
  if isFunc(_G.IsAddOnLoaded) and _G.IsAddOnLoaded("GoggleMaps_Dev") == 1 then
    devEnabled = true
  elseif isFunc(_G.LoadAddOn) then
    -- Try to load on demand; guard with pcall for safety on 1.12
    local ok = pcall(_G.LoadAddOn, "GoggleMaps_Dev")
    if ok and isFunc(_G.IsAddOnLoaded) and _G.IsAddOnLoaded("GoggleMaps_Dev") == 1 then
      devEnabled = true
    end
  end
  local origHandler = _G.SlashCmdList and _G.SlashCmdList.GMAPS

  local function msg(s) Extras:Print(s) end

  local function handleExtras(cmd, arg1, arg2)
    if cmd == "dev" then
      if not devEnabled then
        msg("Dev tools disabled. Enable GoggleMaps_Dev.")
      else
        msg("Dev commands:")
        msg("- /gmaps edit: Toggle hotspot editor")
        msg("- /gmaps hsui: Hotspot list UI (delete/export)")
        msg("- /gmaps export [session|current|mapId]: Copy hotspot lines")
        msg("- /gmaps drawzone <id|name|off>: Force draw target zone")
        msg("- /gmaps mode <rect|poly>: Drawing mode")
        msg("- /gmaps polyres <step>: Polygon fill resolution (default 1.0)")
        msg("- /gmaps combine [all|mapId]: Merge touching session hotspots")
      end
      return true
    end

    if not devEnabled then return false end

    if cmd == "edit" or cmd == "hotspotedit" or cmd == "hse" then
      GM.ExtrasDB.editor.enabled = not GM.ExtrasDB.editor.enabled
      Extras:SetEditorEnabled(GM.ExtrasDB.editor.enabled)
      msg("Hotspot editor: " .. (GM.ExtrasDB.editor.enabled and "ON" or "OFF"))
      return true
    elseif cmd == "hsui" or cmd == "hslist" then
      Extras:ShowEditorList()
      return true
    elseif cmd == "export" or cmd == "exporthotspots" then
      local target = arg1 and string.lower(arg1) or nil
      local mapId
      if not target or target == "" or target == "all" or target == "session" then
        mapId = nil
      elseif target == "current" or target == "selected" then
        mapId = Extras:GetSelectedMapId() or (GM.Map and (GM.Map.mapId or GM.Map.realMapId))
      else
        mapId = tonumber(arg1)
        if not mapId then
          msg("Export: provide a numeric mapId, 'session', or 'current'.")
          return true
        end
      end
      Extras:ExportHotspots(mapId)
      return true
    elseif cmd == "hs" then
      local mode = arg1 and string.lower(arg1) or nil
      if mode == "off" then
        Extras.showAllHotspots = false
        Extras.showAllHotspotsAll = false
        msg("Hotspot overlay: OFF")
      else
        Extras.showAllHotspots = true
        Extras.showAllHotspotsAll = (mode == "all")
        if Extras.showAllHotspotsAll then
          msg("Hotspot overlay: ON (all continents)")
        else
          msg("Hotspot overlay: ON (current continent)")
        end
      end
      Extras:DrawOverlays()
      return true
    elseif cmd == "drawzone" or cmd == "dz" then
      local target = arg1
      if not target or target == "off" or target == "clear" then
        Extras._forceDrawMapId = nil
        if GM.ExtrasDB and GM.ExtrasDB.editor then GM.ExtrasDB.editor.forceMapId = nil end
        msg("Draw zone: OFF")
        return true
      end
      local mapId
      if tonumber(target) then
        mapId = tonumber(target)
      else
        local lower = string.lower(target)
        for id, area in pairs(GM.Map.Area) do
          if area and area.name and string.lower(area.name) == lower then mapId = id; break end
        end
      end
      if mapId and GM.Map.Area[mapId] then
        Extras._forceDrawMapId = mapId
        if GM.ExtrasDB and GM.ExtrasDB.editor then GM.ExtrasDB.editor.forceMapId = mapId end
        msg(string.format("Draw zone: %s (%d)", GM.Map.Area[mapId].name or "?", mapId))
        Extras:SelectZone(mapId, "Extras drawzone", { suppressOverlay = true })
      else
        msg("Draw zone: invalid mapId or name")
      end
      return true
    elseif cmd == "mode" or cmd == "drawmode" or cmd == "dm" then
      local m = arg1 and string.lower(arg1) or ""
      if m == "rect" or m == "poly" then
        Extras._drawMode = m
        msg("Draw mode: " .. m)
      else
        msg("Draw mode: rect|poly")
      end
      return true
    elseif cmd == "polyres" then
      local s = tonumber(arg1)
      if s and s > 0.1 and s <= 10 then
        Extras._polyRes = s
        msg(string.format("Polygon resolution: %.2f", s))
      else
        msg("Polygon resolution must be >0.1 and <=10")
      end
      return true
    elseif cmd == "combine" or cmd == "merge" then
      local scope = arg1 and string.lower(arg1) or nil
      local mapId
      if scope == "all" then
        mapId = nil
      elseif scope and scope ~= "" then
        mapId = tonumber(scope)
      end
      if not mapId and scope ~= "all" then
        mapId = Extras:GetSelectedMapId() or (GM.Map and (GM.Map.realMapId or GM.Map.mapId))
      end
      if not mapId and scope ~= "all" then
        msg("Combine: no map selected.")
        return true
      end
      Extras:CombineSessionHotspots(mapId)
      return true
    elseif cmd == "dbg" or cmd == "debug" then
      local mode = arg1 and string.lower(arg1) or "toggle"
      if mode == "on" then
        if not GM.DEBUG_MODE then GM:ToggleDebug() end
        if GM.debugFrame then GM.debugFrame:Show() end
      elseif mode == "off" then
        if GM.DEBUG_MODE then GM:ToggleDebug() end
      else
        GM:ToggleDebug()
      end
      Extras:InitDebugPanel()
      return true
    elseif cmd == "trace" then
      Extras.debugTrace = not Extras.debugTrace
      msg("Extras trace: " .. (Extras.debugTrace and "ON" or "OFF"))
      return true
    elseif cmd == "pfrefresh" then
      Extras:ForcePfQuestRefresh(true)
      return true
    elseif cmd == "clearselect" then
      Extras:ClearSelection("Extras clearselect")
      msg("Selection cleared; reverted to player zone.")
      return true
    end
    return false
  end

  if _G.SlashCmdList then
    _G.SlashCmdList.GMAPS = function(msgText)
      local cmd, a1 = string.gfind(msgText or "", "([^ ]+)%s*(.*)")()
      cmd = cmd and string.lower(cmd) or nil
      if cmd and handleExtras(cmd, a1) then return end
      if origHandler then origHandler(msgText) end
    end
  end

  ----------------------------------------------------------------------
  -- 3) Custom hotspot layer + catch-all
  ----------------------------------------------------------------------
  Extras.customSpots = Extras.state.customSpots   -- world-rects per mapId (file + session)
  Extras.fileZones = Extras.state.fileZones       -- zone-rects per mapId from override file
  Extras.sessionEdits = Extras.state.sessionEdits -- zone-rects per mapId (drawn this session)
  Extras.frames = Extras.state.frames             -- overlay frames for debug
  Extras.undoStack = Extras.state.undoStack       -- stack of draw actions for undo
  Extras.previewFrames = {}

  local function worldRect(mapId, x, y, w, h)
    local x1, y1 = GM.Utils.GetWorldPos(mapId, x, y)
    local x2, y2 = GM.Utils.GetWorldPos(mapId, x + w, y + h)
    return x1, y1, x2, y2
  end

  function Extras:LoadFileHotspots()
    self.fileZones = {}
    self.customSpots = {}
    local src = _G.GoggleMaps.CustomHotspots or {}
    for mapId, rects in pairs(src) do
      local list = {}; local world = {}
      for part in string.gfind(rects, "([^~]+)") do
        local x, y, w, h, name = GM.Utils.splitString(part, "^")
        x = tonumber(x); y = tonumber(y); w = tonumber(w); h = tonumber(h); name = name or "CUSTOM"
        if x and y and w and h then
          table.insert(list, { x = x, y = y, w = w, h = h, name = name })
          local x1, y1, x2, y2 = worldRect(mapId, x, y, w, h)
          table.insert(world, { x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
        end
      end
      self.fileZones[mapId] = list
      self.customSpots[mapId] = (self.customSpots[mapId] or {})
      for _, r in ipairs(world) do table.insert(self.customSpots[mapId], r) end
    end
  end

  function Extras:RebuildSessionSpots()
    for mapId, list in pairs(self.sessionEdits) do
      self.customSpots[mapId] = self.customSpots[mapId] or {}
      for _, r in ipairs(list) do
        local x1, y1, x2, y2 = worldRect(mapId, r.x, r.y, r.w, r.h)
        table.insert(self.customSpots[mapId], { x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
      end
    end
  end

  -- Overlay visualizer (simple)
  local overlay = CreateFrame("Frame", "GoggleMapsExtrasOverlay", GM.Overlay and GM.Overlay.frame or GM.frame.Content)
  overlay:SetAllPoints()
  overlay:SetFrameLevel((GM.frame and GM.frame:GetFrameLevel() or 1) + 400)
  overlay:Hide()

  local function getRectFrame(name)
    local fr = Extras.frames[name]
    if not fr then
      fr = CreateFrame("Frame", nil, overlay)
      local t = fr:CreateTexture(nil, "OVERLAY")
      t:SetAllPoints(fr)
      t:SetTexture("Interface\\Buttons\\WHITE8x8")
      fr.texture = t
      Extras.frames[name] = fr
    end
    return fr
  end

  local function getPreviewDot(index)
    local fr = Extras.previewFrames[index]
    if not fr then
      fr = CreateFrame("Frame", nil, overlay)
      local t = fr:CreateTexture(nil, "OVERLAY")
      t:SetAllPoints(fr)
      t:SetTexture("Interface\\Buttons\\WHITE8x8")
      fr.texture = t
      Extras.previewFrames[index] = fr
    end
    return fr
  end

  function Extras:ClearPolyPreview()
    for i, fr in ipairs(self.previewFrames) do
      fr:Hide()
    end
  end

  function Extras:DrawPolyPreview(points, curWx, curWy)
    -- draw small dots at each poly world point and optional current cursor point
    if not points then return end
    local DOT = 8 -- world units
    local shown = 0
    for i = 1, table.getn(points) do
      local p = points[i]
      local dot = getPreviewDot(i)
      if GM.Overlay:ClipFrame(dot, (p.wx - DOT/2), (p.wy - DOT/2), DOT, DOT) then
        dot.texture:SetVertexColor(0, 1, 1, 0.7)
        dot:Show()
        shown = shown + 1
      else
        dot:Hide()
      end
    end
    if curWx and curWy then
      local dot = getPreviewDot(table.getn(points) + 1)
      if GM.Overlay:ClipFrame(dot, (curWx - DOT/2), (curWy - DOT/2), DOT, DOT) then
        dot.texture:SetVertexColor(0, 1, 1, 0.5)
        dot:Show()
        shown = shown + 1
      else
        dot:Hide()
      end
    end
    -- hide any extra dots
    local idx = shown + 1
    while self.previewFrames[idx] do
      self.previewFrames[idx]:Hide()
      idx = idx + 1
    end
    overlay:Show()
  end

  function Extras:DrawOverlays()
    local shown = 0
    local touched = {}

    local function shouldDrawMap(mapId)
      if Extras.showAllHotspotsAll then return true end
      local currentMap = GM.Map and (GM.Map.realMapId or GM.Map.mapId)
      if not currentMap then return false end
      return GM.Utils.getContinentId(mapId) == GM.Utils.getContinentId(currentMap)
    end

    if self.showAllHotspots then
      -- Show ONLY Extras custom hotspots (file + session)
      for mapId, list in pairs(self.customSpots) do
        if shouldDrawMap(mapId) then
          for i, r in ipairs(list) do
            local key = "custom:" .. mapId .. ":" .. i
            local fr = getRectFrame(key)
            if GM.Overlay:ClipFrame(fr, r.x1, r.y1, (r.x2 - r.x1), (r.y2 - r.y1)) then
              fr.texture:SetVertexColor(1, 0, 0, 0.28)
              fr:Show(); shown = shown + 1
            else fr:Hide() end
            touched[key] = true
          end
        end
      end
      -- Ensure any old hotspot frames are hidden when no longer in use
      for key, fr in pairs(self.frames) do
        local prefix = string.sub(key or "", 1, 7)
        if ((prefix == "custom:" or string.sub(prefix, 1, 3) == "hs:") and not touched[key]) then
          fr:Hide()
        end
      end
    else
      -- Hide all hotspot frames when overlay is off
      for key, fr in pairs(self.frames) do
        if string.sub(key or "", 1, 3) == "hs:" or string.sub(key or "", 1, 7) == "custom:" then
          fr:Hide()
        end
      end
    end

    if shown > 0 then overlay:Show() else overlay:Hide() end
  end



  -- Hook map update to draw overlays and keep DB rects synced
  if GM and GM.handleUpdate and not GM._Extras_UpdateWrapped then
    local baseUpdate = GM.handleUpdate
    GM._Extras_UpdateWrapped = true
    function GM:handleUpdate()
      baseUpdate(self)
      if not (self.frame and self.frame:IsVisible()) then return end
      if GM.DEBUG_MODE and GM.debugFrame and GM.debugFrame:IsShown() and not Extras._debugPanelInit then
        Extras:InitDebugPanel()
      end
      Extras:DrawOverlays()
      Extras:UpdateDebugPanel()
    end
  end

  -- Build initial caches
  Extras:LoadFileHotspots(); Extras:RebuildSessionSpots()

  -- Install mouse click handlers to drive click-only hotspot switching
  if GM.Map and GM.Map.frame and not Extras._mouseHooksInstalled then
    Extras._mouseHooksInstalled = true
    local frame = GM.Map.frame
    local prevOnMouseDown = frame:GetScript("OnMouseDown")
    local prevOnMouseUp = frame:GetScript("OnMouseUp")
    frame:SetScript("OnMouseDown", function()
      if prevOnMouseDown then prevOnMouseDown() end
      local dx, dy = CursorPosIn(frame)
      Extras._downX, Extras._downY = dx, dy
    end)
    frame:SetScript("OnMouseUp", function()
      if prevOnMouseUp then prevOnMouseUp() end
      local upx, upy = CursorPosIn(frame)
      local downx, downy = Extras._downX, Extras._downY
      if not (downx and downy and upx and upy) then return end
      local moved = (math.abs(upx - downx) > 4) or (math.abs(upy - downy) > 4)
      if moved then return end
      local winx, winy = GM.Utils.getMouseOverPos(frame)
      if not (winx and winy) then return end
      local worldX, worldY = GM.Utils.FramePosToWorldPos(winx, winy)
      Extras:SetClickQuery(true)
      local newMapId = GM.Hotspots:CheckWorldHotspots(worldX, worldY)
      Extras:SetClickQuery(false)
      if newMapId then
        Extras:SelectZone(newMapId, "Extras click")
      end
    end)
  end

  -- Persist selection after click: prevent base from reverting to real map when mouse leaves
  if GM.Map and GM.Utils and GM.Utils.getMouseOverPos and not Extras._persistHook then
    Extras._persistHook = true
    GM.Utils._Extras_OrigGetMouseOverPos = GM.Utils.getMouseOverPos
    function GM.Utils.getMouseOverPos(frame)
      local x, y = GM.Utils._Extras_OrigGetMouseOverPos(frame)
      if x and y then return x, y end
      if Extras._selectedMapId and frame then
        local w = frame:GetWidth()
        local h = frame:GetHeight()
        if w and h then
          return w / 2, h / 2
        end
      end
      return nil, nil
    end
  end

  -- Align pfQuest/pfMap updates to the selected zone context to avoid pin reverts
  local function WrapPfMapWhenReady()
    if _G.pfMap and not _G.pfMap._Extras_AlignSelected then
      _G.pfMap._Extras_AlignSelected = true
      local pfm = _G.pfMap
      local orig = pfm.UpdateNodes
      pfm.UpdateNodes = function(self)
        local this = self or pfm
        local sel = Extras:GetSelectedMapId()
        if sel and GM.frame and GM.frame:IsVisible() and GetCurrentMapContinent and GetCurrentMapZone then
          local wantCont = GM.Utils.getContinentId(sel)
          local area = GM.Map and GM.Map.Area[sel]
          local wantZone = area and area.Zone
          if wantCont and wantZone then
            local curCont = GetCurrentMapContinent() or -1
            local curZone = GetCurrentMapZone() or -1
            if curCont ~= wantCont or curZone ~= wantZone then
              if not this._extras_forcing then
                this._extras_forcing = true
                SetMapZoom(wantCont, wantZone)
                local r = orig(this)
                this._extras_forcing = nil
                return r
              end
            end
          end
        end
        return orig(this)
      end
      return true
    end
    return false
  end
  if not WrapPfMapWhenReady() then
    local waiter = CreateFrame("Frame")
    local tries = 0
    waiter:SetScript("OnUpdate", function()
      tries = tries + 1
      if WrapPfMapWhenReady() or tries > 600 then
        waiter:SetScript("OnUpdate", nil)
      end
    end)
  end

  ----------------------------------------------------------------------
  -- 3b) Performance helpers and behavior changes
  ----------------------------------------------------------------------
  -- Debug panel (integrated with GMapsDebug)
  function Extras:InitDebugPanel()
    local dbg = GM and GM.GMapsDebug
    if not dbg or self._debugPanelInit then return end
    dbg:AddItem("Ex real/fake", "-")
    dbg:AddItem("Ex sel", "-")
    dbg:AddItem("Ex blizz", "-")
    dbg:AddItem("Ex scale", "-")
    dbg:AddItem("Ex pfPins", "-")
    dbg:AddItem("Ex overlays", "-")
    self._debugPanelInit = true
  end

  function Extras:UpdateDebugPanel()
    local dbg = GM and GM.GMapsDebug
    if not dbg then return end
    local Map = GM.Map
    local realId = Map and Map.realMapId or 0
    local mapId = Map and Map.mapId or 0
    local sel = self._selectedMapId or 0
    local blizzCont = (GetCurrentMapContinent and GetCurrentMapContinent()) or -1
    local blizzZone = (GetCurrentMapZone and GetCurrentMapZone()) or -1
    local pf = self._pf or {}
    local overlays = GM.Overlay and table.getn(GM.Overlay.zonesToDraw or {}) or 0
    dbg:UpdateItem("Ex real/fake", string.format("%d/%d", realId, mapId))
    dbg:UpdateItem("Ex sel", sel)
    dbg:UpdateItem("Ex blizz", string.format("%d/%d", blizzCont, blizzZone))
    dbg:UpdateItem("Ex scale", Map and Map.scale or 0)
    dbg:UpdateItem("Ex pfPins", string.format("%d/%d/%d", pf.count or 0, pf.shown or 0, pf.hidden or 0))
    dbg:UpdateItem("Ex overlays", overlays)
  end

  function Extras:Trace(fmt, a,b,c,d,e,f,g,h,i,j)
    if not self.debugTrace then return end
    DEFAULT_CHAT_FRAME:AddMessage("Extras: |r" .. string.format(fmt or "", a,b,c,d,e,f,g,h,i,j))
  end

  function Extras:ForcePfQuestRefresh(verbose)
    if _G.pfMap and _G.pfMap.UpdateNodes then
      _G.pfMap:UpdateNodes() -- compat hook will call GM.compat.pfQuest:UpdateNodes automatically
      if verbose then self:Trace("Forced pfQuest refresh (pfMap:UpdateNodes)") end
    end
  end

  -- Click-only hotspot detection: Extras overrides base/Turtle hotspots completely
  if GM.Hotspots and not GM.Hotspots._Extras_ClickOnly then
    GM.Hotspots._Extras_ClickOnly = true
    local HS = GM.Hotspots
    function HS:CheckWorldHotspots(worldX, worldY)
      if Extras._editing then return nil end
      if not Extras._clickQuery then return nil end
      -- Only use Extras custom hotspots (file + session)
      for mapId, list in pairs(Extras.customSpots) do
        for _, r in ipairs(list) do
          if worldX >= r.x1 and worldX <= r.x2 and worldY >= r.y1 and worldY <= r.y2 then
            return mapId
          end
        end
      end
      return nil
    end
  end

  -- Ensure initial overlays only include the real map (player zone) until explicitly clicked
  if not Extras._didInitialOverlayReset then
    Extras._didInitialOverlayReset = true
    local waiter = CreateFrame("Frame")
    local tries = 0
    waiter:SetScript("OnUpdate", function()
      tries = tries + 1
      if GM.Map and GM.Map.realMapId and GM.Overlay and GM.Overlay.zonesToDraw then
        local ov = GM.Overlay
        local list = ov.zonesToDraw
        for i = 1, table.getn(list or {}) do
          table.insert(ov.zonesToClear, list[i])
        end
        ov.zonesToDraw = {}
        if GM.Map.realMapId then ov:AddMapIdToZonesToDraw(GM.Map.realMapId) end
        if not Extras:GetSelectedMapId() then
          Extras:SelectZone(GM.Map.realMapId, "Extras init")
        end
        if ov.UpdateOverlays then ov:UpdateOverlays() end
        waiter:SetScript("OnUpdate", nil)
      elseif tries > 600 then
        waiter:SetScript("OnUpdate", nil)
      end
    end)
  end

  ----------------------------------------------------------------------
  -- 4) Minimal editor (dev-only): draw rectangles & export
  ----------------------------------------------------------------------
  -- Hotspot listing + export UI
  function Extras:_buildHotspotList(mapId)
    local list = {}
    if mapId then
      local fz = self.fileZones[mapId] or {}
      for i = 1, table.getn(fz) do
        local r = fz[i]
        table.insert(list, { mapId = mapId, x = r.x, y = r.y, w = r.w, h = r.h, name = r.name or "CUSTOM", source = "file" })
      end
      local sz = self.sessionEdits[mapId] or {}
      for i = 1, table.getn(sz) do
        local r = sz[i]
        table.insert(list, { mapId = mapId, x = r.x, y = r.y, w = r.w, h = r.h, name = r.name or "CUSTOM", source = "session", index = i })
      end
    else
      for mid, fz in pairs(self.fileZones) do
        for i = 1, table.getn(fz) do
          local r = fz[i]
          table.insert(list, { mapId = mid, x = r.x, y = r.y, w = r.w, h = r.h, name = r.name or "CUSTOM", source = "file" })
        end
      end
      for mid, sz in pairs(self.sessionEdits) do
        for i = 1, table.getn(sz) do
          local r = sz[i]
          table.insert(list, { mapId = mid, x = r.x, y = r.y, w = r.w, h = r.h, name = r.name or "CUSTOM", source = "session", index = i })
        end
      end
    end
    return list
  end

  -- Export session hotspots to a copy-friendly window. If mapId is nil, exports all maps in session.
  function Extras:ExportHotspots(mapId)
    if not devEnabled then return end
    if type(mapId) == "string" then
      mapId = tonumber(mapId)
    end
    local function fmt(r)
      return string.format("%.2f^%.2f^%.2f^%.2f^%s", r.x, r.y, r.w, r.h, r.name or "CUSTOM")
    end
    local lines = {}
    local function exportFor(mid)
      local sz = self.sessionEdits[mid] or {}
      if table.getn(sz) > 0 then
        local buf = {}
        for i = 1, table.getn(sz) do table.insert(buf, fmt(sz[i])) end
        table.insert(lines, string.format("[%d] = \"%s\",", mid, table.concat(buf, "~")))
      end
    end
    if mapId then
      exportFor(mapId)
    else
      for mid, _ in pairs(self.sessionEdits) do exportFor(mid) end
    end
    local text = table.getn(lines) > 0 and table.concat(lines, "\n") or ""
    self:ShowExportWindow(text)
  end

  function Extras:ShowExportWindow(text)
    if not self._exportWin then
      local frame = CreateFrame("Frame", "GMExtrasExport", UIParent)
      frame:SetWidth(680); frame:SetHeight(420)
      frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
      frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 5, right = 5, top = 5, bottom = 5 } })
      frame:SetBackdropColor(0, 0, 0, 0.92)
      frame:EnableMouse(true); frame:SetMovable(true)
      frame:SetClampedToScreen(true)
      frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart", function() frame:StartMoving() end)
      frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

      local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      title:SetPoint("TOP", 0, -8)
      title:SetText("GoggleMaps Export (Session)")

      local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      close:SetPoint("TOPRIGHT", -10, -6); close:SetWidth(60); close:SetHeight(22)
      close:SetText("Close"); close:SetScript("OnClick", function() frame:Hide() end)

      local scroll = CreateFrame("ScrollFrame", "GMExtrasExportScroll", frame, "UIPanelScrollFrameTemplate")
      scroll:SetPoint("TOPLEFT", 12, -32); scroll:SetPoint("BOTTOMRIGHT", -30, 12)
      local edit = CreateFrame("EditBox", "GMExtrasExportEdit", scroll)
      edit:SetMultiLine(true); edit:SetWidth(620); edit:SetAutoFocus(true)
      if _G.ChatFontNormal then edit:SetFontObject(ChatFontNormal) end
      edit:SetScript("OnEscapePressed", function() frame:Hide() end)
      edit:SetScript("OnEditFocusGained", function() edit:HighlightText() end)
      scroll:SetScrollChild(edit)

      frame.scroll = scroll; frame.edit = edit
      frame:SetScript("OnShow", function() edit:HighlightText(); edit:SetFocus() end)
      self._exportWin = frame
    end
    self._exportWin:Show()
    if self._exportWin.edit then
      self._exportWin.edit:SetText(text or "")
      self._exportWin.edit:HighlightText()
      self._exportWin.edit:SetFocus()
    end
  end

  function Extras:ShowEditorList()
    if not devEnabled then return end
    if not self._listFrame then
      local frame = CreateFrame("Frame", "GMExtrasHSUI", UIParent)
      frame:SetWidth(500); frame:SetHeight(400)
      frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
      frame:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 3, right = 3, top = 5, bottom = 3 } })
      frame:SetBackdropColor(0, 0, 0, 0.85)
      frame:EnableMouse(true); frame:SetMovable(true)
    	frame:SetClampedToScreen(true)
      frame:RegisterForDrag("LeftButton"); frame:SetScript("OnDragStart", function() frame:StartMoving() end)
      frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

      local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      title:SetPoint("TOP", 0, -8)
      title:SetText("GoggleMaps Hotspots")
      frame.title = title

      local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      close:SetPoint("TOPRIGHT", -10, -6); close:SetWidth(60); close:SetHeight(22)
      close:SetText("Close"); close:SetScript("OnClick", function() frame:Hide() end)

      -- Export Session (all session hotspots across all maps)
      local exportSession = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      exportSession:SetPoint("BOTTOMLEFT", 12, 12); exportSession:SetWidth(120); exportSession:SetHeight(22)
      exportSession:SetText("Export Session")
      exportSession:SetScript("OnClick", function() Extras:ExportHotspots(nil) end)

      local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      clear:SetPoint("LEFT", exportSession, "RIGHT", 6, 0); clear:SetWidth(120); clear:SetHeight(22)
      clear:SetText("Clear Session")
      clear:SetScript("OnClick", function()
        Extras:ClearCurrentSession()
      end)

      -- Poly resolution slider
      local slider = CreateFrame("Slider", "GMExtrasPolyRes", frame, "OptionsSliderTemplate")
      slider:SetPoint("BOTTOMLEFT", 12, 70); slider:SetWidth(476)
      slider:SetMinMaxValues(0.5, 10.0); slider:SetValueStep(0.1)
      if slider.SetObeyStepOnDrag then -- not available on 1.12 sliders
        slider:SetObeyStepOnDrag(true)
      end
      slider:SetValue(Extras._polyRes or 1.0)
      local sName = slider:GetName()
      if _G[sName .. "Text"] then _G[sName .. "Text"]:SetText("PolyRes") end
      if _G[sName .. "Low"] then _G[sName .. "Low"]:SetText("0.5") end
      if _G[sName .. "High"] then _G[sName .. "High"]:SetText("10.0") end
      slider:SetScript("OnValueChanged", function()
        local v = this and this.GetValue and this:GetValue() or (slider.GetValue and slider:GetValue())
        if not v then return end
        Extras._polyRes = v
        Extras:Print(string.format("Polygon resolution: %.1f", v))
      end)

      local combineBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      combineBtn:SetWidth(80); combineBtn:SetHeight(22)
      combineBtn:ClearAllPoints(); combineBtn:SetPoint("BOTTOMLEFT", exportSession, "TOPLEFT", 0, 6)
      combineBtn:SetText("Combine")
      combineBtn:SetScript("OnClick", function() Extras:CombineCurrentSession() end)

      local undoBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      undoBtn:SetWidth(60); undoBtn:SetHeight(22)
      undoBtn:ClearAllPoints(); undoBtn:SetPoint("LEFT", combineBtn, "RIGHT", 6, 0)
      undoBtn:SetText("Undo")
      undoBtn:SetScript("OnClick", function() Extras:UndoLastDraw() end)

      local editBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      editBtn:SetWidth(60); editBtn:SetHeight(22)
      editBtn:ClearAllPoints(); editBtn:SetPoint("LEFT", undoBtn, "RIGHT", 6, 0)
      editBtn:SetText("Edit")
      editBtn:SetScript("OnClick", function()
        GM.ExtrasDB.editor.enabled = not GM.ExtrasDB.editor.enabled
        if editBtn.SetText then
          editBtn:SetText(GM.ExtrasDB.editor.enabled and "Edit: On" or "Edit: Off")
        end
        Extras:SetEditorEnabled(GM.ExtrasDB.editor.enabled)
        Extras:Print("Hotspot editor: " .. (GM.ExtrasDB.editor.enabled and "ON" or "OFF"))
      end)

      local hsOff = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      hsOff:SetWidth(70); hsOff:SetHeight(22)
      hsOff:ClearAllPoints(); hsOff:SetPoint("LEFT", editBtn, "RIGHT", 6, 0)
      hsOff:SetText("HS: Off")
      hsOff:SetScript("OnClick", function()
        Extras.showAllHotspots = false; Extras.showAllHotspotsAll = false; Extras:DrawOverlays(); Extras:Print("Hotspot overlay: OFF")
      end)

      -- Hotspot overlay buttons (Extras only)
      local hsAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      hsAll:SetWidth(70); hsAll:SetHeight(22)
      hsAll:ClearAllPoints(); hsAll:SetPoint("LEFT", hsOff, "RIGHT", 6, 0)
      hsAll:SetText("HS: All")
      hsAll:SetScript("OnClick", function()
        Extras.showAllHotspots = true; Extras.showAllHotspotsAll = true; Extras:DrawOverlays(); Extras:Print("Hotspot overlay: ON (all)")
      end)

      -- All maps toggle
      local allChk = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
      allChk:SetPoint("LEFT", clear, "RIGHT", 5, 0)
      allChk.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      allChk.text:SetPoint("LEFT", allChk, "RIGHT", 0, 1)
      allChk.text:SetText("All Maps")
      allChk:SetScript("OnClick", function()
        Extras._listAll = allChk:GetChecked() and true or false
        Extras:RefreshEditorList()
      end)
      frame.allChk = allChk


      -- Scroll area
      local listBG = frame:CreateTexture(nil, "BACKGROUND")
      listBG:SetPoint("TOPLEFT", 10, -30); listBG:SetPoint("BOTTOMRIGHT", -10, 100)
      listBG:SetTexture(0.1, 0.1, 0.1, 0.6)

      local scroll = CreateFrame("ScrollFrame", "GMExtrasHSUIScroll", frame, "UIPanelScrollFrameTemplate")
      scroll:SetPoint("TOPLEFT", 12, -30); scroll:SetPoint("BOTTOMRIGHT", -30, 100)
      local content = CreateFrame("Frame", nil, scroll)
      content:SetWidth(360); content:SetHeight(300)
      scroll:SetScrollChild(content)

      frame.scroll = scroll; frame.content = content
      self._listFrame = frame
      self._rows = {}
      self._rowHeight = 18
    end
    self:RefreshEditorList()
    self._listFrame:Show()
  end

  function Extras:_EnsureEditorRow(index)
    if not index or index < 1 then return nil end
    if not self._listFrame or not self._listFrame.content then return nil end
    self._rows = self._rows or {}
    if self._rows[index] then return self._rows[index] end

    if index > 1 and not self._rows[index - 1] then
      self:_EnsureEditorRow(index - 1)
    end

    local row = CreateFrame("Frame", nil, self._listFrame.content)
    row:SetHeight(self._rowHeight or 18)
    if index == 1 then
      row:SetPoint("TOPLEFT", 4, -4)
    else
      row:SetPoint("TOPLEFT", self._rows[index - 1], "BOTTOMLEFT", 0, -2)
    end

    local rowWidth = 330
    if self._listFrame.scroll and self._listFrame.scroll.GetWidth then
      local w = self._listFrame.scroll:GetWidth()
      if w and w > 0 then rowWidth = math.max(120, w - 30) end
    end
    row:SetWidth(rowWidth)

    local txt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    txt:SetPoint("LEFT", 2, 0); txt:SetJustifyH("LEFT")
    local textWidth = rowWidth - 30
    if textWidth < 80 then textWidth = math.max(40, rowWidth * 0.7) end
    txt:SetWidth(textWidth)
    row.text = txt

    local del = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    del:SetPoint("RIGHT", -2, 0); del:SetWidth(20); del:SetHeight(16); del:SetText("X")
    del:SetScript("OnClick", function()
      local it = row.item
      if it and it.source == "session" and Extras.sessionEdits[it.mapId] and Extras.sessionEdits[it.mapId][it.index] then
        table.remove(Extras.sessionEdits[it.mapId], it.index)
        Extras:LoadFileHotspots(); Extras:RebuildSessionSpots(); Extras:DrawOverlays(); Extras:RefreshEditorList()
      end
    end)
    row.delete = del

    self._rows[index] = row
    return row
  end

  function Extras:RefreshEditorList()
    if not self._listFrame then return end
    local frame = self._listFrame
    local mid
    if not self._listAll then
      mid = Extras:GetSelectedMapId() or (GM.Map and GM.Map.realMapId)
    else
      mid = nil
    end
    local baseItems = self:_buildHotspotList(mid)

    -- Group by mapId and add headers
    local grouped = {}
    for i = 1, table.getn(baseItems) do
      local it = baseItems[i]
      grouped[it.mapId] = grouped[it.mapId] or {}
      table.insert(grouped[it.mapId], it)
    end
    local items = {}
    for mapId, list in pairs(grouped) do
      table.insert(items, { type = "header", mapId = mapId })
      for i = 1, table.getn(list) do table.insert(items, list[i]) end
    end

    -- Resize content height
    local totalHeight = 8 + (table.getn(items) * (self._rowHeight + 2))
    frame.content:SetHeight(totalHeight)
    if frame.scroll and frame.scroll.UpdateScrollChildRect then frame.scroll:UpdateScrollChildRect() end
    if frame.scroll and frame.content and frame.scroll.GetWidth then
      local w = frame.scroll:GetWidth()
      if w and w > 0 then frame.content:SetWidth(w) end
    end

    -- Fill rows
    local rowWidth = 430
    if frame.scroll and frame.scroll.GetWidth then
      local w = frame.scroll:GetWidth()
      if w and w > 0 then rowWidth = math.max(120, w - 30) end
    end

    local maxRow = table.getn(items)
    for i = 1, maxRow do
      local row = self._rows[i] or self:_EnsureEditorRow(i)
      local it = items[i]
      if row then
        row:SetWidth(rowWidth)
        if row.text then
          local textWidth = rowWidth - 30
          if textWidth < 80 then textWidth = math.max(40, rowWidth * 0.7) end
          row.text:SetWidth(textWidth)
        end
        row.item = it
        if it then
          if it.type == "header" then
            local mapName = (GM.Map.Area[it.mapId] and GM.Map.Area[it.mapId].name) or tostring(it.mapId)
            local headerStr = string.format("%s (%d)", mapName, it.mapId)
            local headerLen = string.len(headerStr)
            local dashCount = math.floor((59 - headerLen) / 2)
            local fillerDashes = string.rep("-", dashCount)
            local startDashes = string.rep("-", 59)
            local endDashes = string.rep("-", 59)
            row.text:SetText(startDashes .. fillerDashes .. headerStr .. fillerDashes .. endDashes)
            row.delete:Hide()
          else
            local mapName = (GM.Map.Area[it.mapId] and GM.Map.Area[it.mapId].name) or tostring(it.mapId)
            row.text:SetText(string.format("[%d][%s] %.2f^%.2f^%.2f^%.2f^%s", it.mapId, it.source, it.x, it.y, it.w, it.h, it.name or "CUSTOM"))
            row.delete:Show()
            if it.source == "session" then row.delete:Enable() else row.delete:Disable() end
          end
          row:Show()
        else
          row:Hide()
        end
      end
    end

    for i = maxRow + 1, table.getn(self._rows) do
      local row = self._rows[i]
      if row then
        row.item = nil
        row:Hide()
      end
    end
  end

  -- Clears current session edits based on HSUI view state
  function Extras:ClearCurrentSession()
    if not self._listFrame then return end
    local cleared = 0
    local clearedAny = false
    if self._listAll then
      -- Clear all maps
      for mid, list in pairs(self.sessionEdits) do
        if list and table.getn(list) > 0 then
          self.sessionEdits[mid] = {}
          cleared = cleared + 1
          clearedAny = true
        end
      end
      self:Print("Cleared session hotspots for all maps")
    else
      local mid = Extras:GetSelectedMapId() or (GM.Map and GM.Map.realMapId)
      if mid and self.sessionEdits[mid] then
        self.sessionEdits[mid] = {}
        cleared = 1
        clearedAny = true
        local name = (GM.Map.Area[mid] and GM.Map.Area[mid].name) or tostring(mid)
        self:Print("Cleared session hotspots for " .. name)
      end
    end
    self:LoadFileHotspots(); self:RebuildSessionSpots()
    if clearedAny then self:RefreshCurrentMap("Extras clear session") end
    self:DrawOverlays(); self:RefreshEditorList()
  end

  function Extras:_CombineAxisAlignedRects(rects)
    local EPS = 0.0001
    local function cloneValid(list)
      local copy = {}
      for i = 1, table.getn(list) do
        local r = list[i]
        copy[i] = { x = r.x, y = r.y, w = r.w, h = r.h, name = r.name or "CUSTOM" }
      end
      return copy
    end
    local valid = {}
    for i = 1, table.getn(rects or {}) do
      local r = rects[i]
      if r then
        local w = r.w or 0
        local h = r.h or 0
        if w > EPS and h > EPS then
          local x = r.x or 0
          local y = r.y or 0
          table.insert(valid, { x = x, y = y, w = w, h = h, name = r.name })
        end
      end
    end
    if table.getn(valid) == 0 then return {} end

    local function collectEdges()
      local xs, ys = {}, {}
      for i = 1, table.getn(valid) do
        local r = valid[i]
        table.insert(xs, r.x)
        table.insert(xs, r.x + r.w)
        table.insert(ys, r.y)
        table.insert(ys, r.y + r.h)
      end
      local function dedupe(sorted)
        table.sort(sorted)
        local unique = {}
        for i = 1, table.getn(sorted) do
          local v = sorted[i]
          if table.getn(unique) == 0 or math.abs(v - unique[table.getn(unique)]) > EPS then
            table.insert(unique, v)
          end
        end
        return unique
      end
      return dedupe(xs), dedupe(ys)
    end

    local xs, ys = collectEdges()
    if table.getn(xs) < 2 or table.getn(ys) < 2 then
      return cloneValid(valid)
    end

    local function findIndex(arr, value)
      for i = 1, table.getn(arr) do
        if math.abs(arr[i] - value) <= EPS then
          return i
        end
      end
      local bestIdx, bestDelta
      for i = 1, table.getn(arr) do
        local delta = math.abs(arr[i] - value)
        if not bestDelta or delta < bestDelta then
          bestDelta = delta
          bestIdx = i
        end
      end
      if bestDelta and bestDelta <= (EPS * 10) then
        return bestIdx
      end
      return nil
    end

    local filled = {}
    for i = 1, table.getn(valid) do
      local r = valid[i]
      local x1Index = findIndex(xs, r.x)
      local x2Index = findIndex(xs, r.x + r.w)
      local y1Index = findIndex(ys, r.y)
      local y2Index = findIndex(ys, r.y + r.h)
      if x1Index and x2Index and y1Index and y2Index and x2Index > x1Index and y2Index > y1Index then
        for yIndex = y1Index, y2Index - 1 do
          local row = filled[yIndex]
          if not row then row = {}; filled[yIndex] = row end
          for xIndex = x1Index, x2Index - 1 do
            row[xIndex] = true
          end
        end
      end
    end

    local function pickName(x1, y1, x2, y2)
      for i = 1, table.getn(valid) do
        local src = valid[i]
        local sx1 = src.x
        local sy1 = src.y
        local sx2 = src.x + src.w
        local sy2 = src.y + src.h
        if sx1 <= x1 + EPS and sx2 >= x2 - EPS and sy1 <= y1 + EPS and sy2 >= y2 - EPS then
          if src.name and src.name ~= "" then return src.name end
        end
      end
      return "CUSTOM"
    end

    local final = {}
    local xCells = table.getn(xs) - 1
    local yCells = table.getn(ys) - 1

    local function addRect(x1Index, x2Index, y1Index, y2Index)
      if not x1Index or not x2Index or not y1Index or not y2Index then return end
      if x2Index <= x1Index or y2Index <= y1Index then return end
      local x1 = xs[x1Index]
      local x2 = xs[x2Index]
      local y1 = ys[y1Index]
      local y2 = ys[y2Index]
      if (x2 - x1) > EPS and (y2 - y1) > EPS then
        table.insert(final, {
          x = x1,
          y = y1,
          w = x2 - x1,
          h = y2 - y1,
          name = pickName(x1, y1, x2, y2)
        })
      end
    end

    local used = {}
    for yIndex = 1, yCells do
      local row = filled[yIndex]
      local usedRow = used[yIndex]
      local xIndex = 1
      while xIndex <= xCells do
        local cellFilled = row and row[xIndex]
        local cellUsed = usedRow and usedRow[xIndex]
        if cellFilled and not cellUsed then
          local xEnd = xIndex
          while xEnd <= xCells do
            local filledRow = row and row[xEnd]
            local usedRowVal = usedRow and usedRow[xEnd]
            if not filledRow or usedRowVal then break end
            xEnd = xEnd + 1
          end
          local yEnd = yIndex + 1
          while yEnd <= yCells do
            local nextRow = filled[yEnd]
            if not nextRow then break end
            local nextUsed = used[yEnd]
            local ok = true
            for xi = xIndex, xEnd - 1 do
              if not nextRow[xi] or (nextUsed and nextUsed[xi]) then
                ok = false
                break
              end
            end
            if not ok then break end
            yEnd = yEnd + 1
          end
          for yy = yIndex, yEnd - 1 do
            local markRow = used[yy]
            if not markRow then markRow = {}; used[yy] = markRow end
            for xx = xIndex, xEnd - 1 do
              markRow[xx] = true
            end
          end
          addRect(xIndex, xEnd, yIndex, yEnd)
          usedRow = used[yIndex]
          xIndex = xEnd
        else
          xIndex = xIndex + 1
        end
      end
    end

    local function mergeAdjacency(list)
      local changed = true
      while changed do
        changed = false
        local i = 1
        while i <= table.getn(list) do
          local a = list[i]
          local j = i + 1
          while j <= table.getn(list) do
            local b = list[j]
            local ax1 = a.x
            local ax2 = a.x + a.w
            local ay1 = a.y
            local ay2 = a.y + a.h
            local bx1 = b.x
            local bx2 = b.x + b.w
            local by1 = b.y
            local by2 = b.y + b.h
            local merged = false
            if math.abs(ay1 - by1) <= EPS and math.abs(ay2 - by2) <= EPS then
              if math.abs(ax2 - bx1) <= EPS then
                a.w = bx2 - ax1
                if not a.name or a.name == "" then a.name = b.name end
                table.remove(list, j)
                changed = true
                merged = true
              elseif math.abs(bx2 - ax1) <= EPS then
                a.w = ax2 - bx1
                a.x = bx1
                if not a.name or a.name == "" then a.name = b.name end
                table.remove(list, j)
                changed = true
                merged = true
              end
            elseif math.abs(ax1 - bx1) <= EPS and math.abs(ax2 - bx2) <= EPS then
              if math.abs(ay2 - by1) <= EPS then
                a.h = by2 - ay1
                if not a.name or a.name == "" then a.name = b.name end
                table.remove(list, j)
                changed = true
                merged = true
              elseif math.abs(by2 - ay1) <= EPS then
                a.h = ay2 - by1
                a.y = by1
                if not a.name or a.name == "" then a.name = b.name end
                table.remove(list, j)
                changed = true
                merged = true
              end
            end
            if merged then
              break
            else
              j = j + 1
            end
          end
          i = i + 1
        end
      end
      return list
    end

    local combined = mergeAdjacency(final)
    if table.getn(combined) == 0 then
      return cloneValid(valid)
    end
    return combined
  end

  function Extras:CombineSessionHotspots(mapId)
    local targets = {}
    if mapId ~= nil then
      table.insert(targets, mapId)
    else
      for mid, list in pairs(self.sessionEdits) do
        if list and table.getn(list) > 0 then table.insert(targets, mid) end
      end
    end
    if table.getn(targets) == 0 then
      self:Print("No session hotspots to combine.")
      return false
    end
    local changed = {}
    local totalBefore, totalAfter = 0, 0
    for i = 1, table.getn(targets) do
      local mid = targets[i]
      local list = self.sessionEdits[mid]
      local count = list and table.getn(list) or 0
      if count > 0 then
        local combined = self:_CombineAxisAlignedRects(list)
        local after = table.getn(combined)
        local different = (after ~= count)
        if not different and after == count then
          for j = 1, after do
            local a = list[j]
            local b = combined[j]
            if not (a and b and nearlyEqual(a.x, b.x) and nearlyEqual(a.y, b.y) and nearlyEqual(a.w, b.w) and nearlyEqual(a.h, b.h)) then
              different = true
              break
            end
          end
        end
        if different then
          self.sessionEdits[mid] = combined
          totalBefore = totalBefore + count
          totalAfter = totalAfter + after
          table.insert(changed, { mapId = mid, before = count, after = after })
        end
      end
    end
    if table.getn(changed) > 0 then
      self:LoadFileHotspots(); self:RebuildSessionSpots(); self:DrawOverlays(); self:RefreshEditorList()
      if table.getn(changed) == 1 then
        local info = changed[1]
        local name = (GM.Map.Area[info.mapId] and GM.Map.Area[info.mapId].name) or tostring(info.mapId)
        self:Print(string.format("Combined session hotspots for %s: %d -> %d", name, info.before, info.after))
      else
        self:Print(string.format("Combined session hotspots across %d maps: %d -> %d", table.getn(changed), totalBefore, totalAfter))
      end
      return true
    end
    self:Print("No combinable session hotspots found.")
    return false
  end

  function Extras:CombineCurrentSession()
    if self._listAll then
      self:CombineSessionHotspots(nil)
    else
      local mid = self:GetSelectedMapId() or (GM.Map and GM.Map.realMapId)
      if mid then
        self:CombineSessionHotspots(mid)
      else
        self:Print("Combine: no map selected.")
      end
    end
  end

  -- Editor enable/disable
  function Extras:SetEditorEnabled(enabled)
    if not devEnabled then return end
    self._editing = enabled and true or false
    if not self._layer then
      local parent = GM.Overlay and GM.Overlay.frame or GM.frame.Content
      local layer = CreateFrame("Frame", "GMExtrasEditorLayer", parent)
      layer:SetAllPoints(parent)
      layer:SetFrameLevel(parent:GetFrameLevel() + 500)
      layer:EnableMouse(true)
      self._layer = layer
      local rect = CreateFrame("Frame", nil, layer)
      rect:Hide(); self._rect = rect
      local t = rect:CreateTexture(nil, "OVERLAY"); t:SetAllPoints(rect)
      t:SetTexture("Interface\\Buttons\\WHITE8x8"); t:SetVertexColor(0,1,1,0.25)
      rect.texture = t
    end
    if self._editing then self._layer:Show() else self._layer:Hide() end
    if not self._editing then self._rect:Hide() end

    if self._editing then
      -- drawing mode and resolution
      self._drawMode = self._drawMode or "poly" -- default to polygon mode
      self._polyRes = self._polyRes or 1.0      -- scanline step in percent

      self._layer:SetScript("OnMouseDown", function()
        local button = arg1 -- 1.12 uses global arg1 for script handlers
        if button ~= "LeftButton" then return end
        if self._forceDrawMapId then
          Extras:SelectZone(self._forceDrawMapId, "Extras drawzone start")
        end
        local fx, fy = (function(frame)
          local scale = frame:GetEffectiveScale(); local cx, cy = GetCursorPosition();
          cx = cx/scale; cy = cy/scale; local l = frame:GetLeft(); local t = frame:GetTop();
          return cx - l, t - cy
        end)(self._layer)
        if not fx or not fy then return end
        local wx, wy = GM.Utils.FramePosToWorldPos(fx, fy)
        if self._drawMode == "poly" then
          self._polyPoints = { { wx = wx, wy = wy } }
          self._dragging = true
          self._rect:Hide()
          Extras:DrawPolyPreview(self._polyPoints)
        else
          self._sfx, self._sfy, self._swx, self._swy = fx, fy, wx, wy
          self._dragging = true
          self._rect:Show()
        end
      end)
      self._layer:SetScript("OnMouseUp", function()
        if not self._dragging then return end
        self._dragging = false
        local fx, fy = (function(frame)
          local scale = frame:GetEffectiveScale(); local cx, cy = GetCursorPosition();
          cx = cx/scale; cy = cy/scale; local l = frame:GetLeft(); local t = frame:GetTop();
          return cx - l, t - cy
        end)(self._layer)
        local wx, wy = GM.Utils.FramePosToWorldPos(fx, fy)
        local mapId
        if self._drawMode == "poly" then
          local pts = self._polyPoints or {}
          table.insert(pts, { wx = wx, wy = wy })
          -- centroid in world to pick map
          local sx, sy, n = 0, 0, 0
          for i = 1, table.getn(pts) do sx = sx + pts[i].wx; sy = sy + pts[i].wy; n = n + 1 end
          local cwX = (n > 0) and (sx / n) or wx
          local cwY = (n > 0) and (sy / n) or wy
          mapId = self._forceDrawMapId or self:GetMapAt(cwX, cwY) or (GM.Map and GM.Map.realMapId)
          if not mapId then self._polyPoints = nil; return end
          -- convert to zone coords
          local zpts = {}
          for i = 1, table.getn(pts) do
            local zx, zy = GM.Utils.GetZonePosFromWorldPos(mapId, pts[i].wx, pts[i].wy)
            table.insert(zpts, { x = zx, y = zy })
          end
          local rects = Extras:FillPolygonAsRects(zpts, self._polyRes)
          if rects and table.getn(rects) > 0 then
            Extras.sessionEdits[mapId] = Extras.sessionEdits[mapId] or {}
            for i = 1, table.getn(rects) do table.insert(Extras.sessionEdits[mapId], rects[i]) end
            Extras:LoadFileHotspots(); Extras:RebuildSessionSpots(); Extras:RefreshEditorList(); Extras:DrawOverlays()
            msg(string.format("Added %d hotspot spans to %s", table.getn(rects), (GM.Map.Area[mapId] and GM.Map.Area[mapId].name) or tostring(mapId)))
            table.insert(Extras.undoStack, { mapId = mapId, count = table.getn(rects) })
          end
          self._polyPoints = nil
          Extras:ClearPolyPreview()
        else
          local cx = (self._swx + wx)/2; local cy = (self._swy + wy)/2
          mapId = self._forceDrawMapId or self:GetMapAt(cx, cy) or (GM.Map and GM.Map.realMapId)
          if not mapId then self._rect:Hide(); return end
          local zx1, zy1 = GM.Utils.GetZonePosFromWorldPos(mapId, self._swx, self._swy)
          local zx2, zy2 = GM.Utils.GetZonePosFromWorldPos(mapId, wx, wy)
          local x = math.min(zx1, zx2); local y = math.min(zy1, zy2)
          local w = math.abs(zx2 - zx1); local h = math.abs(zy2 - zy1)
          Extras.sessionEdits[mapId] = Extras.sessionEdits[mapId] or {}
          table.insert(Extras.sessionEdits[mapId], { x = x, y = y, w = w, h = h, name = "CUSTOM" })
          Extras:LoadFileHotspots(); Extras:RebuildSessionSpots(); Extras:RefreshEditorList(); Extras:DrawOverlays()
          msg(string.format("Added hotspot to %s (%.2f^%.2f^%.2f^%.2f)", (GM.Map.Area[mapId] and GM.Map.Area[mapId].name) or tostring(mapId), x, y, w, h))
          table.insert(Extras.undoStack, { mapId = mapId, count = 1 })
          self._rect:Hide()
        end
      end)
      self._layer:SetScript("OnUpdate", function()
        if not self._dragging then return end
        local frame = self._layer
        local scale = frame:GetEffectiveScale(); local cx, cy = GetCursorPosition();
        cx = cx/scale; cy = cy/scale; local l = frame:GetLeft(); local t = frame:GetTop();
        local fx, fy = cx - l, t - cy
        if self._drawMode == "poly" then
          local wx, wy = GM.Utils.FramePosToWorldPos(fx, fy)
          local pts = self._polyPoints or {}
          local last = pts[table.getn(pts)]
          local dx = last and (wx - last.wx) or 0
          local dy = last and (wy - last.wy) or 0
          if (not last) or ((dx*dx + dy*dy) > 25) then -- ~5 world units threshold
            table.insert(pts, { wx = wx, wy = wy })
            self._polyPoints = pts
          end
          Extras:DrawPolyPreview(self._polyPoints, wx, wy)
        else
          local fx1 = math.min(self._sfx, fx); local fy1 = math.min(self._sfy, fy)
          local fw = math.abs(fx - self._sfx); local fh = math.abs(fy - self._sfy)
          local rect = self._rect
          rect:ClearAllPoints(); rect:SetPoint("TopLeft", fx1, -fy1); rect:SetWidth(fw); rect:SetHeight(fh)
        end
      end)
    else
      self._layer:SetScript("OnMouseDown", nil)
      self._layer:SetScript("OnMouseUp", nil)
      self._layer:SetScript("OnUpdate", nil)
    end
  end

  -- Fill polygon into horizontal spans and vertically merge into rectangles
  function Extras:FillPolygonAsRects(points, step)
    local rects = {}
    if not points or table.getn(points) < 3 then return rects end
    step = step or 1.0
    local function round1(v)
      return math.floor(v * 10 + 0.5) / 10
    end
    -- compute polygon vertical bounds in zone coords (can be outside 0..100)
    local minY, maxY = points[1].y, points[1].y
    for i=2, table.getn(points) do
      local y = points[i].y
      if y < minY then minY = y end
      if y > maxY then maxY = y end
    end

    local buckets = {} -- key -> last rect for a given [x1:x2]
    local y = minY
    while y <= maxY do
      local xs = {}
      -- gather intersections at scanline y (include low endpoint, exclude high to avoid double counting)
      for i=1, table.getn(points) do
        local p1 = points[i]
        local p2 = points[i + 1] or points[1]
        if p1.y ~= p2.y then
          local ylow = p1.y < p2.y and p1.y or p2.y
          local yhigh = p1.y > p2.y and p1.y or p2.y
          if y >= ylow and y < yhigh then
            local t = (y - p1.y) / (p2.y - p1.y)
            local xi = p1.x + t * (p2.x - p1.x)
            table.insert(xs, xi)
          end
        end
      end
      table.sort(xs)
      local i = 1
      while i <= table.getn(xs) - 1 do
        local x1 = xs[i]
        local x2 = xs[i+1]
        if x2 > x1 then
          local rx1 = round1(x1)
          local rx2 = round1(x2)
          local ry = round1(y)
          local key = tostring(rx1) .. ":" .. tostring(rx2)
          local rec = buckets[key]
          if rec and math.abs((rec.y + rec.h) - ry) < 0.0001 then
            rec.h = rec.h + step
          else
            local nr = { x = rx1, y = ry, w = rx2 - rx1, h = step, name = "CUSTOM" }
            table.insert(rects, nr)
            buckets[key] = nr
          end
        end
        i = i + 2
      end
      y = y + step
    end
    return rects
  end

  function Extras:GetMapAt(wx, wy)
    for id, zone in pairs(GM.Map.Area) do
      if zone and not zone.isInstance and not zone.isRaid then
        local _, x, y, w, h = GM.Utils.GetWorldZoneInfo(id)
        if wx >= x and wx <= x + w and wy >= y and wy <= y + h then return id end
      end
    end
    return nil
  end

  -- Mark initialized once everything is set up
  GMglobal._Extras_Initialized = true
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage((GetAddOnMetadata(GM.name, "Title") or "GoggleMaps") .. ": |rTurtle_Extras initialized") end
end

f:SetScript("OnEvent", function()
  TryInit()
  if not (_G.GoggleMaps and _G.GoggleMaps._Extras_Initialized) then
    if not f._extrasPoll then
      f._extrasPoll = true
      f:SetScript("OnUpdate", function()
        TryInit()
        if _G.GoggleMaps and _G.GoggleMaps._Extras_Initialized then
          f:SetScript("OnUpdate", nil)
        end
      end)
    end
  end
end)
