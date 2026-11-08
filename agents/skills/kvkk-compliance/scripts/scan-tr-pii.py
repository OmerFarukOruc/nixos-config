#!/usr/bin/env python3
"""Find Turkish personal data in files: TC kimlik numbers, TR IBANs, Turkish mobile numbers, and emails.

Usage:
  python3 scan-tr-pii.py PATH [PATH ...]   report hits
  python3 scan-tr-pii.py --mask FILE       print FILE with personal data replaced

Scan mode walks directories, skipping .git, node_modules, and binary files. Each hit prints
as `path:line: kind masked-value`, so the output itself carries no personal data.
Exit 0 = no hits, 1 = hits, 2 = usage error.

Mask mode prints the file with every hit replaced by [TC], [IBAN], [PHONE], or [EMAIL], and
the string value of every JSON key that names a person or a place (see MASK_KEYS) replaced
by [MASKED]. Exit 0, or 2 on a usage error.

A value counts as synthetic, and is skipped, only when it cannot belong to a real person:
- a TC kimlik number or IBAN whose checksum fails,
- a phone number whose operator digits are masked (+90 5XX ...), which this pattern skips,
- an email at a reserved domain (RFC 2606 and RFC 6761).
"""
import os
import re
import sys

SKIP_DIRS = {'.git', 'node_modules'}

# TR IBAN: "TR", 2 check digits, then 22 digits (5-digit bank code, 1 reserve digit, 16-digit account), optional spaces.
IBAN_RE = re.compile(r'\bTR\d{2}(?: ?\d){22}\b')
# TC kimlik: 11 digits, first digit not 0, not part of a longer digit run.
TC_RE = re.compile(r'(?<!\d)[1-9]\d{10}(?!\d)')
# Mobile numbers are 10 digits starting with 5, with an optional +90, 0090, or 0 prefix and common separators.
PHONE_RE = re.compile(r'(?<![\d+])(?:(?:\+|00)90[\s.-]?|0[\s.-]?)?\(?5\d{2}\)?[\s.-]?\d{3}[\s.-]?\d{2}[\s.-]?\d{2}(?!\d)')
EMAIL_RE = re.compile(r'[A-Za-z0-9._%+-]+@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})')
# Reserved for documentation and testing: example.com/.net/.org (RFC 2606) and the .test, .example, .invalid, .localhost names (RFC 6761).
RESERVED_DOMAINS = ('example.com', 'example.net', 'example.org')
RESERVED_TLDS = ('test', 'example', 'invalid', 'localhost')
# JSON keys whose string values are names or addresses, which no pattern can recognise: "fullName", "recipient", "line", "ad", "soyad", ...
MASK_KEYS = re.compile(r'"((?:\w*(?:name|surname|recipient|address|street|line|district|birth)\w*)|ad|soyad|adres|isim)"(\s*:\s*)"(?:[^"\\]|\\.)*"', re.IGNORECASE)
TAGS = {'TC kimlik': '[TC]', 'IBAN': '[IBAN]', 'mobile': '[PHONE]', 'email': '[EMAIL]'}


def tc_valid(number):
    """The Nüfus ve Vatandaşlık İşleri check digits: digit 10 from the odd and even sums, digit 11 from the sum of the first 10."""
    d = [int(c) for c in number]
    tenth = ((d[0] + d[2] + d[4] + d[6] + d[8]) * 7 - (d[1] + d[3] + d[5] + d[7])) % 10
    return d[9] == tenth and d[10] == sum(d[:10]) % 10


def iban_valid(iban):
    """ISO 13616 mod-97: move the first 4 characters to the end, letters become 10..35, the number mod 97 is 1."""
    s = iban[4:] + iban[:4]
    return int(''.join(str(int(c, 36)) for c in s)) % 97 == 1


def email_reserved(domain):
    domain = domain.lower()
    return domain.rsplit('.', 1)[-1] in RESERVED_TLDS or any(domain == r or domain.endswith('.' + r) for r in RESERVED_DOMAINS)


def mask(value):
    if '@' in value:
        local, domain = value.split('@', 1)
        return local[:1] + '***@' + domain
    digits = value.replace(' ', '')
    return digits[:4] + '*' * max(len(digits) - 6, 3) + digits[-2:]


def scan_line(line):
    """Return (kind, value, start, end) for each hit. Each IBAN is blanked before the digit patterns run, so its digits are not read again as a TC number or a phone."""
    hits = []
    for m in IBAN_RE.finditer(line):
        if iban_valid(m.group().replace(' ', '')):
            hits.append(('IBAN', m.group(), m.start(), m.end()))
        line = line[:m.start()] + ' ' * len(m.group()) + line[m.end():]
    for m in EMAIL_RE.finditer(line):
        if not email_reserved(m.group(1)):
            hits.append(('email', m.group(), m.start(), m.end()))
        line = line[:m.start()] + ' ' * len(m.group()) + line[m.end():]
    for m in TC_RE.finditer(line):
        if tc_valid(m.group()):
            hits.append(('TC kimlik', m.group(), m.start(), m.end()))
    for m in PHONE_RE.finditer(line):
        hits.append(('mobile', m.group(), m.start(), m.end()))
    return hits


def mask_line(line):
    for kind, _, start, end in sorted(scan_line(line), key=lambda h: h[2], reverse=True):
        line = line[:start] + TAGS[kind] + line[end:]
    return MASK_KEYS.sub(lambda m: f'"{m.group(1)}"{m.group(2)}"[MASKED]"', line)


def files_under(path):
    if os.path.isfile(path):
        yield path
        return
    for root, dirs, files in os.walk(path):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            yield os.path.join(root, name)


def is_binary(path):
    with open(path, 'rb') as f:
        return b'\0' in f.read(8192)


def main(paths):
    if not paths or paths[0] in ('-h', '--help'):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if paths[0] == '--mask':
        if len(paths) != 2 or not os.path.isfile(paths[1]):
            print('scan-tr-pii: --mask takes exactly one existing file', file=sys.stderr)
            return 2
        with open(paths[1], encoding='utf-8', errors='replace') as fh:
            for line in fh:
                sys.stdout.write(mask_line(line))
        return 0
    # A pipe or device would be skipped by the walk and reported as clean, so only regular files and directories are accepted.
    missing = [p for p in paths if not (os.path.isfile(p) or os.path.isdir(p))]
    if missing:
        print(f'scan-tr-pii: not a regular file or directory: {", ".join(missing)}', file=sys.stderr)
        return 2
    total, scanned = 0, 0
    for path in paths:
        for f in files_under(path):
            if is_binary(f):
                continue
            scanned += 1
            with open(f, encoding='utf-8', errors='replace') as fh:
                for n, line in enumerate(fh, 1):
                    for kind, value, _, _ in scan_line(line):
                        total += 1
                        print(f'{f}:{n}: {kind} {mask(value)}')
    if total:
        print(f'scan-tr-pii: {total} hits in {scanned} files; replace each with synthetic or masked data and rerun', file=sys.stderr)
        return 1
    print(f'scan-tr-pii: no hits in {scanned} files', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
