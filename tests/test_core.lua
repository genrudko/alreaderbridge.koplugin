local src=debug.getinfo(1,"S").source:sub(2)
local testdir=src:match("^(.*)[/\\][^/\\]+$") or "."
package.path=testdir.."/../alreaderbridge.koplugin/?.lua;"..package.path
local core=require("core")
local record=assert(core.parse("!-1717171717!231644"))
assert(record.opaque=="-1717171717" and record.position==231644)
assert(not core.parse("!a!231644"))
assert(not core.parse("!1!-3"))
local filename="abr_fixture_book.1234.05.6e5.abcdef1234567890"
local info=assert(core.sync_filename(filename))
assert(info.size==1765)
assert(not core.sync_filename("../escape"))
print("PASS: signed sync ID, bounded record parser and filename validation")
