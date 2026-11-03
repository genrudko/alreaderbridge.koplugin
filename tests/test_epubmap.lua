local function here()
    return debug.getinfo(1,"S").source:sub(2):match("^(.*)[/\\][^/\\]+$") or "."
end
package.path=here().."/../alreaderbridge.koplugin/?.lua;"..package.path
local epub=require("epubmap")
local core=require("core")
local function read(n)
    local f=assert(io.open(here().."/native-fixtures/"..n,"rb"))
    local x=f:read("*a");f:close();return x
end
local opf=read("epub-content.opf")
local files={
    ["OEBPS/chapter1.xhtml"]=read("epub-chapter1.xhtml"),
    ["OEBPS/chapter2.xhtml"]=read("epub-chapter2.xhtml")
}
local doc,err=epub.fromFiles("table-demo.epub","OEBPS/content.opf",opf,files)
assert(doc,err)
assert(doc.total==211,"Expected AlReaderX EPUB 211 units; got "..doc.total)
assert(#doc.segments==10)
local expected_sync="table_demo_epub.ae1ae9a3b56e4264.!00000000-0000-4000-8000-123456789abc"
assert(doc.sync_name==expected_sync,doc.sync_name)
assert(core.sync_filename(expected_sync).kind=="epub")
local ru=epub.epub_name("тестовая-книга.epub","00000000-0000-4000-8000-123456789abc")
assert(ru=="тестовая_книга_epub.18c186b8849d019a.!00000000-0000-4000-8000-123456789abc")
local expected={
    {"/body[1]/DocFragment[1]/body[1]/h1[1]/text()[1]",0},
    {"/body[1]/DocFragment[1]/body[1]/p[1]/text()[1]",10},
    {"/body[1]/DocFragment[1]/body[1]/p[2]/text()[1]",64},
    {"/body[1]/DocFragment[1]/body[1]/p[2]/strong[1]/text()[1]",79},
    {"/body[1]/DocFragment[2]/body[1]/h1[1]/text()[1]",107},
    {"/body[1]/DocFragment[2]/body[1]/p[1]/text()[1]",114},
    {"/body[1]/DocFragment[2]/body[1]/p[2]/strong[1]/text()[1]",183},
}
for _,pair in ipairs(expected) do
    local node=assert(doc.by_path[pair[1]],pair[1])
    assert(node.start==pair[2],pair[1].." expected "..pair[2]..", got "..node.start)
end
local n=0
for _,entry in ipairs(doc.segments) do
    for _,off in ipairs({0,math.floor(entry.length/2),entry.length}) do
        local xp=entry.path.."."..off
        local pos=assert(require("positionmap").toAlReader(doc,xp,entry.text))
        local back=assert(require("positionmap").toXPointer(doc,pos))
        assert(require("positionmap").toAlReader(doc,back)==pos)
        n=n+1
    end
end
for _,item in ipairs({{tag="wrapped",total=211,first=0,second=107},
    {tag="no-heading",total=197,first=0,second=100}}) do
    local variant={}
    for chapter=1,2 do
        variant["OEBPS/chapter"..chapter..".xhtml"]=read("epub-"..item.tag.."-chapter"..chapter..".xhtml")
    end
    local map,why=epub.fromFiles("variant.epub","OEBPS/content.opf",opf,variant)
    assert(map,why)
    assert(map.total==item.total,item.tag.." expected "..item.total.." got "..map.total)
    assert(map.segments[1].start==item.first)
    local fragment2
    for _,part in ipairs(map.segments) do
        if part.path:find("DocFragment[2]",1,true) then
            fragment2=part.start;break
        end
    end
    assert(fragment2==item.second,item.tag.." chapter 2 should start "..item.second)
end
local entry=assert(core.match_record("table-demo.epub",2126,{
    {name=expected_sync,body="!1793605000100!114"}
},expected_sync))
assert(entry.key=="epub:"..expected_sync and entry.position==114)
assert(not core.match_record("table-demo.epub",2126,{
    {name="other.epub.deadbeef.!00000000-0000-4000-8000-123456789abc",body="!1793605000100!114"}
},expected_sync))
local unsupported=files["OEBPS/chapter1.xhtml"]:gsub("<p>",'<p><img src="img.jpg"/>',1)
local bad=epub.fromFiles("table-demo.epub","OEBPS/content.opf",opf,{
    ["OEBPS/chapter1.xhtml"]=unsupported,
    ["OEBPS/chapter2.xhtml"]=files["OEBPS/chapter2.xhtml"]
})
assert(not bad,"Cannot safely map unknown EPUB image CSS to AlReaderX")
print("PASS: EPUB cross-reader native mappings, identity and roundtrips",n)
