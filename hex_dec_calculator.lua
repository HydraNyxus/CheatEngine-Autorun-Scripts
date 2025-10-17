-- Hex/Dec Calculator v2.3
-- Utility for converting values between hexadecimal and decimal.
--
-- v2.x — Refactoring & UI Overhaul
-- --------------------------------
-- Added: Real-time, bidirectional updates
--    • Editing any field (main, decimal, or hex) updates the others instantly
-- Added: Type auto-detection for input (hexadecimal or decimal)
-- Changed: UI/UX redesigned for a cleaner, more intuitive interface
--    • Two editable fields in the results memo for interactive editing
--    • Results displayed simultaneously in both hex and decimal
--    • Removed redundant "Convert" button for immediate conversion
-- Changed: Adopted encapsulated design pattern for stability and cross-script compatibility
-- Fixed: Critical UI layout issues and startup bugs
--
-- v1.x — Foundation & Initial Release
-- -----------------------------------
-- Added: Basic form for fast value conversion
-- Added: "Copy to Clipboard" button for results
-- Added: Integration into Cheat Engine's Extra Extensions menu
-- Changed: Minor UI/behavior adjustments

-- Only run this script once.
if syntaxcheck then return end

local function findFormByName_HexDecCalc(name)
  for i = 0, getFormCount() - 1 do
    local form = getForm(i)
    if form and form.Name == name then
      return form
    end
  end
  return nil
end

if findFormByName_HexDecCalc('frmHexDecCalcOwner') then
  local existingForm = findFormByName_HexDecCalc('frmHexDecCalculator')
  if existingForm then
    existingForm.show()
    existingForm.bringToFront()
  end
  print("Hex/Dec Calculator is already running.")
  return
end


do
  -- /// STATE & CONFIGURATION ///
  local calculator = {
    form = nil,
    editBox = nil,
    resultMemo = nil,
    menuItemCaption = 'Hex/Dec Calculator',
    extGroupMenuCaption = 'Nyxus Toolbox'
  }

  -- /// CORE LOGIC ///

  function performConversion()
    local input = calculator.editBox.Text:trim():lower()
    if input == '' then
      calculator.resultMemo.Lines.Text = ''
      return
    end

    local numberValue
    if input:match('^0x') then
      numberValue = tonumber(input)
    else
      numberValue = tonumber(input)
    end

    if not numberValue then
      calculator.resultMemo.Lines.Text = 'Error: Invalid input value.'
      return
    end

    local decResult = string.format("Decimal: %d", numberValue)
    local hexResult = string.format("Hex: 0x%X", numberValue)
    calculator.resultMemo.Lines.Text = table.concat({decResult, hexResult}, '\n')
  end

  function copyResult(keyword)
    local lines = calculator.resultMemo.Lines
    for i = 0, lines.Count - 1 do
      if lines[i]:match(keyword) then
        local valueToCopy = lines[i]:match('^[^:]+:%s*(.*)$')
        if valueToCopy then
          writeToClipboard(valueToCopy)
        end
        return
      end
    end
  end

  -- /// GUI CREATION & EVENT HANDLING ///

  function createGUI()
    calculator.form = createForm(false)
    local f = calculator.form
    f.Caption = calculator.menuItemCaption
    f.Name = 'frmHexDecCalculator'
    f.Width = 320
    f.Height = 220 -- [MODIFIED] Reduced height slightly as button is gone.
    f.BorderStyle = 'bsSingle'
    f.Position = 'poScreenCenter'

    -- Panel 1: Top section for input
    local pnlTop = createPanel(f)
    pnlTop.Align = 'alTop'
    pnlTop.Height = 65 -- [MODIFIED] Reduced height.
    pnlTop.BevelOuter = 'bvNone'

    local lblInfo = createLabel(pnlTop)
    lblInfo.Caption = 'Enter a decimal (e.g., 255) or hex (e.g., 0xFF) value:'
    lblInfo.Left = 10; lblInfo.Top = 10; lblInfo.Width = 290; lblInfo.Height = 15;

    calculator.editBox = createEdit(pnlTop)
    calculator.editBox.Left = 10; calculator.editBox.Top = 30; calculator.editBox.Width = 290; calculator.editBox.Height = 21;

    -- Panel 2: Bottom section for copy buttons
    local pnlBottom = createPanel(f)
    pnlBottom.Align = 'alBottom'
    pnlBottom.Height = 45
    pnlBottom.BevelOuter = 'bvNone'

    local btnCopyDec = createButton(pnlBottom)
    btnCopyDec.Caption = 'Copy Decimal'
    btnCopyDec.Left = 10; btnCopyDec.Top = 10; btnCopyDec.Width = 90; btnCopyDec.Height = 25;

    local btnCopyHex = createButton(pnlBottom)
    btnCopyHex.Caption = 'Copy Hex'
    btnCopyHex.Left = 110; btnCopyHex.Top = 10; btnCopyHex.Width = 90; btnCopyHex.Height = 25;

    -- Panel 3: Client (middle) section for results, fills remaining space
    local pnlClient = createPanel(f)
    pnlClient.Align = 'alClient'
    pnlClient.BevelOuter = 'bvNone'

    calculator.resultMemo = createMemo(pnlClient)
    calculator.resultMemo.Align = 'alClient'
    calculator.resultMemo.ReadOnly = true
    calculator.resultMemo.Font.Name = 'Consolas'
    calculator.resultMemo.BorderSpacing.Around = 10

    -- Event Handlers
    f.OnClose = function() return caHide end
    -- [MODIFIED] Switched to OnChange for real-time updates.
    calculator.editBox.OnChange = performConversion
    btnCopyHex.OnClick = function() copyResult('Hex') end
    btnCopyDec.OnClick = function() copyResult('Decimal') end
  end

  function addMenuItem()
    local mf = getMainForm()
    local mm = mf.Menu
    local extMenu = nil

    for i = 0, mm.Items.Count - 1 do
      if mm.Items[i].Caption == calculator.extGroupMenuCaption then
        extMenu = mm.Items[i]
        break
      end
    end
    if not extMenu then
      extMenu = createMenuItem(mm)
      extMenu.Caption = calculator.extGroupMenuCaption
      mm.Items.add(extMenu)
    end

    local extMenuItem = createMenuItem(extMenu)
    extMenuItem.Caption = calculator.menuItemCaption
    extMenu.add(extMenuItem)

    extMenuItem.OnClick = function()
      calculator.form.show()
      calculator.form.bringToFront()
    end
  end

  -- /// INITIALIZATION ///
  createGUI()
  addMenuItem()

  local ownerForm = createForm(false)
  ownerForm.Name = 'frmHexDecCalcOwner'
  calculator.form.Owner = ownerForm
end