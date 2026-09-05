import Foundation

extension DocumentPrinter {
    /// Runs after fonts/math at the real printable width. Repairs overflowing equation galleries,
    /// while leaving ordinary data tables and every authored colour/font untouched.
    static let layoutValidationScript = #"""
    (() => {
      const report = {reflowedMathTables:0,reflowedContainers:0,reflowedMathGrids:0,paginatedMathLayouts:0,wrappedMath:0,mathOverflow:0,brokenImages:0,bodyOverflow:0};
      const style = document.createElement('style');
      style.textContent = `html,body{width:auto!important;height:auto!important;min-height:0!important;overflow:visible!important}body{margin:0!important}
        main,article,.document,.page,.sheet{max-width:100%!important;box-sizing:border-box!important}
        .firas-print-math-table,.firas-print-math-table>thead,.firas-print-math-table>tbody,.firas-print-math-table>tfoot{display:block!important;width:100%!important;max-width:100%!important;box-sizing:border-box!important}
        .firas-print-math-table tr{display:block!important;width:auto!important;height:auto!important;break-inside:auto!important;page-break-inside:auto!important}
        .firas-print-math-table th,.firas-print-math-table td{display:block!important;width:auto!important;max-width:100%!important;height:auto!important;box-sizing:border-box!important;break-inside:avoid!important;page-break-inside:avoid!important}
        .firas-print-math-flow{display:block!important;columns:auto!important;height:auto!important;max-height:none!important;overflow:visible!important;break-inside:auto!important;page-break-inside:auto!important}
        .firas-print-math-flow>*{display:block!important;width:auto!important;max-width:100%!important;height:auto!important;min-height:0!important;box-sizing:border-box!important;break-inside:avoid!important;page-break-inside:avoid!important}
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
      function container(node) {
        const cell = node.closest('td,th');
        if (cell) return cell;
        // The math walker inserts an inline span. Inline spans have clientWidth=0 even when
        // their visible equation fits perfectly; only a real layout box owns available width.
        for (let parent = node.parentElement; parent; parent = parent.parentElement) {
          const display = getComputedStyle(parent).display;
          if (display !== 'inline' && display !== 'contents' && parent.clientWidth > 0) return parent;
        }
        return document.body;
      }
      // Authored A4 wrappers often include the full 210mm paper width plus padding. UIKit
      // already reserves margins. Fit those boxes to the printable area without scaling text.
      for (const node of document.querySelectorAll('main,article,section,header,footer,aside,div,figure,ol,ul')) {
        if (node.closest('.katex,.katex-display,svg')) continue;
        const display = getComputedStyle(node).display;
        if (display === 'inline' || display === 'contents') continue;
        const parent = container(node);
        if (parent && node.getBoundingClientRect().width > innerWidth(parent) + 2) {
          node.style.setProperty('max-width','100%','important');
          node.style.setProperty('min-width','0','important');
          node.style.setProperty('box-sizing','border-box','important');
          report.reflowedContainers++;
        }
      }
      // WebKit's print formatter can slice CSS grid/flex items across page boundaries even
      // with break-inside:avoid. A long equation collection needs ordinary block fragmentation.
      // Short authored layouts keep their columns, colours and fonts.
      const pageHeight = Number(document.documentElement.dataset.firasPrintableHeight) || 970;
      for (const layout of document.querySelectorAll('main,article,section,div,ol,ul')) {
        if (layout.closest('.katex,.katex-display,svg') || layout.children.length < 2) continue;
        const css = getComputedStyle(layout);
        const compound = ['grid','inline-grid','flex','inline-flex'].includes(css.display) || parseInt(css.columnCount,10) > 1;
        if (!compound || !layout.querySelector('.katex') || layout.getBoundingClientRect().height <= pageHeight) continue;
        layout.classList.add('firas-print-math-flow');
        layout.style.setProperty('display','block','important');
        layout.style.setProperty('columns','auto','important');
        for (const child of layout.children) {
          child.style.setProperty('break-inside','avoid','important');
          child.style.setProperty('page-break-inside','avoid','important');
        }
        report.paginatedMathLayouts++;
      }
      for (const math of document.querySelectorAll('.katex')) {
        let parent = container(math);
        if (!parent) continue;
        for (let layout = parent; layout && layout !== document.body; layout = layout.parentElement) {
          const css = getComputedStyle(layout);
          const cramped = mathWidth(math) > innerWidth(parent) + 2 || layout.scrollWidth > layout.clientWidth + 2;
          let changed = false;
          if (cramped && (css.display === 'grid' || css.display === 'inline-grid') && layout.children.length > 1) {
            layout.style.setProperty('grid-template-columns','minmax(0,1fr)','important');
            layout.style.setProperty('grid-auto-flow','row','important');
            for (const child of layout.children) {
              child.style.setProperty('grid-column','auto','important');
              child.style.setProperty('min-width','0','important');
            }
            report.reflowedMathGrids++;
            changed = true;
          } else if (cramped && css.display === 'flex' && css.flexDirection.startsWith('row') && layout.children.length > 1) {
            layout.style.setProperty('flex-direction','column','important');
            report.reflowedMathGrids++;
            changed = true;
          } else if (cramped && parseInt(css.columnCount,10) > 1) {
            layout.style.setProperty('columns','auto','important');
            report.reflowedMathGrids++;
            changed = true;
          }
          parent = container(math);
          if (changed && mathWidth(math) <= innerWidth(parent) + 2) break;
        }
      }
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
