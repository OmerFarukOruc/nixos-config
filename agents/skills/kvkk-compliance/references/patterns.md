# Build patterns

Code shapes for the build rules in `SKILL.md`. Adapt the names to the repository's stack; the fields and the behaviour are the part that matters.

Contents:

- Consent record
- Privacy notice
- Cookie consent
- Commercial messages and İYS
- Retention and deletion
- Copy of a person's data
- Logs
- Sources

## Consent record

Store consent as append-only events, one per purpose, so the history shows what the person agreed to, when, and to which text:

```sql
CREATE TABLE consent_events (
  id            bigserial PRIMARY KEY,
  subject_id    text        NOT NULL,  -- person id, or the signup id for a visitor without an account
  purpose       text        NOT NULL,  -- 'marketing_email', 'marketing_sms', 'cookie_analytics', ...
  granted       boolean     NOT NULL,  -- false records a withdrawal
  text_version  text        NOT NULL,  -- id of the consent text shown, kept in the repo or a table
  source        text        NOT NULL,  -- 'newsletter_form', 'account_settings', 'unsubscribe_link', 'iys'
  created_at    timestamptz NOT NULL DEFAULT now()
);
```

- The current state of a purpose is its latest event.
- The API accepts consent only as an explicit `true` per purpose; a missing field means no consent. One flag for email and SMS together fails, because each channel is its own purpose.
- Withdrawal inserts `granted = false`. Every marketing message carries a working unsubscribe link or SMS opt-out, and a withdrawal applies before the next send.
- Keep each consent text version resolvable to its exact words, because a consent proves nothing without the text it answered.

## Privacy notice

The privacy notice (aydınlatma metni, Art. 10) is shown when data is collected and is separate from any consent request. It names the data controller, the purposes, the recipients and why they receive the data, the collection method and legal basis, and the Art. 11 rights.

- Store which notice version the person saw (`notice_version`) next to the record collected.
- Acknowledging the notice and giving consent are two separate actions: an unticked consent checkbox with its own short text, outside the notice body.
- The notice text itself is the owner's open item; the code provides the place to show it and records the version.

## Cookie consent

The Authority's cookie guide (June 2022) is advisory, and the Board applies it in its decisions. Cookies that only carry the communication or that the service strictly needs (login, security, load balancing, the consent choice itself, first-party audience measurement without cross-site tracking) need no consent. Advertising, cross-site tracking, and social plug-in tracking cookies need explicit consent per category before they are set.

- Every consent-based category starts off; the person turns it on.
- Offer accept, reject, and preferences at the same visual weight; the guide gives this as good practice.
- Load third-party scripts for a category only after its consent event exists, and keep a panel where the person can withdraw.
- Store each choice as a consent event with purpose `cookie_<category>`.

## Commercial messages and İYS

Law No. 6563 and its regulation on commercial communications govern commercial electronic messages (SMS, email, calls). İYS (İleti Yönetim Sistemi) is the national register of those consents.

- A message needs the recipient's prior consent, held in İYS. A consent the product collects itself is uploaded to İYS within 3 business days; a consent not registered in İYS is invalid (regulation Art. 7(11)-(12)). Send only to recipients whose consent İYS shows.
- The consent box starts unticked, and consent is never a condition for the product (Art. 7(8)-(9)).
- Every message offers a free refusal through the same channel. After a refusal, sending stops within 3 business days, and a refusal the product receives itself goes to İYS within 3 business days (Law Art. 8(3), regulation Art. 9).
- Merchants and tradespeople (tacir and esnaf) may receive messages without prior consent, but their addresses are registered in İYS and checked for a refusal before each send. Treat every recipient as a consumer unless the product records that it is a business.
- Keep the local consent event and the İYS status apart, so a failed upload shows up.

## Retention and deletion

Give every stored field a period and a removal path in one place the code reads:

```js
// Retention per record type. Each period starts at the named event. Example values; the owner sets the real periods.
const RETENTION = {
  newsletter_signup: { days: 30, after: 'withdrawal' },
  support_ticket: { days: 730, after: 'closed' },
};
```

- A scheduled job deletes or anonymizes records past their period, at an interval of at most 6 months (3 months for a controller without a retention policy; see `law.md`).
- A person's deletion request is completed within 30 days, across every store: database, caches, search indexes, files, and exports.
- Anonymizing removes every value that identifies the person, alone or combined. A hash of an email is pseudonymous, not anonymous, and stays personal data.
- Record each removal (record id, date, method) in a log that holds no personal data, and keep it for at least 3 years.

## Copy of a person's data

One function returns everything stored about a person, from every store, by person id, as JSON. It serves the Art. 11 right to learn what is processed and the right to a copy, and it doubles as the list of stores the deletion path must reach.

## Logs

```js
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    console.log(JSON.stringify({ t: new Date().toISOString(), method: req.method, route: req.route?.path ?? req.path, status: res.statusCode, ms: Date.now() - start }));
  });
  next();
});
```

- Log the route pattern, not the URL: a URL can carry an email or a token in the path or query.
- Error handlers log the error class, a request id, and record ids. Error messages can quote input, so log `err.message` only for errors the code itself raises.
- When a logger serializes objects (pino, winston), configure its redaction paths for personal data fields instead of trusting each call site.

## Sources

Checked on 27-10-2026. The Law No. 6563 and regulation texts came from a mirror (secondary), because mevzuat.gov.tr did not answer.

- Çerez Uygulamaları Hakkında Rehber (June 2022): https://www.kvkk.gov.tr/SharedFolderServer/CMSFiles/fb193dbb-b159-4221-8a7b-3addc083d33f.pdf
- Law No. 6563 (secondary): https://www.lexpera.com.tr/mevzuat/kanunlar/elektronik-ticaretin-duzenlenmesi-hakkinda-kanun-6563
- Ticari İletişim ve Ticari Elektronik İletiler Hakkında Yönetmelik (secondary): https://www.lexpera.com.tr/mevzuat/yonetmelikler/ticari-iletisim-ve-ticari-elektronik-iletiler-hakkinda-yonetmelik
- Deletion regulation: https://www.kvkk.gov.tr/Icerik/5441/KISISEL-VERILERIN-SILINMESI-YOK-EDILMESI-VEYA-ANONIM-HALE-GETIRILMESI-HAKKINDA-YONETMELIK
