# Liquipedia FGC Query

A small, non-commercial PowerShell tool for researching fighting-game players and events through the official Liquipedia Fighting Games MediaWiki API.

This project is maintained as a personal hobby for Chinese-speaking fighting-game community coverage. It is intended for research and fact-checking of original news posts and event summaries. It does not reproduce the Liquipedia website, redistribute raw API data, support betting, or modify Liquipedia.

## Features

- Search Fighting Games wiki page titles.
- Read page wikitext through `action=query`.
- Extract common `Infobox player` fields.
- Explicitly request `action=parse` data when required.
- Send a project-specific User-Agent with real contact information.
- Enforce the Liquipedia request intervals locally.
- Cache identical responses for 24 hours by default.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- A real contact email address or contact URL for the User-Agent

No API key is required for the MediaWiki API.

## Usage

Set your contact information for the current terminal session:

```powershell
$env:LIQUIPEDIA_CONTACT = 'your-real-email@example.org'
```

Query a player:

```powershell
.\liquipedia-query.ps1 -Mode player -Query 'Sahara'
```

Search for a page:

```powershell
.\liquipedia-query.ps1 -Mode search -Query 'Capcom Cup 12' -Limit 10
```

Read page wikitext:

```powershell
.\liquipedia-query.ps1 -Mode page -Query 'Capcom Cup/12'
```

Request parsed sections explicitly:

```powershell
.\liquipedia-query.ps1 -Mode parse -Query 'Sahara' -ParseProperty sections
```

Inspect a request without network access or file writes:

```powershell
.\liquipedia-query.ps1 -Mode player -Query 'Sahara' -DryRun
```

The script rejects placeholder contact information. Your contact value is sent only in the User-Agent header; it is not written to the repository, cache key, or command output.

## Rate limits and caching

The script follows Liquipedia's published MediaWiki API limits:

- At most one ordinary HTTP request every 2 seconds.
- At most one `action=parse` request every 30 seconds.
- Identical responses are cached for 24 hours by default.
- Requests are serialized with a local mutex.

Use `-Refresh` only when you genuinely need a fresh response. Cache and rate-limit state are stored under the current user's local application-data directory, not in this repository.

## LPDB API status

This repository currently implements the public MediaWiki API. LPDB API integration is not included because access and complete documentation are provided only after approval. If LPDB access is approved, its client will be added separately and API credentials will remain outside version control.

## Attribution

Liquipedia content is available under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). Applications using the returned data must credit Liquipedia and comply with its current terms.

- [Liquipedia API terms of use](https://liquipedia.net/api-terms-of-use)
- [MediaWiki page-content API](https://www.mediawiki.org/wiki/API:Get_the_contents_of_a_page/en)
- [MediaWiki Revisions API](https://www.mediawiki.org/wiki/API:Revisions)

The source code in this repository is licensed under the MIT License.
