-- Hotkey Manager v1.5.0
-- Quality-of-life tool to view, manage, and resolve hotkey conflicts in a cheat table.
--
-- v1.x — Foundation & Initial Release
-- ----------------------------------------------
-- Added: In-place editing of hotkeys directly within the list view
-- Added: Right-click context menu for direct hotkey manipulation
--    • Enable / Disable / Remove hotkeys
-- Added: On-demand management window, accessible from a top-level menu
-- Added: Automated cheat table scan with results displayed in a detailed, sortable list
-- Added: Enhanced usability features:
--    • Visual conflict detection — highlights duplicate hotkeys in red
--    • Interactive navigation — double-click a hotkey to jump to its record in the address list
--    • Global control — enable, disable, or remove all hotkeys at once

-- Only run this script once.
if syntaxcheck then return end

local function findFormByName_HotkeyManager(name)
  for i = 0, getFormCount()-1 do local form=getForm(i) if form and form.Name==name then return form end end
  return nil
end

if findFormByName_HotkeyManager('frmHotkeyManagerOwner') then
  return -- Silently exit if the tool is already running
end

do
  -- /// STATE & CONFIGURATION ///
  local hotkeyManager = {
    form = nil, lvHotkeys = nil, chkEnableAll = nil,
    allHotkeys = {},
    lastSortColumn = 0, lastSortDirection = 1,
    activeEditControl = nil, -- To track the temporary edit box
    uiSettings = {
      formName = 'frmHotkeyManager', ownerFormName = 'frmHotkeyManagerOwner',
      menuItemCaption = 'Hotkey Manager', topLevelMenuCaption = 'Nyxus Toolbox',
      conflictColor = 0xFF0000
    }
  }

  local hotkeyActionMap = {
    [0]="Toggle Activation",[1]="Toggle+Allow Increase",[2]="Toggle+Allow Decrease",
    [3]="Activate",[4]="Deactivate",[5]="Set Value",[6]="Increase Value",[7]="Decrease Value"
  }

  -- /// CORE LOGIC ///
  local function getAllMemoryRecords(records)
    local allRecords={}
    for i=0,records.Count-1 do
      local mr=records[i];table.insert(allRecords,mr)
      if mr.Count > 0 then for _,child in ipairs(getAllMemoryRecords(mr)) do table.insert(allRecords, child) end end
    end
    return allRecords
  end

  local function findHotkeyObjectByID(id)
    if not id then return nil end
    local allRecords = getAllMemoryRecords(getAddressList())
    for _, mr in ipairs(allRecords) do
      local hotkey = mr.getHotkeyByID(id)
      if hotkey then return hotkey end
    end
    return nil
  end

  local function populateHotkeyListView()
    if not hotkeyManager.lvHotkeys then return end
    local lv = hotkeyManager.lvHotkeys
    lv.Items.beginUpdate()
    lv.Items.clear()
    lv.ShowHint = true -- Enable tooltips

    local hotkeyCounts = {}
    for _, data in ipairs(hotkeyManager.allHotkeys) do
      hotkeyCounts[data.hotkeyObj.HotkeyString] = (hotkeyCounts[data.hotkeyObj.HotkeyString] or 0) + 1
    end

    for _, data in ipairs(hotkeyManager.allHotkeys) do
      local item = lv.Items.add()
      item.Caption = data.hotkeyObj.HotkeyString
      item.SubItems.add(data.mr.Description)
      item.SubItems.add(hotkeyActionMap[data.hotkeyObj.Action] or "Unknown")
      item.SubItems.add(tostring(data.hotkeyObj.Active))
      item.Data = data.hotkeyObj.ID

      local isConflict = hotkeyCounts[data.hotkeyObj.HotkeyString] > 1
      item.SubItems.add(isConflict and "Conflict" or "")
      if isConflict then
        item.Color = hotkeyManager.uiSettings.conflictColor
        item.Hint = "This hotkey is assigned to multiple records. Please resolve the conflict."
      else
        item.Hint = ""
      end
    end
    lv.Items.endUpdate()
  end

  local function gatherHotkeyData()
    local allRecords = getAllMemoryRecords(getAddressList())
    hotkeyManager.allHotkeys = {}
    for _, mr in ipairs(allRecords) do
      for i = 0, mr.HotkeyCount - 1 do
        local hotkey = mr.Hotkey[i]
        table.insert(hotkeyManager.allHotkeys, {hotkeyObj = hotkey, mr = mr})
      end
    end
    table.sort(hotkeyManager.allHotkeys, function(a, b) return a.hotkeyObj.HotkeyString < b.hotkeyObj.HotkeyString end)
    hotkeyManager.lastSortColumn = 0
    hotkeyManager.lastSortDirection = 1
  end

  local function refreshHotkeyData()
    gatherHotkeyData()
    populateHotkeyListView()
  end
  
  local function removeAllHotkeys()
    if messageDialog("Are you sure you want to remove ALL hotkeys from this table? This action cannot be undone.", mtConfirmation, mbYes, mbNo) == mrYes then
      local allRecords = getAllMemoryRecords(getAddressList())
      local removedCount = 0
      for _, mr in ipairs(allRecords) do
        removedCount = removedCount + mr.HotkeyCount
        mr.freeHotkeys()
      end
      showMessage(string.format("Removed %d hotkeys from the table.", removedCount))
      refreshHotkeyData()
    end
  end
  
  local launchTool -- Forward declaration
  
  -- /// GUI CREATION ///
  local function createGUI()
    hotkeyManager.form=createForm(false); local f=hotkeyManager.form
    f.Caption=hotkeyManager.uiSettings.menuItemCaption; f.Name=hotkeyManager.uiSettings.formName; f.Width=750; f.Height=400
    local pnlTop=createPanel(f); pnlTop.Align='alTop'; pnlTop.Height=40; pnlTop.BevelOuter='bvNone'
    hotkeyManager.chkEnableAll=createCheckBox(pnlTop);
    hotkeyManager.chkEnableAll.Caption='Enable All Hotkeys'; hotkeyManager.chkEnableAll.Left=10; hotkeyManager.chkEnableAll.Top=10;
    local btnRefresh=createButton(pnlTop); btnRefresh.Caption='Refresh'; btnRefresh.Left=150; btnRefresh.Top=8
    local btnRemoveAll=createButton(pnlTop); btnRemoveAll.Caption='Remove All'; btnRemoveAll.Left=240; btnRemoveAll.Top=8
    
    local pnlClient=createPanel(f); pnlClient.Align='alClient'; pnlClient.BevelOuter='bvNone'
    hotkeyManager.lvHotkeys=createListView(pnlClient); local lv=hotkeyManager.lvHotkeys
    lv.Align='alClient'; lv.GridLines=true; lv.RowSelect=true; lv.ViewStyle='vsReport'; lv.MultiSelect=true
    lv.Columns.add().Caption='Hotkey'; lv.Columns[0].Width=150
    lv.Columns.add().Caption='Description'; lv.Columns[1].Width=300
    lv.Columns.add().Caption='Action'; lv.Columns[2].Width=150
    lv.Columns.add().Caption='Enabled'; lv.Columns[3].Width=70
    lv.Columns.add().Caption = 'Conflict'
    lv.Columns[4].Width = 80
    f.OnClose=function()
      if hotkeyManager.activeEditControl then hotkeyManager.activeEditControl.destroy() end
      return caHide
    end
    btnRefresh.OnClick = refreshHotkeyData
    btnRemoveAll.OnClick = removeAllHotkeys

    hotkeyManager.chkEnableAll.OnClick = function(sender)
      local allRecords = getAllMemoryRecords(getAddressList())
      for _, mr in ipairs(allRecords) do
        for i = 0, mr.HotkeyCount - 1 do
          mr.Hotkey[i].Active = sender.Checked
        end
      end
      refreshHotkeyData()
      showMessage(sender.Checked and "All hotkeys enabled." or "All hotkeys disabled.")
    end

    lv.OnColumnClick = function(sender, column)
      local sortCol, sortDir = hotkeyManager.lastSortColumn, hotkeyManager.lastSortDirection or 1
      if sortCol == column.Index then sortDir = -sortDir else sortDir = 1 end
      hotkeyManager.lastSortColumn, hotkeyManager.lastSortDirection = column.Index, sortDir

      table.sort(hotkeyManager.allHotkeys, function(a, b)
        local valA, valB
        if column.Index == 0 then
          valA, valB = a.hotkeyObj.HotkeyString, b.hotkeyObj.HotkeyString
        elseif column.Index == 1 then
          valA, valB = a.mr.Description, b.mr.Description
        elseif column.Index == 2 then
          valA, valB = hotkeyActionMap[a.hotkeyObj.Action] or "", hotkeyActionMap[b.hotkeyObj.Action] or ""
        elseif column.Index == 3 then
          valA, valB = tostring(a.hotkeyObj.Active), tostring(b.hotkeyObj.Active)
        elseif column.Index == 4 then
          -- Conflict column: sort by presence of conflict
          local hotkeyCounts = {}
          for _, data in ipairs(hotkeyManager.allHotkeys) do
            hotkeyCounts[data.hotkeyObj.HotkeyString] = (hotkeyCounts[data.hotkeyObj.HotkeyString] or 0) + 1
          end
          local isConflictA = (hotkeyCounts[a.hotkeyObj.HotkeyString] or 0) > 1 and 1 or 0
          local isConflictB = (hotkeyCounts[b.hotkeyObj.HotkeyString] or 0) > 1 and 1 or 0
          if isConflictA ~= isConflictB then
            return sortDir == 1 and isConflictA > isConflictB or isConflictA < isConflictB
          else
            valA, valB = a.hotkeyObj.HotkeyString, b.hotkeyObj.HotkeyString
          end
        end
        if sortDir == 1 then return valA < valB else return valB < valA end
      end)
      populateHotkeyListView()
    end
    
    local function getSelectedHotkeys()
      local selected = {}
      for i=0, lv.Items.Count-1 do if lv.Selected[i] then local hk = findHotkeyObjectByID(lv.Items[i].Data) if hk then table.insert(selected, hk) end end end
      return selected
    end
    
    -- In-place editing implementation
    local function startHotkeyEdit(item, col)
      if hotkeyManager.activeEditControl then hotkeyManager.activeEditControl.destroy() end
      
      local hotkey = findHotkeyObjectByID(item.Data)
      if not hotkey then return end
      
      local rect = item.displayRectSubItem(col, drLabel)
      local hotkeyControl = createHotKey(lv)
      hotkeyControl.Left = rect.Left - 2; hotkeyControl.Top = rect.Top - 2
      hotkeyControl.Width = lv.Columns[col].Width + 4; hotkeyControl.Height = rect.Bottom - rect.Top + 4
      hotkeyControl.HotKey = textToShortCut(item.Caption)

      local function commitAndDestroy(shouldSave)
        if not hotkeyManager.activeEditControl then return end
        if shouldSave then
          local newKeys = shortCutToText(hotkeyControl.HotKey)
          if newKeys ~= "" then
            hotkey.setKeys(textToShortCut(newKeys))
          else
            hotkey.setKeys(0) -- Clear hotkey
          end
          refreshHotkeyData()
        end
        hotkeyManager.activeEditControl.destroy()
        hotkeyManager.activeEditControl = nil
      end

      hotkeyControl.OnExit = function() commitAndDestroy(true) end
      hotkeyControl.OnKeyDown = function(sender, key)
        if key == VK_RETURN then commitAndDestroy(true)
        elseif key == VK_ESCAPE then commitAndDestroy(false) end
      end

      hotkeyControl.show(); hotkeyControl.setFocus()
      hotkeyManager.activeEditControl = hotkeyControl
    end

    local function goToRecord(item)
      if not item or item.Data == 0 then return end
      local allRecords = getAllMemoryRecords(getAddressList())
      for _, mr in ipairs(allRecords) do
        if mr.getHotkeyByID(item.Data) then
          getAddressList().setSelectedRecord(mr)
          getMainForm().bringToFront()
          return
        end
      end
    end

    lv.OnDblClick = function()
      local item = lv.Selected; if not item then return end
      local screenX,screenY = getMousePos(); local clientX,clientY = lv.ScreenToClient(screenX,screenY)
      local col = -1; local currentWidth = 0
      for i=0,lv.Columns.Count-1 do currentWidth=currentWidth+lv.Columns[i].Width;if clientX<currentWidth then col=i;break end end

      if col == 0 then -- Hotkey column
        startHotkeyEdit(item, col)
      else -- Any other column
        goToRecord(item)
      end
    end

    local lvPopup = createPopupMenu(lv); lv.PopupMenu = lvPopup
    local miGoTo = createMenuItem(lvPopup); miGoTo.Caption = "Go to Record"
    local miSeparator = createMenuItem(lvPopup); miSeparator.Caption = "-"
    local miToggle = createMenuItem(lvPopup); miToggle.Caption = "Enable/Disable Hotkey(s)"
    local miRemove = createMenuItem(lvPopup); miRemove.Caption = "Remove Hotkey(s)"
    miGoTo.OnClick = function() if lv.Selected then goToRecord(lv.Selected) end end
    miToggle.OnClick = function() local hks=getSelectedHotkeys() for _,hk in ipairs(hks) do hk.Active=not hk.Active end; refreshHotkeyData() end
    miRemove.OnClick = function()
      local hks=getSelectedHotkeys()
      if #hks > 0 and messageDialog(string.format("Remove %d selected hotkey(s)?", #hks), mtConfirmation, mbYes, mbNo)==mrYes then
        for _,hk in ipairs(hks) do hk.destroy() end
        refreshHotkeyData()
      end
    end
    lvPopup.OnPopup = function()
      local selCount = lv.SelCount
      miGoTo.Enabled = (selCount == 1)
      miToggle.Enabled = (selCount > 0)
      miRemove.Enabled = (selCount > 0)
    end
  end

  -- /// ON-DEMAND LAUNCHER ///
  launchTool = function()
    if not hotkeyManager.form then createGUI() end
    hotkeyManager.form.show()
    hotkeyManager.form.bringToFront()
    refreshHotkeyData()
    hotkeyManager.chkEnableAll.Checked = (getHotkeyHandlerThread().state == 0)
  end

  -- /// STARTUP INITIALIZATION ///
  local function addTopLevelMenuItem()
    local mainMenu=getMainForm().Menu; local toolsMenu=nil
    for i=0,mainMenu.Items.Count-1 do if mainMenu.Items[i].Caption==hotkeyManager.uiSettings.topLevelMenuCaption then toolsMenu=mainMenu.Items[i];break end end
    if not toolsMenu then toolsMenu=createMenuItem(mainMenu);toolsMenu.Caption=hotkeyManager.uiSettings.topLevelMenuCaption;mainMenu.Items.add(toolsMenu) end
    local menuItem=createMenuItem(toolsMenu);menuItem.Caption=hotkeyManager.uiSettings.menuItemCaption;menuItem.OnClick=launchTool;toolsMenu.add(menuItem)
  end

  local ownerForm=createForm(false)
  ownerForm.Name=hotkeyManager.uiSettings.ownerFormName
  local initTimer=createTimer(ownerForm)
  initTimer.Interval=2000
  initTimer.OnTimer = function(timer)
    if getOpenedProcessID()>0 then addTopLevelMenuItem(); timer.destroy() end
  end
end