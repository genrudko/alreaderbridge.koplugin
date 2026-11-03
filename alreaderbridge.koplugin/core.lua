-- AlReaderX Bridge. Pure UTF-8/FB2 helpers. No device/network dependencies.
local M = {}

function M.parse(content)
    if type(content) ~= "string" or #content > 256 then return nil, "not a small text record" end
    local opaque, pos = content:match("^%s*!([%-]?[0-9]+)!([0-9]+)%s*$")
    if not opaque then return nil, "unexpected sync record" end
    if #opaque > 32 or #pos > 14 then return nil, "out-of-range fields" end
    local n = tonumber(pos)
    if not n or n < 0 or n > 1000000000 then return nil, "invalid position" end
    return { opaque = opaque, position = n }
end

function M.sync_filename(name)
    if type(name) ~= "string" or #name > 250 or name:find("[/\\%c]") then return nil end
    -- EPUB uses filename's Java long-hash and the embedded EPUB book ID,
    -- unlike FB2, which embeds the source's uncompressed file size in hex.
    local epubhash,epubid=name:match("%.([a-fA-F0-9]+)%.!([%w%-]+)$")
    if epubhash and epubid and #epubid>=8 and #epubid<=96 then
        return {kind="epub",hash=epubhash:lower(),id=epubid,name=name}
    end
    local hx, fingerprint = name:match("%.([a-fA-F0-9]+)%.([a-fA-F0-9]+)$")
    if not hx or not fingerprint or #hx > 12 or #fingerprint < 8 then return nil end
    local size = tonumber(hx,16)
    if not size or size < 1 or size > 1024*1024*1024 then return nil end
    return { kind="fb2",size = size, fingerprint = fingerprint:lower(), name = name, stem = name:match("^([^.]+)") or "" }
end

local chars = { ["а"]="a",["б"]="b",["в"]="v",["г"]="g",["д"]="d",["е"]="e",["ё"]="e",["ж"]="zh",["з"]="z",["и"]="i",["й"]="y",["к"]="k",["л"]="l",["м"]="m",["н"]="n",["о"]="o",["п"]="p",["р"]="r",["с"]="s",["т"]="t",["у"]="u",["ф"]="f",["х"]="h",["ц"]="ts",["ч"]="ch",["ш"]="sh",["щ"]="sch",["ы"]="y",["э"]="e",["ю"]="yu",["я"]="ya",["ь"]="",["ъ"]="" }
local uppercase = { ["А"]="а",["Б"]="б",["В"]="в",["Г"]="г",["Д"]="д",["Е"]="е",["Ё"]="ё",["Ж"]="ж",["З"]="з",["И"]="и",["Й"]="й",["К"]="к",["Л"]="л",["М"]="м",["Н"]="н",["О"]="о",["П"]="п",["Р"]="р",["С"]="с",["Т"]="т",["У"]="у",["Ф"]="ф",["Х"]="х",["Ц"]="ц",["Ч"]="ч",["Ш"]="ш",["Щ"]="щ",["Ъ"]="ъ",["Ы"]="ы",["Ь"]="ь",["Э"]="э",["Ю"]="ю",["Я"]="я" }
function M.translit(name)
    name = (name or ""):lower()
    for up,lo in pairs(uppercase) do name=name:gsub(up,lo) end
    for ru,en in pairs(chars) do name = name:gsub(ru,en) end
    return (name:gsub("[^a-z0-9]", ""))
end

function M.match_record(book_path, book_size, entries, epub_identity)
    if epub_identity then
        local found={}
        for _,entry in ipairs(entries or {}) do
            if entry.name==epub_identity then
                local synced=M.parse(entry.body)
                if synced then
                    found[#found+1]={
                        name=entry.name,body=entry.body,size=book_size,
                        fingerprint=epub_identity,position=synced.position,
                        opaque=synced.opaque,etag=entry.etag,
                        remote=entry.remote,remote_url=entry.remote_url
                    }
                end
            end
        end
        if #found~=1 then
            return nil,#found==0 and "EPUB sync ID not found" or "Ambiguous EPUB sync entries"
        end
        found[1].key="epub:"..epub_identity
        return found[1]
    end
    -- FB2: identical uncompressed source size and substantial filename prefix.
    -- Never guess based on a singleton or size alone.
    if not book_path or not book_path:lower():match("%.fb2$") then return nil, "open a plain .fb2 book" end
    local name = book_path:match("([^/\\]+)$") or ""
    name = name:gsub("%.%w+$", "")
    local normalized = M.translit(name)
    local matches = {}
    for _, entry in ipairs(entries or {}) do
        local parsed = M.sync_filename(entry.name)
        local matchname = parsed and M.translit(parsed.stem) or ""
        if parsed and parsed.size == book_size and #matchname >= 10 and #normalized >= 10 then
            local minlen = math.min(#matchname, #normalized)
            if normalized:sub(1,minlen) == matchname:sub(1,minlen) then
                local sync = M.parse(entry.body)
                if sync then matches[#matches+1] = { name=entry.name, body=entry.body, size=parsed.size,
                    fingerprint=parsed.fingerprint, position=sync.position, opaque=sync.opaque,
                    etag=entry.etag, remote=entry.remote, remote_url=entry.remote_url }
                end
            end
        end
    end
    if #matches ~= 1 then
        return nil, #matches == 0 and "No verified sync file for this book (same filename and FB2 bytes required)" or "Multiple matching sync records; refusing to guess"
    end
    local r = matches[1]
    r.key = r.fingerprint .. ":" .. tostring(r.size)
    return r
end

function M.utf8len(text)
    local _, n = (text or ""):gsub("[\128-\191]", "")
    return #(text or "") - n
end
function M.first_chars(text, count)
    if type(text) ~= "string" then return "" end
    local n=0
    for i=1,#text do
        local b=text:byte(i)
        if b < 128 or b >= 192 then
            n=n+1
            if n > count then return text:sub(1,i-1) end
        end
    end
    return text
end
local function entity_decode(s)
    -- Unicode codepoints from numeric XML entities need proper UTF-8, not x placeholders.
    local function enc(num)
        num = tonumber(num)
        if not num or num < 1 or num > 0x10ffff or (num >= 0xd800 and num <= 0xdfff) then return "?" end
        if num < 128 then return string.char(num) end
        if num < 2048 then return string.char(192+math.floor(num/64),128+num%64) end
        if num < 65536 then return string.char(224+math.floor(num/4096),128+math.floor(num/64)%64,128+num%64) end
        return string.char(240+math.floor(num/262144),128+math.floor(num/4096)%64,128+math.floor(num/64)%64,128+num%64)
    end
    s=s:gsub("&#x([0-9a-fA-F]+);",function(a)return enc(tonumber(a,16)) end)
    s=s:gsub("&#([0-9]+);",function(a)return enc(a) end)
    s=s:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&")
    return s
end

function M.clean_text(xml_fragment)
    local s = xml_fragment:gsub("<[^>]*>","")
    s=entity_decode(s)
    s=s:gsub("%s+"," ")
    return (s:match("^%s*(.-)%s*$"))
end

function M.paragraphs(xml)
    if type(xml)~="string" or #xml > 16*1024*1024 then return nil,"FB2 too large" end
    if not xml:match("^%s*<%?xml") and not xml:find("<FictionBook",1,true) then return nil,"not an XML FB2" end
    local enc = xml:match("<%?xml[^>]-encoding%s*=%s*['\"]([^'\"]+)['\"]")
    if enc and enc:lower():gsub("%-","") ~= "utf8" then return nil,"FB2 must be UTF-8" end
    local body=xml:match("<body>(.-)</body>") or xml:match("<body%s[^>]*>(.-)</body>")
    if not body then return nil,"main FB2 body missing" end
    local result, cum = {}, 0
    for inner in body:gmatch("<p[^>]*>(.-)</p>") do
        local text = M.clean_text(inner)
        if #text > 0 then
            result[#result+1]={pos=cum,text=text,length=M.utf8len(text)}
            cum=cum+result[#result].length
        end
    end
    if #result==0 then return nil,"no text paragraphs" end
    return result,cum
end

function M.candidates(paragraphs, pos, offset, window, limit)
    -- offset = (AlReader coordinate - text-only FB2 coordinate).
    local target=pos-(offset or 540)
    local results={}
    for _,p in ipairs(paragraphs) do
        local dist=math.abs(p.pos-target)
        if dist <= (window or 1500) and M.utf8len(p.text) >= 26 then
            local phrase=p.text:gsub("^—%s*",""):gsub("^%-%s*","")
            phrase=M.first_chars(phrase, 62)
            results[#results+1]={pos=p.pos,phrase=phrase,preview=M.first_chars(p.text,65),distance=dist,
                calibration=pos-p.pos}
        end
    end
    table.sort(results,function(a,b) if a.distance==b.distance then return a.pos<b.pos else return a.distance<b.distance end end)
    while #results > (limit or 8) do table.remove(results) end
    return results
end

function M.find_fragment(paragraphs, fragment)
    -- Exact normalized case-sensitive prefix; no unsafe partial matches.
    local needle = M.clean_text(fragment or "")
    if M.utf8len(needle) < 18 then return nil, "text fragment too short" end
    local hits={}
    for _,p in ipairs(paragraphs) do
        local i=p.text:find(needle,1,true)
        if i then hits[#hits+1]={pos=p.pos+M.utf8len(p.text:sub(1,i-1)),text=p.text} end
    end
    if #hits ~= 1 then return nil, #hits==0 and "text not found in source FB2" or "non-unique text fragment" end
    return hits[1]
end

function M.decode_xml(s)
    s=s:gsub("&amp;","&"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&lt;","<"):gsub("&gt;",">")
    return s
end
function M.xml_items(xml)
    if type(xml)~="string" or #xml> 1024*1024 then return nil,"invalid WebDAV collection" end
    local out={}
    for block in xml:gmatch("<[%w_]*:?response[^>]*>(.-)</[%w_]*:?response>") do
        local href=block:match("<[%w_]*:?href[^>]*>(.-)</[%w_]*:?href>")
        local etag=block:match("<[%w_]*:?getetag[^>]*>(.-)</[%w_]*:?getetag>")
        local size=block:match("<[%w_]*:?getcontentlength[^>]*>(%d+)</[%w_]*:?getcontentlength>")
        if href and not block:find(":collection") and not block:find("<collection") then
            out[#out+1]={href=M.decode_xml(href),etag=etag and M.decode_xml(etag),size=tonumber(size)}
        end
    end
    return out
end

return M
