---
name: kvkk-compliance
description: "KVKK (Turkish Personal Data Protection Law 6698) rules for code that handles personal data of people in Türkiye. Use when building or reviewing a feature that collects, stores, logs, exports, or deletes personal data; when adding a third-party service or AI API that receives personal data; when writing consent, privacy notice (aydınlatma metni), cookie, or SMS and email marketing flows; when creating seed data or fixtures, or reading production logs, dumps, or exports; and when creating a repository, or writing its agent instructions, for a product whose users are in Türkiye."
---

# KVKK compliance

KVKK (Law No. 6698) governs personal data: any information about an identified or identifiable living person, such as a name, email, phone number, TC kimlik number, IBAN, address, IP address, or free text that mentions them. This skill makes the code compliant and lists the legal steps only the owner can take. `<skill>` below stands for the folder this file is in; other paths are relative to the repository.

Open a production log, database dump, export, or support ticket only through the mask, from the first look onward, because everything you read reaches the model vendor's servers abroad:

```
python3 <skill>/scripts/scan-tr-pii.py --mask logs/prod.log | grep -n -B2 -A8 'Error'
```

Copy this checklist into your notes and tick each step when its completion check holds:

```
KVKK
- [ ] 1 Classify: every field and recipient listed
- [ ] 2 Build: every code rule met in the diff
- [ ] 3 Agent context: scanner exits 0 on new data files; production data read only through the mask
- [ ] 4 Report: the KVKK section is in the final message or PR body
```

## 1. Classify

List each field of personal data the change reads, stores, logs, or sends, and each recipient of it. For each field and recipient, note:

- **Special category data** (Art. 6): health, biometric and genetic data, religion, ethnic origin, political opinion, union membership, sexual life, criminal records, and appearance. Free text written by people (tickets, notes, chat, reviews) can hold any of these, health most often, so treat a free-text field as special category data unless the feature removes it.
- **Transfer abroad** (Art. 9): any recipient whose servers are outside Türkiye. Every LLM API, most email and SMS providers, analytics, error trackers, and cloud regions abroad count.

Done when every new field and every recipient is in the list. Then read the reference that matches what the list shows:

- personal data goes to an AI or LLM API, or an AI result affects a person: [`references/ai-features.md`](references/ai-features.md)
- you need a legal basis, special category data is involved, data goes abroad, or a deadline matters: [`references/law.md`](references/law.md)
- the change has consent, cookies, commercial SMS or email, deletion, or export: [`references/patterns.md`](references/patterns.md)

## 2. Build

Build each rule the change touches in this change. Only legal steps go to the report as open items for the owner: a contract, a registration, a notice text, or the choice of a retention period. Code that serves those steps, such as a withdrawal endpoint or a deletion job, is built now, because an open item for code ships the feature without it.

- **Logs carry ids, not people.** Request loggers, error handlers, and analytics events record the route, status, record id, and error class. They leave out request bodies, headers, and query strings, because each log line copies personal data into another store with its own readers and retention. Check by sending a real request with known values and searching the server output for them.
- **Minimum fields.** Collect, return, and send only the fields the purpose needs (Art. 4). An endpoint that returns personal data checks the caller and returns only the fields that caller needs.
- **Privacy notice apart from consent.** Every collection point shows the privacy notice (aydınlatma metni) and stores which version was shown. Ask for explicit consent only when no other legal basis fits, and then as a separate text and action, because the Board holds one checkbox for both unlawful.
- **Consent per purpose.** Store one consent record per purpose and channel (email and SMS are separate, and each can be given alone), given only by an action of the person, with a timestamp and the version of the text they saw. Withdrawal works as easily as giving, through an endpoint or a link in every message, and is stored as a new record.
- **Commercial SMS and email go through İYS.** A consent for commercial messages that the product collects is registered in İYS (İleti Yönetim Sistemi) within 3 business days, or it is invalid, and the sender sends only to recipients with consent in İYS.
- **Retention for every field.** Each new field has a retention period and a deletion or anonymization path (a job, an endpoint, or a script) in code or config. When the owner has not set the period, use a named constant with a proposed value and list the choice as an open item. Deleting a record also covers its copies: caches, search indexes, exports, and backups by their own cycle.
- **Rights are reachable.** The person can get a copy of their data, have it corrected or deleted, and withdraw consent (Art. 11). The data controller answers within 30 days (Art. 13), so each new store is reachable by person id.
- **Transfer abroad is minimized.** Send a recipient abroad only the fields it needs; strip or pseudonymize the rest before the call.

Done when each rule the change touches is met in the diff.

## 3. Agent context

Reading real personal data is itself a transfer abroad, so work on synthetic or masked data.

- **Read production data through the mask**, with the command at the top of this file. The mask replaces TC kimlik numbers, IBANs, mobile numbers, and emails with tags, and blanks JSON values whose key names a person or a place. Before you read any unknown data file, run the scanner on it; its output is masked too.
- **Seeds and fixtures are synthetic by construction.** Emails use `example.com` or a `.test` domain. TC kimlik numbers and IBANs are invented with a failing checksum. Phone numbers keep the operator digits masked, as in `+90 5XX 000 00 17`, so no SMS gateway delivers them. Names and street names can look real. A validator test that needs a valid TC kimlik number or IBAN computes one at test time from the checksum rule, so no valid value is committed.
- **Scan what you wrote.** Run the scanner on every new or changed seed, fixture, test data file, and log sample:

  ```
  python3 <skill>/scripts/scan-tr-pii.py scripts/seed.js test/fixtures
  ```

  Exit 1 lists each hit by file, line, and kind. Replace each one with a synthetic value and rerun until it exits 0.
- **Real data already in the repository** (a committed log, dump, or export) goes to the report as an open item: the owner deletes it from the working tree and from git history.

Done when the scanner exits 0 on every data file you wrote, and every production file you used was read through the mask.

## 4. Report

End the final message or PR body with this section, because the owner reads it to find the legal steps only they can take. The lines bind; write `none` where a line does not apply.

```markdown
## KVKK
- Personal data: <fields>; special category: <fields or none>
- Purpose and legal basis: <purpose>: <basis, e.g. Art. 5(2)(c) contract, or explicit consent>
- Recipients: <service> (<country>; transfer abroad: <yes, route | no>)
- Retention: <field or group>: <period>, removed by <job, endpoint, or script>
- Rights: copy <how>; deletion <how>; consent withdrawal <how | none>
- Agent context: scanner <exit 0 on files>; read through the mask: <files | none>
- Open items for the owner: <each legal step, e.g. standard contract with <vendor> filed within 5 business days; privacy notice text; İYS registration; VERBIS>
```

## New repository

Only when you create a repository, or write its agent instructions, for a product whose users are in Türkiye, add the block in [`assets/AGENTS-kvkk.md`](assets/AGENTS-kvkk.md) to its `AGENTS.md` or `CLAUDE.md`, and merge [`assets/claude-deny.json`](assets/claude-deny.json) into its `.claude/settings.json`. The block makes agents in that repository reach this skill, and the deny rules keep Claude Code from reading secret and data files.
