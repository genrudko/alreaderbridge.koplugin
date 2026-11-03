local function here()
    local source=debug.getinfo(1,"S").source:sub(2)
    return source:match("^(.*)[/\\][^/\\]+$") or "."
end
local base=here().."/../"
package.path=base.."alreaderbridge.koplugin/?.lua;"..package.path
local pm=require("positionmap")
local f=assert(io.open(here().."/fixture.fb2","rb"))
local s=f:read("*a");f:close()
local map,err=pm.build(s)
assert(map,err)
assert(map.total==577, "Expected 577 internal AlReaderX characters, got "..map.total)
assert(map.main_start==19)
local expected={
 {"Заглавие книги",19},{"Глава 1",49},{"Первый абзац",56},
 {"***",106},{"Второй абзац",109},{"Третий абзац",164},
 {"Текст со ссылкой",210},{"Абзац с примечанием",292},
 {"И вот другой",350},{"Четвёртый абзац",375},
 {"Глава 2",422},{"Пятый большой",429},{"Последний фрагмент",478},
}
for _,sample in ipairs(expected) do
 local found=false
 for _,entry in ipairs(map.segments) do
  if entry.text:find(sample[1],1,true) then
   assert(entry.start==sample[2], sample[1].." wrong offset "..entry.start)
   found=true;break
  end
 end
 assert(found,"No sample "..sample[1])
end
local count=0
for _,entry in ipairs(map.segments) do
 for _,off in ipairs({0,math.floor(entry.length/2),entry.length}) do
  local xp=entry.path.."."..off
  local pos=assert(pm.toAlReader(map,xp,entry.text))
  assert(pos==entry.start+off)
  local back=assert(pm.toXPointer(map,pos))
  assert(pm.toAlReader(map,back)==pos)
  count=count+1
 end
end
assert(not pm.toXPointer(map,map.total+1))
assert(not pm.toAlReader(map,"/FictionBook[1]/description[1]/title-info[1].0"))
assert(not pm.build(s:gsub('encoding="utf%-8"','encoding="made-up"')))
assert(pm.build(s:gsub('</body>','<p><image l:href="#x"/></p></body>',1)))
print("PASS: synthetic AlReaderX native-fixture mapping and roundtrip",count)
