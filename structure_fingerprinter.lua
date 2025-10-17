-- Structure Fingerprinter v4.7.0
-- Advanced data dissection tool for analyzing memory regions and generating structure layouts.
--
-- v4.x — Recursive Scanning & Finalization
-- ----------------------------------------
-- Added: Confidence scoring with color-coded results for at-a-glance analysis
--    • Default (Black): High confidence
--    • Blue: Medium confidence
--    • Gray: Low confidence
-- Added: Right-click option for recursive scanning to explore interconnected structures
-- Added: Threaded analysis engine with progress bar and cancel button to prevent UI freezes
-- Added: "Show Padding" checkbox to reduce clutter in results
-- Improved: Editing workflow in results list
--    • In-place dropdown editor for the "Type" column
--    • Popup dialog fully replaced with inline editing
-- Improved: Expanded heuristics engine with enhanced detection logic
--    • Qwords
--    • Unicode Strings
--    • Byte[4] arrays
--    • Padding
--    • Arrays of small integers
--    • Unix timestamps
-- Fixed: Global function collision, ensuring full script isolation and compatibility with other tools
--
-- v3.x — Advanced Heuristics Engine
-- ---------------------------------
-- Added: Two-pass analysis engine for stronger pattern recognition
-- Improved: Detection of complex data types, including:
--    • Pointer types
--    • Vectors
--    • Arrays
--
-- v2.x — Refactoring & Live Syncing
-- ---------------------------------
-- Changed: Re-architected into an on-demand tool accessible from a new top-level menu
-- Added: Live Address Syncing with the Memory Viewer disassembler
-- Fixed: Stability issues, including memory access violations and UI crashes
--
-- v1.x — Foundation & Initial Release
-- -----------------------------------
-- Added: Professional UI with menu integration
-- Added: Basic analysis engine for structure detection

-- Only run this script once.
if syntaxcheck then return end

local function findFormByName_Fingerprinter(name)
  for i = 0, getFormCount()-1 do local form=getForm(i) if form and form.Name==name then return form end end
  return nil
end

if findFormByName_Fingerprinter('frmStructureFingerprinter') then
  return -- Silently exit if the tool is already running
end

do
  -- /// STATE & CONFIGURATION ///
  local fingerprinter = {
    form = nil, edtAddress = nil, edtSize = nil, lvResults = nil,
    btnScan = nil, btnCreate = nil, btnCancel = nil, pbScan = nil, chkShowPadding = nil,
    scanThread = nil,
    activeEditControl = nil,
    fullResults = {},
    allTypes = {},
    originalOnSelectionChange = nil,
    uiSettings = {
      menuItemCaption = 'Structure Fingerprinter', topLevelMenuCaption = 'Nyxus Toolbox',
      addressCaption = 'Address:', sizeCaption = 'Size (bytes):',
      scanCaption = 'Scan', createCaption = 'Create CE Structure', cancelCaption = 'Cancel',
      colorHighConfidence = clWindowText,
      colorMediumConfidence = clBlue,
      colorLowConfidence = clGrayText
    }
  }

  local typeMap = {
    ['Byte']=vtByte, ['Word']=vtWord, ['Dword']=vtDword, ['Qword']=vtQword, ['Float']=vtSingle,
    ['Double']=vtDouble, ['String']=vtString, ['Unicode String']=vtUnicodeString, ['Pointer']=vtPointer,
    ['Vector3']=vtFloat, ['Vector4']=vtFloat, ['Float[]']=vtFloat, ['Dword[]']=vtDword,
    ['Byte[4]']=vtDword
  }
  for k in pairs(typeMap) do table.insert(fingerprinter.allTypes, k) end
  table.sort(fingerprinter.allTypes)

  local createGUI, launchTool

  -- /// CORE LOGIC & ANALYSIS ENGINE ///
  local function getValidRegionSize(address)
    local regions=enumMemoryRegions() if not regions then return 0 end
    for _,r in ipairs(regions) do if address>=r.BaseAddress and address<(r.BaseAddress+r.RegionSize) then return(r.BaseAddress+r.RegionSize)-address end end
    return 0
  end

  local function analyzeRegion(baseAddress, safeScanSize, memBlock, thread)
    local results, claimedOffsets = {}, {}
    local pointerSize = getPointerSize()
    local unixEpoch2000 = 946684800
    local unixEpochFuture = os.time() + 157788000 -- 5 years from now

    -- Pass 1: High-Confidence
    for i = 1, safeScanSize do
      if thread and thread.Terminated then return nil, "Scan cancelled" end
      if i % 512 == 0 then synchronize(function() if fingerprinter.pbScan then fingerprinter.pbScan.Position = math.floor((i / safeScanSize) * 100) end end) end
      local currentOffset = i - 1
      if not claimedOffsets[currentOffset] then
        if (currentOffset % pointerSize == 0) and (i <= safeScanSize - pointerSize) then
          local ptr = (pointerSize == 8) and byteTableToQword(memBlock, i) or byteTableToDword(memBlock, i)
          if ptr and ptr > 0x10000 then
            local symbolName = getNameFromAddress(ptr)
            if symbolName and symbolName ~= '' and not symbolName:match('^%x+$') then
              table.insert(results, {offset=currentOffset, type='Pointer', size=pointerSize, value=string.format("-> %s", symbolName), name=(symbolName:match('vtable') and 'VTable' or 'p'..symbolName:gsub('[^%w]','')), ptr_dest=ptr, confidence=95})
              for j = 0, pointerSize - 1 do claimedOffsets[currentOffset + j] = true end
            end
          end
        end
        if not claimedOffsets[currentOffset] then
          local isString, strLen = true, 0
          for j = i, math.min(i + 255, safeScanSize) do if not memBlock[j] or memBlock[j] == 0 then break end if memBlock[j] < 32 or memBlock[j] > 126 then isString = false; break end strLen = strLen + 1 end
          if isString and strLen > 3 then
            table.insert(results, {
              offset = currentOffset,
              type = 'String',
              size = strLen + 1,
              value = readString(baseAddress + currentOffset, strLen),
              name = 'sNameOrDesc',
              strLen = strLen -- Store actual string length
            })
            for j = 0, strLen do claimedOffsets[currentOffset + j] = true end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % 2 == 0) and (i <= safeScanSize - 8) then
          local isUnicode, charCount = true, 0
          for j = i, math.min(i + 255, safeScanSize - 1), 2 do
            if not memBlock[j] or not memBlock[j+1] then isUnicode = false; break end
            if memBlock[j+1] ~= 0 then isUnicode = false; break end
            if memBlock[j] < 32 or memBlock[j] > 126 then isUnicode = false; break end
            if memBlock[j] == 0 then break end
            charCount = charCount + 1
          end
          if isUnicode and charCount > 3 then
            local byteSize = (charCount * 2) + 2
            table.insert(results, {offset=currentOffset, type='Unicode String', size=byteSize, value=readString(baseAddress + currentOffset, byteSize, true), name='wsNameOrDesc', confidence=90})
            for j = 0, byteSize - 1 do claimedOffsets[currentOffset + j] = true end
          end
        end
      end
    end

    -- Pass 2: Speculative
    for i = 1, safeScanSize do
      if thread and thread.Terminated then return nil, "Scan cancelled" end
      if i % 512 == 0 then synchronize(function() if fingerprinter.pbScan then fingerprinter.pbScan.Position = 33 + (i / safeScanSize) * 33 end end) end
      local currentOffset = i - 1
      if not claimedOffsets[currentOffset] then
        if (currentOffset % 4 == 0) and (i <= safeScanSize - 12) then
          local floats = {}
          for j = i, safeScanSize - 3, 4 do local f = byteTableToFloat(memBlock, j) if f and f ~= 0 and math.abs(f) > 0.001 and math.abs(f) < 100000 then table.insert(floats, f) else break end end
          if #floats >= 3 then
            local r = {offset = currentOffset, confidence=75}
            if #floats == 3 then r.type = 'Vector3'; r.size = 12; r.value = string.format('(%.4f,%.4f,%.4f)', floats[1], floats[2], floats[3]); r.name = 'vec3_Coords'
            elseif #floats == 4 then r.type = 'Vector4'; r.size = 16; r.value = string.format('(%.4f,%.4f,%.4f,%.4f)', floats[1], floats[2], floats[3], floats[4]); r.name = 'vec4_ColorOrQuat'
            else r.type = 'Float['..#floats..']'; r.size = #floats * 4; r.value = 'Array of '..#floats..' floats'; r.name = 'arr_fValues' end
            table.insert(results, r); for j = 0, r.size - 1 do claimedOffsets[currentOffset + j] = true end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % 4 == 0) and (i <= safeScanSize - 12) then
          local dwords = {}
          for j = i, safeScanSize - 3, 4 do local d = byteTableToDword(memBlock, j) if d and d >= 0 and d <= 8192 then table.insert(dwords, d) else break end end
          if #dwords >= 3 then
            local r = {offset=currentOffset, type='Dword['..#dwords..']', size=#dwords*4, value='Array of '..#dwords..' dwords', name='arr_iIDsOrCounts', confidence=65}
            table.insert(results, r); for j=0, r.size-1 do claimedOffsets[currentOffset+j] = true end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % pointerSize == 0) and (i <= safeScanSize - pointerSize) then
          local ptr = (pointerSize == 8) and byteTableToQword(memBlock, i) or byteTableToDword(memBlock, i)
          if ptr and ptr > 0x10000 then
            local s, p2 = pcall(readPointer, ptr)
            if s and p2 and p2 > 0x10000 and getAddressSafe(p2) then
              table.insert(results, {offset=currentOffset, type='Pointer', size=pointerSize, value=string.format("-> 0x%X", ptr), name='ppNestedObject', ptr_dest=ptr, confidence=70}); for j = 0, pointerSize - 1 do claimedOffsets[currentOffset + j] = true end
            else
              local s2, p = pcall(getMemoryProtection, ptr)
              if s2 and p and p.w and not p.x then table.insert(results, {offset=currentOffset, type='Pointer', size=pointerSize, value=string.format("-> 0x%X", ptr), name='pDataObject', ptr_dest=ptr, confidence=60}); for j = 0, pointerSize - 1 do claimedOffsets[currentOffset + j] = true end end
            end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % 8 == 0) and (i <= safeScanSize - 8) then
          local q = byteTableToQword(memBlock, i)
          if q and q > unixEpoch2000 and q < unixEpochFuture then
            table.insert(results, {offset=currentOffset, type='Qword', size=8, value=os.date('%Y-%m-%d %H:%M:%S', q), name='timestamp_unix', confidence=65})
            for j=0,7 do claimedOffsets[currentOffset+j]=true end
          end
        end
        -- Boolean (Byte)
        if not claimedOffsets[currentOffset] then
          local b = memBlock[i]
          if b == 0 or b == 1 then
            table.insert(results, {offset=currentOffset, type='Boolean', size=1, value=tostring(b), name='bFlag', confidence=50})
            claimedOffsets[currentOffset] = true
          end
        end
        -- Boolean (Dword)
        if not claimedOffsets[currentOffset] and (currentOffset % 4 == 0) and (i <= safeScanSize - 4) then
          local d = byteTableToDword(memBlock, i)
          if d == 0 or d == 1 then
            table.insert(results, {offset=currentOffset, type='Boolean32', size=4, value=tostring(d), name='bFlag32', confidence=45})
            for j = 0, 3 do claimedOffsets[currentOffset + j] = true end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % 8 == 0) and (i <= safeScanSize - 8) then
          local q = byteTableToQword(memBlock, i)
          if q and q >= 0 and q <= 4096 then
            table.insert(results, {offset=currentOffset, type='Qword', size=8, value=tostring(q), name='i64ValueOrFlag', confidence=40})
            for j=0,7 do claimedOffsets[currentOffset+j]=true end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % 4 == 0) and (i <= safeScanSize - 4) then
          local d = byteTableToDword(memBlock, i)
          if d and d >= 0 and d <= 2048 then
            table.insert(results, {offset=currentOffset, type='Dword', size=4, value=tostring(d), name='iValueOrFlag', confidence=40})
            for j = 0, 3 do claimedOffsets[currentOffset + j] = true end
          end
        end
        if not claimedOffsets[currentOffset] and (currentOffset % 4 == 0) and (i <= safeScanSize - 4) then
            if memBlock[i]==255 or memBlock[i+1]==255 or memBlock[i+2]==255 or memBlock[i+3]==255 then
                table.insert(results, {offset=currentOffset, type='Byte[4]', size=4, value=string.format('%d, %d, %d, %d', memBlock[i], memBlock[i+1], memBlock[i+2], memBlock[i+3]), name='colorRGBA', confidence=35})
                for j=0,3 do claimedOffsets[currentOffset+j]=true end
            end
        end
      end
    end

    -- Pass 3: Padding and Unclaimed
    local i = 1
    while i <= safeScanSize do
      if thread and thread.Terminated then return nil, "Scan cancelled" end
      if i % 512 == 0 then synchronize(function() if fingerprinter.pbScan then fingerprinter.pbScan.Position = 66 + (i / safeScanSize) * 34 end end) end
      local currentOffset = i - 1
      if not claimedOffsets[currentOffset] then
        local padByte = memBlock[i]
        if padByte == 0x00 or padByte == 0xCC then
          local runLength = 1
          while (i + runLength <= safeScanSize) and (memBlock[i + runLength] == padByte) and (not claimedOffsets[currentOffset + runLength]) do runLength = runLength + 1 end
          if runLength >= 4 then
            table.insert(results, {offset=currentOffset, type='Padding', size=runLength, value=string.format('%02X x %d', padByte, runLength), name='_padding', confidence=10})
            for j = 0, runLength - 1 do claimedOffsets[currentOffset + j] = true end
            i = i + runLength
            goto continue_loop
          end
        end
        table.insert(results, {offset=currentOffset, type='Byte', size=1, value=string.format('%d (0x%02X)', memBlock[i], memBlock[i]), name='_unk', confidence=5})
        claimedOffsets[currentOffset] = true
      end
      i = i + 1
      ::continue_loop::
    end

    table.sort(results, function(a, b) return a.offset < b.offset end)
    return results
  end

  local function populateListView()
    if not fingerprinter.lvResults then return end
    fingerprinter.lvResults.Items.beginUpdate()
    fingerprinter.lvResults.Items.clear()
    local showPadding = fingerprinter.chkShowPadding.Checked
    for _, r in ipairs(fingerprinter.fullResults) do
      if showPadding or r.type ~= 'Padding' then
        local item = fingerprinter.lvResults.Items.add()
        item.Caption = string.format('%X', r.offset)
        item.SubItems.add(r.type)
        item.SubItems.add(r.value)
        item.SubItems.add(r.name)
        item.SubItems.add(string.format('%d%%', r.confidence)) -- Add confidence to subitem
        if r.confidence >= 85 then item.Color = fingerprinter.uiSettings.colorHighConfidence
        elseif r.confidence >= 50 then item.Color = fingerprinter.uiSettings.colorMediumConfidence
        else item.Color = fingerprinter.uiSettings.colorLowConfidence end
        if r.type == 'String' or r.type == 'Unicode String' then item.Data = r.size
        elseif r.ptr_dest then item.Data = r.ptr_dest end
      end
    end
    fingerprinter.lvResults.Items.endUpdate()
  end

  local function scanMemoryRegion(baseAddress, requestedSize)
    fingerprinter.lvResults.Items.clear()
    fingerprinter.btnScan.Enabled = false
    fingerprinter.btnCreate.Enabled = false
    fingerprinter.pbScan.Position = 0
    fingerprinter.pbScan.Visible = true
    fingerprinter.btnCancel.Visible = true
    local function onScanComplete(finalResults, errorMessage)
      if finalResults then
        fingerprinter.fullResults = finalResults
        populateListView()
      elseif errorMessage then
        showMessage(errorMessage)
      end
      fingerprinter.pbScan.Visible = false
      fingerprinter.btnCancel.Visible = false
      fingerprinter.btnScan.Enabled = true
      fingerprinter.btnCreate.Enabled = true
      fingerprinter.scanThread = nil
    end
    fingerprinter.scanThread = createThread(function(thread)
      local maxReadableSize = getValidRegionSize(baseAddress)
      if maxReadableSize == 0 then synchronize(onScanComplete, nil, "The specified address is not in a valid memory region."); return end
      local safeScanSize = math.min(requestedSize, maxReadableSize)
      if safeScanSize ~= requestedSize then synchronize(function() fingerprinter.edtSize.Text = tostring(safeScanSize) end) end
      local memBlock = readBytes(baseAddress, safeScanSize, true)
      if not memBlock then synchronize(onScanComplete, nil, "Failed to read the specified memory region."); return end
      local results, err = analyzeRegion(baseAddress, safeScanSize, memBlock, thread)
      synchronize(onScanComplete, results, err)
    end)
  end

  local function createCEStructure()
    if fingerprinter.lvResults.Items.Count==0 then showMessage("Please scan a memory region first.");return end
    local structureName=inputQuery("Create Structure","Enter a name for the new structure:","MyNewStructure")
    if not structureName or structureName=='' then return end
    local newStruct=createStructure(structureName)
    newStruct.beginUpdate()
    for i = 0, fingerprinter.lvResults.Items.Count - 1 do
      local item = fingerprinter.lvResults.Items[i]
      local offset = tonumber(item.Caption, 16)
      local typeStr = item.SubItems[0]
      local nameStr = item.SubItems[2]
      local ceType = typeMap[typeStr]
      if offset and ceType then
        local element = newStruct.addElement()
        element.Offset = offset
        element.VarType = ceType
        element.Name = nameStr
        if ceType == vtString or ceType == vtUnicodeString then
          -- Look up the original result for this offset and type
          local strLen = nil
          if fingerprinter.fullResults then
            for _, r in ipairs(fingerprinter.fullResults) do
              if r.offset == offset and r.type == typeStr then
                -- For Unicode, size is in bytes; for ASCII, strLen is chars
                if ceType == vtString and r.strLen then
                  strLen = r.strLen + 1
                elseif ceType == vtUnicodeString and r.size then
                  strLen = r.size
                end
                break
              end
            end
          end
          if strLen then
            element.Bytesize = strLen
          else
            element.Bytesize = #item.SubItems[1] + 1 -- fallback
          end
        end
      end
    end
    newStruct.endUpdate()
    newStruct.addToGlobalStructureList()
    showMessage(string.format("Structure '%s' created successfully!",structureName))
  end

  -- /// GUI CREATION & EVENT HANDLING ///
  createGUI = function()
    fingerprinter.form = createForm(false); local f=fingerprinter.form
    f.Caption=fingerprinter.uiSettings.menuItemCaption; f.Name='frmStructureFingerprinter'; f.Width=700; f.Height=500
    local pnlTop=createPanel(f); pnlTop.Align='alTop'; pnlTop.Height=40; pnlTop.BevelOuter='bvNone'
    local lblAddr=createLabel(pnlTop); lblAddr.Caption=fingerprinter.uiSettings.addressCaption; lblAddr.Left=10; lblAddr.Top=12
    fingerprinter.edtAddress=createEdit(pnlTop); fingerprinter.edtAddress.Left=65; fingerprinter.edtAddress.Top=10; fingerprinter.edtAddress.Width=120
    local lblSize=createLabel(pnlTop); lblSize.Caption=fingerprinter.uiSettings.sizeCaption; lblSize.Left=200; lblSize.Top=12
    fingerprinter.edtSize=createEdit(pnlTop); fingerprinter.edtSize.Text='4096'; fingerprinter.edtSize.Left=270; fingerprinter.edtSize.Top=10; fingerprinter.edtSize.Width=60
    fingerprinter.btnScan=createButton(pnlTop); fingerprinter.btnScan.Caption=fingerprinter.uiSettings.scanCaption; fingerprinter.btnScan.Left=350; fingerprinter.btnScan.Top=8
    fingerprinter.pbScan = createProgressBar(pnlTop); fingerprinter.pbScan.Left=430; fingerprinter.pbScan.Top=10; fingerprinter.pbScan.Width=100; fingerprinter.pbScan.Visible=false
    fingerprinter.btnCancel = createButton(pnlTop); fingerprinter.btnCancel.Caption=fingerprinter.uiSettings.cancelCaption; fingerprinter.btnCancel.Left=540; fingerprinter.btnCancel.Top=8; fingerprinter.btnCancel.Visible=false
    local pnlBottom=createPanel(f); pnlBottom.Align='alBottom'; pnlBottom.Height=40; pnlBottom.BevelOuter='bvNone'
    fingerprinter.btnCreate=createButton(pnlBottom); fingerprinter.btnCreate.Caption=fingerprinter.uiSettings.createCaption; fingerprinter.btnCreate.Left=10; fingerprinter.btnCreate.Top=8; fingerprinter.btnCreate.Width=150
    fingerprinter.chkShowPadding = createCheckBox(pnlBottom); fingerprinter.chkShowPadding.Left=170; fingerprinter.chkShowPadding.Top=12; fingerprinter.chkShowPadding.Caption = "Show Padding"
    local pnlClient=createPanel(f); pnlClient.Align='alClient'; pnlClient.BevelOuter='bvNone'
    fingerprinter.lvResults=createListView(pnlClient); local lv=fingerprinter.lvResults
    lv.Align='alClient'; lv.GridLines=true; lv.RowSelect=true; lv.ViewStyle='vsReport'
    lv.Columns.add().Caption='Offset'; lv.Columns[0].Width=70
    lv.Columns.add().Caption='Proposed Type'; lv.Columns[1].Width=100
    lv.Columns.add().Caption='Value'; lv.Columns[2].Width=180
    lv.Columns.add().Caption='Proposed Name'; lv.Columns[3].Width=150
    lv.Columns.add().Caption='Confidence'; lv.Columns[4].Width=80
    local function executeScan()
      if fingerprinter.scanThread then return end
      local addr=fingerprinter.edtAddress.Tag; local size=tonumber(fingerprinter.edtSize.Text)
      if not addr or addr==0 then addr=getAddressSafe(fingerprinter.edtAddress.Text) end
      if not addr or addr==0 then showMessage(string.format("Could not resolve address: '%s'", fingerprinter.edtAddress.Text)); return end
      if not size or size<=0 then showMessage("Please enter a valid size."); return end
      scanMemoryRegion(addr, size)
    end
    fingerprinter.btnScan.OnClick = executeScan
    fingerprinter.btnCancel.OnClick = function() if fingerprinter.scanThread then fingerprinter.scanThread.terminate() end end
    fingerprinter.edtAddress.OnKeyDown=function(sender,key) if key==VK_RETURN then local addr=getAddressSafe(sender.Text) if addr and addr>0 then sender.Tag=addr;executeScan() else showMessage(string.format("Could not resolve address: '%s'",sender.Text)) end end end
    fingerprinter.btnCreate.OnClick=createCEStructure
    fingerprinter.chkShowPadding.OnClick = populateListView

    local function commitAndDestroyEdit(shouldSave)
      if not fingerprinter.activeEditControl then return end
      local ctrl = fingerprinter.activeEditControl.control
      local item = fingerprinter.activeEditControl.item
      local col = fingerprinter.activeEditControl.col
      if shouldSave and ctrl.Text ~= "" then
        item.SubItems.Strings[col - 1] = ctrl.Text
      end
      ctrl.destroy()
      fingerprinter.activeEditControl = nil
    end

    lv.OnDblClick = function()
      if fingerprinter.activeEditControl then return end
      local item = lv.Selected; if not item then return end
      local screenX,screenY = getMousePos(); local clientX,clientY = lv.ScreenToClient(screenX,screenY)
      local col = -1; local currentWidth = 0
      for i=0,lv.Columns.Count-1 do currentWidth=currentWidth+lv.Columns[i].Width;if clientX<currentWidth then col=i;break end end

      local rect = item.displayRectSubItem(col, drLabel)
      local ctrl
      if col == 1 then -- Proposed Type
        ctrl = createComboBox(lv); ctrl.Items.addStrings(fingerprinter.allTypes); ctrl.Style = 'csDropDownList'; ctrl.OnSelect = function() commitAndDestroyEdit(true) end
      elseif col == 2 or col == 3 then -- Value or Name
        ctrl = createEdit(lv)
        ctrl.OnKeyDown = function(sender, key) if key == VK_RETURN then commitAndDestroyEdit(true) elseif key == VK_ESCAPE then commitAndDestroyEdit(false) end end
      else return end
      
      ctrl.Left=rect.Left-2; ctrl.Top=rect.Top-2; ctrl.Width=lv.Columns[col].Width+4; ctrl.Height=rect.Bottom-rect.Top+4
      ctrl.Text = item.SubItems[col - 1]
      ctrl.OnExit = function() commitAndDestroyEdit(true) end
      ctrl.show(); ctrl.setFocus()
      if ctrl.ClassName == 'TComboBox' then ctrl.DroppedDown = true else ctrl.selectAll() end
      fingerprinter.activeEditControl = {control = ctrl, item = item, col = col}
    end

    local lvPopup=createPopupMenu(lv); lv.PopupMenu=lvPopup
    local miFingerprintPointer=createMenuItem(lvPopup); miFingerprintPointer.Caption="Fingerprint This Pointer"
    lvPopup.Items.add(miFingerprintPointer)
    lvPopup.OnPopup=function() local item=lv.Selected; miFingerprintPointer.Enabled=(item and item.Data and item.Data>0) end
    miFingerprintPointer.OnClick=function()
      local item=lv.Selected; if not item or not item.Data or item.Data==0 then return end
      local newAddr=item.Data
      fingerprinter.edtAddress.Text=getNameFromAddress(newAddr)
      fingerprinter.edtAddress.Tag=newAddr
      executeScan()
    end
    local memview=getMemoryViewForm()
    if memview then
      local dv=memview.DisassemblerView; fingerprinter.originalOnSelectionChange=dv.OnSelectionChange
      dv.OnSelectionChange = function(sender,address,address2)
        if fingerprinter.form and fingerprinter.form.Visible then
          if fingerprinter.edtAddress.Tag~=address then fingerprinter.edtAddress.Text=getNameFromAddress(address);fingerprinter.edtAddress.Tag=address;fingerprinter.lvResults.Items.clear() end
        end
        if fingerprinter.originalOnSelectionChange then fingerprinter.originalOnSelectionChange(sender,address,address2) end
      end
    end
    f.OnClose = function()
      if fingerprinter.scanThread then fingerprinter.scanThread.terminate() end
      if fingerprinter.activeEditControl then fingerprinter.activeEditControl.control.destroy(); fingerprinter.activeEditControl=nil end
      local memview=getMemoryViewForm() if memview then memview.DisassemblerView.OnSelectionChange=fingerprinter.originalOnSelectionChange end;
      return caHide
    end
    f.show()
  end

  launchTool = function()
    if not fingerprinter.form then createGUI() end
    fingerprinter.form.show()
    fingerprinter.form.bringToFront()
    local memview=getMemoryViewForm()
    if memview and memview.DisassemblerView.SelectedAddress then
      local newAddress=memview.DisassemblerView.SelectedAddress
      if fingerprinter.edtAddress.Tag~=newAddress then
        fingerprinter.edtAddress.Text=getNameFromAddress(newAddress)
        fingerprinter.edtAddress.Tag=newAddress
        fingerprinter.lvResults.Items.clear()
      end
    end
  end

  local function addTopLevelMenuItem()
    local mainMenu=getMainForm().Menu;local toolsMenu=nil
    for i=0,mainMenu.Items.Count-1 do if mainMenu.Items[i].Caption==fingerprinter.uiSettings.topLevelMenuCaption then toolsMenu=mainMenu.Items[i];break end end
    if not toolsMenu then toolsMenu=createMenuItem(mainMenu);toolsMenu.Caption=fingerprinter.uiSettings.topLevelMenuCaption;mainMenu.Items.add(toolsMenu) end
    local menuItem=createMenuItem(toolsMenu);menuItem.Caption=fingerprinter.uiSettings.menuItemCaption;menuItem.OnClick=launchTool;toolsMenu.add(menuItem)
  end

  addTopLevelMenuItem()
end