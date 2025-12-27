--[[
  Programmer's Calculator Suite v1.0.0 for Cheat Engine 7.6
  Author: HydraNyxus
  
  Features:
  - Real-time Hex/Dec/Oct/Bin conversion
  - Float/Double representation of integer values
  - Endianness swapping (2, 4, 8 bytes)
  - Bitwise operations (AND, OR, XOR, NOT, SHL, SHR)
  - ASCII/Text decoding
  - Memory Expression Evaluator
]]

-- Prevent multiple instances of the script definition
if syntaxcheck then return end

-- /// SINGLETON CHECK ///
local function findFormByName_ProgCalc(name)
    for i = 0, getFormCount() - 1 do
        local form = getForm(i)
        if form and form.Name == name then
            return form
        end
    end
    return nil
end

-- If form exists, bring it to front instead of creating a new one
if findFormByName_ProgCalc("frmProgCalculatorOwner") then
    local existingForm = findFormByName_ProgCalc("frmProgCalculator")
    if existingForm then
        existingForm:show()
        existingForm:bringToFront()
    end
    print("Programmer's Calculator is already running.")
    return
end

do
    -- /// STATE & CONFIGURATION ///
    local Calculator = {
        form = nil,
        pageControl = nil,
        ui = {}, -- Holds all UI components
        menuItemCaption = "Programmer's Calculator",
        extGroupMenuCaption = "Nyxus Toolbox",
        history = {},
        maxHistory = 50,
        isUpdatingUI = false, -- Flag to prevent recursive UI updates
        bitOpHandler = nil    -- Forward declaration
    }

    -- /// HELPER FUNCTIONS ///

    -- Safe evaluation for the "Memory Calc" tab
    local function safeEvaluate(expr)
        if not expr or expr == "" then return nil, "Empty expression" end
        
        -- Restricted environment for safety
        local env = {
            abs = math.abs, acos = math.acos, asin = math.asin, atan = math.atan,
            ceil = math.ceil, cos = math.cos, deg = math.deg, exp = math.exp,
            floor = math.floor, fmod = math.fmod, huge = math.huge, log = math.log,
            max = math.max, min = math.min, modf = math.modf, pi = math.pi,
            pow = math.pow, rad = math.rad, sin = math.sin, sqrt = math.sqrt,
            tan = math.tan,
            tonumber = tonumber, tostring = tostring, type = type,
            -- CE Bitwise globals
            bAnd = bAnd, bOr = bOr, bNot = bNot, bXor = bXor, bShl = bShl, bShr = bShr
        }
        
        local func, err = load("return " .. expr, "expression", "t", env)
        if not func then return nil, "Syntax error: " .. err end
        
        local ok, result = pcall(func)
        if not ok then return nil, "Runtime error: " .. tostring(result) end
        
        return result
    end

    -- Convert integer to formatted binary string (32-bit limit)
    local function toBinaryString(n)
        if not n then return "" end
        n = tonumber(n)
        if not n then return "" end
        
        if n < 0 then n = 0xFFFFFFFF + n + 1 end
        n = bAnd(n, 0xFFFFFFFF)
        
        local bits = {}
        for i = 31, 0, -1 do
            table.insert(bits, bAnd(bShr(n, i), 1))
            if i > 0 and i % 8 == 0 then
                if i % 16 == 0 then
                    table.insert(bits, "  ") -- Extra space for word boundary
                else
                    table.insert(bits, " ")  -- Space for byte boundary
                end
            end
        end
        return table.concat(bits)
    end

    -- Swap endianness for specific byte widths
    local function swapEndian(n, bytes)
        n = tonumber(n)
        if not n then return 0 end
        if bytes ~= 2 and bytes ~= 4 and bytes ~= 8 then return n end
        
        local result = 0
        for i = 0, bytes - 1 do
            local byte = bAnd(bShr(n, i * 8), 0xFF)
            result = bOr(result, bShl(byte, (bytes - 1 - i) * 8))
        end
        return result
    end

    local function addToHistory(entry)
        if not entry or entry == "" then return end
        table.insert(Calculator.history, 1, entry)
        if #Calculator.history > Calculator.maxHistory then
            table.remove(Calculator.history)
        end
        if Calculator.ui.historyList then
            Calculator.ui.historyList.Lines.Text = table.concat(Calculator.history, "\r\n")
        end
    end

    -- /// GUI HELPERS ///
    local function makeLabel(parent, caption, x, y)
        local lbl = createLabel(parent)
        lbl.Caption = caption
        if x and y then
            lbl.Left, lbl.Top, lbl.Width, lbl.Height = x, y, 100, 21
        end
        return lbl
    end

    local function makeButton(parent, caption, x, y, width)
        local btn = createButton(parent)
        btn.Caption = caption
        btn.Left, btn.Top, btn.Width, btn.Height = x, y, width or 75, 25
        return btn
    end

    local function makeLabeledEdit(parent, caption, x, y, width)
        local lbl = createLabel(parent)
        lbl.Left, lbl.Top, lbl.Width, lbl.Height = x, y + 2, 50, 21
        lbl.Caption = caption .. ":"
        
        local edt = createEdit(parent)
        edt.Left, edt.Top, edt.Width, edt.Height = x + 60, y, width, 21
        edt.Font.Name = "Consolas"
        return edt
    end

    -- Helper to convert Int representation to Float
    local function bytesToFloat(intValue)
        if not intValue then return 0 end
        intValue = tonumber(intValue)
        if not intValue then return 0 end
        
        if intValue > 0xFFFFFFFF then return 0 end
        if intValue < 0 then intValue = 0xFFFFFFFF + intValue + 1 end
        
        local ok, result = pcall(function()
            return byteTableToFloat(dwordToByteTable(intValue))
        end)
        return ok and result or 0
    end

    -- Helper to convert Int representation to Double
    local function bytesToDouble(intValue)
        if not intValue then return 0 end
        intValue = tonumber(intValue)
        if not intValue then return 0 end
        
        local ok, result = pcall(function()
            return byteTableToDouble(qwordToByteTable(intValue))
        end)
        return ok and result or 0
    end

    -- /// CORE LOGIC - UI UPDATES ///

    function Calculator:updateAllViews(source)
        if self.isUpdatingUI then return end
        self.isUpdatingUI = true

        local text = source.Text
        local numberValue

        if source == self.ui.progBin then
            text = text:gsub("[^01]", "")
            if text ~= "" then numberValue = tonumber(text, 2) end
        elseif source == self.ui.progHex or source == self.ui.floatHex then
            text = text:lower():gsub("0x", ""):gsub("[^0-9a-f%-]", "")
            if text ~= "" then
                if text:sub(1,1) == "-" then
                    local hexPart = text:sub(2)
                    if hexPart ~= "" then numberValue = -tonumber(hexPart, 16) end
                else
                    numberValue = tonumber(text, 16)
                end
            end
        elseif source == self.ui.progDec then
            text = text:gsub("[^0-9%-]", "")
            if text ~= "" and text ~= "-" then numberValue = tonumber(text, 10) end
        elseif source == self.ui.progOct then
            text = text:gsub("[^0-7]", "")
            if text ~= "" then numberValue = tonumber(text, 8) end
        end

        if numberValue then
            if self.ui.progHex ~= source then
                self.ui.progHex.Text = (numberValue >= 0) and string.format("0x%X", numberValue) or string.format("-0x%X", -numberValue)
            end
            if self.ui.progDec ~= source then
                self.ui.progDec.Text = tostring(numberValue)
            end
            if self.ui.progOct ~= source then
                self.ui.progOct.Text = (numberValue >= 0) and string.format("%o", numberValue) or ""
            end
            if self.ui.progBin ~= source then
                self.ui.progBin.Text = toBinaryString(numberValue)
            end
            if self.ui.floatHex ~= source then
                self.ui.floatHex.Text = (numberValue >= 0) and string.format("0x%X", numberValue) or string.format("-0x%X", -numberValue)
            end

            self.ui.floatVal.Text = tostring(bytesToFloat(numberValue))
            self.ui.doubleVal.Text = tostring(bytesToDouble(numberValue))
        end

        self.isUpdatingUI = false
    end

    function Calculator:updateTextView(source)
        if self.isUpdatingUI then return end
        self.isUpdatingUI = true
        
        local text = source.Text
        if text == "" then
            if source == self.ui.textChar then self.ui.textCode.Text = "" else self.ui.textChar.Text = "" end
            self.isUpdatingUI = false
            return
        end
        
        if source == self.ui.textChar then
            local codes = {}
            for i = 1, #text do
                table.insert(codes, string.format("0x%02X", string.byte(text, i)))
            end
            self.ui.textCode.Text = table.concat(codes, " ")
        elseif source == self.ui.textCode then
            local chars = {}
            -- Try 0x format first
            for code in text:gmatch("0x(%x+)") do
                local num = tonumber(code, 16)
                if num and num >= 0 and num <= 255 then table.insert(chars, string.char(num)) end
            end
            -- Fallback to plain hex
            if #chars == 0 then
                for code in text:gmatch("(%x%x)") do
                    local num = tonumber(code, 16)
                    if num and num >= 0 and num <= 255 then table.insert(chars, string.char(num)) end
                end
            end
            self.ui.textChar.Text = table.concat(chars)
        end
        
        self.isUpdatingUI = false
    end

    function Calculator:evaluateMemoryExpression()
        local expr = self.ui.memExpr.Text
        local result, err = safeEvaluate(expr)
        
        if result then
            local numResult = tonumber(result)
            if numResult then
                self.ui.memResult.Text = string.format("Decimal: %d\r\nHex: 0x%X", numResult, numResult)
                addToHistory(string.format("%s = %d (0x%X)", expr, numResult, numResult))
            else
                self.ui.memResult.Text = "Result: " .. tostring(result)
                addToHistory(string.format("%s = %s", expr, tostring(result)))
            end
        else
            self.ui.memResult.Text = "Error: " .. tostring(err)
        end
    end

    -- /// GUI CREATION ///

    function Calculator:createGUI()
        self.form = createForm(false)
        local f = self.form
        f.Caption, f.Name = self.menuItemCaption, "frmProgCalculator"
        f.Width, f.Height = 500, 420
        f.Position = "poScreenCenter"
        f.BorderStyle = "bsSingle"
        
        self.pageControl = createPageControl(f)
        self.pageControl.Align = "alClient"
        
        self:createProgrammerTab()
        self:createFloatingPointTab()
        self:createTextTab()
        self:createMemoryTab()
        self:createHistoryTab()
        
        f.OnClose = function() return caHide end
    end

    function Calculator:createProgrammerTab()
        local tab = self.pageControl.addTab()
        tab.Caption = "Programmer"
        local ui = self.ui
        local y = 10
        
        ui.progHex = makeLabeledEdit(tab, "Hex", 10, y, 400)
        y = y + 30
        ui.progDec = makeLabeledEdit(tab, "Dec", 10, y, 400)
        y = y + 30
        ui.progOct = makeLabeledEdit(tab, "Octal", 10, y, 400)
        y = y + 30
        ui.progBin = makeLabeledEdit(tab, "Binary", 10, y, 400)
        y = y + 40
        
        makeLabel(tab, "Endian Swap:", 10, y)
        ui.btnSwap2 = makeButton(tab, "2-Byte", 100, y - 2, 70)
        ui.btnSwap4 = makeButton(tab, "4-Byte", 180, y - 2, 70)
        ui.btnSwap8 = makeButton(tab, "8-Byte", 260, y - 2, 70)
        y = y + 35
        
        makeLabel(tab, "Bitwise Ops:", 10, y)
        ui.progBitOpInput = createEdit(tab)
        ui.progBitOpInput.Left, ui.progBitOpInput.Top, ui.progBitOpInput.Width, ui.progBitOpInput.Height =
            100, y - 2, 100, 21
        ui.progBitOpInput.Text = "0"
        ui.progBitOpInput.Font.Name = "Consolas"
        
        local ops = {"AND", "OR", "XOR", "NOT", "LShift", "RShift"}
        local opX = 210
        for _, opName in ipairs(ops) do
            local btnWidth = (opName:find("Shift")) and 55 or 45
            local btn = makeButton(tab, opName, opX, y - 2, btnWidth)
            ui["btnOp" .. opName] = btn
            btn.OnClick = function() Calculator.bitOpHandler(opName) end
            opX = opX + btnWidth + 5
        end
    end

    function Calculator:createFloatingPointTab()
        local tab = self.pageControl.addTab()
        tab.Caption = "Floating-Point"
        local ui = self.ui
        
        ui.floatHex = makeLabeledEdit(tab, "Hex Value", 10, 10, 300)
        ui.floatVal = makeLabeledEdit(tab, "As Float", 10, 55, 300)
        ui.doubleVal = makeLabeledEdit(tab, "As Double", 10, 100, 300)
        ui.floatVal.ReadOnly = true
        ui.doubleVal.ReadOnly = true
    end

    function Calculator:createTextTab()
        local tab = self.pageControl.addTab()
        tab.Caption = "Text / ASCII"
        local ui = self.ui
        
        ui.textChar = makeLabeledEdit(tab, "Text", 10, 10, 350)
        ui.textCode = makeLabeledEdit(tab, "Hex Code", 10, 55, 350)
        
        local helpLabel = createLabel(tab)
        helpLabel.Caption = "Enter text above or hex codes (e.g., 0x48 0x65 or 4865) below"
        helpLabel.Left, helpLabel.Top = 10, 90
        helpLabel.AutoSize = true
    end

    function Calculator:createMemoryTab()
        local tab = self.pageControl.addTab()
        tab.Caption = "Memory Calc"
        local ui = self.ui
        
        ui.memExpr = makeLabeledEdit(tab, "Expression", 10, 10, 350)
        ui.memResult = createMemo(tab)
        ui.memResult.Left, ui.memResult.Top, ui.memResult.Width, ui.memResult.Height = 10, 55, 410, 100
        ui.memResult.ReadOnly = true
        ui.memResult.Font.Name = "Consolas"
        ui.btnMemCalc = makeButton(tab, "Calculate", 10, 165, 100)
        
        local helpLabel = createLabel(tab)
        helpLabel.Caption = "Supports: +, -, *, /, ^, %, math functions, and bitwise ops (bAnd, bOr, etc.)"
        helpLabel.Left, helpLabel.Top = 10, 195
        helpLabel.AutoSize = true
    end

    function Calculator:createHistoryTab()
        local tab = self.pageControl.addTab()
        tab.Caption = "History"
        self.ui.historyList = createMemo(tab)
        self.ui.historyList.Align = "alClient"
        self.ui.historyList.ReadOnly = true
        self.ui.historyList.ScrollBars = "ssVertical"
        self.ui.historyList.Font.Name = "Consolas"
    end

    -- /// EVENT HANDLERS ///

    function Calculator:setupEventHandlers()
        local ui = self.ui
        local safeUpdate = function(sender) self:updateAllViews(sender) end
        
        ui.progHex.OnChange = safeUpdate
        ui.progDec.OnChange = safeUpdate
        ui.progBin.OnChange = safeUpdate
        ui.progOct.OnChange = safeUpdate
        ui.floatHex.OnChange = safeUpdate
        
        ui.textChar.OnChange = function(sender) self:updateTextView(sender) end
        ui.textCode.OnChange = function(sender) self:updateTextView(sender) end
        
        ui.btnMemCalc.OnClick = function() self:evaluateMemoryExpression() end
        ui.memExpr.OnKeyDown = function(sender, key)
            if key == 13 then self:evaluateMemoryExpression() end
        end

        local endianHandler = function(byteSize)
            local n = tonumber(ui.progDec.Text)
            if n then
                local swapped = swapEndian(n, byteSize)
                ui.progDec.Text = tostring(swapped)
                addToHistory(string.format("Swapped %d-byte: 0x%X -> 0x%X", byteSize, n, swapped))
            end
        end
        ui.btnSwap2.OnClick = function() endianHandler(2) end
        ui.btnSwap4.OnClick = function() endianHandler(4) end
        ui.btnSwap8.OnClick = function() endianHandler(8) end

        -- Bitwise Handler
        Calculator.bitOpHandler = function(op)
            local val1 = tonumber(ui.progDec.Text)
            local val2 = tonumber(ui.progBitOpInput.Text)
            if not val1 then return end
            
            local result
            if op == "NOT" then
                result = bNot(val1)
            else
                if not val2 then return end
                if op == "AND" then result = bAnd(val1, val2)
                elseif op == "OR" then result = bOr(val1, val2)
                elseif op == "XOR" then result = bXor(val1, val2)
                elseif op == "LShift" then result = bShl(val1, val2)
                elseif op == "RShift" then result = bShr(val1, val2)
                end
            end
            
            if result then
                ui.progDec.Text = tostring(result)
                local hist = (op == "NOT") and 
                    string.format("NOT 0x%X = 0x%X", val1, result) or
                    string.format("0x%X %s 0x%X = 0x%X", val1, op, val2, result)
                addToHistory(hist)
            end
        end
    end

    -- /// LAUNCHER ///

    local function launchTool()
        if not Calculator.form then
            Calculator:createGUI()
            Calculator:setupEventHandlers()
            local ownerForm = createForm(false)
            ownerForm.Name = "frmProgCalculatorOwner"
            Calculator.form.Owner = ownerForm
        end
        Calculator.form:show()
        Calculator.form:bringToFront()
    end

    local function addMenuItem()
        local mm = getMainForm().Menu
        local extMenu
        
        for i = 0, mm.Items.Count - 1 do
            if mm.Items[i].Caption == Calculator.extGroupMenuCaption then
                extMenu = mm.Items[i]
                break
            end
        end
        
        if not extMenu then
            extMenu = createMenuItem(mm)
            extMenu.Caption = Calculator.extGroupMenuCaption
            mm.Items.add(extMenu)
        end
        
        for i = 0, extMenu.Count - 1 do
            if extMenu.Item[i].Caption == Calculator.menuItemCaption then return end
        end
        
        local extMenuItem = createMenuItem(extMenu)
        extMenuItem.Caption = Calculator.menuItemCaption
        extMenu.add(extMenuItem)
        extMenuItem.OnClick = launchTool
    end

    addMenuItem()
end
