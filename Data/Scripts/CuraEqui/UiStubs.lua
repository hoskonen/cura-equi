-- Scripts/CuraEqui/UiStubs.lua
local function U(fmt, ...) if CuraEqui.DEBUG then System.LogAlways(("[CuraEqui][UI] " .. fmt):format(...)) end end
function onOpened() U("ItemSelection onOpened") end

function onClosed() U("ItemSelection onClosed") end

function onFocusChanged(ids, isExpandable, isExpand, clientId) U("onFocusChanged ids=%s", tostring(ids)) end

function onDoubleClicked(ids, clientId) U("onDoubleClicked ids=%s", tostring(ids)) end
