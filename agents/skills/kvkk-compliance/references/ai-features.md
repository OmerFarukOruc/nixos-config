# AI features that receive personal data

For a feature that sends personal data to an LLM or other AI API, or uses an AI result to decide something about a person. The Authority's generative AI guide (see Sources) is advisory; it treats using a foreign AI service as a transfer abroad, and asks for minimisation, transparency, a human route for automated results, and defences against prompt injection.

## Transfer abroad

Every hosted LLM API (Anthropic, OpenAI, Google, Microsoft, and others) processes the prompt on servers outside Türkiye, so each call that carries personal data is a transfer abroad under Art. 9. The Board has issued no adequacy decision for any country, so the route is a KVKK standard contract between the product's company and the vendor, normally Standard Contract 2 (controller to processor), signed without changes and filed with the Authority within 5 business days of the last signature. The vendor's DPA and the EU standard contractual clauses do not satisfy KVKK. Explicit consent cannot replace the contract, because the occasional-transfer exceptions exclude transfers in the normal course of business. Details are in `law.md`.

The code cannot sign that contract. Put it in the report as an open item for the owner, naming the vendor. If the vendor will not sign one, the options are to send only anonymous data, or to use a model hosted in Türkiye.

## Minimize before the call

Art. 4 limits processing to what the purpose needs, so pseudonymize the text in code before it leaves the server:

1. Replace the values the system already knows about the people involved (the customer's name, email, phone, address from the linked record) with placeholders such as `[CUSTOMER]`, by exact string match.
2. Replace pattern-shaped identifiers with tags: TC kimlik numbers, IBANs, phone numbers, emails, card numbers. The patterns in the skill's `scripts/scan-tr-pii.py` show the Turkish formats and checksums; port them to the app's language.
3. Send only the fields the task needs; a summary needs the ticket text, not the customer record.
4. If the output must name the person, restore the placeholders in the response on the server.

Check it by pointing the SDK at a local capture server (most SDKs read a base URL from the environment, such as `ANTHROPIC_BASE_URL`) and searching the captured request for the known values.

Pseudonymized text still names third parties in free text and can still identify the person, so it remains personal data and the transfer abroad stands. Say so in the report; only anonymous data leaves KVKK's scope.

## Special category data in free text

Tickets, chats, and notes often mention health (a diagnosis, a medicine, a pregnancy). Sending that abroad needs the Art. 6 basis and the Art. 9 route together. Flag it in the report, and offer a code-side reduction where one exists, such as letting staff mark a record as excluded from AI processing.

## Vendor settings

- Use an API or business plan whose terms exclude training on inputs, and record which plan in the report.
- Turn off or shorten the vendor's retention of prompts where the plan allows it.
- Leave prompts and responses out of the product's own logs, for the reasons in `SKILL.md` step 2.

## Automated results about a person

Art. 11(1)(g) gives the person the right to object to a result against them produced only by automated analysis. When an AI output scores, ranks, flags, or rejects a person (fraud, credit, moderation, hiring), show it to a human as a suggestion, keep the inputs (by id) and the output for review, and give the person a way to object that reaches a human.

## Untrusted text

Ticket and message text is written by outsiders and can carry prompt injection. Wrap it in delimiters, tell the model it is data, and give a model that reads untrusted text no tools that read or change other people's data. Check that the output, shown to staff or other users, carries no personal data the reader should not see.

## Privacy notice

The privacy notice names the AI vendor as a recipient, the purpose, and the transfer abroad. A chat or assistant tells the person they are talking to an AI system. The text is the owner's open item.

## Sources

Checked on 27-10-2026:

- KVKK, Üretken Yapay Zeka ve Kişisel Verilerin Korunması Rehberi (15 Soruda), published 24-11-2025: https://www.kvkk.gov.tr/Icerik/8547/uretken-yapay-zeka-ve-kisisel-verilerin-korunmasi-rehberi-15-soruda
- Transfer abroad page, stating no adequacy decision exists: https://www.kvkk.gov.tr/Icerik/2053/Yurtdisina-Aktarim
