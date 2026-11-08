## Personal data (KVKK)

This product's users are in Türkiye, so personal data here falls under KVKK (Law No. 6698). Use the `kvkk-compliance` skill for every change that collects, stores, logs, exports, deletes, or sends personal data, and for seed data and fixtures.

Work on synthetic or masked data, because everything an agent reads reaches the model vendor's servers abroad. Read production logs, dumps, exports, and tickets only through the skill's mask (`scan-tr-pii.py --mask`). Leave `.env` files, `logs/`, `exports/`, `dumps/`, `backups/`, and database dumps unread.
