#!/usr/bin/env python3
"""Validate the mounted file-card smoke PDF, using its actually visible text.

Install the exact tested parser: python -m pip install PyMuPDF==1.27.2.3
Usage: python ios/scripts/validate-final-pdf.py /path/to/evidence

PDFKit includes fully clipped duplicate labels in WebKit print output. PyMuPDF's
default text extraction respects those PDF clipping instructions. Keep its version
and default extraction flags fixed: run65 must fail and corrected run66 must pass.
This is a fixture check for 100 problems plus 100 solutions, each with one integral.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys


PYMUPDF_VERSION = "1.27.2.3"
MARGIN_TOLERANCE_PT = 5.0
ERROR_PREFIX = "[final-pdf] "


def inspect_pdf(evidence: Path, smoke: dict) -> dict:
    import fitz

    if fitz.VersionBind != PYMUPDF_VERSION:
        raise ValueError(f"Install PyMuPDF=={PYMUPDF_VERSION}; found {fitz.VersionBind}")
    pdf_path = evidence / "reliability-100-integrals.pdf"
    geometry = smoke.get("fileCardExportDiagnostics", {}).get("printableRect")
    if not isinstance(geometry, list) or len(geometry) != 4:
        raise ValueError("The smoke report has no printableRect for the file-card PDF")
    if any(isinstance(value, bool) or not isinstance(value, (int, float))
           or not math.isfinite(value) for value in geometry):
        raise ValueError("The printableRect contains invalid coordinates")
    x, y, width, height = geometry
    if width <= 0 or height <= 0:
        raise ValueError("The printableRect must have positive width and height")
    printable = fitz.Rect(x, y, x + width, y + height)
    allowed = printable + (-MARGIN_TOLERANCE_PT, -MARGIN_TOLERANCE_PT,
                           MARGIN_TOLERANCE_PT, MARGIN_TOLERANCE_PT)
    result = {
        "status": "passed", "errors": [], "pymupdfVersion": fitz.VersionBind,
        "mupdfVersion": fitz.VersionFitz, "marginTolerancePoints": MARGIN_TOLERANCE_PT,
        "pdfSHA256": hashlib.sha256(pdf_path.read_bytes()).hexdigest(),
        "printableRect": geometry, "visibleLabels": 0, "visibleIntegrals": 0,
        "checkedCharacters": 0, "fullyClippedCharacters": 0,
        "outsideCharacters": 0, "outsidePages": [], "separatedEntryPages": [],
        "maximumMarginExcessPoints": 0.0, "pages": [],
    }
    errors = result["errors"]
    visible_entries = []
    with fitz.open(pdf_path) as document:
        result["pageCount"] = len(document)
        if len(document) < 2:
            errors.append("The full 100-integral document is not paginated")
        for index, page in enumerate(document):
            page_number = index + 1
            if page.rotation != 0:
                raise ValueError(f"Unexpected rotation on fixture page {page_number}")
            # Use PyMuPDF defaults: disabling clipping would resurrect invisible PDF text.
            chars = [char for block in page.get_text("rawdict")["blocks"]
                     if "lines" in block for line in block["lines"]
                     for span in line["spans"] for char in span["chars"]
                     if char["c"].strip()]
            visible = [char for char in chars if fitz.Rect(char["bbox"]).intersects(printable)]
            text = "".join(char["c"] for char in visible)
            entries = re.findall(r"(?:PROBLEM|SOLUTION)-\d{3}", text)
            visible_entries.extend(entries)
            labels = len(entries)
            integrals = text.count("∫")
            outside = 0
            for char in visible:
                bounds = fitz.Rect(char["bbox"])
                excess = max(0.0, printable.x0 - bounds.x0, printable.y0 - bounds.y0,
                             bounds.x1 - printable.x1, bounds.y1 - printable.y1)
                result["maximumMarginExcessPoints"] = max(result["maximumMarginExcessPoints"], excess)
                if not allowed.contains(bounds):
                    outside += 1
            result["visibleLabels"] += labels
            result["visibleIntegrals"] += integrals
            result["checkedCharacters"] += len(visible)
            result["fullyClippedCharacters"] += len(chars) - len(visible)
            result["outsideCharacters"] += outside
            result["pages"].append({"page": page_number, "labels": labels,
                                    "integrals": integrals, "outsideCharacters": outside})
            if outside:
                result["outsidePages"].append(page_number)
            if labels != integrals:
                result["separatedEntryPages"].append(page_number)
                errors.append(f"Page {page_number} separates labels from formulas ({labels}/{integrals})")
        if result["outsideCharacters"]:
            errors.append(f"{result['outsideCharacters']} visible characters cross printable margins")
        if result["visibleLabels"] != 200 or result["visibleIntegrals"] != 200:
            errors.append("The PDF must visibly contain 200 entry labels and 200 integral symbols")
        expected = [f"{kind}-{number:03d}" for kind in ("PROBLEM", "SOLUTION") for number in range(1, 101)]
        result["visibleEntryOrderVerified"] = visible_entries == expected
        if not result["visibleEntryOrderVerified"]:
            errors.append("Visible problem/solution identifiers are missing, duplicated or out of order")
        if len(document):
            last = document[-1]
            no_text = not last.get_text().strip()
            pixmap = last.get_pixmap(matrix=fitz.Matrix(0.5, 0.5), colorspace=fitz.csGRAY, alpha=False)
            ink = sum(value < 248 for value in pixmap.samples)
            result["lastPageHasText"] = not no_text
            result["lastPageInkPixels"] = ink
            result["blankTrailingPage"] = no_text and ink == 0
            if result["blankTrailingPage"]:
                errors.append("The PDF has a completely blank trailing page")
    if errors:
        result["status"] = "failed"
    return result


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence_dir", type=Path)
    args = parser.parse_args()
    evidence = args.evidence_dir.resolve()
    report_path = evidence / "reliability-smoke.json"
    try:
        smoke = json.loads(report_path.read_text(encoding="utf-8"))
        if not isinstance(smoke, dict) or not isinstance(smoke.get("errors", []), list):
            raise ValueError("The smoke report must be an object with an errors array")
    except (OSError, ValueError) as error:
        print(f"Final PDF validation cannot read its smoke report: {error}", file=sys.stderr)
        return 2
    try:
        result = inspect_pdf(evidence, smoke)
    except Exception as error:
        result = {"status": "failed", "errors": [f"Final PDF inspection failed: {error}"],
                  "requiredPyMuPDFVersion": PYMUPDF_VERSION}
    write_json(evidence / "final-pdf-qa.json", result)
    smoke["finalPDF"] = result
    if result["errors"]:
        # Preserve every pre-existing native failure. This validator cannot clear another test.
        existing = list(smoke.get("errors", []))
        for error in result["errors"]:
            qualified = ERROR_PREFIX + error
            if qualified not in existing:
                existing.append(qualified)
        smoke["errors"] = existing
        smoke["status"] = "failed"
    write_json(report_path, smoke)
    print(json.dumps({"status": result["status"], "pages": result.get("pageCount"),
                      "visibleLabels": result.get("visibleLabels"),
                      "visibleIntegrals": result.get("visibleIntegrals"),
                      "outsidePages": result.get("outsidePages"),
                      "errors": result["errors"]}, ensure_ascii=False))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
