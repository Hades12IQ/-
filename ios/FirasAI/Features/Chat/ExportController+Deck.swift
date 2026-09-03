import Foundation

/// The parts of a `.pptx` that never change: the content types, the relationship graph, the one
/// slide master, the one blank layout, and the theme a viewer insists on before it will open the
/// deck at all.
///
/// Split out of `ExportController+Slides.swift` because it is pure boilerplate — the interesting
/// half of a deck is the slides, and that file should be readable without scrolling past a theme.
extension ExportSlides {

    static func contentTypes(count: Int) -> String {
        var out = ExportOOXML.declaration
        out += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        out += "<Default Extension=\"rels\""
        out += " ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        out += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        out += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
        out += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
        out += "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
        out += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        out += "<Override PartName=\"/docProps/core.xml\" ContentType=\""
        out += "application/vnd.openxmlformats-package.core-properties+xml\"/>"
        for index in 0..<max(1, count) {
            out += "<Override PartName=\"/ppt/slides/slide"
            out += String(index + 1)
            out += ".xml\" ContentType=\""
            out += "application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        out += "</Types>"
        return out
    }

    static func packageRelationships() -> String {
        ExportOOXML.relationships([
            ("rId1", ExportOOXML.officeRelationships + "/officeDocument", "ppt/presentation.xml"),
            (
                "rId2",
                ExportOOXML.relationshipsNamespace + "/metadata/core-properties",
                "docProps/core.xml"
            )
        ])
    }

    /// 12 192 000 × 6 858 000 EMU is 13.333 × 7.5 inches — 16:9.
    static func presentation(count: Int) -> String {
        var out = ExportOOXML.declaration
        out += "<p:presentation xmlns:a=\""
        out += drawingNamespace
        out += "\" xmlns:r=\""
        out += ExportOOXML.officeRelationships
        out += "\" xmlns:p=\""
        out += presentationNamespace
        out += "\">"
        out += "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
        out += "<p:sldIdLst>"
        for index in 0..<max(1, count) {
            out += "<p:sldId id=\""
            out += String(256 + index)
            out += "\" r:id=\"rId"
            out += String(index + 2)
            out += "\"/>"
        }
        out += "</p:sldIdLst>"
        out += "<p:sldSz cx=\"12192000\" cy=\"6858000\"/>"
        out += "<p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
        out += "</p:presentation>"
        return out
    }

    static func presentationRelationships(count: Int) -> String {
        var entries: [(String, String, String)] = []
        entries.append(
            (
                "rId1",
                ExportOOXML.officeRelationships + "/slideMaster",
                "slideMasters/slideMaster1.xml"
            )
        )
        for index in 0..<max(1, count) {
            entries.append(
                (
                    "rId" + String(index + 2),
                    ExportOOXML.officeRelationships + "/slide",
                    "slides/slide" + String(index + 1) + ".xml"
                )
            )
        }
        entries.append(
            (
                "rId" + String(max(1, count) + 2),
                ExportOOXML.officeRelationships + "/theme",
                "theme/theme1.xml"
            )
        )
        return ExportOOXML.relationships(entries)
    }

    static func masterRelationships() -> String {
        ExportOOXML.relationships([
            (
                "rId1",
                ExportOOXML.officeRelationships + "/slideLayout",
                "../slideLayouts/slideLayout1.xml"
            ),
            ("rId2", ExportOOXML.officeRelationships + "/theme", "../theme/theme1.xml")
        ])
    }

    static func layoutRelationships() -> String {
        ExportOOXML.relationships([
            (
                "rId1",
                ExportOOXML.officeRelationships + "/slideMaster",
                "../slideMasters/slideMaster1.xml"
            )
        ])
    }

    static func slideRelationships() -> String {
        ExportOOXML.relationships([
            (
                "rId1",
                ExportOOXML.officeRelationships + "/slideLayout",
                "../slideLayouts/slideLayout1.xml"
            )
        ])
    }

    static func emptyTree() -> String {
        var out = "<p:spTree>"
        out += "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        out += "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/>"
        out += "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        out += "</p:spTree>"
        return out
    }

    static func slideMaster() -> String {
        var out = ExportOOXML.declaration
        out += "<p:sldMaster xmlns:a=\""
        out += drawingNamespace
        out += "\" xmlns:r=\""
        out += ExportOOXML.officeRelationships
        out += "\" xmlns:p=\""
        out += presentationNamespace
        out += "\">"
        out += "<p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill>"
        out += "<a:effectLst/></p:bgPr></p:bg>"
        out += emptyTree()
        out += "</p:cSld>"
        out += "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\""
        out += " accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\""
        out += " accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        out += "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>"
        out += "</p:sldMaster>"
        return out
    }

    static func slideLayout() -> String {
        var out = ExportOOXML.declaration
        out += "<p:sldLayout xmlns:a=\""
        out += drawingNamespace
        out += "\" xmlns:r=\""
        out += ExportOOXML.officeRelationships
        out += "\" xmlns:p=\""
        out += presentationNamespace
        out += "\" type=\"blank\" preserve=\"1\">"
        out += "<p:cSld name=\"Blank\">"
        out += emptyTree()
        out += "</p:cSld>"
        out += "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
        out += "</p:sldLayout>"
        return out
    }

    // MARK: - Theme

    /// The minimum a viewer will accept: twelve scheme colours, two font faces, and three entries in
    /// every format list. Nothing in a generated slide reads from it — every run names its own
    /// colour and face — but PowerPoint refuses to open a deck whose master has no theme.
    static func theme() -> String {
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        var line = "<a:ln w=\"6350\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">"
        line += fill
        line += "<a:prstDash val=\"solid\"/></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"

        var out = ExportOOXML.declaration
        out += "<a:theme xmlns:a=\""
        out += drawingNamespace
        out += "\" name=\"Firas\"><a:themeElements>"

        out += "<a:clrScheme name=\"Firas\">"
        out += "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>"
        out += "<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
        out += "<a:dk2><a:srgbClr val=\"111418\"/></a:dk2>"
        out += "<a:lt2><a:srgbClr val=\"F2F4F7\"/></a:lt2>"
        let accents = ["1F6F6B", "2E7D6B", "4C6EF5", "F08C00", "E03131", "7048E8"]
        for (index, value) in accents.enumerated() {
            let tag = "accent" + String(index + 1)
            out += "<a:"
            out += tag
            out += "><a:srgbClr val=\""
            out += value
            out += "\"/></a:"
            out += tag
            out += ">"
        }
        out += "<a:hlink><a:srgbClr val=\"1F6F6B\"/></a:hlink>"
        out += "<a:folHlink><a:srgbClr val=\"7048E8\"/></a:folHlink>"
        out += "</a:clrScheme>"

        out += "<a:fontScheme name=\"Firas\">"
        out += "<a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/>"
        out += "<a:cs typeface=\"Arial\"/></a:majorFont>"
        out += "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/>"
        out += "<a:cs typeface=\"Arial\"/></a:minorFont>"
        out += "</a:fontScheme>"

        out += "<a:fmtScheme name=\"Firas\"><a:fillStyleLst>"
        out += fill
        out += fill
        out += fill
        out += "</a:fillStyleLst><a:lnStyleLst>"
        out += line
        out += line
        out += line
        out += "</a:lnStyleLst><a:effectStyleLst>"
        out += effect
        out += effect
        out += effect
        out += "</a:effectStyleLst><a:bgFillStyleLst>"
        out += fill
        out += fill
        out += fill
        out += "</a:bgFillStyleLst></a:fmtScheme>"

        out += "</a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
        return out
    }
}
