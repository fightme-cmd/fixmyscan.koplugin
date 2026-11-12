--[[--
FixMyScan for KOReader: turn a scanned PDF or DjVu into a clean, searchable PDF.

Tools > FixMyScan > Connect pairs the device with a FixMyScan account (QR code
or a short code, no typing a key). "Fix with FixMyScan" then uploads the open
book, or a book long-pressed in the file browser, and saves
"<name> (fixed).pdf" next to it.

@module koplugin.FixMyScan
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

-- Load our api.lua by path: a bare require("api") could pick up another plugin's module.
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local Api = dofile(plugin_dir .. "/api.lua")

local SUPPORTED = { pdf = true, djvu = true }
local BOOK_POLL_SECONDS = 5
local NETWORK_RETRIES = 8
local NETWORK_RETRY_SECONDS = 15
local PENDING_MAX_AGE = 23 * 3600 -- files are deleted after 24 hours

---------------------------------------------------------------- settings
-- One settings file shared by the reader and file browser instances.

local settings
local function getSettings()
    if not settings then
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/fixmyscan.lua")
    end
    return settings
end

local function newApi(with_key)
    local s = getSettings()
    return Api.new{
        base_url = s:readSetting("base_url"), -- override for tests
        api_key = with_key and s:readSetting("api_key") or nil,
    }
end

local function isConnected()
    return getSettings():readSetting("api_key") ~= nil
end

local function fileName(path)
    return path:match("([^/]+)$") or path
end

local function isSupported(path)
    local ext = path and path:match("%.([^./]+)$")
    if ext == nil or SUPPORTED[ext:lower()] ~= true then return false end
    -- A copy this plugin already saved ("name (fixed).pdf", "name (fixed 2).pdf") is not offered again.
    return not fileName(path):lower():match("%(fixed[%d ]*%)%.pdf$")
end

local function displayUrl(url)
    return (url:gsub("^https?://", ""):gsub("[?#].*$", ""):gsub("/$", ""))
end

local function setPending(path, book_id)
    local s = getSettings()
    local pending = s:readSetting("pending") or {}
    pending[path] = book_id and { id = book_id, at = os.time() } or nil
    s:saveSetting("pending", pending)
    s:flush()
end

local function getPending(path)
    local pending = getSettings():readSetting("pending") or {}
    local p = pending[path]
    if p and os.time() - (p.at or 0) < PENDING_MAX_AGE then
        return p.id
    end
    return nil
end

---------------------------------------------------------------- widgets

-- A QR code, the code in big type, one line of help and Cancel.
local PairDialog = InputContainer:extend{
    url = nil,
    code = nil,
    cancel_callback = nil,
}

function PairDialog:init()
    local short = math.min(Screen:getWidth(), Screen:getHeight())
    local width = math.floor(short * 0.85)
    local inner = width - 2 * Size.padding.large
    local group = VerticalGroup:new{ align = "center" }

    local ok_qr, QRWidget = pcall(require, "ui/widget/qrwidget")
    if ok_qr then
        local qr_size = math.floor(short * 0.5)
        local ok, qr = pcall(QRWidget.new, QRWidget, { text = self.url, width = qr_size, height = qr_size })
        if ok and qr then
            table.insert(group, qr)
            table.insert(group, VerticalSpan:new{ width = Size.padding.large })
        end
    end
    table.insert(group, TextWidget:new{
        text = self.code,
        face = Font:getFace("tfont", 40),
        bold = true,
    })
    table.insert(group, VerticalSpan:new{ width = Size.padding.large })
    table.insert(group, TextBoxWidget:new{
        -- The address gets its own line, so it never wraps at the slash.
        text = T(_("Scan this, or go to\n%1\nand enter %2"), displayUrl(self.url), self.code),
        face = Font:getFace("cfont", 20),
        width = inner,
        alignment = "center",
    })
    table.insert(group, VerticalSpan:new{ width = Size.padding.large })
    table.insert(group, ButtonTable:new{
        width = inner,
        buttons = { { { text = _("Cancel"), callback = function() self:onClose() end } } },
        zero_sep = true,
        show_parent = self,
    })

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        self.frame,
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function PairDialog:onShow()
    UIManager:setDirty(self, function() return "flashui", self.frame.dimen end)
    return true
end

function PairDialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

function PairDialog:onClose()
    UIManager:close(self)
    if self.cancel_callback then self.cancel_callback() end
    return true
end

local function showLink(text, url)
    local dialog
    local buttons = { {
        { text = _("Close"), callback = function() UIManager:close(dialog) end },
    } }
    if url and pcall(require, "ui/widget/qrmessage") then
        table.insert(buttons[1], 1, {
            text = _("Show QR code"),
            callback = function()
                UIManager:close(dialog)
                local QRMessage = require("ui/widget/qrmessage")
                UIManager:show(QRMessage:new{ text = url, width = Screen:getWidth(), height = Screen:getHeight() })
            end,
        })
    end
    dialog = ButtonDialog:new{
        title = url and (text .. "\n\n" .. url) or text,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

---------------------------------------------------------------- pairing

local pairing -- the one pairing in progress, if any

local function stopPairing()
    if pairing then
        if pairing.task then UIManager:unschedule(pairing.task) end
        if pairing.dialog then UIManager:close(pairing.dialog) end
        pairing = nil
    end
end

local function connect(on_connected)
    stopPairing()
    NetworkMgr:runWhenOnline(function()
        local api = newApi(false)
        local res, err = api:pairStart(Device.model)
        if not res then
            UIManager:show(InfoMessage:new{ text = err.message })
            return
        end
        local current = { deadline = os.time() + res.expires_in }
        pairing = current
        current.dialog = PairDialog:new{
            url = res.url,
            code = res.code,
            cancel_callback = function()
                current.dialog = nil
                if pairing == current then stopPairing() end
            end,
        }
        UIManager:show(current.dialog)

        local network_failures = 0
        current.task = function()
            if pairing ~= current then return end
            if os.time() > current.deadline then
                stopPairing()
                UIManager:show(InfoMessage:new{ text = _("The code expired. Try Connect again.") })
                return
            end
            local poll, perr = api:pairPoll(res.pair_id)
            if pairing ~= current then return end
            if not poll then
                if perr.code == "network" then
                    network_failures = network_failures + 1
                    if network_failures > NETWORK_RETRIES then
                        stopPairing()
                        UIManager:show(InfoMessage:new{ text = perr.message })
                        return
                    end
                elseif not perr.retry_after then
                    stopPairing()
                    UIManager:show(InfoMessage:new{ text = perr.message })
                    return
                end
                UIManager:scheduleIn(perr.retry_after or res.interval, current.task)
                return
            end
            network_failures = 0
            if poll.state == "approved" then
                stopPairing()
                local s = getSettings()
                s:saveSetting("api_key", poll.api_key)
                s:saveSetting("account_email", poll.account_email)
                s:flush()
                UIManager:show(InfoMessage:new{
                    text = poll.account_email and T(_("Connected as %1."), poll.account_email) or _("Connected."),
                    timeout = 3,
                })
                if on_connected then UIManager:scheduleIn(3, on_connected) end
            elseif poll.state == "pending" then
                UIManager:scheduleIn(res.interval, current.task)
            else
                stopPairing()
                UIManager:show(InfoMessage:new{ text = _("The code expired. Try Connect again.") })
            end
        end
        UIManager:scheduleIn(res.interval, current.task)
    end)
end

local function disconnect()
    local s = getSettings()
    local email = s:readSetting("account_email")
    UIManager:show(ConfirmBox:new{
        text = email and T(_("Disconnect %1 from this device?"), email) or _("Disconnect from this device?"),
        ok_text = _("Disconnect"),
        ok_callback = function()
            s:delSetting("api_key")
            s:delSetting("account_email")
            s:flush()
            UIManager:show(InfoMessage:new{ text = _("Disconnected. Connect again any time."), timeout = 3 })
        end,
    })
end

---------------------------------------------------------------- fixing a book

local jobs = {} -- path -> job, so a book is never fixed twice at once

local function openBook(path)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(path)
    else
        ReaderUI:showReader(path)
    end
end

local function refreshFileBrowser()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance and FileManager.instance.file_chooser then
        FileManager.instance.file_chooser:refreshPath()
    end
end

local Job = {}
Job.__index = Job

function Job:closeStatus()
    if self.status then
        UIManager:close(self.status)
        self.status = nil
    end
end

-- The progress dialog: the API's own message, with Stop and Keep reading.
function Job:showStatus(message)
    if self.hidden or self.finished then return end
    if self.status and self.status_text == message then return end
    self:closeStatus()
    self.status_text = message
    self.status = ButtonDialog:new{
        title = T(_("%1\n\n%2"), fileName(self.path), message),
        title_align = "center",
        dismissable = false,
        buttons = { {
            { text = _("Stop"), callback = function() self:askStop() end },
            { text = _("Keep reading"), callback = function()
                self.hidden = true
                self:closeStatus()
                UIManager:show(InfoMessage:new{ text = _("Still fixing. You'll see a message when it's ready."), timeout = 3 })
            end },
        } },
    }
    UIManager:show(self.status)
end

function Job:askStop()
    UIManager:show(ConfirmBox:new{
        text = _("Stop fixing this book?"),
        ok_text = _("Stop"),
        cancel_text = _("Keep going"),
        ok_callback = function()
            self:finish()
            if self.book_id then
                newApi(true):cancelBook(self.book_id)
            end
            setPending(self.path, nil)
            UIManager:show(InfoMessage:new{ text = _("Stopped. The original book is unchanged."), timeout = 3 })
        end,
    })
end

function Job:finish()
    self.finished = true
    if self.task then UIManager:unschedule(self.task) end
    self:closeStatus()
    jobs[self.path] = nil
end

function Job:fail(err)
    self:finish()
    if err.status == 401 then
        local s = getSettings()
        s:delSetting("api_key")
        s:delSetting("account_email")
        s:flush()
        setPending(self.path, nil)
        UIManager:show(ConfirmBox:new{
            text = err.message,
            ok_text = _("Connect"),
            ok_callback = function() connect() end,
        })
    elseif err.upgrade_url then
        setPending(self.path, nil)
        showLink(err.message, err.upgrade_url)
    else
        UIManager:show(InfoMessage:new{ text = err.message })
    end
end

function Job:schedule(seconds)
    if self.finished then return end
    UIManager:scheduleIn(seconds, self.task)
end

-- Handles an error mid-way: wait on 429 and short network drops, else stop.
function Job:retryOrFail(err)
    if err.retry_after then
        self:schedule(err.retry_after)
        return
    end
    if err.code == "network" and self.book_id then
        self.network_failures = (self.network_failures or 0) + 1
        if self.network_failures <= NETWORK_RETRIES then
            self:schedule(NETWORK_RETRY_SECONDS)
            return
        end
        self:finish()
        UIManager:show(InfoMessage:new{
            text = _("Lost the connection. Choose Fix with FixMyScan again to pick up where it left off."),
        })
        return
    end
    self:fail(err)
end

function Job:upload()
    local name = fileName(self.path)
    local size = Api.fileSize(self.path)
    if not size or size == 0 then
        return self:fail({ message = _("Could not read the book file.") })
    end
    local info = InfoMessage:new{ text = T(_("Uploading %1…"), name) }
    UIManager:show(info)
    UIManager:forceRePaint()
    local api = newApi(true)
    local up, err = api:createUpload(name, size)
    if up then
        local ok
        ok, err = api:putFile(up.upload, self.path)
        if ok then
            local book
            book, err = api:startBook(up.upload_id, up.upload_id)
            if book then
                UIManager:close(info)
                self.book_id = book.id
                setPending(self.path, book.id)
                return self:onBook(book)
            end
        end
    end
    UIManager:close(info)
    if err.retry_after then
        -- Rate limited before anything started: try the whole upload again later.
        self.task = function() self:upload() end
        return self:schedule(err.retry_after)
    end
    self:fail(err)
end

function Job:poll()
    local book, err = newApi(true):getBook(self.book_id)
    if self.finished then return end
    if not book then
        if err.status == 404 then
            -- Expired or deleted on the server: start over with a fresh upload.
            setPending(self.path, nil)
            self.book_id = nil
            self.task = function() self:upload() end
            return self:schedule(0)
        end
        return self:retryOrFail(err)
    end
    self.network_failures = 0
    self:onBook(book)
end

function Job:onBook(book)
    local state = Api.str(book.state) or "processing"
    local message = Api.str(book.message) or _("Working on it…")
    if state == "ready" then
        return self:download(book)
    elseif state == "refused" then
        self:finish()
        setPending(self.path, nil)
        if Api.str(book.upgrade_url) then
            showLink(message, book.upgrade_url)
        else
            UIManager:show(InfoMessage:new{ text = message })
        end
        return
    elseif Api.isFinished(state) then -- failed, cancelled, expired
        self:finish()
        setPending(self.path, nil)
        UIManager:show(InfoMessage:new{ text = message })
        return
    end
    self:showStatus(message)
    self.task = function() self:poll() end
    self:schedule(BOOK_POLL_SECONDS)
end

function Job:download(book)
    local url = Api.str(book.download_url)
    if not url then
        -- Ready but the link is not there yet: ask again shortly.
        self.task = function() self:poll() end
        return self:schedule(BOOK_POLL_SECONDS)
    end
    self:closeStatus()
    local info = InfoMessage:new{ text = T(_("Downloading %1…"), fileName(self.path)) }
    UIManager:show(info)
    UIManager:forceRePaint()
    local dest = Api.fixedPath(self.path)
    local saved, err = newApi(false):download(url, dest)
    UIManager:close(info)
    if not saved then
        if err.code == "network" or (err.status and err.status >= 400) then
            -- The link may have lapsed (it lasts an hour); get a fresh one and retry.
            self.network_failures = (self.network_failures or 0) + 1
            if self.network_failures <= NETWORK_RETRIES then
                self.task = function() self:poll() end
                return self:schedule(NETWORK_RETRY_SECONDS)
            end
        end
        return self:fail(err)
    end
    self:finish()
    setPending(self.path, nil)
    refreshFileBrowser()
    UIManager:show(ConfirmBox:new{
        text = T(_("Saved as %1"), fileName(saved)),
        ok_text = _("Open it"),
        cancel_text = _("Not now"),
        ok_callback = function() openBook(saved) end,
    })
end

local function fixFile(path)
    if not isSupported(path) then
        UIManager:show(InfoMessage:new{ text = _("FixMyScan works on PDF and DjVu files.") })
        return
    end
    local running = jobs[path]
    if running then
        running.hidden = false
        running.status_text = nil
        running:showStatus(_("Still fixing…"))
        return
    end
    if not isConnected() then
        connect(function() fixFile(path) end)
        return
    end
    NetworkMgr:runWhenOnline(function()
        if jobs[path] then return end
        local job = setmetatable({ path = path }, Job)
        jobs[path] = job
        local book_id = getPending(path)
        if book_id then
            job.book_id = book_id
            job:showStatus(_("Picking up where it left off…"))
            job.task = function() job:poll() end
            job:schedule(0)
        else
            job:upload()
        end
    end)
end

---------------------------------------------------------------- plugin

local FixMyScan = WidgetContainer:extend{
    name = "fixmyscan",
    is_doc_only = false,
}

function FixMyScan:init()
    self.ui.menu:registerToMainMenu(self)
    self:addFileDialogButton()
end

-- Long-press a PDF or DjVu in the file browser: "Fix with FixMyScan".
function FixMyScan:addFileDialogButton()
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager.addFileDialogButtons then return end -- older KOReader
    FileManager.addFileDialogButtons(FileManager, "fixmyscan", function(file, is_file)
        if not (is_file and isSupported(file)) then return nil end
        return { {
            text = _("Fix with FixMyScan"),
            callback = function()
                local fm = FileManager.instance
                local dialog = fm and fm.file_chooser and fm.file_chooser.file_dialog
                if dialog then UIManager:close(dialog) end
                fixFile(file)
            end,
        } }
    end)
end

function FixMyScan:currentFile()
    return self.ui.document and self.ui.document.file
end

function FixMyScan:addToMainMenu(menu_items)
    menu_items.fixmyscan = {
        text = _("FixMyScan"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local items = {}
            local file = self:currentFile()
            if file and isSupported(file) then
                table.insert(items, {
                    text = _("Fix with FixMyScan"),
                    keep_menu_open = false,
                    callback = function() fixFile(file) end,
                    separator = true,
                })
            end
            if isConnected() then
                local email = getSettings():readSetting("account_email")
                table.insert(items, {
                    text = email and T(_("Disconnect %1"), email) or _("Disconnect"),
                    callback = function() disconnect() end,
                })
            else
                table.insert(items, {
                    text = _("Connect"),
                    callback = function() connect() end,
                })
            end
            return items
        end,
    }
end

-- Exposed for tests and for other plugins.
FixMyScan.fixFile = fixFile
FixMyScan.connect = connect

logger.dbg("FixMyScan: plugin loaded")

return FixMyScan
