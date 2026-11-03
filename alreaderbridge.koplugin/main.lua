-- AlReaderX Bridge: local / WebDAV sync. Network transactions are never done
-- on page-turn events; only on book open/close, manual sync and reconnect.
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local DataStorage=require("datastorage")
local LuaSettings=require("luasettings")
local UIManager=require("ui/uimanager")
local InfoMessage=require("ui/widget/infomessage")
local ConfirmBox=require("ui/widget/confirmbox")
local InputDialog=require("ui/widget/inputdialog")
local Menu=require("ui/widget/menu")
local Event=require("ui/event")
local lfs=require("libs/libkoreader-lfs")
local NetworkMgr=require("ui/network/manager")
local core=require("core")
local mapper=require("positionmap")
local epubmap=require("epubmap")
local _=require("gettext")

local Bridge=WidgetContainer:extend{
    name="alreaderbridge", is_doc_only=true,
    settings_file=DataStorage:getSettingsDir().."/alreaderbridge.lua",
}
local MAX_FB2=16*1024*1024
local function notify(s) UIManager:show(InfoMessage:new{text=tostring(s)}) end
local function read_file(path, limit)
    local a=lfs.attributes(path)
    if not a or a.mode~="file" or a.size>limit then return nil,"file absent or too large" end
    local f,why=io.open(path,"rb")
    if not f then return nil,why end
    local text=f:read("*a");f:close()
    return text
end
local function save_private(path, text)
    local fh,why=io.open(path,"wb")
    if not fh then return nil,why end
    local ok,err=fh:write(text)
    fh:close()
    return ok~=nil,err
end
local function book_filename(path) return (path or ""):match("([^/\\]+)$") or "" end
local function boolword(b) return b and "Да" or "Нет" end

function Bridge:init()
    self.store=LuaSettings:open(self.settings_file)
    self.settings=self.store:readSetting("bridge_v1",{})
    local s=self.settings
    s.auto_import=s.auto_import~=false
    -- v1.0 RC could write to the wrong WebDAV directory and used an
    -- unproven constant offset. Disable old auto-export on upgrade.
    if not s.migrated_v11 then
        s.auto_export=false
        s.migrated_v11=true
        self.store:saveSetting("bridge_v1",s)
        self.store:flush()
    else
        s.auto_export=s.auto_export==true
    end
    s.dav_url=s.dav_url or ""
    s.backup_dav_url=s.backup_dav_url or ""
    s.user=s.user or ""
    s.password=s.password or ""
    s.calibrations=s.calibrations or {} -- legacy v1.1 metadata, not used by v1.2
    s.last_seen=s.last_seen or {}
    s.last_applied=s.last_applied or {}
    s.pending=s.pending or {}
    if not s.migrated_v12 then
        -- v1.1's +543 calibration was unsound. Do not treat its records as imported.
        s.calibrations={}
        s.last_applied={}
        s.last_seen={}
        -- Enable safe automatic export after an accepted import, never before it.
        s.auto_export=true
        s.migrated_v12=true
        self.store:saveSetting("bridge_v1",s)
        self.store:flush()
    end
    -- On AlReaderX the first field is syncIdDevice, not an opaque book ID.
    -- The sender is ignored when that ID equals the receiving device's ID.
    -- Generate one persistent Kindle sender ID, never reuse the AlReader sender.
    if not s.sender_id then
        local value = tostring(G_reader_settings and G_reader_settings:readSetting("device_id") or "")
        local hash = 0
        for i=1,#value do hash=(hash*31+value:byte(i))%1000 end
        s.sender_id=tostring(os.time()*1000+hash)
        self.store:saveSetting("bridge_v1",s)
        self.store:flush()
    end
    self.local_dir=DataStorage:getDataDir().."/alreaderx-sync"
    if lfs.attributes(self.local_dir,"mode")~="directory" then lfs.mkdir(self.local_dir) end
    self.ui.menu:registerToMainMenu(self)
    self.on_open_xp=nil
    self.last_record=nil
    self.parsed=nil
end
function Bridge:save()
    self.store:saveSetting("bridge_v1",self.settings)
    self.store:flush()
end
function Bridge:can_dav() return self.settings.dav_url:match("^https://")~=nil and self.settings.user~="" and self.settings.password~="" end
function Bridge:book_info()
    local path=self.ui.document.file
    if self.book_cache and self.book_cache.path==path then return self.book_cache end
    if not path then return nil,"no opened document" end
    local data,inner,size
    if path:lower():match("%.fb2$") then
        local attrs=lfs.attributes(path)
        if not attrs or attrs.size>MAX_FB2 then return nil,"FB2 missing or too large" end
        data=read_file(path,MAX_FB2)
        inner=book_filename(path)
        size=attrs.size
    elseif path:lower():match("%.epub$") then
        -- The EPUB spine has a different internal text order and document ID
        -- than FB2; parse its OPF and spine rather than pretending it is FB2.
        local epub,reason=epubmap.open(path)
        if not epub then return nil,reason end
        local attrs=lfs.attributes(path)
        if not attrs then return nil,"EPUB file not found" end
        self.book_cache={path=path,kind="epub",map=epub,
            sync_name=epub.sync_name,inner_name=book_filename(path),size=attrs.size}
        return self.book_cache
    elseif path:lower():match("%.fb2%.zip$") then
        local Archiver=require("ffi/archiver")
        local arc=Archiver.Reader:new()
        if not arc:open(path) then return nil,"Could not open FB2 ZIP" end
        local count=0
        for entry in arc:iterate() do
            if entry.mode=="file" and entry.path:lower():match("%.fb2$") then
                count=count+1
                if entry.size>0 and entry.size<=MAX_FB2 and count==1 then
                    data=arc:extractToMemory(entry.path)
                    inner=book_filename(entry.path)
                    size=entry.size
                end
            end
        end
        arc:close()
        if count~=1 then return nil,"FB2 ZIP must contain exactly one FB2 file" end
    else
        return nil,"Supported books: .fb2, .fb2.zip and compatible .epub"
    end
    if not data or #data~=size then return nil,"Uncompressed FB2 size mismatch" end
    self.book_cache={path=path,xml=data,inner_name=inner,size=size}
    return self.book_cache
end
function Bridge:load_local()
    local out={}
    if lfs.attributes(self.local_dir,"mode")~="directory" then return out end
    for name in lfs.dir(self.local_dir) do
        if core.sync_filename(name) then
            local body=read_file(self.local_dir.."/"..name,256)
            if body and core.parse(body) then out[#out+1]={name=name,body=body} end
        end
    end
    return out
end
function Bridge:local_save(record)
    -- Only replace a file obtained from the current WebDAV listing; a private
    -- snapshot of the previous value is retained separately.
    local file=self.local_dir.."/"..record.name
    if not core.sync_filename(record.name) or not core.parse(record.body) then return nil,"invalid sync record" end
    local old=read_file(file,256)
    if old and old~=record.body then
        local key=self.settings.last_seen[record.key] and self.settings.last_seen[record.key].content
        if old~=key then return nil,"local record modified independently; not overwriting" end
        save_private(file..".bridge-backup",old)
    end
    return save_private(file,record.body)
end
function Bridge:load_remote()
    if not self:can_dav() then return nil,"WebDAV not configured" end
    if not NetworkMgr:isOnline() then return nil,"Wi-Fi is offline" end
    local book,why=self:book_info()
    if not book then return nil,why end
    local dav=require("dav")
    local base=self.settings.dav_url:gsub("/+$","")
    local dirs={}
    local function add(path)
        if path and path~="" then
            for _,u in ipairs(dirs) do if u==path then return end end
            dirs[#dirs+1]=path
        end
    end
    -- The native AlReaderX WebDAV writer always uses this folder beneath
    -- the user-configured WebDAV root (verified in APK v1.33).
    add(base.."/AlReaderX-01Sync")
    add(self.settings.resolved_dav)
    add(base)
    for _,suffix in ipairs({"Sync","sync","AlReaderX/Sync","AlReaderXPro/sync"}) do
        add(base.."/"..suffix)
    end
    local out, root_error={},nil
    for index,dir in ipairs(dirs) do
        local cfg={url=dir,user=self.settings.user,password=self.settings.password}
        local listed,err=dav.list(cfg)
        if not listed then
            if index==1 then root_error=err end
        else
            for _,it in ipairs(listed) do
                local parsed=core.sync_filename(it.name)
                if parsed and ((parsed.kind=="fb2" and parsed.size==book.size)
                    or (parsed.kind=="epub" and parsed.name==book.sync_name)) then
                    local rec=dav.get(cfg,it.name)
                    if rec then
                        rec.etag=rec.etag or it.etag
                        rec.remote_url=dir
                        out[#out+1]=rec
                    end
                end
            end
        end
        if #out>0 then
            if self.settings.resolved_dav~=dir then
                self.settings.resolved_dav=dir;self:save()
            end
            break
        end
    end
    if #out==0 and root_error then return nil,root_error end
    return out
end
function Bridge:current_record(interactive)
    local book,why=self:book_info()
    if not book then return nil,why end
    local local_records=self:load_local()
    local records=local_records
    local source="local"
    if self:can_dav() then
        local remote,err=self:load_remote()
        if remote then
            records=remote;source="WebDAV"
        else
            if interactive then notify("WebDAV недоступен: "..tostring(err).."\nЛокальная копия — только для просмотра.") end
            source="offline-local"
        end
    end
    local r,reason=core.match_record(book.inner_name,book.size,records,book.sync_name)
    if not r then return nil,reason end
    r.source=source
    self.last_record=r
    return r
end
function Bridge:position_map()
    local book,why=self:book_info()
    if not book then return nil,why end
    if book.kind=="epub" then return book.map end
    if self.parsed and self.parsed.path==book.path then return self.parsed.map end
    local map,err=mapper.build(book.xml)
    if not map then return nil,err end
    self.parsed={path=book.path,map=map}
    return map
end
function Bridge:current_xp()
    if not self.ui.rolling then return nil end
    local ok,value=pcall(self.ui.rolling.getLastProgress,self.ui.rolling)
    return ok and value or nil
end
function Bridge:engine_text(xp)
    local doc=self.ui.document
    if not xp or type(doc.getTextFromXPointer)~="function" then return nil end
    local ok,value=pcall(doc.getTextFromXPointer,doc,xp)
    return ok and type(value)=="string" and value or nil
end
function Bridge:resolve_import_xp(map,position)
    local xp,err=mapper.toXPointer(map,position)
    if not xp then return nil,err end
    if err and err>0 then return nil,"Position is inside non-text XML markup; exact mapping is unavailable" end
    local doc=self.ui.document
    local ok,valid=pcall(doc.isXPointerInDocument,doc,xp)
    if ok and valid then return xp end
    -- Only use a unique textual match if the CRengine DOM is not isomorphic
    -- to the FB2 source. Never jump to the first of several matches.
    local best,dist
    for _,entry in ipairs(map.segments) do
        local d=math.min(math.abs(entry.start-position),math.abs(entry.stop-position))
        if not dist or d<dist then best,dist=entry,d end
    end
    if not best or dist>60 then return nil,"XPointer absent and no nearby text segment" end
    local phrase=core.first_chars(best.text:gsub("^—%s*",""),70)
    if mapper.utf16len(phrase)<20 then return nil,"Text anchor too short" end
    if type(doc.findAllText)~="function" then return nil,"Text search unavailable" end
    local good,hits=pcall(doc.findAllText,doc,phrase,false,3,10,false,0x00FF)
    if not good or type(hits)~="table" or #hits~=1 then
        return nil,"DOM mismatch and text anchor not unique"
    end
    xp=hits[1].start
    local check,valid2=pcall(doc.isXPointerInDocument,doc,xp)
    if not check or not valid2 then return nil,"Fallback XPointer invalid" end
    return xp
end
function Bridge:commit_import(r,xp,quiet)
    self.ui:handleEvent(Event:new("GotoXPointer",xp))
    self.on_open_xp=self:current_xp() or xp
    self.settings.last_seen[r.key]={content=r.body,source=r.source}
    self.settings.last_applied[r.key]={body=r.body,xp=xp}
    self.last_record=r
    self:save()
    if not quiet then notify("Позиция AlReaderX применена.\n"..xp) end
end
function Bridge:import_position(interactive)
    local r,why=self:current_record(interactive)
    if not r then if interactive then notify(why) end;return end
    if r.source=="offline-local" and not interactive then return end
    local last=self.settings.last_applied[r.key]
    if not interactive and last and last.body==r.body then return end
    local map,err=self:position_map()
    if not map then if interactive then notify(err) end;return end
    local xp,why2=self:resolve_import_xp(map,r.position)
    if not xp then if interactive then notify("Переход заблокирован: "..tostring(why2)) end;return end
    if last and last.body==r.body and last.xp==xp then
        if interactive then notify("Уже синхронизировано") end
        return
    end
    local current=self:current_xp()
    local changed=last and current and current~=last.xp
    local confirm=interactive or not last or changed
    if confirm then
        UIManager:show(ConfirmBox:new{
            text="AlReaderX → KOReader\n\n"..string.format("%s / %d",r.name,r.position)..
                "\n\n"..xp..(changed and "\n\nНа Kindle есть непрочитанные изменения!" or "").."\nПерейти?",
            ok_callback=function() self:commit_import(r,xp,false) end,
        })
    else
        self:commit_import(r,xp,true)
    end
end
function Bridge:choose_anchor()
    local r,err=self:current_record(true)
    if not r then return notify(err) end
    local map,why=self:position_map()
    if not map then return notify(why) end
    local xp,error_msg=mapper.toXPointer(map,r.position)
    local current=self:current_xp()
    local current_pos,reason=mapper.toAlReader(map,current,self:engine_text(current))
    notify(table.concat({"Проверка координат FB2/EPUB (без ручной калибровки)",
        "AlReaderX: "..r.position,
        "KOReader XPointer: "..tostring(xp or error_msg),
        "Текущая координата Kindle: "..tostring(current_pos or reason),
        "Внутренний размер текста: "..map.total},"\n"))
end
function Bridge:estimate_export_position(_r)
    local map,why=self:position_map()
    if not map then return nil,why end
    local xp=self:current_xp()
    local pos,err=mapper.toAlReader(map,xp,self:engine_text(xp))
    if not pos then return nil,err end
    return pos,xp
end
function Bridge:queue_export()
    local r=self.last_record
    if not r then return end
    local seen=self.settings.last_seen[r.key]
    if not seen or seen.content~=r.body then return end
    local pos=self:estimate_export_position(r)
    if not pos or pos==r.position then return end
    self.settings.pending[r.key]={position=pos,base=r.body,name=r.name}
    self:save()
end
function Bridge:flush_pending(interactive)
    if not NetworkMgr:isOnline() or not self:can_dav() then return end
    local r=self:current_record(false)
    if not r or r.source~="WebDAV" then return end
    local pending=self.settings.pending[r.key]
    if not pending then return end
    if r.body~=pending.base or not r.etag then
        if interactive then notify("Отложенная позиция конфликтует с обновлением AlReaderX. Перезапись запрещена.") end
        return
    end
    local new_body="!"..tostring(self.settings.sender_id).."!"..pending.position
    local dav=require("dav")
    local cfg={url=r.remote_url,user=self.settings.user,password=self.settings.password}
    local ok,err=dav.put_existing(cfg,r.name,new_body,r.etag)
    if not ok then if interactive then notify("Отложенная отправка не удалась: "..tostring(err)) end;return end
    self.settings.pending[r.key]=nil
    self.settings.last_seen[r.key]={content=new_body,source="WebDAV"}
    self.settings.last_applied[r.key]={body=new_body,xp=self:current_xp()}
    if self.last_record and self.last_record.key==r.key then
        self.last_record.body=new_body
        self.last_record.position=pending.position
        self.last_record.opaque=tostring(self.settings.sender_id)
    end
    self:save()
    if interactive then notify("Отложенная позиция успешно отправлена") end
end
function Bridge:export_position(interactive)
    if not self.settings.auto_export and not interactive then return end
    if not self:can_dav() then if interactive then notify("Для экспорта настрой WebDAV") end;return end
    if not NetworkMgr:isOnline() then
        self:queue_export()
        if interactive then notify("Нет Wi-Fi. Позиция сохранена локально для отправки позже.") end
        return
    end
    local r,why=self:current_record(interactive)
    if not r then if interactive then notify(why) end;return end
    if r.source~="WebDAV" then if interactive then notify("WebDAV не прочитан. Экспорт заблокирован.") end;return end
    local pos,details=self:estimate_export_position(r)
    if not pos then if interactive then notify("Экспорт заблокирован: "..tostring(details)) end;return end
    if pos==r.position then if interactive then notify("Позиция не изменилась") end;return end
    local seen=self.settings.last_seen[r.key]
    if not seen or seen.content~=r.body then
        if interactive then notify("На другом устройстве есть новая позиция. Сначала импортируй её.") end
        return
    end
    if not r.etag then if interactive then notify("WebDAV не поддерживает ETag: запись заблокирована") end;return end
    local sender=tostring(self.settings.sender_id or "")
    if not sender:match("^%d+$") then if interactive then notify("Некорректный ID Kindle") end;return end
    local new_body="!"..sender.."!"..pos
    local function finish()
        save_private(self.local_dir.."/"..r.name..".bridge-backup",r.body)
        local dav=require("dav")
        local cfg={url=r.remote_url or self.settings.dav_url,user=self.settings.user,password=self.settings.password}
        local ok,err=dav.put_existing(cfg,r.name,new_body,r.etag)
        if not ok then return notify("WebDAV: "..tostring(err)..". Данные не изменены.") end
        self.settings.last_seen[r.key]={content=new_body,source="WebDAV"}
        self.settings.last_applied[r.key]={body=new_body,xp=self:current_xp()}
        self.last_record.body=new_body;self.last_record.position=pos
        self:save()
        if interactive then notify("Точная позиция отправлена: "..pos) end
    end
    if interactive then
        UIManager:show(ConfirmBox:new{
            text="KOReader → AlReaderX\n\n"..pos.."\n"..details.."\n\nЗаписать на WebDAV?",
            ok_callback=finish,
        })
    else
        finish()
    end
end
function Bridge:test_webdav()
    if not self:can_dav() then return notify("Укажи HTTPS URL WebDAV-каталога") end
    if not NetworkMgr:isOnline() then return notify("Нет подключения к Wi-Fi") end
    local dav=require("dav")
    local base=self.settings.dav_url:gsub("/+$","")
    local folder=base
    if not base:match("/AlReaderX%-01Sync$") then folder=base.."/AlReaderX-01Sync" end
    local found,err=dav.list({url=folder,user=self.settings.user,password=self.settings.password})
    if not found then return notify("WebDAV: ошибка\n"..tostring(err).."\nКаталог: "..folder) end
    notify("WebDAV подключён. Записей в AlReaderX-01Sync: "..#found)
end
function Bridge:diagnostics()
    local r,why=self:current_record(true)
    if not r then return notify("AlReaderX Bridge: "..tostring(why)) end
    local map=self:position_map()
    notify(table.concat({
        "AlReaderX Bridge v1.4 — FB2/EPUB",
        "Книга: "..book_filename(self.ui.document.file),
        "Источник: "..r.source,
        "Файл: "..r.name,
        "Позиция: "..r.position,
        "Отправитель текущей записи: "..r.opaque,
        "ID Kindle: "..tostring(self.settings.sender_id),
        "Размер исходного файла: "..r.size,
        "XML-модель: "..(map and (tostring(map.total).." символов, полная") or "недоступна"),
        "WebDAV: "..boolword(self:can_dav()),
        "Автоимпорт: "..boolword(self.settings.auto_import),
        "Экспорт: "..(self.settings.auto_export and "при закрытии с проверкой XPointer" or "только вручную"),
    },"\n"))
end
function Bridge:configure(field,title,mask)
    local dialog
    dialog=InputDialog:new{
        title=title, input=self.settings[field] or "",
        buttons={{
            {text=_("Cancel"),id="close",callback=function()UIManager:close(dialog)end},
            {text=_("Save"),callback=function()
                local value=dialog:getInputText() or ""
                if (field=="dav_url" or field=="backup_dav_url") and value~="" and not value:match("^https://[^%s]+$") then
                    return notify("Нужен HTTPS URL WebDAV-каталога")
                end
                self.settings[field]=value
                if field=="dav_url" then self.settings.resolved_dav=nil end
                self:save()
                UIManager:close(dialog)
                if field=="password" then notify("Пароль сохранён локально в KOReader; хранится без шифрования") end
            end},
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end
function Bridge:onReaderReady()
    self.on_open_xp=self:current_xp()
    UIManager:nextTick(function()
        self:flush_pending(false)
        if self.settings.auto_import then self:import_position(false) end
    end)
end
function Bridge:onNetworkConnected()
    UIManager:scheduleIn(1,function() self:flush_pending(false) end)
end
function Bridge:onCloseDocument()
    if self.settings.auto_export then self:export_position(false) end
end
-- Backup & Restore is supplied as a pinned, separately maintained companion
-- plugin. No custom archive parser or destructive restore routine is duplicated.
-- Backup endpoint is configured per-user; never ship personal server URLs.

function Bridge:backup_ui()
    local ok, ui = pcall(require,"backup_ui")
    if not ok or type(ui)~="table" then
        notify("Компонент Device Backup & Restore не установлен или отключён. Установи отдельно backup.koplugin и перезапусти KOReader.")
        return nil
    end
    return ui
end

function Bridge:backup_action(name)
    local ui=self:backup_ui()
    if not ui then return end
    local actions={
        create="showCreateDialog",
        restore="showRestoreDialog",
        manage="showManageBackupsDialog",
        settings="showSettingsDialog",
    }
    local method=actions[name]
    if not method or type(ui[method])~="function" then
        return notify("Эта функция недоступна в установленном Backup & Restore")
    end
    local ok,err=pcall(ui[method])
    if not ok then notify("Backup & Restore: "..tostring(err)) end
end

function Bridge:setup_backup_cloud()
    if not self:can_dav() then
        return notify("Сначала настрой пароль AlReaderX WebDAV. Без него нельзя настроить общий сервер резервных копий.")
    end
    local backup_url=self.settings.backup_dav_url
    if type(backup_url)~="string" or not backup_url:match("^https://[^%s]+$") then
        return notify("Укажи HTTPS URL для резервных копий в меню Bridge: WebDAV — адрес бэкапов")
    end
    local ui=self:backup_ui()
    if not ui then return end
    UIManager:show(ConfirmBox:new{
        text="Подключить Device Backup & Restore к выбранному WebDAV?".. 
            "\n\nАдрес: "..backup_url..
            "\nКаталог: koreader_backups"..
            "\n\nБудет использован тот же логин и пароль, что для позиций AlReaderX."..
            "\nСекрет сохранится также в настройках Backup & Restore на Kindle."..
            "\nУдаление старых облачных копий отключено. Отправка — только при создании бэкапа или по расписанию, если отдельно включить.",
        ok_callback=function()
            local ok,err=pcall(function()
                local Cloud=require("backup_cloud")
                local settings=ui.getPluginSettings()
                if type(settings)~="table" then error("settings unavailable") end
                local creds={url=backup_url,username=self.settings.user,password=self.settings.password}
                if not Cloud.saveCredentials("webdav",creds) then error("credentials could not be saved") end
                settings.cloud_provider="webdav"
                settings.cloud_remote_dir="koreader_backups"
                settings.cloud_prune_remote=false
                settings.upload_to_cloud=true
                settings.auto_backup_enabled=settings.auto_backup_enabled==true
                ui.savePluginSettings()
            end)
            if not ok then return notify("Ошибка настройки резервных копий: "..tostring(err)) end
            notify("WebDAV для Backup & Restore настроен. Открой «Создать резервную копию» и отметь шрифты, стили и настройки. После восстановления перезапусти KOReader.")
        end,
    })
end

function Bridge:addToMainMenu(menu_items)
    menu_items.alreaderbridge={
        text="AlReaderX Bridge v1.4.0",sorting_hint="more_tools",
        sub_item_table={
            {text="Импортировать позицию сейчас",callback=function()self:import_position(true)end},
            {text="Показать соответствие координат",callback=function()self:choose_anchor()end},
            {text="Отправить текущую позицию",callback=function()self:export_position(true)end},
            {text="Диагностика",callback=function()self:diagnostics()end,separator=true},
            {text="Автоимпорт при открытии",checked_func=function()return self.settings.auto_import end,
                callback=function()self.settings.auto_import=not self.settings.auto_import;self:save()end},
            {text="Автоэкспорт при закрытии (с защитой)",checked_func=function()return self.settings.auto_export end,
                callback=function()self.settings.auto_export=not self.settings.auto_export;self:save()end,separator=true},
            {text="Отправить отложенную позицию",callback=function()self:flush_pending(true)end},
            {text="Проверить подключение WebDAV",callback=function()self:test_webdav()end},
            {text="WebDAV: адрес каталога",callback=function()self:configure("dav_url","HTTPS URL WebDAV (конечный каталог)")end},
            {text="WebDAV: логин",callback=function()self:configure("user","WebDAV имя пользователя")end},
            {text="WebDAV: пароль",callback=function()self:configure("password","WebDAV пароль (будет сохранён в настройках)")end},
            {text="Локальный каталог: koreader/alreaderx-sync",callback=function()notify(self.local_dir)end,separator=true},
            {text="Резервная копия KOReader: создать",callback=function()self:backup_action("create")end},
            {text="Резервная копия KOReader: восстановить",callback=function()self:backup_action("restore")end},
            {text="Резервные копии: локальные и облачные",callback=function()self:backup_action("manage")end},
            {text="WebDAV: адрес резервных копий",callback=function()self:configure("backup_dav_url","HTTPS URL WebDAV для резервных копий")end},
            {text="Настроить WebDAV резервных копий",callback=function()self:setup_backup_cloud()end},
            {text="Расписание бэкапов и другие настройки",callback=function()self:backup_action("settings")end},
        },
    }
end
return Bridge
