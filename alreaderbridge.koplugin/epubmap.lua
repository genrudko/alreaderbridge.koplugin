-- EPUB spine->AlReaderX coordinate mapping to KOReader crengine XPointer paths.
-- Conservative: supports well-formed XHTML + measured inline markup. Complex CSS,
-- scripts, SVG, tables and dynamically altered DOM are not assumed exact.
local Charset=require("charset")
local FB2=require("positionmap")
local M={}
local MAX_ITEM=16*1024*1024
local function attr(s,k)
    local esc=k:gsub("([^%w])","%%%1")
    return s:match("%f[%w]"..esc..'%s*=%s*"([^"]*)"')
        or s:match("%f[%w]"..esc.."%s*=%s*'([^']*)'")
end
local function tagend(s,idx)
    local q=nil
    for i=idx+1,#s do
        local c=s:sub(i,i)
        if q then if q==c then q=nil end
        elseif c=="'" or c=='"' then q=c
        elseif c==">" then return i end
    end
end
local function lname(t) return (t:match("([^:]+)$") or t):lower() end
local function parse_xml(raw)
    local xml,enc=Charset.decode(raw)
    if not xml then return nil,enc end
    local root,stack=nil,{}
    local count=0
    local i=1
    local function text(s)
        local parent=stack[#stack]
        if not parent or s=="" then return end
        parent.text_count=parent.text_count+1
        parent.children[#parent.children+1]={kind="text",raw=s,index=parent.text_count}
    end
    while i<=#xml do
        local a=xml:find("<",i,true)
        if not a then text(xml:sub(i));break end
        if a>i then text(xml:sub(i,a-1)) end
        if xml:sub(a,a+3)=="<!--" then
            local e=xml:find("-->",a+4,true)
            if not e then return nil,"Unterminated HTML comment" end
            i=e+3
        elseif xml:sub(a,a+8)=="<![CDATA[" then
            local e=xml:find("]]>",a+9,true)
            if not e then return nil,"Unterminated CDATA" end
            text(xml:sub(a+9,e-1))
            i=e+3
        else
            local b=tagend(xml,a)
            if not b then return nil,"Malformed XHTML" end
            local content=xml:sub(a+1,b-1)
            if content:sub(1,1)=="/" then
                local name=lname(content:match("^/%s*([%w_:%.%-]+)") or "")
                if not stack[#stack] or stack[#stack].name~=name then
                    return nil,"Malformed XHTML closing tag: "..name
                end
                stack[#stack]=nil
            elseif not content:match("^%s*[!?]") then
                local name=lname(content:match("^%s*([%w_:%.%-]+)") or "")
                if name~="" then
                    count=count+1
                    if count>80000 then return nil,"XHTML contains too many elements" end
                    local parent=stack[#stack]
                    local ix=1
                    if parent then
                        parent.counts[name]=(parent.counts[name] or 0)+1
                        ix=parent.counts[name]
                    end
                    local node={kind="element",name=name,index=ix,attrs=content,
                        children={},counts={},text_count=0}
                    if parent then parent.children[#parent.children+1]=node
                    else root=node end
                    if not content:match("/%s*$") then
                        stack[#stack+1]=node
                    end
                end
            end
            i=b+1
        end
    end
    if #stack~=0 or not root then return nil,"Malformed XHTML element tree" end
    return root
end
local function child(node,name)
    for _,v in ipairs(node.children or {}) do
        if v.kind=="element" and v.name==name then return v end
    end
end
local function nonspace(s)
    return s and s:find("%S")
end
local blocks={p=true,h1=true,h2=true,h3=true,h4=true,h5=true,h6=true,
    li=true,blockquote=true,pre=true,dt=true,dd=true,figcaption=true}
local skip={style=true,script=true,svg=true,math=true}
local before_after={b=2,strong=2,i=2,em=2,emphasis=2,strikethrough=2,s=2}
local function map_spine(html,number,initial,all_segments,lookup)
    local root,err=parse_xml(html)
    if not root then return nil,err end
    if root.name~="html" then return nil,"EPUB spine is not XHTML" end
    local body=child(root,"body")
    if not body then return nil,"XHTML <body> missing" end
    local pos=initial
    local first_block=(number==1)
    local prefix="/body[1]/DocFragment["..number.."]/body[1]"
    local trouble=nil
    local function walk(node,path,inside)
        for _,c in ipairs(node.children) do
            if c.kind=="text" then
                local t=FB2.decode(c.raw)
                if inside or nonspace(t) then
                    if nonspace(t) then
                        local l=FB2.utf16len(t)
                        local item={path=path.."/text()["..c.index.."]",
                            start=pos,stop=pos+l,length=l,text=t}
                        all_segments[#all_segments+1]=item
                        lookup[item.path]=item
                        pos=pos+l
                    elseif t=="" then
                        -- nothing
                    else
                        -- Whitespace between inline nodes is visible.
                        -- CRengine may collapse it: keep its measured width.
                        local l=FB2.utf16len(t)
                        pos=pos+l
                    end
                end
            elseif c.kind=="element" and not skip[c.name] then
                if c.name=="table" or c.name=="img" or c.name=="br" or c.name=="ruby" then
                    trouble=trouble or c.name
                end
                local sub=path.."/"..c.name.."["..c.index.."]"
                local style=before_after[c.name]
                local in_block=inside or blocks[c.name]==true
                if style then pos=pos+style end
                if c.name=="a" and attr(c.attrs,"href") then
                    -- EPUB hyperlink encoding is not yet native-verified.
                    trouble=trouble or "a href"
                end
                walk(c,sub,in_block)
                if style then pos=pos+style end
                if first_block and blocks[c.name] then
                    -- AlReaderX 1.33 pads the first EPUB content block with
                    -- 3 internal zero glyphs; native fixture shows 10 vs 7.
                    pos=pos+3
                    first_block=false
                end
            end
        end
    end
    walk(body,prefix,false)
    if trouble then
        return nil,"EPUB markup <"..trouble.."> needs AlReaderX coordinate calibration"
    end
    return pos
end
local function extract_id(opf)
    local head=opf:match("<[%w_:%.%-]*package%s+([^>]+)>")
    local key=head and attr(head,"unique-identifier")
    if not key then return nil,"EPUB unique-identifier absent" end
    for attrs,t in opf:gmatch("<[%w_:%.%-]*identifier%s*([^>]*)>(.-)</[%w_:%.%-]*identifier%s*>") do
        if attr(attrs,"id")==key then
            t=t:gsub("^%s+",""):gsub("%s+$","")
            t=t:gsub("^urn:uuid:","")
            if not t:match("^[0-9a-fA-F%-]+$") or #t<8 then
                return nil,"AlReaderX EPUB book ID needs verification"
            end
            return t
        end
    end
    return nil,"EPUB unique identifier not found"
end
local function is_file(s) return type(s)=="string" and #s>0 and #s<256 end
local function unescape_uri(s)
    if s:find("%%[^0-9a-fA-F]") then return nil end
    return (s:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end))
end
local function normpath(base,relative)
    relative=unescape_uri(relative:match("^[^#]*") or "")
    if not relative or relative:sub(1,1)=="/" then return nil end
    local segments={}
    for seg in (base.."/"..relative):gmatch("[^/]+") do
        if seg==".." then
            if #segments==0 then return nil end
            table.remove(segments)
        elseif seg~="." then segments[#segments+1]=seg end
    end
    return table.concat(segments,"/")
end
local function manifest(opf)
    local items={}
    for tag in opf:gmatch("<[%w_:%.%-]*item%s+[^>]+>") do
        local id,href,media=attr(tag,"id"),attr(tag,"href"),attr(tag,"media-type")
        if id and href then items[id]={href=href,media=media} end
    end
    local spine={}
    for tag in opf:gmatch("<[%w_:%.%-]*itemref%s+[^>]+>") do
        local id=attr(tag,"idref")
        if id then
            local obj=items[id]
            if not obj or obj.media~="application/xhtml+xml" then
                return nil,"EPUB spine contains unsupported document item"
            end
            spine[#spine+1]=obj.href
        end
    end
    if #spine==0 then return nil,"EPUB spine is empty" end
    if #spine>500 then return nil,"EPUB spine too long" end
    return spine
end
local function utf8_iter(s)
    local i=1
    return function()
        if i>#s then return nil end
        local b=s:byte(i)
        local n,cp
        if b<128 then n,cp=1,b
        elseif b<224 then n,cp=2,(b-192)*64+s:byte(i+1)-128
        elseif b<240 then
            n,cp=3,(b-224)*4096+(s:byte(i+1)-128)*64+s:byte(i+2)-128
        else
            n,cp=4,(b-240)*262144+(s:byte(i+1)-128)*4096+
                (s:byte(i+2)-128)*64+s:byte(i+3)-128
        end
        local ch=s:sub(i,i+n-1)
        i=i+n
        return cp,ch
    end
end
local function java_name_crc(filename)
    if not Charset.isValidUtf8(filename) then return nil,"Invalid UTF-8 EPUB filename" end
    local hi,lo=0,0
    local output,units={},0
    local function add_u16(w)
        local val=lo*31+w
        lo=val%4294967296
        hi=(hi*31+math.floor(val/4294967296))%4294967296
    end
    for cp,ch in utf8_iter(filename) do
        local n=cp>0xFFFF and 2 or 1
        if cp>0xFFFF then
            local a=cp-0x10000
            add_u16(0xD800+math.floor(a/1024))
            add_u16(0xDC00+a%1024)
        else add_u16(cp) end
        if units<32 then
            local is_alnum=(cp>=48 and cp<=57) or
                (cp>=65 and cp<=90) or (cp>=97 and cp<=122) or
                (cp>=192 and cp<=687) or (cp>=0x0400 and cp<=0x052F) or
                (cp>=0x0590 and cp<=0x08FF) or (cp>=0x3040 and cp<=0x9FFF)
            output[#output+1]=is_alnum and ch or "_"
        end
        units=units+n
    end
    local hash=string.format("%08x%08x",hi,lo):gsub("^0+","")
    if hash=="" then hash="0" end
    return table.concat(output).."."..hash
end
local function epub_name(filename,id)
    local prefix,err=java_name_crc(filename)
    if not prefix then return nil,err end
    return prefix..".!"..id
end
M.epub_name=epub_name
function M.fromFiles(filename, opf_path, opf,files)
    local id,why=extract_id(opf)
    if not id then return nil,why end
    local refs,err=manifest(opf)
    if not refs then return nil,err end
    local folder=opf_path:match("^(.*)/[^/]+$") or ""
    local segments,lookup,position={}, {},0
    for i,href in ipairs(refs) do
        local path=normpath(folder,href)
        if not path then return nil,"unsafe EPUB spine path" end
        local data=files[path]
        if type(data)~="string" or #data>MAX_ITEM then return nil,"missing/oversized EPUB spine item "..path end
        local nextpos,msg=map_spine(data,i,position,segments,lookup)
        if not nextpos then return nil,msg end
        position=nextpos
    end
    if #segments==0 then return nil,"No readable text in EPUB" end
    return {segments=segments,by_path=lookup,total=position,
        sync_name=epub_name(filename,id),kind="epub",main_start=0}
end
function M.open(path)
    local Archive=require("ffi/archiver")
    local reader=Archive.Reader:new()
    if not reader:open(path) then return nil,"Could not read EPUB archive" end
    -- The archiver's name lookup is populated during iterate(), and is not
    -- immediately available after open() (verified against KOReader Android).
    local available={}
    for entry in reader:iterate() do
        if entry.mode=="file" and type(entry.path)=="string" then
            available[entry.path]=tonumber(entry.size) or 0
        end
    end
    local function get(name)
        if not available[name] or available[name]>MAX_ITEM then return nil end
        local data=reader:extractToMemory(name)
        if not data or #data>MAX_ITEM then return nil end
        return data
    end
    local container=get("META-INF/container.xml")
    if not container then reader:close();return nil,"EPUB container.xml missing" end
    local opf_path=container:match('full%-path%s*=%s*"([^"]+)"')
        or container:match("full%-path%s*=%s*'([^']+)'")
    if not is_file(opf_path) then reader:close();return nil,"EPUB OPF location missing" end
    local opf=get(opf_path)
    if not opf then reader:close();return nil,"EPUB OPF file missing" end
    local spine,err=manifest(opf)
    if not spine then reader:close();return nil,err end
    local folder=opf_path:match("^(.*)/[^/]+$") or ""
    local files={}
    for _,href in ipairs(spine) do
        local name=normpath(folder,href)
        if not name then reader:close();return nil,"EPUB spine path unsafe" end
        files[name]=get(name)
        if not files[name] then reader:close();return nil,"EPUB spine resource unavailable: "..name end
    end
    reader:close()
    local filename=path:match("([^/\\]+)$") or path
    return M.fromFiles(filename,opf_path,opf,files)
end
return M
