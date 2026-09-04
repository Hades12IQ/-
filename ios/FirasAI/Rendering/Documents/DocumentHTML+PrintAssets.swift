import Foundation

extension DocumentHTML {
    /// Licensed local faces for Arabic shaping and Latin/Greek/Cyrillic. Other scripts use iOS's
    /// native fallback cascade. Embedded faces also work in a saved, offline HTML document.
    static let documentFontCSS: String = {
        var css = ""
        for (name, family) in [("NotoSansArabic", "Firas Document Arabic"), ("NotoSans", "Firas Document Sans")] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "DocumentFonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/DocumentFonts")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            guard let url, let bytes = try? Data(contentsOf: url) else { continue }
            css += "@font-face{font-family:'" + family + "';font-style:normal;font-weight:100 900;src:url(data:font/ttf;base64,"
                + bytes.base64EncodedString() + ") format('truetype');font-display:block}\n"
        }
        css += """
        :where(body){font-family:'Firas Document Arabic','Firas Document Sans','Geeza Pro',system-ui,sans-serif;font-size:12pt;line-height:1.8}
        :where(body[dir='ltr'],html[dir='ltr'] body){font-family:'Firas Document Sans','Firas Document Arabic',system-ui,sans-serif}
        .katex,.katex-display{direction:ltr;unicode-bidi:isolate}
        .katex-display{break-inside:avoid;page-break-inside:avoid}
        @media print{.katex-mathml{display:none!important}img,svg{max-width:100%}p,li{orphans:3;widows:3}}
        """
        return css
    }()

    /// The authored document has no network or application session. A navigation delegate only
    /// handles navigations, so subresource requests also need an explicit document policy.
    static let documentCSP = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src firas-katex: 'unsafe-inline'; style-src firas-katex: 'unsafe-inline'; font-src firas-katex: data:; img-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'\">"
}
