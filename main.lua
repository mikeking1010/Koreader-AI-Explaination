local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local socket = require("socket")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Button = require("ui/widget/button")
local QRWidget = require("ui/widget/qrwidget")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Font = require("ui/font")
local Screen = require("device").screen

local Prompts = require("prompts")

local DEFAULT_MODEL = "gemini-3.1-flash-lite"

local Device = require("device")

local KEY_SERVER_PORT = 8848
local KEY_SERVER_TIMEOUT = 300

local AskGemini = WidgetContainer:extend{ name = "askgemini" }

function AskGemini:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/askgemini.lua")

    if self.ui and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("askgemini_button", function(this)
            return {
                text = _("✦ Explain with Gemini"),
                enabled = true,
                callback = function()
                    self:onAskGemini(this.selected_text and this.selected_text.text, Prompts.ASK_GEMINI_PROMPT, "✦ Explain with Gemini")
                end,
            }
        end)

        self.ui.highlight:addToHighlightDialog("factcheck_button", function(this)
            return {
                text = _("✦ Fact Checker"),
                enabled = true,
                callback = function()
                    self:onAskGemini(this.selected_text and this.selected_text.text, Prompts.FACT_CHECKER_PROMPT, "✦ Fact Checker")
                end,
            }
        end)

        self.ui.highlight:addToHighlightDialog("eli_button", function(this)
            return {
                text = _("✦ Explain Like I'm 5"),
                enabled = true,
                callback = function()
                    self:onAskGemini(this.selected_text and this.selected_text.text, Prompts.ELI5_PROMPT, "✦ Explain Like I'm 5")
                end,
            }
        end)
    end

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function AskGemini:addToMainMenu(menu_items)
    menu_items.askgemini = {
        text = _("Ask Gemini"),
        sub_item_table = {
            {
                text = _("Set API key via QR code (uses localhost)"),
                keep_menu_open = true,
                callback = function() self:startKeyServer() end,
            },
            {
                text_func = function()
                    local k = self.settings:readSetting("api_key")
                    return k and k ~= "" and _("Gemini API key (set)") or _("Gemini API key (not set)")
                end,
                keep_menu_open = true,
                callback = function() self:editApiKey() end,
            },
            {
                text_func = function()
                    return _("Model: ") .. (self.settings:readSetting("model") or DEFAULT_MODEL)
                end,
                keep_menu_open = true,
                callback = function() self:editModel() end,
            },
        },
    }
end

function AskGemini:editApiKey()
    local dialog
    dialog = InputDialog:new{
        title = _("Gemini API key"),
        input = self.settings:readSetting("api_key") or "",
        input_hint = _("Paste your API key"),
        text_type = "password",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local key = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                self.settings:saveSetting("api_key", key)
                self.settings:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AskGemini:editModel()
    local dialog
    dialog = InputDialog:new{
        title = _("Gemini model"),
        input = self.settings:readSetting("model") or DEFAULT_MODEL,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                self.settings:saveSetting("model", dialog:getInputText())
                self.settings:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ===== QR / local HTTP server key entry =====

local function getLocalIP()
    local ok, s = pcall(socket.udp)
    if not ok or not s then return nil end
    s:setpeername("8.8.8.8", 80) -- no packet actually sent, just picks the outbound iface
    local ip = s:getsockname()
    s:close()
    return ip
end

local function urldecode(s)
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

local FORM_HTML = [[<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Set Gemini key</title></head><body style="font-family:sans-serif;max-width:400px;margin:2em auto;padding:0 1em">
<h3>Set Gemini API key</h3>
<form method="POST" action="/save">
<input type="password" name="key" placeholder="Paste your Gemini API key" style="width:100%%;padding:.5em;font-size:1em" autofocus>
<button type="submit" style="margin-top:1em;padding:.5em 1em;font-size:1em">Save to Kindle</button>
</form></body></html>]]

local DONE_HTML = [[<!doctype html><html><body style="font-family:sans-serif;max-width:400px;margin:2em auto;padding:0 1em">
<h3>Saved</h3><p>You can close this tab and go back to your Kindle.</p></body></html>]]

function AskGemini:stopKeyServer(message)
    if self.key_server_task then
        UIManager:unschedule(self.key_server_task)
        self.key_server_task = nil
    end
    if self.key_server_sock then
        self.key_server_sock:close()
        self.key_server_sock = nil
    end
    if self.key_qr_dialog then
        UIManager:close(self.key_qr_dialog)
        self.key_qr_dialog = nil
    end
    if message then
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    end
end

local function buildQRSetupWidget(url, on_cancel)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local content_w = math.floor(screen_w * 0.9)
    local qr_size = math.floor(math.min(screen_w, screen_h) * 0.8)

    local link_text = TextBoxWidget:new{
        text = url,
        face = Font:getFace("cfont", 20),
        width = content_w,
        alignment = "center",
    }

    local qr = QRWidget:new{
        text = url,
        width = qr_size,
        height = qr_size,
    }

    local cancel_button = Button:new{
        text = _("Cancel"),
        width = math.floor(content_w * 0.5),
        callback = on_cancel,
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        VerticalGroup:new{
            align = "center",
            link_text,
            VerticalSpan:new{ width = Size.padding.large },
            qr,
            VerticalSpan:new{ width = Size.padding.large },
            cancel_button,
        },
    }

    local widget = InputContainer:new{}
    widget[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        MovableContainer:new{ frame },
    }
    return widget
end

local function allowPortThroughFirewall(port)
    if Device:isKindle() then
        pcall(os.execute, string.format(
            "iptables -A INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    end
end

function AskGemini:startKeyServer()
    local ip = getLocalIP()
    if not ip then
        UIManager:show(InfoMessage:new{ text = _("Could not detect local IP — make sure Wi-Fi is on."), timeout = 3 })
        return
    end

    -- Always close any previous server before starting a new one
    if self.key_server_sock then
        self.key_server_sock:close()
        self.key_server_sock = nil
    end
    if self.key_server_task then
        UIManager:unschedule(self.key_server_task)
        self.key_server_task = nil
    end

    allowPortThroughFirewall(KEY_SERVER_PORT)

    local server = socket.tcp()
    server:setoption("reuseaddr", true)
    server:settimeout(0)
    local bind_ok, bind_err = server:bind("0.0.0.0", KEY_SERVER_PORT)
    if not bind_ok then
        UIManager:show(InfoMessage:new{ text = _("Could not start server: ") .. tostring(bind_err), timeout = 3 })
        return
    end
    server:listen(1)
    self.key_server_sock = server

    -- (rest of the function unchanged from before)

    local url = string.format("http://%s:%d/", ip, KEY_SERVER_PORT)

    local QRMessage = require("ui/widget/qrmessage")
    self.key_qr_dialog = QRMessage:new{
        text = url,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(self.key_qr_dialog)
    UIManager:forceRePaint()

    local function poll()
        local client = self.key_server_sock and self.key_server_sock:accept()
        if client then
            client:settimeout(2)
            local request_line = client:receive("*l") or ""
            local content_length = 0
            while true do
                local line = client:receive("*l")
                if not line or line == "" then break end
                local len = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
                if len then content_length = tonumber(len) end
            end

            if request_line:match("^GET / ") then
                local body = FORM_HTML
                client:send("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
                    .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
                client:close()
            elseif request_line:match("^POST /save ") then
                local body = content_length > 0 and client:receive(content_length) or ""
                client:send("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
                    .. #DONE_HTML .. "\r\nConnection: close\r\n\r\n" .. DONE_HTML)
                client:close()

                local key = body:match("key=([^&]*)")
                key = key and urldecode(key) or ""
                key = key:gsub("^%s+", ""):gsub("%s+$", "")  -- trim
                if key ~= "" then
                    self.settings:saveSetting("api_key", key)
                    self.settings:flush()
                    self:stopKeyServer(_("Gemini API key saved."))
                    return
                end
            else
                client:close()
            end
        end

        self.key_server_task = function() poll() end
        UIManager:scheduleIn(0.5, self.key_server_task)
    end

    self.key_server_task = function() poll() end
    UIManager:scheduleIn(0.5, self.key_server_task)
end

-- Retrieves the document title and chapter title from Koreader
function AskGemini:getContext()
    local title = "Unknown title"
    if self.ui and self.ui.document and self.ui.document.getProps then
        local ok, props = pcall(function() return self.ui.document:getProps() end)
        if ok and props and props.title and props.title ~= "" then title = props.title end
    end
    local chapter
    if self.ui and self.ui.toc and self.view then
        local ok, t = pcall(function()
            return self.ui.toc:getTocTitleByPage(self.view.state.page)
        end)
        if ok and t and t ~= "" then chapter = t end
    end
    return title, chapter
end

function AskGemini:onAskGemini(highlighted_text, prompt, operation)
    if not highlighted_text or highlighted_text == "" then return end

    local api_key = self.settings:readSetting("api_key")
    if not api_key or api_key == "" then
        UIManager:show(InfoMessage:new{ text = _("Set a Gemini API key first (menu → Ask Gemini).") })
        return
    end
    local model = self.settings:readSetting("model") or DEFAULT_MODEL

    local title, chapter = self:getContext()
    local context_str = "Book: " .. title .. (chapter and (" | Chapter: " .. chapter) or "")
    local prompt = string.format(
        [[Context: %s\n\nHighlighted passage:\n\"%s\"\n\n
        
        %s

        ]],
        context_str, highlighted_text, prompt)

    local loading = InfoMessage:new{ text = _("Asking Gemini…") }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local body = json.encode({ contents = {{ parts = {{ text = prompt }} }} })
    local response = {}
    local url = ("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s")
        :format(model, api_key)

    local ok, code = https.request{
        url = url,
        method = "POST",
        headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body) },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }

    UIManager:close(loading)

    local answer
    if ok and code == 200 then
        local raw = table.concat(response)
        local dok, data = pcall(json.decode, raw)
        local part = dok and data.candidates and data.candidates[1]
            and data.candidates[1].content and data.candidates[1].content.parts
            and data.candidates[1].content.parts[1]
        answer = part and part.text or _("Could not parse Gemini's response.")
        if not part then logger.warn("AskGemini parse fail:", raw) end
    else
        local raw = table.concat(response)
        local dok, data = pcall(json.decode, raw)
        local msg = dok and data.error and data.error.message
        answer = _("Error contacting Gemini: ") .. tostring(code) .. (msg and (" — " .. msg) or "")
        logger.warn("AskGemini request fail:", code, raw)
    end

    UIManager:show(InfoMessage:new{ text = answer, show_icon = false })
end

return AskGemini