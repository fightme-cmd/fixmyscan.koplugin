--[[--
FixMyScan HTTP client: pairing, uploads, books, downloads.

No UI in here, so it can be tested with a plain Lua interpreter.
Every call returns `result` on success, or `nil, err` where `err` is a table:
  { status = <HTTP status or nil>, code = "...", message = "...",
    upgrade_url = "...", retry_after = <seconds> }
]]

local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
local JSON = require("json")

-- socketutil is KOReader's; outside KOReader we fall back to LuaSocket defaults.
local ok_su, socketutil = pcall(require, "socketutil")
if not ok_su then socketutil = nil end

local Api = {
    DEFAULT_BASE_URL = "https://api.fixmyscan.com/v1",
    -- Short calls (JSON), and file transfers (block timeout only; total unlimited).
    JSON_TIMEOUT = { 20, 60 },
    FILE_TIMEOUT = { 60, -1 },
}
Api.__index = Api

function Api.new(o)
    o = o or {}
    local self = setmetatable({}, Api)
    self.base_url = (o.base_url or Api.DEFAULT_BASE_URL):gsub("/+$", "")
    self.api_key = o.api_key
    self.user_agent = o.user_agent
    return self
end

-- JSON null (luajson gives a function, rapidjson a userdata) and other non-strings become nil.
local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end
local function num(v)
    if type(v) == "number" then return v end
    return nil
end
Api.str, Api.num = str, num

local function requester(url)
    if url:match("^https://") then
        return require("ssl.https")
    end
    return http
end

local function setTimeout(t)
    if socketutil then
        socketutil:set_timeout(t[1], t[2])
    else
        http.TIMEOUT = t[1]
    end
end

local function resetTimeout()
    if socketutil then socketutil:reset_timeout() end
end

local function header(headers, name)
    if not headers then return nil end
    name = name:lower()
    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == name then return v end
    end
    return nil
end

local function networkError(e)
    local message = "Could not reach FixMyScan. Check the Wi-Fi and try again."
    if e == "timeout" or e == "wantread" or e == "wantwrite" or e == "sink timeout" then
        message = "FixMyScan took too long to answer. Try again."
    end
    return { code = "network", message = message, detail = tostring(e) }
end

-- Turns a non-2xx answer into an err table, using the API's {"error": {...}} body.
local function httpError(status, body, headers)
    local err = { status = status }
    local e = type(body) == "table" and type(body.error) == "table" and body.error or {}
    err.code = str(e.code) or ("http_" .. tostring(status))
    err.message = str(e.message)
    err.upgrade_url = str(e.upgrade_url) or (type(body) == "table" and str(body.upgrade_url)) or nil
    if status == 429 then
        err.retry_after = tonumber(header(headers, "retry-after") or "") or 10
        err.message = err.message or "FixMyScan is busy. Trying again shortly."
    elseif status == 401 then
        err.message = "This device is no longer connected. Connect it again."
    elseif status == 402 then
        err.message = err.message or "No pages left on your plan."
    elseif status and status >= 500 then
        err.message = err.message or "FixMyScan had a problem. Try again in a few minutes."
    end
    err.message = err.message or "Something went wrong. Try again."
    return err
end

--- Low-level JSON request. `path` is relative to base_url, or a full URL.
-- Returns status, decoded body (table or nil), headers; or nil, err.
function Api:request(method, path, body, extra_headers)
    local url = path:match("^https?://") and path or (self.base_url .. path)
    local sink = {}
    local headers = { ["Accept"] = "application/json" }
    if self.user_agent then headers["User-Agent"] = self.user_agent end
    if self.api_key then headers["Authorization"] = "Bearer " .. self.api_key end
    for k, v in pairs(extra_headers or {}) do headers[k] = v end
    local source
    if body ~= nil then
        local payload = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    elseif method == "POST" or method == "PUT" then
        headers["Content-Length"] = "0"
    end
    setTimeout(Api.JSON_TIMEOUT)
    local code, resp_headers = socket.skip(1, requester(url).request{
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = socketutil and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    })
    resetTimeout()
    if type(code) ~= "number" then
        return nil, networkError(code)
    end
    local raw = table.concat(sink)
    local decoded
    if raw ~= "" then
        local ok, res = pcall(JSON.decode, raw)
        if ok and type(res) == "table" then decoded = res end
    end
    return code, decoded, resp_headers
end

-- request() that treats anything but 2xx as an error.
function Api:call(method, path, body, extra_headers)
    local status, decoded, headers = self:request(method, path, body, extra_headers)
    if not status then return nil, decoded end
    if status >= 200 and status < 300 then
        if not decoded then
            return nil, { status = status, code = "bad_response",
                message = "FixMyScan sent an answer this plugin cannot read. Try again." }
        end
        return decoded, nil, headers
    end
    return nil, httpError(status, decoded, headers)
end

---------------------------------------------------------------- pairing

--- POST /pair/start -> {pair_id, code, url, interval, expires_in}
function Api:pairStart(device)
    local res, err = self:call("POST", "/pair/start", { client = "koreader", device = device or "KOReader" })
    if not res then return nil, err end
    if not (str(res.pair_id) and str(res.code) and str(res.url)) then
        return nil, { code = "bad_response", message = "FixMyScan sent an answer this plugin cannot read. Try again." }
    end
    res.interval = num(res.interval) or 5
    res.expires_in = num(res.expires_in) or 600
    return res
end

--- POST /pair/poll -> {state="pending"} | {state="approved", api_key, account_email} | {state="expired"} (410)
function Api:pairPoll(pair_id)
    local status, decoded, headers = self:request("POST", "/pair/poll", { pair_id = pair_id })
    if not status then return nil, decoded end
    if status == 410 or status == 404 then
        return { state = "expired" }
    end
    if status < 200 or status >= 300 then
        return nil, httpError(status, decoded, headers)
    end
    decoded = decoded or {}
    local state = str(decoded.state)
    if state == "approved" then
        if not str(decoded.api_key) then
            return nil, { code = "bad_response", message = "FixMyScan sent an answer this plugin cannot read. Try again." }
        end
        return { state = "approved", api_key = decoded.api_key, account_email = str(decoded.account_email) }
    elseif state == "expired" or state == "denied" then
        return { state = state }
    end
    return { state = "pending" }
end

---------------------------------------------------------------- books

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end
Api.fileSize = fileSize

--- POST /uploads {filename, size} -> {upload_id, upload={method,url,headers,expires_at}}
function Api:createUpload(filename, size)
    local res, err = self:call("POST", "/uploads", { filename = filename, size = size })
    if not res then return nil, err end
    if not (str(res.upload_id) and type(res.upload) == "table" and str(res.upload.url)) then
        return nil, { code = "bad_response", message = "FixMyScan sent an answer this plugin cannot read. Try again." }
    end
    return res
end

--- PUT the file's bytes to the presigned URL, streamed from disk.
-- `progress(bytes_sent)` is optional.
function Api:putFile(upload, path, progress)
    local size = fileSize(path)
    local f = size and io.open(path, "rb")
    if not f then
        return nil, { code = "file", message = "Could not read the book file." }
    end
    local headers = {}
    if type(upload.headers) == "table" then
        for k, v in pairs(upload.headers) do
            if type(v) == "string" then headers[k] = v end
        end
    end
    headers["Content-Length"] = tostring(size)
    local source = ltn12.source.file(f)
    if progress then
        local sent = 0
        source = ltn12.source.chain(source, function(chunk)
            if chunk and #chunk > 0 then
                sent = sent + #chunk
                progress(sent, size)
            end
            return chunk
        end)
    end
    local sink = {}
    setTimeout(Api.FILE_TIMEOUT)
    local url = upload.url
    local code, resp_headers = socket.skip(1, requester(url).request{
        url = url,
        method = str(upload.method) or "PUT",
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    })
    resetTimeout()
    if type(code) ~= "number" then
        return nil, networkError(code)
    end
    if code < 200 or code >= 300 then
        return nil, { status = code, code = "upload_failed", message = "The upload did not go through. Try again." }
    end
    return true
end

--- POST /books {upload_id} -> Book
function Api:startBook(upload_id, idempotency_key)
    return self:call("POST", "/books", { upload_id = upload_id },
        idempotency_key and { ["Idempotency-Key"] = idempotency_key } or nil)
end

--- GET /books/{id} -> Book
function Api:getBook(book_id)
    return self:call("GET", "/books/" .. book_id)
end

--- POST /books/{id}/cancel -> Done
function Api:cancelBook(book_id)
    return self:call("POST", "/books/" .. book_id .. "/cancel")
end

--- GET a presigned download URL into `dest`, via `dest .. ".part"` so a broken
-- download never leaves a half file under the final name.
function Api:download(url, dest)
    local part = dest .. ".part"
    local f = io.open(part, "wb")
    if not f then
        return nil, { code = "file", message = "Could not save next to the book. Is the folder read-only?" }
    end
    setTimeout(Api.FILE_TIMEOUT)
    local code = socket.skip(1, requester(url).request{
        url = url,
        method = "GET",
        sink = socketutil and socketutil.file_sink(f) or ltn12.sink.file(f),
    })
    resetTimeout()
    if type(code) ~= "number" or code < 200 or code >= 300 then
        os.remove(part)
        if type(code) ~= "number" then return nil, networkError(code) end
        return nil, { status = code, code = "download_failed", message = "The download did not finish. Try again." }
    end
    os.remove(dest)
    local ok, e = os.rename(part, dest)
    if not ok then
        os.remove(part)
        return nil, { code = "file", message = "Could not save the fixed book: " .. tostring(e) }
    end
    return dest
end

---------------------------------------------------------------- helpers

local TERMINAL = { ready = true, failed = true, refused = true, cancelled = true, expired = true }
function Api.isFinished(state)
    return TERMINAL[state] == true
end

--- "/books/Old book.djvu" -> "/books/Old book (fixed).pdf"; numbered if taken.
function Api.fixedPath(path, exists)
    exists = exists or function(p)
        local f = io.open(p, "rb")
        if f then f:close() return true end
        return false
    end
    local base = path:gsub("%.[^./]+$", "")
    local candidate = base .. " (fixed).pdf"
    local n = 2
    while exists(candidate) do
        candidate = string.format("%s (fixed %d).pdf", base, n)
        n = n + 1
    end
    return candidate
end

return Api
