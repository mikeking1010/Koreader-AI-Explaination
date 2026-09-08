local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")

local DEFAULT_MODEL = "gemini-3.1-flash-lite"
local TEMP_API_KEY = "YOUR_API_KEY_HERE"

local AskGemini = WidgetContainer:extend{ name = "askgemini" }

function AskGemini:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/askgemini.lua")
    self.settings:saveSetting("api_key", TEMP_API_KEY)

    if self.ui and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("askgemini_button", function(this)
            return {
                text = _("Ask Gemini"),
                enabled = true,
                callback = function()
                    self:onAskGemini(this.selected_text and this.selected_text.text)
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
                self.settings:saveSetting("api_key", dialog:getInputText())
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

function AskGemini:onAskGemini(highlighted_text)
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
        
        Your job is to be a helper for a person reading a book or document on their Kindle.

        Explain this highlighted passage to the user, prioritising the meaning of the highlighted text in your response.
        
        Do not use more than 100 words in your response.

        Keep the response short and concise, with minimal use of multiple paragraphs.

        ]],
        context_str, highlighted_text)

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
        answer = _("Error contacting Gemini: ") .. tostring(code)
        logger.warn("AskGemini request fail:", code, table.concat(response))
    end

    UIManager:show(InfoMessage:new{ text = answer, show_icon = false })
end

return AskGemini