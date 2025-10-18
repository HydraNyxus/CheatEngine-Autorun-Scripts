-- AOB Generator v3.8.0
-- Generates resilient, instruction-aware AOB signatures from selected code.
--
-- v3.x — Resilience & User Experience
-- -----------------------------------
-- Added: Console hint when scanning a single instruction
-- Added: Module detection algorithm for faster, targeted scans
-- Added: Deep Scan functionality (hold SHIFT) for pattern frequency analysis
--    • Automatically generates unique signatures if the initial one fails
--    • Progress bar and status label for user feedback
-- Improved: String-to-address conversion for safer handling of AOB results
-- Improved: Output formatting for signatures
--    • Console output now uses space-separated formatting for readability
--    • Clipboard and scanner output now compact and fully functional
-- Changed: Standardized wildcard usage to '??' for consistency
-- Fixed: Signature formatting issues that caused "scan failed" errors
-- Fixed: All variables are now locally scoped within the main block
-- Removed: Redundant string manipulation step before scanning
--
-- v2.x — Engine Overhaul & Advanced Generation
-- --------------------------------------------
-- Added: Advanced signature generation algorithm with instruction metadata analysis
-- Added: Timer-based GUI integration for stable operation
-- Added: Centralized configuration system for more maintainable code
-- Changed: Major architectural refactor with full encapsulation
--
-- v1.x — Foundation & Initial Release
-- -----------------------------------
-- Added: Basic AOB signature generation functionality

-- Only run this script once.
if syntaxcheck then return end

local function findFormByName_AOBGen(name)
  for i = 0, getFormCount() - 1 do
    local form = getForm(i)
    if form and form.Name == name then
      return form
    end
  end
  return nil
end

if findFormByName_AOBGen('frmAOBGenerator') then
  print("AOB Generator is already running.")
  return
end

do
  -- /// STATE & CONFIGURATION ///
  local AOBGen = {
    WildCard = '??',
    MinimumBytes = 5,
    MaxResultsPrinted = 20,
    CopySignatureToClipboard = true,
    MenuItemCaption = 'Generate Advanced AOB and Scan (Hold SHIFT for Deep Scan)',
    MenuItemShortcut = 'Ctrl+Shift+B',
    NgramSize = 4,
    memview = nil,
    menuItem = nil,
    progressPanel = nil,
    progressBar = nil,
    progressLabel = nil
  }

  -- /// DEPENDENCY SETUP ///
  local AOBScanModule
  local status = pcall(require, 'I2CETLua.functions')
  if status then
    AOBScanModule = _G['AOBScanModule']
  else
    AOBScanModule = function(moduleName, signature)
      if not moduleName or not signature then return nil end
      local modInfo = getAddressSafe(moduleName)
      if not modInfo then return nil end
      local aobResults = AOBScan(signature, "+X", 0, "", getAddress(moduleName), getAddress(moduleName) + getModuleSize(moduleName))
      return aobResults
    end
  end

  -- /// CE API CONSTANTS ///
  local DisassemblerValueTypes = { dvtNone = 0, dvtAddress = 1, dvtValue = 2 }
  local disassembler = createDisassembler()

  -- /// CORE LOGIC ///
  local function splitString(inputstr, sep)
    if sep == nil then sep = "%s" end
    local t = {}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
      table.insert(t, str)
    end
    return t
  end

  function getModuleForAddress(address)
    local modules = enumModules()
    if not modules then return nil end
    for i, moduleInfo in ipairs(modules) do
      if address >= moduleInfo.Address and address < (moduleInfo.Address + moduleInfo.Size) then
        return moduleInfo.Name
      end
    end
    return nil
  end

  function generateAdvancedSignature(startAddr, endAddr)
    local signatureBytes = {}
    local currentAddr = startAddr
    while currentAddr <= endAddr do
      local instSize = getInstructionSize(currentAddr)
      if instSize == 0 then break end
      disassembler.disassemble(currentAddr)
      local lastData = disassembler.getLastDisassembleData()
      local bytesTable = readBytes(currentAddr, instSize, true)
      local hexParts = {}
      for i = 1, #bytesTable do table.insert(hexParts, string.format('%02X', bytesTable[i])) end
      local isMemoryOperand = (lastData.modrmValueType == DisassemblerValueTypes.dvtAddress or lastData.parameterValueType == DisassemblerValueTypes.dvtAddress)
      if lastData.isJump or lastData.isCall or isMemoryOperand then
        local operandSize = 0
        if instSize > 4 and (lastData.isJump or lastData.isCall or isMemoryOperand) then operandSize = 4
        elseif instSize > 2 and (lastData.isJump or lastData.isCall) then operandSize = 2
        elseif instSize > 1 and lastData.isJump then operandSize = 1 end
        if operandSize > 0 then
          for i = (instSize - operandSize + 1), instSize do hexParts[i] = AOBGen.WildCard end
        end
      end
      for _, byteStr in ipairs(hexParts) do table.insert(signatureBytes, byteStr) end
      currentAddr = currentAddr + instSize
    end
    return signatureBytes
  end

  function findUniqueSignature(originalSigTable, startAddr, endAddr, moduleName, parentThread)
    local selectionSize = (endAddr - startAddr) + getInstructionSize(endAddr)
    local originalBytes = readBytes(startAddr, selectionSize, true)
    if not originalBytes then return nil end

    local patterns = {}
    if #originalBytes < AOBGen.NgramSize then return nil end
    for i = 1, #originalBytes - (AOBGen.NgramSize - 1) do
      local patternBytes = {}
      for j = 0, AOBGen.NgramSize - 1 do table.insert(patternBytes, string.format("%02X", originalBytes[i+j])) end
      local patternStr = table.concat(patternBytes, " ")
      patterns[patternStr] = { count = 0, offset = i - 1 }
    end

    local totalPatterns = 0
    for _ in pairs(patterns) do totalPatterns = totalPatterns + 1 end
    local patternsScanned = 0
    synchronize(function()
      AOBGen.progressLabel.Caption = 'Analyzing Frequencies...'
      AOBGen.progressBar.Max = totalPatterns
      AOBGen.progressBar.Position = 0
      AOBGen.progressPanel.Visible = true
    end)

    local rankedPatterns = {}
    for pStr, data in pairs(patterns) do
      if parentThread.Terminated then synchronize(function() AOBGen.progressPanel.Visible = false end); return nil end
      local res = AOBScanModule(moduleName, pStr)
      if res then
        data.count = res.Count
        table.insert(rankedPatterns, { pattern = pStr, data = data })
        res.destroy()
      end
      patternsScanned = patternsScanned + 1
      if patternsScanned % 5 == 0 then
        synchronize(function() AOBGen.progressBar.Position = patternsScanned end)
      end
    end

    table.sort(rankedPatterns, function(a, b) return a.data.count < b.data.count end)

    synchronize(function()
      AOBGen.progressLabel.Caption = 'Refining Signature...'
      AOBGen.progressBar.Max = #rankedPatterns
      AOBGen.progressBar.Position = 0
    end)

    local refinedSigTable = {}
    for _, b in ipairs(originalSigTable) do table.insert(refinedSigTable, b) end

    for i, ranked in ipairs(rankedPatterns) do
      if parentThread.Terminated then synchronize(function() AOBGen.progressPanel.Visible = false end); return nil end
      if ranked.data.count > 0 then
        local bytesToUnwildcard = splitString(ranked.pattern, " ")
        for j = 1, #bytesToUnwildcard do
          refinedSigTable[ranked.data.offset + j] = bytesToUnwildcard[j]
        end
        local newSig = table.concat(refinedSigTable, ' ')
        local res = AOBScanModule(moduleName, newSig)
        
        if res and res.Count == 1 then
          res.destroy()
          synchronize(function() AOBGen.progressPanel.Visible = false end)
          return newSig
        end
        if res then res.destroy() end
      end
      if i % 5 == 0 then
        synchronize(function() AOBGen.progressBar.Position = i end)
      end
    end

    synchronize(function() AOBGen.progressPanel.Visible = false end)
    return nil
  end

  function performAOBScan(deepScan, parentThread)
    local dv = AOBGen.memview and AOBGen.memview.DisassemblerView
    if not dv then print("AOB Generator Error: Memory View is not available."); return end
    
    local startAddress = math.min(dv.SelectedAddress, dv.SelectedAddress2)
    local endAddress = math.max(dv.SelectedAddress, dv.SelectedAddress2)

    -- Add hint for single-line selections.
    if startAddress == endAddress then
      print("Hint: Only one instruction is selected. To scan a larger range for a more robust signature, highlight multiple lines in the disassembler.")
    end

    local selectionLength = (endAddress - startAddress) + getInstructionSize(endAddress)

    if selectionLength < AOBGen.MinimumBytes then
      print(string.format("Error: You must select at least %d bytes. Only %d selected.", AOBGen.MinimumBytes, selectionLength))
      return
    end

    local signatureTable = generateAdvancedSignature(startAddress, endAddress)
    local scanSignature = table.concat(signatureTable, ' ')
    
    if AOBGen.CopySignatureToClipboard then
      writeToClipboard(table.concat(signatureTable, ''))
      synchronize(function()
        local nf = createForm(false); nf.BorderStyle='bsNone'; nf.FormStyle='fsStayOnTop'; nf.Position='poScreenCenter'; nf.Color=clInfoBk
        local lbl = createLabel(nf); lbl.Caption="AOB signature copied to clipboard!"; lbl.Font.Color=clInfoText; lbl.ParentFont=false
        local p=20; nf.Width=nf.Canvas.getTextWidth(lbl.Caption)+(p*2); nf.Height=nf.Canvas.getTextHeight("X")+(p*2); lbl.Left=p; lbl.Top=p
        local ct=createTimer(nf); ct.Interval=1000; ct.OnTimer=function(t) nf.close(); t.destroy() end; nf.OnClose=function() return caFree end
        nf.show()
      end)
    end

    local output = {'-'..string.rep('-', 78)..'-'}
    table.insert(output, "Advanced AOB Signature Scan Initiated" .. (deepScan and " (Deep Scan)" or ""))
    table.insert(output, string.format("  Process: %s", process or "N/A"))
    table.insert(output, string.format("  Initial Signature: %s", scanSignature))
    table.insert(output, string.format("  Addresses: %s -> %s", getNameFromAddress(startAddress), getNameFromAddress(endAddress)))
    print(table.concat(output, '\n'))

    local moduleName = getModuleForAddress(startAddress)
    local results
    local resultsOutput = {}

    if moduleName then
      table.insert(resultsOutput, string.format("  Scanning Module: %s", moduleName))
      results = AOBScanModule(moduleName, scanSignature)
    else
      table.insert(resultsOutput, "  Module not found. Scanning all process memory...")
      results = AOBScan(scanSignature)
    end

    if deepScan and results and results.Count > 1 and moduleName then
      table.insert(resultsOutput, string.format("  Initial signature is not unique (%d results). Starting deep analysis...", results.Count))
      print(table.concat(resultsOutput, '\n')); resultsOutput = {}
      
      local uniqueSignature = findUniqueSignature(signatureTable, startAddress, endAddress, moduleName, parentThread)
      
      if uniqueSignature then
        table.insert(resultsOutput, "  [SUCCESS] Found a unique signature:")
        table.insert(resultsOutput, string.format("    %s", uniqueSignature))
        scanSignature = uniqueSignature
        if results then results.destroy() end
        results = AOBScanModule(moduleName, scanSignature)
      else
        table.insert(resultsOutput, "  [FAILURE] Could not find a unique signature after deep analysis.")
      end
    end

    if results then
      table.insert(resultsOutput, string.format("  Final Matches Found: %d", results.Count))
      if results.Count > 0 and results.Count <= AOBGen.MaxResultsPrinted then
        for i = 0, results.Count - 1 do
          local resultAddr = getAddressSafe("0x" .. results[i])
          if resultAddr then
            local locationStr = getNameFromAddress(resultAddr)
            if resultAddr == startAddress then
              table.insert(resultsOutput, string.format("    %s  <-- [Original Address]", locationStr))
            else
              table.insert(resultsOutput, string.format("    %s", locationStr))
            end
          end
        end
      elseif results.Count > AOBGen.MaxResultsPrinted then
        table.insert(resultsOutput, string.format("  (More than %d results, not printing all.)", AOBGen.MaxResultsPrinted))
      end
      results.destroy()
    else
      table.insert(resultsOutput, "  Error: AOB scan failed or returned no results object.")
    end

    print(table.concat(resultsOutput, '\n'))
  end

  function runScanThreaded()
    local deepScanRequested = isKeyPressed(VK_SHIFT)
    createThread(function(thread)
      performAOBScan(deepScanRequested, thread)
    end)
  end

  -- /// GUI INTEGRATION ///
  function addMenuItemToView(memview)
    if not memview then return end
    AOBGen.memview = memview
    
    local mf = getMainForm()
    AOBGen.progressPanel = createPanel(mf)
    AOBGen.progressPanel.Align = alBottom
    AOBGen.progressPanel.Height = 25
    AOBGen.progressPanel.BevelOuter = 'bvNone'
    AOBGen.progressPanel.Visible = false

    AOBGen.progressLabel = createLabel(AOBGen.progressPanel)
    AOBGen.progressLabel.Align = alLeft
    AOBGen.progressLabel.Caption = 'Analyzing Frequencies...'
    AOBGen.progressLabel.BorderSpacing.Left = 5

    AOBGen.progressBar = createProgressBar(AOBGen.progressPanel)
    AOBGen.progressBar.Align = alClient
    AOBGen.progressBar.BorderSpacing.Left = 5
    AOBGen.progressBar.BorderSpacing.Right = 5
    
    local popup = memview.DisassemblerView.PopupMenu
    if not popup then return end
    for i = 0, popup.Items.Count - 1 do
      if popup.Items[i].Caption:find('Generate Advanced AOB') then return end
    end
    local separator = createMenuItem(popup); separator.Caption = '-';
    local menuItem = createMenuItem(popup)
    menuItem.Caption = AOBGen.MenuItemCaption
    menuItem.Shortcut = AOBGen.MenuItemShortcut
    menuItem.OnClick = runScanThreaded
    
    local insertPos = math.min(6, popup.Items.Count)
    popup.Items.insert(insertPos, separator)
    popup.Items.insert(insertPos + 1, menuItem)
  end

  local initTimer = createTimer()
  initTimer.Interval = 2000
  initTimer.OnTimer = function(timer)
    if getOpenedProcessID() > 0 then
      local memview = getMemoryViewForm()
      if memview then
        addMenuItemToView(memview)
        timer.destroy()
      end
    end
  end

  local ownerForm = createForm(false)
  ownerForm.Name = 'frmAOBGenerator'
  ownerForm.OnClose = function()
    if AOBGen.progressPanel then AOBGen.progressPanel.destroy() end
    return caFree
  end
  initTimer.Owner = ownerForm
end