import Foundation

extension DocumentPrinter {
    /// Runs after fonts/math at the real printable width. Repairs overflowing equation galleries,
    /// while leaving ordinary data tables and every authored colour/font untouched.
    static let layoutValidationScript = #"""
    (() => {
      const report = {reflowedMathTables:0,wrappedMath:0,mathOverflow:0,brokenImages:0,bodyOverflow:0};
      const style = document.createElement('style');
      style.textContent = `html,body{width:auto!important;height:auto!important;min-height:0!important;overflow:visible!important}body{margin:0!important}
        main,article,.document,.page,.sheet{max-width:100%!important;box-sizing:border-box!important}
        .firas-print-math-table,.firas-print-math-table>thead,.firas-print-math-table>tbody,.firas-print-math-table>tfoot{display:block!important;width:100%!important;max-width:100%!important;box-sizing:border-box!important}
        .firas-print-math-table tr{display:block!important;width:auto!important;height:auto!important;break-inside:auto!important;page-break-inside:auto!important}
        .firas-print-math-table th,.firas-print-math-table td{display:block!important;width:auto!important;max-width:100%!important;height:auto!important;box-sizing:border-box!important;break-inside:avoid!important;page-break-inside:avoid!important}
        .firas-wrap-math>.katex-html{display:block!important;white-space:normal!important;line-height:1.8}
        .firas-wrap-math>.katex-html>.base{margin-block:0.12em}
        img,figure>svg{max-width:100%;height:auto}figure{break-inside:avoid;page-break-inside:avoid}`;
      document.head.appendChild(style);
      function innerWidth(node) {
        const css = getComputedStyle(node);
        return Math.max(1, node.clientWidth - (parseFloat(css.paddingLeft)||0) - (parseFloat(css.paddingRight)||0));
      }
      function mathWidth(node) {
        const html = node.querySelector('.katex-html');
        // A block's box can be narrow while the actual equation ink spills out of it. Measure
        // KaTeX's atomic base boxes, not only its containing span's CSS width.
        const bases = Array.from(node.querySelectorAll(':scope > .katex-html > .base'));
        const natural = bases.reduce((sum, base) => sum + base.getBoundingClientRect().width, 0);
        return Math.max(natural, node.getBoundingClientRect().width, html ? html.getBoundingClientRect().width : 0);
      }
      function container(node) { return node.closest('td,th') || node.parentElement; }
      for (const table of document.querySelectorAll('table')) {
        const cells = Array.from(table.querySelectorAll('td'));
        const formulas = cells.filter(cell => cell.querySelector('.katex'));
        if (!cells.length || formulas.length < Math.ceil(cells.length / 2)) continue;
        const tooNarrow = formulas.some(cell => Array.from(cell.querySelectorAll('.katex')).some(math => mathWidth(math) > innerWidth(cell) + 2));
        if (!tooNarrow) continue;
        // This is an equation gallery whose columns cannot contain their content at readable size.
        // A regular table with descriptive headers/data retains its tabular structure.
        const headers = Array.from(table.querySelectorAll('th'));
        if (headers.filter(cell => cell.colSpan <= 1).length > 1) continue;
        table.classList.add('firas-print-math-table');
        report.reflowedMathTables++;
      }
      for (const math of document.querySelectorAll('.katex')) {
        const parent = container(math);
        if (!parent || mathWidth(math) <= innerWidth(parent) + 2) continue;
        // KaTeX's top-level base boxes are semantic break opportunities. Keep every fraction,
        // radical and matrix intact; never slice a bitmap or shrink an equation to tiny text.
        math.classList.add('firas-wrap-math');
        math.style.setProperty('white-space','normal','important');
        report.wrappedMath++;
      }
      for (const math of document.querySelectorAll('.katex')) {
        const parent = container(math);
        if (!parent) continue;
        const available = innerWidth(parent);
        const bases = Array.from(math.querySelectorAll(':scope > .katex-html > .base'));
        const widest = bases.length ? Math.max(...bases.map(node => node.getBoundingClientRect().width)) : mathWidth(math);
        if (widest > available + 2) report.mathOverflow++;
      }
      for (const image of document.images) {
        if (!image.complete || !image.naturalWidth || !image.naturalHeight) report.brokenImages++;
      }
      report.bodyOverflow = Math.max(0, document.body.scrollWidth - document.documentElement.clientWidth);
      return report;
    })()
    """#
}
