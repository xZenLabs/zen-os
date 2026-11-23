require("ffi/loadlib")

local Archiver = require("ffi/archiver")
local ComicInfo = require("common/comic_info")

local XML = [==[<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Title>Romance Dawn &amp; Beyond</Title>
  <Series>One Piece</Series>
  <SeriesGroup>Shonen Jump</SeriesGroup>
  <Number>1.5</Number>
  <AlternateNumber>9</AlternateNumber>
  <Volume>2016</Volume>
  <Summary><![CDATA[Luffy sets sail.]]></Summary>
  <Writer>Eiichiro Oda, Second Writer</Writer>
  <Penciller>Someone Else</Penciller>
  <Genre>Action, Adventure</Genre>
  <Tags>Pirates, Action</Tags>
  <LanguageISO>en</LanguageISO>
  <Pages><Page Image="0" Type="FrontCover" /></Pages>
</ComicInfo>]==]

describe("comic info", function()
    local root

    local function make_cbz(name, entries)
        local path = root .. "/" .. name
        local writer = Archiver.Writer:new()
        assert.is_true(writer:open(path, "zip"))
        for _i, entry in ipairs(entries) do
            assert.is_true(writer:addFileFromMemory(entry[1], entry[2]))
        end
        writer:close()
        return path
    end

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert.is_true(require("libs/libkoreader-lfs").mkdir(root))
    end)

    after_each(function()
        os.execute(("rm -rf %q"):format(root))
    end)

    it("maps ComicInfo fields to document properties", function()
        assert.are.same({
            title = "Romance Dawn & Beyond",
            authors = "Eiichiro Oda\nSecond Writer",
            series = "One Piece #1.5",
            language = "en",
            keywords = "Action\nAdventure\nPirates",
            description = "Luffy sets sail.",
        }, ComicInfo.parse(XML))
    end)

    it("falls back to the artist and volume, and skips non-numeric numbers", function()
        assert.are.same({ authors = "Artist", series = "Saga #3" }, ComicInfo.parse(
            "<ComicInfo><Series>Saga</Series><Volume>3</Volume><Penciller>Artist</Penciller></ComicInfo>"))
        assert.are.same({ series = "Saga" }, ComicInfo.parse(
            "<ComicInfo><Series>Saga</Series><Number>Annual 1</Number><Volume>3</Volume><Title> </Title></ComicInfo>"))
        assert.are.same({}, ComicInfo.parse("<ComicInfo/>"))
    end)

    it("reads ComicInfo.xml from the archive", function()
        local tagged = make_cbz("tagged.cbz", { { "001.png", "page" }, { "Book/comicinfo.XML", XML } })
        assert.are.equal("Romance Dawn & Beyond", ComicInfo.read(tagged).title)
        assert.is_nil(ComicInfo.read(make_cbz("plain.cbz", { { "001.png", "page" } })))
        assert.is_nil(ComicInfo.read(make_cbz("huge.cbz", { { "ComicInfo.xml", XML .. (" "):rep(1024 * 1024) } })))
    end)

    describe("document hook", function()
        local saved, meta, saves, statements

        before_each(function()
            saved = { package.loaded["document/pdfdocument"], package.loaded["bookinfomanager"] }
            meta, saves, statements = {}, 0, {}
            ZenSpec.replace("document/pdfdocument", {
                getDocumentProps = function() return { title = "", author = "" } end,
            })
            ZenSpec.replace("bookinfomanager", {
                openDbConnection = function(self)
                    self.db_conn = { exec = function(_self, sql) statements[#statements + 1] = sql end }
                end,
            })
            ComicInfo.install({ config = { _meta = meta }, saveConfig = function() saves = saves + 1 end })
        end)

        after_each(function()
            package.loaded["document/pdfdocument"], package.loaded["bookinfomanager"] = saved[1], saved[2]
        end)

        it("fills cbz properties and leaves other documents and subclasses alone", function()
            local PdfDocument = require("document/pdfdocument")
            local tagged = make_cbz("tagged.CBZ", { { "ComicInfo.xml", XML } })
            local props = PdfDocument.getDocumentProps({ file = tagged })
            assert.are.equal("Romance Dawn & Beyond", props.title)
            assert.are.equal("One Piece #1.5", props.series)
            assert.are.equal("", props.author)

            assert.are.same({ title = "", author = "" },
                PdfDocument.getDocumentProps({ file = make_cbz("plain.cbz", { { "001.png", "page" } }) }))
            assert.are.same({ title = "", author = "" },
                PdfDocument.getDocumentProps({ file = make_cbz("tagged.zip", { { "ComicInfo.xml", XML } }) }))

            local Subclass = setmetatable({ getDocumentProps = function() return { title = "Own" } end },
                { __index = PdfDocument })
            assert.are.same({ title = "Own" }, Subclass.getDocumentProps({ file = tagged }))
        end)

        it("drops metadata-less cbz cache rows once", function()
            assert.are.equal(1, #statements)
            assert.matches("DELETE FROM bookinfo WHERE filename LIKE '%.cbz' AND has_meta IS NULL", statements[1], 1, true)
            assert.is_true(meta.comic_info_cache_migrated)
            assert.are.equal(1, saves)
            ComicInfo.install({ config = { _meta = meta }, saveConfig = function() saves = saves + 1 end })
            assert.are.equal(1, #statements)
            assert.are.equal(1, saves)
        end)
    end)
end)
