local function here()
    return debug.getinfo(1,"S").source:sub(2):match("^(.*)[/\\][^/\\]+$") or "."
end
local path=here().."/../alreaderbridge.koplugin/?.lua;"
package.path=path..package.path
local pm=require("positionmap")
local Charset=require("charset")
local cases={
    ["table-utf8.fb2"]={
        total=428,
        texts={
            ["Глава первая с длинным названием"]=20,
            ["Первый обычный абзац с русскими буквами. Пролог."]=52,
            ["Таблица: ячейка 1-1."]=100,
            ["Таблица: ячейка 1-2."]=120,
            ["Таблица: ячейка 2-1."]=147,
            ["Таблица: ячейка 2-2."]=167,
            ["После таблицы есть обычная строка и другие теги: "]=195,
            ["А это глубокая разметка: "]=293,
            ["Ссылка "]=371,
            ["Примечание."]=417
        }
    },
    ["table-cp1251.fb2"]={
        total=428,
        texts={
            ["Глава первая с длинным названием"]=20,
            ["Первый обычный абзац с русскими буквами. Пролог."]=52,
            ["Таблица: ячейка 1-1."]=100,
            ["Таблица: ячейка 2-1."]=147,
            ["После таблицы есть обычная строка и другие теги: "]=195,
            ["Примечание."]=417
        }
    },
    ["image-tags.fb2"]={
        total=302,
        texts={
            ["Заголовок"]=14,
            ["Простой абзац перед изображением."]=23,
            ["Простой абзац после изображения."]=66,
            ["До встроенного "]=98,
            ["Этот абзац содержит "]=155,
            ["Нижний индекс "]=209,
            ["Последний после всяких тегов абзац."]=267
        }
    },
}
for name,expected in pairs(cases) do
    local f=assert(io.open(here().."/native-fixtures/"..name,"rb"))
    local raw=f:read("*a");f:close()
    local map,err=pm.build(raw)
    assert(map, tostring(err))
    assert(map.total==expected.total, name..": expected "..expected.total..", got "..map.total)
    for text,pos in pairs(expected.texts) do
        local found=false
        for _,seg in ipairs(map.segments) do
            if seg.text==text then
                assert(seg.start==pos,name..": "..text.." expected "..pos.." got "..seg.start)
                found=true
                break
            end
        end
        assert(found,name..": text not found: "..text)
    end
    local successful=0
    for _,seg in ipairs(map.segments) do
        for _,offset in ipairs({0,math.floor(seg.length/2),seg.length}) do
            local xp=seg.path.."."..offset
            local pos=assert(pm.toAlReader(map,xp,seg.text))
            local back=assert(pm.toXPointer(map,pos))
            assert(pm.toAlReader(map,back)==pos)
            successful=successful+1
        end
    end
    print("PASS: AlReaderX Android 1.33 native",name,map.total,"roundtrips",successful)
end
do
    local s='<?xml version="1.0" encoding="UTF-16"?><FictionBook><description><title-info><book-title>T</book-title></title-info></description><body><section><p>ASCII</p></section></body></FictionBook>'
    local utf16le=s:gsub(".",function(c)return c.."\0"end)
    local decoded,encoding=Charset.decode("\255\254"..utf16le)
    assert(decoded==s and encoding=="utf-16le")
    local map=assert(pm.build("\255\254"..utf16le))
    assert(map.total>0)
    assert(not Charset.decode("\255\254"..utf16le:sub(1,-2)))
end
do
    local unknown='<?xml version="1.0" encoding="cp9999"?><FictionBook/>'
    local decoded,err=Charset.decode(unknown)
    assert(not decoded and err:find("unsupported"))
    local bad='\192\128'
    assert(not Charset.isValidUtf8(bad))
end
print("PASS: verified charsets, UTF-16LE, malformed-charset rejection")
