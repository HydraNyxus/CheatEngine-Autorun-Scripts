-- Code Flow Visualizer v1.0.0
-- An advanced reverse engineering tool that visualizes the call chain leading to a specific instruction.
-- Recursively finds all functions that call a target address and displays the results as an interactive graph.
--
-- v1.x — Foundation & Initial Release
-- -----------------------------------
-- Added: Call chain visualization for selected instructions in the disassembler
-- Added: Recursive analysis of all functions calling a target address
-- Added: Interactive graph display to explore call relationships visually
-- Added: Context menu integration ("Visualize Callers") in Cheat Engine’s Memory Viewer disassembler

-- Only run this script once.
if syntaxcheck then return end

-- Prevent multiple instances by checking for our management form.
local function findFormByName_CFV(name)
  for i = 0, getFormCount() - 1 do
    local form = getForm(i)
    if form and form.Name == name then return form end
  end
  return nil
end

if findFormByName_CFV('frmCodeFlowVizManager') then
  print("Code Flow Visualizer is already running.")
  return
end

do
  -- Localize frequently used globals for a minor speed boost.
  local pairs, ipairs, math, string, table = pairs, ipairs, math, string, table
  local jtCall = _G.jtCall or 0

  -- /// HELPER FUNCTIONS ///

  local function getModuleForAddress(address)
    local modules = enumModules()
    if not modules then return nil end
    for i, moduleInfo in ipairs(modules) do
      if address >= moduleInfo.Address and address < (moduleInfo.Address + moduleInfo.Size) then
        return moduleInfo.Name
      end
    end
    return nil
  end

  local function enrichNodeName(address)
    local symbol = getNameFromAddress(address)
    local module = getModuleForAddress(address)
    local addrStr = string.format("0x%X", address)
    local parts = {}

    if symbol and symbol ~= "" and not symbol:match("^%x+$") then
      table.insert(parts, symbol)
    end
    if module and module ~= "" then
      table.insert(parts, "[" .. module .. "]")
    end
    table.insert(parts, "(" .. addrStr .. ")")

    return table.concat(parts, " ")
  end

  -- Create a namespace to encapsulate all our functions and data.
  local CodeFlowViz = {}

  -- /// CONFIGURATION ///
  CodeFlowViz.config = {
    MaxDepth = 5, -- How many levels of callers to scan.
    MenuItemCaption = "Visualize Callers",
    MenuItemShortcut = "Ctrl+Shift+V",
    DiagramFormTitle = "Code Flow Visualizer",
    BlockWidth = 200,
    BlockHeight = 40,
    HSpacing = 100, -- Horizontal space between depth levels.
    VSpacing = 20,  -- Vertical space between blocks in the same level.
  }

  -- /// CORE LOGIC ///

  -- Recursively builds a graph of nodes (functions) and edges (calls).
  function CodeFlowViz.buildCallGraph(startAddress, dissect)
    local graph = { nodes = {}, edges = {} }
    local visited = {}

    local function traverse(targetAddress, depth)
      if depth > CodeFlowViz.config.MaxDepth or visited[targetAddress] then return end
      visited[targetAddress] = true

      if not graph.nodes[targetAddress] then
        graph.nodes[targetAddress] = {
          name = enrichNodeName(targetAddress),
          depth = depth
        }
      end

      local refs = dissect:getReferences(targetAddress)
      if not refs then return end

      for _, refInfo in ipairs(refs) do
        if refInfo.Type == jtCall then
          local callerAddress = refInfo.Address
          if not graph.nodes[callerAddress] then
            graph.nodes[callerAddress] = {
              name = enrichNodeName(callerAddress),
              depth = depth + 1
            }
          end
          table.insert(graph.edges, { from = callerAddress, to = targetAddress })
          traverse(callerAddress, depth + 1)
        end
      end
    end

    traverse(startAddress, 1)
    return graph
  end

  -- /// DIAGRAM GENERATION ///

  -- Creates a visual diagram from the generated call graph data.
  function CodeFlowViz.createDiagramFromGraph(graph)
    local cfg = CodeFlowViz.config
    local form = createForm(true)
    form.Caption = cfg.DiagramFormTitle
    form.Width = 1000
    form.Height = 700
    form.Position = 'poScreenCenter'

    local diagram = createDiagram(form)
    diagram.Align = 'alClient'

    local blockMap = {}
    local layout = { columns = {} }

    for address, nodeInfo in pairs(graph.nodes) do
      local block = diagram.createBlock()
      block.Caption = nodeInfo.name
      block.Width = cfg.BlockWidth
      block.Height = cfg.BlockHeight
      block.AutoSize = false
      blockMap[address] = block

      local depth = nodeInfo.depth
      layout.columns[depth] = layout.columns[depth] or {}
      table.insert(layout.columns[depth], block)
    end

    local maxBlocksInColumn = 0
    for _, blocks in pairs(layout.columns) do
      maxBlocksInColumn = math.max(maxBlocksInColumn, #blocks)
    end
    local totalHeight = maxBlocksInColumn * (cfg.BlockHeight + cfg.VSpacing)

    for depth, blocks in pairs(layout.columns) do
      local x = (cfg.MaxDepth - depth) * (cfg.BlockWidth + cfg.HSpacing) + 50
      local columnHeight = #blocks * (cfg.BlockHeight + cfg.VSpacing)
      local y_start = (totalHeight - columnHeight) / 2
      for i, block in ipairs(blocks) do
        block.X = x
        block.Y = y_start + (i - 1) * (cfg.BlockHeight + cfg.VSpacing)
      end
    end

    for _, edge in ipairs(graph.edges) do
      local sourceBlock = blockMap[edge.from]
      local destBlock = blockMap[edge.to]
      if sourceBlock and destBlock then
        diagram.addConnection(sourceBlock, destBlock)
      end
    end

    form.show()
    return form
  end

  -- /// ENTRY POINT & INTEGRATION ///

  -- Main function called by the menu item or hotkey.
  function CodeFlowViz.run()
    local memview = getMemoryViewForm()
    if not memview or not memview.DisassemblerView then
      return showMessage("Memory Viewer is not available.")
    end

    local dv = memview.DisassemblerView
    if not dv.SelectedAddress or dv.SelectedAddress == 0 then
      return showMessage("Please select an instruction to analyze.")
    end

    local targetAddress = dv.SelectedAddress
    local moduleName = getModuleForAddress(targetAddress)
    if not moduleName then
      return showMessage("Could not find a module for the selected address.")
    end

    showMessage("Analyzing call graph... This may take a moment.")

    createThread(function()
      local dissect = getDissectCode()
      dissect:dissect(moduleName)
      local graph = CodeFlowViz.buildCallGraph(targetAddress, dissect)
      synchronize(function()
        if #graph.edges == 0 then
          showMessage("No callers found for " .. enrichNodeName(targetAddress) .. " within the specified depth.")
        else
          CodeFlowViz.createDiagramFromGraph(graph)
        end
      end)
    end)
  end

  -- /// INITIALIZATION ///
  
  -- Adds the menu item to the Memory Viewer's context menu.
  function CodeFlowViz.addMenuItem(memview)
    local popup = memview.DisassemblerView.PopupMenu
    if not popup then return end
    
    for i = 0, popup.Items.Count - 1 do
      if popup.Items[i].Caption == CodeFlowViz.config.MenuItemCaption then return end
    end
    
    local separator = createMenuItem(popup); separator.Caption = '-';
    local menuItem = createMenuItem(popup)
    menuItem.Caption = CodeFlowViz.config.MenuItemCaption
    menuItem.Shortcut = CodeFlowViz.config.MenuItemShortcut
    menuItem.OnClick = function() pcall(CodeFlowViz.run) end -- Use pcall for safety
    
    local insertPos = math.min(9, popup.Items.Count)
    popup.Items.insert(insertPos, separator)
    popup.Items.insert(insertPos + 1, menuItem)
  end

  -- Sets up the plugin by waiting for a process to be opened.
  function CodeFlowViz.initialize()
    local initTimer = createTimer()
    initTimer.Interval = 2000
    initTimer.OnTimer = function(timer)
      if getOpenedProcessID() > 0 then
        local memview = getMemoryViewForm()
        if memview then
          CodeFlowViz.addMenuItem(memview)
          timer.destroy()
        end
      end
    end
    -- Create an invisible form to own the timer and manage the script's lifecycle.
    local managerForm = createForm(false)
    managerForm.Name = 'frmCodeFlowVizManager'
    initTimer.Owner = managerForm
  end

  CodeFlowViz.initialize()
end