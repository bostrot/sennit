# Store listing copy

The single source for both stores. Character limits are per store; counts
noted where they matter. Trademarked network names appear only in
descriptions (nominative use), never in the Apple keyword field — Apple
rejects other brands as keywords outright.

## Listing text

The text of both stores lives in [`listings/`](listings/), one folder per
language (`en`, `de`, `es`, `fr`, `pt`, `zh`, `hi`, `ar`) and one plain-text
file per field, with English as the source. `listings.py` checks every field
against its store's limit and sends it (dry run by default; the
**Store listings** workflow runs it with the repository's credentials):

```
python3 tooling/store/listings.py all --screenshots --apply
```

| File | Store field | Limit |
|---|---|---|
| `name.txt` | Apple app name | 30 |
| `subtitle.txt` | Apple subtitle | 30 |
| `title.txt` | Play title | 30 |
| `short_description.txt` | Play short description | 80 |
| `description.txt` | both stores' description | 4000 |
| `keywords.txt` | Apple keywords, comma-separated | 100 |
| `promotional_text.txt` | Apple promotional text, changeable without review | 170 |

When changing the English, change every language in the same pull request,
as with the app's own strings. Write each one natively rather than word for
word, with the terms the app's catalogue uses (bridges, merged chats,
disappearing messages), and keep it true: the AI features, semantic search,
transcription, MCP server and integrations are Sennit Pro.

## Screenshots

`tooling/store/screenshots/<language>/` holds one set per listing language,
rendered from the demo fixtures by
`flutter test test/tools/marketing_screenshots_test.dart` (from `apps/weft`,
on a Mac, which supplies the emoji, Chinese, Devanagari and Arabic faces).
The chats are translated in that test; the app's own words come from its
catalogues, and Arabic is drawn right to left. `play_*` are Play's 9:16 phone
and 16:9 tablet shots, `iphone_69_*` and `ipad_13_*` Apple's 6.9" iPhone and
13" iPad sizes.

## URLs

| Field | Value |
|---|---|
| Support URL | https://erictrenkel.com/apps/sennit/ |
| Marketing URL | https://erictrenkel.com/apps/sennit/ |
| Privacy policy | https://erictrenkel.com/apps/sennit/privacy.html |

## Categories

- Apple: primary `SOCIAL_NETWORKING`, secondary `PRODUCTIVITY`
- Play: `Communication`

## Data collection

Both questionnaires: **no data collected** — no analytics or crash SDKs;
the app only talks to user-configured servers. See PRIVACY.md.
