#!/usr/bin/env python3
"""Assembly files for manufacturers other than JLCPCB (NextPCB, PCBWay, ...).

Reads fabrication/bom.csv and fabrication/cpl.csv (JLCPCB format with LCSC numbers) and writes
  fabrication/bom-mpn.csv / bom-mpn.xlsx  - S/N, Designator, Quantity, Manufacturer Part Number,
                                           Manufacturer, Description, Footprint, LCSC Part #
  fabrication/cpl.xlsx                    - the placement file as an Excel sheet
Usage: python3 make_assembly_files.py [fabrication directory ...]
"""
import csv
import pathlib
import sys
import zipfile
from xml.sax.saxutils import escape

# LCSC number -> (manufacturer part number, manufacturer), checked against the LCSC product pages
MPN = {
    "C113053": ("LQG15HN1N5S02D", "Murata"), "C113055": ("LQG15HN39NJ02D", "Murata"),
    "C11702": ("0402WGF1001TCE", "UNI-ROYAL"), "C12891": ("CL31A226KAHNNNE", "Samsung Electro-Mechanics"),
    "C14663": ("CC0603KRX7R9BB104", "YAGEO"), "C15127": ("AO3401A", "AOS"),
    "C15195": ("CL05B103KB5NNNC", "Samsung Electro-Mechanics"), "C1523": ("0402B102K500NT", "FH"),
    "C1546": ("0402CG101J500NT", "FH"), "C1555": ("0402CG220J500NT", "FH"), "C1567": ("0402CG470J500NT", "FH"),
    "C1573": ("0402CG5R0C500NT", "FH"), "C160404": ("SM04B-SRSS-TB(LF)(SN)", "JST"),
    "C162555": ("LQG18HN68NJ00D", "Murata"), "C165948": ("TYPE-C-31-M-12", "Korean Hroparts Elec"),
    "C17168": ("0402WGF0000TCE", "UNI-ROYAL"), "C1811": ("0805CG3R3C500NT", "FH"),
    "C19666": ("CL10A475KO8NNNC", "Samsung Electro-Mechanics"), "C19702": ("CL10A106KP8NNNC", "Samsung Electro-Mechanics"),
    "C21004": ("SMD1812P300TF", "RUILON"), "C21189": ("0603WAF0000T5E", "UNI-ROYAL"),
    "C21190": ("0603WAF1001T5E", "UNI-ROYAL"), "C2286": ("KT-0603R", "Hubei KENTO Elec"),
    "C23162": ("0603WAF4701T5E", "UNI-ROYAL"), "C23186": ("0603WAF5101T5E", "UNI-ROYAL"),
    "C23242": ("0603WAF7502T5E", "UNI-ROYAL"), "C25744": ("0402WGF1002TCE", "UNI-ROYAL"),
    "C25804": ("0603WAF1002T5E", "UNI-ROYAL"), "C3151650": ("USB4125-GF-A", "Global Connector Technology"),
    "C441735": ("LQG18HN5N6S00D", "Murata"), "C4748685": ("SE2435L-R", "Skyworks"),
    "C496551": ("BWSMA-KWE-Z001", "BAT WIRELESS"), "C544759": ("TLV75901PDRVR", "Texas Instruments"),
    "C72043": ("19-217/GHC-YR1S2/3T", "Everlight"), "C7519": ("USBLC6-2SC6", "STMicroelectronics"),
    "C76904": ("GJM1555C1H2R7BB01D", "Murata"), "C76906": ("GJM1555C1H3R3BB01D", "Murata"),
    "C76907": ("GJM1555C1H3R9BB01D", "Murata"), "C80165": ("BLM18PG221SN1D", "Murata"),
    "C83333": ("SMBJ5.0A", "Littelfuse"), "C84403": ("LQG15HN6N8J02D", "Murata"), "C84681": ("CH340C", "WCH"),
    "C8545": ("2N7002", "JSCJ"), "C85874": ("GJM1555C1H100JB01D", "Murata"),
    "C8678": ("SS34", "MDD (Microdiode Semiconductor)"), "C882493": ("LQG18HN6N8J00D", "Murata"),
    "C882496": ("LQG18HN1N2S00D", "Murata"), "C97981": ("LQG15HN1N0S02D", "Murata"),
    "C98006": ("LQG18HN15NJ00D", "Murata"), "C98009": ("LQG18HN8N2J00D", "Murata"),
    "C98010": ("LQG18HNR10J00D", "Murata"),
    "C2651001": ("B39871B3725U410", "TDK (EPCOS)"),
}
THT = {"BWSMA-KWE-Z001"}   # through-hole parts among the assembled ones


def col(i):
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s


def write_xlsx(path, rows, sheet="Sheet1"):
    """.xlsx with the parts Excel itself writes (shared strings, styles, document properties), so
    that the upload checks of the assembly services accept it. Integers become number cells."""
    strings, index, data = [], {}, []
    for r, row in enumerate(rows, 1):
        cells = []
        for c, v in enumerate(row):
            ref = "%s%d" % (col(c), r)
            if isinstance(v, int):
                cells.append('<c r="%s"><v>%d</v></c>' % (ref, v))
                continue
            s = str(v)
            if s == "":
                continue
            if s not in index:
                index[s] = len(strings)
                strings.append(s)
            cells.append('<c r="%s" t="s"><v>%d</v></c>' % (ref, index[s]))
        data.append('<row r="%d">%s</row>' % (r, "".join(cells)))
    ns = "http://schemas.openxmlformats.org"
    ct = ns + "/officeDocument/2006/relationships"
    width = max(len(r) for r in rows)
    files = {
        "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="%s/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        '</Types>' % ns,
        "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s/package/2006/relationships">'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="%s/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '<Relationship Id="rId3" Type="%s/extended-properties" Target="docProps/app.xml"/>'
        '</Relationships>' % (ns, ct, ns, ct),
        "docProps/core.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="%s/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>%s</dc:title></cp:coreProperties>' % (ns, escape(sheet)),
        "docProps/app.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Properties xmlns="%s/officeDocument/2006/extended-properties"><Application>Microsoft Excel</Application></Properties>' % ns,
        "xl/workbook.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="%s/spreadsheetml/2006/main" xmlns:r="%s"><sheets>'
        '<sheet name="%s" sheetId="1" r:id="rId1"/></sheets></workbook>' % (ns, ct, escape(sheet)),
        "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="%s/package/2006/relationships">'
        '<Relationship Id="rId1" Type="%s/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="%s/styles" Target="styles.xml"/>'
        '<Relationship Id="rId3" Type="%s/sharedStrings" Target="sharedStrings.xml"/>'
        '</Relationships>' % (ns, ct, ct, ct),
        "xl/styles.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="%s/spreadsheetml/2006/main">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>' % ns,
        "xl/sharedStrings.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<sst xmlns="%s/spreadsheetml/2006/main" count="%d" uniqueCount="%d">%s</sst>'
        % (ns, len(strings), len(strings), "".join('<si><t xml:space="preserve">%s</t></si>' % escape(s) for s in strings)),
        "xl/worksheets/sheet1.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="%s/spreadsheetml/2006/main"><dimension ref="A1:%s%d"/><sheetData>%s</sheetData></worksheet>'
        % (ns, col(width - 1), len(rows), "".join(data)),
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in files.items():
            z.writestr(name, text)


def make(fab):
    fab = pathlib.Path(fab)
    with open(fab / "bom.csv", newline="", encoding="utf-8") as f:
        bom = list(csv.DictReader(f))
    rows = [["S/N", "Designator", "Quantity", "Manufacturer Part Number", "Manufacturer", "Description",
             "Footprint", "LCSC Part #", "Procurement Type", "Customer Note"]]
    missing = []
    for n, b in enumerate(bom, 1):
        lcsc = b["LCSC Part #"].strip()
        if lcsc not in MPN:
            missing.append(lcsc)
            continue
        mpn, maker = MPN[lcsc]
        des = b["Designator"].replace(" ", "")
        note = "through-hole part" if mpn in THT else ""
        rows.append([n, des, len(des.split(",")), mpn, maker, b["Comment"], b["Footprint"], lcsc, "", note])
    if missing:
        sys.exit("no manufacturer part number for: " + ", ".join(missing))
    with open(fab / "bom-mpn.csv", "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(rows)
    write_xlsx(fab / "bom-mpn.xlsx", rows, "BOM")
    with open(fab / "cpl.csv", newline="", encoding="utf-8") as f:
        cpl = list(csv.reader(f))
    write_xlsx(fab / "cpl.xlsx", cpl, "Centroid")
    print("%s: %d BOM lines, %d placements" % (fab, len(rows) - 1, len(cpl) - 1))


if __name__ == "__main__":
    here = pathlib.Path(__file__).resolve().parent
    for d in sys.argv[1:] or [here / "fabrication", here.parent / "filter868" / "fabrication"]:
        make(d)
