-- WebDAV transport matching the KOReader socket.http / socketutil integration.
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local core = require("core")
local M = {}

local function valid_url(u)
    return type(u)=="string" and #u<1500 and u:match("^https://[^/%s?]+[%w%p]*$")
        and not u:find("[\r\n]") and not u:find("#",1,true)
end
function M.join(base, name)
    if not valid_url(base) then return nil,"WebDAV URL must be HTTPS" end
    if type(name)~="string" or name:find("[/\\%c]") or #name>240 then return nil,"unsafe filename" end
    return base:gsub("/+$","").."/"..util.urlEncode(name)
end
local function request(cfg, method, url, body, more_headers, max_bytes)
    if not valid_url(url) then return nil,nil,"URL must use HTTPS" end
    local buf, bytes = {}, 0
    local function sink(chunk)
        if chunk then
            bytes=bytes+#chunk
            if bytes > (max_bytes or 1024*1024) then return nil,"response too large" end
            buf[#buf+1]=chunk
        end
        return 1
    end
    local headers=more_headers or {}
    if body~=nil then
        headers["Content-Length"]=tostring(#body)
        headers["Content-Type"]=headers["Content-Type"] or "application/octet-stream"
    end
    local opts={ url=url, method=method, headers=headers,
        user=cfg.user or "", password=cfg.password or "",
        sink=sink }
    if body~=nil then opts.source=ltn12.source.string(body) end
    socketutil:set_timeout(3,12)
    local ok, a,b,c=pcall(function()return socket.skip(1,http.request(opts)) end)
    socketutil:reset_timeout()
    if not ok then return nil,nil,tostring(a) end
    local code=tonumber(a)
    if not code then return nil,nil,tostring(c or a) end
    return {code=code, headers=b or {}, body=table.concat(buf)},nil,nil
end
function M.list(cfg)
    local url=cfg.url
    if not valid_url(url) then return nil,"Set a HTTPS WebDAV directory URL" end
    if url:sub(-1)~="/" then url=url.."/" end
    local body=[[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>]]
    local r,_,err=request(cfg,"PROPFIND",url,body,{["Depth"]="1",["Content-Type"]="application/xml"},1024*1024)
    if not r then return nil,err end
    if r.code~=207 then return nil,"PROPFIND returned HTTP "..r.code end
    local items,why=core.xml_items(r.body)
    if not items then return nil,why end
    local out={}
    for _,x in ipairs(items) do
        -- The last href segment is percent-encoded by WebDAV servers.
        local name=(x.href:gsub("/+$","")):match("([^/]+)$")
        if name then
            name=util.urlDecode(name)
            local valid=core.sync_filename(name)
            if valid and (not x.size or x.size<=256) then
                out[#out+1]={name=name,etag=x.etag}
            end
        end
    end
    return out
end
function M.get(cfg, name)
    local url,why=M.join(cfg.url,name)
    if not url then return nil,why end
    local r,_,err=request(cfg,"GET",url,nil,nil,256)
    if not r then return nil,err end
    if r.code~=200 then return nil,"GET returned HTTP "..r.code end
    local parsed,why=core.parse(r.body)
    if not parsed then return nil,why end
    return {name=name,body=r.body,etag=r.headers.etag or r.headers.ETag,remote=true},nil
end
function M.put_existing(cfg,name,body,etag)
    if not etag or etag=="" or etag:sub(1,2)=="W/" then
        return nil,"Remote ETag missing/weak. No overwrite allowed."
    end
    if not core.parse(body) then return nil,"Not a valid AlReaderX record" end
    local url,why=M.join(cfg.url,name)
    if not url then return nil,why end
    local r,_,err=request(cfg,"PUT",url,body,{["If-Match"]=etag,["Content-Type"]="text/plain; charset=utf-8"},2048)
    if not r then return nil,err end
    if r.code==412 or r.code==409 then return nil,"Remote record changed; refusing to overwrite" end
    if r.code~=200 and r.code~=201 and r.code~=204 then return nil,"PUT returned HTTP "..r.code end
    return true
end
return M
