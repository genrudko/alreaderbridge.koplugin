-- AlReaderX FB2 textual coordinate map, modeled from APK 1.33
-- (AlFormat, AlFormatFB2, AlAXML) and compared against the running Android engine.
-- The Kindle uses KOReader's original FB2 DOM paths and XPointer text offsets.
local M={}
local Charset=require("charset")
local function u16len(s)
    local n=0
    local i=1
    while i<=#s do
        local a=s:byte(i)
        if a<128 then i=i+1
        elseif a<224 and i+1<=#s then i=i+2
        elseif a<240 and i+2<=#s then i=i+3
        elseif a<248 and i+3<=#s then i=i+4
        else i=i+1 end
        n=n+(a>=240 and a<248 and 2 or 1)
    end
    return n
end
M.utf16len=u16len
local function utf8cp(n)
    if n<0 or n>0x10ffff or (n>=0xd800 and n<=0xdfff) then return "?" end
    if n<0x80 then return string.char(n) end
    if n<0x800 then return string.char(0xc0+math.floor(n/64),0x80+n%64) end
    if n<0x10000 then return string.char(0xe0+math.floor(n/4096),0x80+math.floor(n/64)%64,0x80+n%64) end
    return string.char(0xf0+math.floor(n/262144),0x80+math.floor(n/4096)%64,0x80+math.floor(n/64)%64,0x80+n%64)
end
local function decode(s)
    return (s:gsub("&#x([0-9a-fA-F]+);",function(h)return utf8cp(tonumber(h,16))end)
        :gsub("&#([0-9]+);",function(d)return utf8cp(tonumber(d))end)
        :gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"')
        :gsub("&apos;","'"):gsub("&amp;","&"))
end
M.decode=decode
local function lname(n) return n:match("([^:]+)$") or n end
local function attr(s,k)
    local v=s:match("[%w_:%-]+"..k.."%s*=%s*\"(.-)\"") or s:match("[%w_:%-]+"..k.."%s*=%s*'(.-)'")
    -- Also allow a bare attribute like name=... (when prefix capture fails).
    if not v then v=s:match("%f[%w]"..k.."%s*=%s*\"(.-)\"") or s:match("%f[%w]"..k.."%s*=%s*'(.-)'") end
    return v and decode(v) or nil
end
local function tagend(s,opening)
    local q, i=nil,opening+1
    while i<=#s do
        local c=s:sub(i,i)
        if q then if c==q then q=nil end
        elseif c=='"' or c=="'" then q=c
        elseif c==">" then return i end
        i=i+1
    end
end
function M.build(xml)
    if type(xml)~="string" or #xml>16*1024*1024 then return nil,"FB2 missing or too large" end
    -- Keep raw file bytes for source offsets (AlReaderX table markers); use
    -- decoded UTF-8 only for constructing text nodes & XPointer paths.
    local raw=xml
    local encoding
    xml,encoding=Charset.decode(xml)
    if not xml then return nil,encoding end
    local table_starts={}
    local source=raw
    if encoding=="utf-16le" or encoding=="utf-16be" then
        local needle="<table"
        local bytes={}
        for i=1,#needle do
            local ch=needle:sub(i,i)
            bytes[i]=encoding=="utf-16le" and (ch.."\0") or ("\0"..ch)
        end
        local encoded=table.concat(bytes)
        local at=1
        while true do
            local k=source:find(encoded,at,true)
            if not k then break end
            table_starts[#table_starts+1]=k-1;at=k+#encoded
        end
    else
        local at=1
        while true do
            local k=source:find("<table",at,true)
            if not k then break end
            table_starts[#table_starts+1]=k-1;at=k+6
        end
    end
    local table_cursor=0
    if not xml:find("<FictionBook",1,true) and not xml:find("<fb:FictionBook",1,true) then
        return nil,"Not an FB2 FictionBook XML" end
    local root,stack=nil,{}
    local unsupported=nil
    local firstbody,booktitle,ann
    local elements=0
    local function appendtext(raw)
        local parent=stack[#stack]
        if not parent or parent.name=="binary" or raw=="" then return end
        local n=(parent.text_count or 0)+1
        parent.text_count=n
        parent.children[#parent.children+1]={kind="text",raw=raw,path=parent.path.."/text()["..n.."]"}
    end
    local i=1
    while i<=#xml do
        local a=xml:find("<",i,true)
        if not a then appendtext(xml:sub(i));break end
        if a>i then appendtext(xml:sub(i,a-1)) end
        if xml:sub(a,a+3)=="<!--" then
            local e=xml:find("-->",a+4,true);if not e then return nil,"unclosed comment" end;i=e+3
        elseif xml:sub(a,a+8)=="<![CDATA[" then
            local e=xml:find("]]>",a+9,true);if not e then return nil,"unclosed CDATA" end
            appendtext(xml:sub(a+9,e-1));i=e+3
        else
            local b=tagend(xml,a)
            if not b then return nil,"unclosed XML tag" end
            local content=xml:sub(a+1,b-1)
            if content:sub(1,1)=="/" then
                local name=lname(content:match("^/%s*([%w_:%.%-]+)") or "")
                if not stack[#stack] or stack[#stack].name~=name then return nil,"XML structure mismatch: "..name end
                stack[#stack]=nil
            elseif content:sub(1,1)~="?" and content:sub(1,1)~="!" then
                local tag=content:match("^%s*([%w_:%.%-]+)")
                if tag then
                    elements=elements+1;if elements>80000 then return nil,"XML too complex" end
                    local name=lname(tag)
                    if name=="script" or name=="style" then
                        local in_body=false
                        for _,ancestor in ipairs(stack) do if ancestor.name=="body" then in_body=true;break end end
                        if in_body then unsupported=unsupported or name end
                    end
                    local parent=stack[#stack]
                    local index
                    if parent then
                        parent.counts[name]=(parent.counts[name] or 0)+1
                        index=parent.counts[name]
                    else
                        index=1
                    end
                    local path=(parent and parent.path or "").."/"..name.."["..index.."]"
                    local node={kind="element",name=name,path=path,children={},counts={},href=attr(content,"href"),attrname=attr(content,"name")}
                    if name=="table" then
                        table_cursor=table_cursor+1
                        node.table_source_start=table_starts[table_cursor]
                        if not node.table_source_start then
                            unsupported=unsupported or "table source offset"
                        end
                    end
                    if parent then parent.children[#parent.children+1]=node else root=node end
                    if name=="body" and not firstbody and (not node.attrname or node.attrname=="") then firstbody=node end
                    if name=="book-title" and not booktitle then booktitle=node end
                    if name=="annotation" and not ann then ann=node end
                    if not content:match("/%s*$") then stack[#stack+1]=node end
                end
            end
            i=b+1
        end
    end
    if not root or #stack~=0 then return nil,"Malformed XML" end
    if not firstbody then return nil,"Main FB2 body not found" end
    if unsupported then return nil,"Exact FB2 model for tag <"..unsupported.."> is not yet verified; safe sync disabled for this book" end
    local segments,by_path={},{}
    local pos=0
    local function walktext(el,record)
        for _,ch in ipairs(el.children) do
            if ch.kind=="text" then
                local str=decode(ch.raw)
                -- AlReaderX treats NBSP and XML whitespace as single text glyphs.
                local width=u16len(str)
                if record and width>0 then
                    local entry={path=ch.path,start=pos,stop=pos+width,text=str,length=width}
                    segments[#segments+1]=entry
                    by_path[ch.path]=entry
                end
                pos=pos+width
            else
                local name=ch.name
                local before,after=0,0
                if name=="strong" or name=="emphasis" or name=="strikethrough" then before,after=2,2
                elseif name=="sup" or name=="sub" or name=="code" then before,after=3,3
                elseif name=="a" then before,after=u16len(ch.href or "")+5,3
                elseif name=="image" then before,after=u16len(ch.href or "")+3,0 end
                pos=pos+before
                walktext(ch,record)
                pos=pos+after
            end
        end
    end
    local function visit(parent,record)
        for _,ch in ipairs(parent.children) do
            if ch.kind=="element" then
                if ch.name=="p" or ch.name=="subtitle" or ch.name=="v" or ch.name=="text-author" then
                    walktext(ch,record)
                elseif ch.name=="image" then
                    -- Standalone <image> occupies a dedicated AlReader paragraph;
                    -- observed marker is one character longer than the inline image.
                    pos=pos+u16len(ch.href or "")+4
                elseif ch.name=="table" then
                    -- AlReaderX emits one internal navigation marker at every
                    -- end-of-row: \014<source byte offset>:<zero-based row>\015
                    -- and a trailing newline after the last row.
                    local row=0
                    for _,item in ipairs(ch.children) do
                        if item.kind=="element" and item.name=="tr" then
                            visit(item,record)
                            local marker="\014"..ch.table_source_start..":"..row.."\015"
                            pos=pos+u16len(marker)
                            row=row+1
                        elseif item.kind=="element" then
                            visit({children={item}},record)
                        end
                    end
                    pos=pos+1
                else visit(ch,record) end
            end
        end
    end
    -- AlReaderX generates one book-title paragraph with 3 hidden characters,
    -- followed by annotation paragraphs (verified with native Android).
    if booktitle then
        walktext(booktitle,false)
        pos=pos+3
    end
    if ann then visit(ann,false) end
    local main_start=pos
    visit(firstbody,true)
    -- AlReaderX appends named bodies (e.g., footnotes) to its partition
    -- after the main body: these also contribute to the numeric total.
    for _,ch in ipairs(root.children) do
        if ch.kind=="element" and ch.name=="body" and ch~=firstbody then
            visit(ch,true)
        end
    end
    if #segments==0 then return nil,"No readable FB2 text segments" end
    return {segments=segments,by_path=by_path,total=pos,main_start=main_start,xml_size=#xml}
end
local function xp_parts(xp)
    if type(xp)~="string" then return nil end
    local base,offset=xp:match("^(.-)%.([0-9]+)$")
    return base,tonumber(offset)
end
function M.toAlReader(map,xp,text_from_engine)
    local base,offset=xp_parts(xp)
    if not base then return nil,"Invalid KOReader XPointer" end
    local entry=map.by_path[base]
    if not entry then return nil,"XPointer is outside the mapped FB2 body or DOM differs" end
    if offset>entry.length then return nil,"XPointer offset exceeds text node" end
    -- Sanity check CRengine text: do not export when DOM differs from source XML.
    if type(text_from_engine)=="string" and #text_from_engine>0 then
        local a=entry.text:gsub("%s+"," "):sub(1,65)
        local b=text_from_engine:gsub("%s+"," "):sub(1,65)
        if a~=b then return nil,"KOReader text does not match source XML at XPointer" end
    end
    return entry.start+offset
end
function M.toXPointer(map,raw_position)
    if type(raw_position)~="number" or raw_position<0 or raw_position>map.total then
        return nil,"AlReaderX position out of bounds" end
    local lo,hi=1,#map.segments
    while lo<=hi do
        local mid=math.floor((lo+hi)/2)
        local e=map.segments[mid]
        if raw_position<e.start then hi=mid-1
        elseif raw_position>e.stop then lo=mid+1
        else return e.path.."."..math.min(e.length,raw_position-e.start),0 end
    end
    local candidates={map.segments[math.max(1,hi)],map.segments[math.min(#map.segments,lo)]}
    local best,dist
    for _,e in ipairs(candidates) do
        if e then
            local d=math.min(math.abs(e.start-raw_position),math.abs(e.stop-raw_position))
            if not dist or d<dist then best=e;dist=d end
        end
    end
    if not best or dist>40 then return nil,"AlReaderX coordinate falls in an unmappable region" end
    local offset=math.max(0,math.min(best.length,raw_position-best.start))
    return best.path.."."..offset,dist
end
return M
