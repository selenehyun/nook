# Choosing an RSS reader

There is no universally best reader. The important differences are where data lives, what transports it between devices, which platforms are supported, and whether the product is primarily an RSS client or a broader reading service.

This comparison uses public, official product information checked on **July 24, 2026**. Listed dollar prices are from US pricing pages and may vary by storefront or region. Prices and features can change; follow the source links before purchasing. A dash means the linked product overview does not advertise an equivalent feature, not that no workaround exists.

## At a glance

| | Nook | NetNewsWire | Reeder | Feedly | Readwise Reader |
| --- | --- | --- | --- | --- | --- |
| Price model | Free, MIT-licensed | Free, open source | Free download; $1/month or $10/year in-app purchases | Free tier; paid Pro, Pro+, and enterprise plans | 30-day trial; $9.99/month annually or $12.99 monthly |
| Platforms | macOS, iOS, iPadOS | macOS, iOS, iPadOS | macOS, iOS, iPadOS | Web, iOS, Android | Web, macOS, Windows, iOS, Android |
| Reader-service account required | No | No for direct/iCloud use; third-party services need their own accounts | No; iCloud sync | Yes | Yes |
| What transports sync | A folder provider chosen by the reader: iCloud Drive, Dropbox, Google Drive, and others | iCloud or a supported RSS service such as Feedly, Feedbin, FreshRSS, or Inoreader | iCloud | Feedly's hosted service | Readwise's hosted service |
| Conflict/data model | Per-device JSON files merged by Nook CRDTs | Managed by the selected sync account | Subscriptions, timeline position, and tagged items sync through iCloud | Managed by Feedly | Managed by Readwise |
| Main reading model | Traditional unread RSS with native and full-page readers | Traditional unread RSS client | Unified timeline for reading, watching, and listening; syncs timeline position instead of unread counts | Hosted news reader and source discovery, with paid research/AI tiers | Read-it-later and knowledge workflow for RSS, articles, newsletters, PDFs, EPUBs, video, highlights, and notes |
| Built-in translation/AI relevant to reading | In-place full-article translation; opt-in automatic list-title translation; optional semantic categories | — | — | AI feeds in Pro+; translation is documented for specialized newsletter/intelligence workflows | Ghostreader can translate selected words or passages and provides document chat |
| Server can collect feeds while every personal device is offline | No | Yes when using a hosted RSS account; no for direct/iCloud-only feeds | No; content is fetched from sources | Yes | Yes |

## How to read the sync row

“iCloud” and “CRDT” are not competing sync choices:

1. **Transport:** iCloud Drive or another folder provider copies Nook's files between devices.
2. **Merge:** after those files arrive, Nook's CRDT layer resolves concurrent state without letting one device overwrite another.

NetNewsWire and Reeder can also use iCloud, but their storage formats and merge behavior are their own. Hosted services such as Feedly and Readwise collect feeds and keep the authoritative account state on their servers.

## Which one is likely to fit?

- **Nook** fits a reader who uses Apple devices, wants no reader-service account, wants to choose the storage folder, and values native in-place translation and granular opt-in controls. It is not a web or Android service, and currently requires building the iOS app from source.
- **NetNewsWire** fits someone who wants a mature, free, open-source, traditional Apple-platform RSS client and broad compatibility with established RSS sync services.
- **Reeder** fits someone who prefers a calm unified timeline across feeds, video, podcasts, and social sources and does not want unread counts to drive the experience.
- **Feedly** fits someone who wants a hosted cross-platform news reader, server-side collection, source discovery, and optional paid research or AI-feed capabilities.
- **Readwise Reader** fits someone whose RSS feeds are part of a larger highlighting, annotation, PDF/EPUB, read-it-later, and knowledge-retention workflow.

## Nook's control model

Nook deliberately separates features that are often bundled together:

- New-article notifications are off by default and independent from the unread badge.
- Automatic list-title translation is off by default and independent from manual article translation.
- Apple Intelligence, Gemini article translation, Gemini title translation, and Gemini categorization are selected per surface.
- Gemini is never used until the reader selects it and stores an API key on that device.
- AI categorization is optional; keyword rules and manual categories do not require AI.
- Full-article offline downloads are chosen explicitly and remain on that device.

The complete defaults and network implications are listed in [Features and controls](features.md#defaults-and-user-control).

## Official sources

- Nook: this repository's [README](../README.md), [features](features.md), and [data and sync](data-and-sync.md) documentation
- NetNewsWire: [official overview and feature list](https://netnewswire.com/)
- Reeder: [official website](https://reeder.app/) and [US App Store listing](https://apps.apple.com/us/app/reeder/id6475002485)
- Feedly: [News Reader overview](https://feedly.com/news-reader) and [Free, Pro, Pro+, and Enterprise plan description](https://docs.feedly.com/article/140-what-is-the-difference-between-feedly-basic-pro-and-teams)
- Readwise Reader: [product documentation](https://docs.readwise.io/reader/docs), [pricing](https://readwise.io/pricing/reader), and [Ghostreader translation documentation](https://docs.readwise.io/reader/guides/ghostreader/overview)
