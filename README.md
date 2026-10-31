# ImpactDiscipleAsst

Turns Impact Church YouTube sermons into a static recap site ([impact-recap.com](https://impact-recap.com)).

A scheduled job on a home machine runs a Python sync that finds new videos in the channel's playlists, fetches the transcript, asks Claude for a summary, three tags, main points, verses, and a six-day action plan, and commits one JSON file per sermon. Netlify builds the Astro site from those files on every push. The sync runs locally because YouTube blocks transcript fetches from GitHub-hosted runners.

```
YouTube playlists ──▶ video_sync.py (home machine) ──▶ content/sermons/<date>_<videoId>.json
                                                                   │
                                                 git push ─────────┘
                                                                   ▼
                                               Netlify: npm run build (Astro) ──▶ dist/
```

There is no database and no webhook. A video is "ingested" when its file exists in `content/sermons/`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `video_sync.py` | CLI entrypoint: list playlist videos, decide what to ingest, run the pipeline |
| `video_utils.py` | YouTube Data API, transcripts, prompt loading, model call, validation, file writes |
| `requirements-sync.txt` | Python deps for the sync (named so Netlify does not try to pip-install them) |
| `tests/` | pytest suite for the pure parts of the pipeline (no network) |
| `data/prompt.yaml`, `data/prompts/*.md` | Model and prompt text sent to Claude |
| `data/tags.yml` | The allowed tag list. The model must pick exactly three |
| `data/config.example.yml` | Template for the local `data/config.yml` (gitignored) |
| `data/failed/` | Raw model output for sermons that failed validation (committed for debugging) |
| `content/sermons/*.json` | The site's data. Written by Python, read by Astro |
| `src/` | Astro site: layout, components, pages, client scripts, styles |
| `public/` | Static assets (favicon, images) |
| `netlify.toml` | Netlify build settings and redirects from the old `.html` URLs |
| `.github/workflows/sync-sermons.yml` | Manual sermon sync from the Actions tab |
| `scripts/sync-sermons.sh` | Weekly sync on Linux, then push |
| `scripts/sync-sermons.ps1` | Weekly sync on Windows, then push |
| `.github/workflows/site-build.yml` | Builds the site on pull requests to catch bad JSON early |

## Sermon JSON

```json
{
  "videoId": "9HKkiJCXWic",
  "title": "How to Stop Drifting Away from God | Planted in God's Word",
  "speaker": "Pastor Travis Hearn",
  "date": "2026-04-13",
  "duration": "0:55:46",
  "thumbnailUrl": "https://i.ytimg.com/vi/9HKkiJCXWic/maxresdefault.jpg",
  "videoUrl": "https://www.youtube.com/embed/9HKkiJCXWic",
  "summaryText": "...",
  "tags": ["Faith", "Obedience", "Wisdom"],
  "mainPoints": ["...", "...", "..."],
  "versesMentioned": [{ "verse": "John 15:5", "text": "...", "version": "NIV" }],
  "dailyActionPlan": {
    "Monday": { "scripture": "...", "focus": "...", "action": "...", "prayer": "..." },
    "...": {}
  }
}
```

The same shape is enforced twice: by Pydantic (`SermonRecord` in `video_utils.py`) before a file is written, and by Zod (`src/content.config.ts`) when the site builds. A model response that does not validate is saved to `data/failed/<videoId>.txt` and the existing sermon file, if any, is left untouched.

`speaker` and `duration` may be `null` for entries migrated from the old site that were never indexed; `--mode repair` fills them from the YouTube API.

## GitHub Actions

### Sync sermons

The weekly run is not this workflow. GitHub-hosted runners are blocked by YouTube when fetching transcripts. Install the local timer instead (below). This workflow stays available for a manual run from the Actions tab, with a mode choice:

| Mode | What it does |
| --- | --- |
| `incremental` | Ingest playlist videos that have no file in `content/sermons/` |
| `repair` | `incremental`, plus fetch metadata for files with placeholder title or no duration |
| `full` | Re-run the model for every playlist video (rewrites every sermon; about 5 cents each) |

Manual runs also accept a `limit` and a `dry_run` flag. The job commits `content/sermons` and `data/failed` as `github-actions[bot]`, which triggers a Netlify deploy. A blank limit processes every eligible video. The run is marked failed if any ingest failed or the model rate-limited, after the commit has already been pushed.

Secrets required (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `CHANNEL_ID` | YouTube channel id |
| `YT_TOKEN` | YouTube Data API v3 key |
| `CLAUDE_TOKEN` | Anthropic API key |
| `YT_PROXY_HTTP`, `YT_PROXY_HTTPS` | Optional. Transcript proxy if YouTube blocks GitHub's IP range |

The repository must allow workflows to write: Settings → Actions → General → Workflow permissions → **Read and write**.

### Site build check

On pull requests and pushes touching `src/`, `content/`, or the build config, runs `astro check` and `npm run build`.

## Local development

Python 3.10+ and Node 22+.

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-sync.txt
cp data/config.example.yml data/config.yml   # fill in keys
python -m pytest -q

npm install
npm run dev        # http://localhost:4321
npm run check      # astro check
npm run build      # writes dist/
npm run preview    # serve dist/ locally
```

Sync examples:

```bash
python video_sync.py --dry-run             # what would be ingested
python video_sync.py -n 1                  # ingest one new video
python video_sync.py --mode repair
python video_sync.py -i https://www.youtube.com/watch?v=abc123DEF45   # regenerate one sermon
python video_sync.py --model claude-sonnet-5 -i abc123DEF45           # with a different model
```

Only videos in a channel playlist are considered. Live and upcoming broadcasts, unlisted or private videos, and videos under 25 minutes are skipped.

## Local schedule

YouTube blocks transcript fetches from GitHub's IP ranges. The weekly job runs on a home computer so those requests use a normal residential IP. It keeps a separate checkout and only commits `content/sermons` and `data/failed`.

Sunday at 6:00 PM MST and Monday at 6:00 AM MST, at most 3 new videos each run. MST is UTC-7 year-round. Monday morning catches a sermon uploaded after Sunday evening's run. If the computer is off or asleep, the missed run starts the next time it is on.

### Linux

Checkout: `~/.local/share/impact-recap/checkout`.

```bash
chmod +x scripts/sync-sermons.sh scripts/install-local-sync.sh
./scripts/install-local-sync.sh
cp data/config.example.yml ~/.config/impact-recap/config.yml
chmod 600 ~/.config/impact-recap/config.yml
# fill in channel_id, yt_token, and claude_token; leave the proxy lines unset
./scripts/sync-sermons.sh
```

Logs: `journalctl --user -u impact-recap-sync.service`. The timer needs linger (`loginctl enable-linger`) to fire when you are logged out.

### Windows

Requires Git for Windows, Python 3.10 or newer with the `py` launcher, and an SSH key that can push without asking for a passphrase. Checkout: `%LOCALAPPDATA%\impact-recap\checkout`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-local-sync.ps1
copy data\config.example.yml "$env:APPDATA\impact-recap\config.yml"
# fill in channel_id, yt_token, and claude_token; leave the proxy lines unset
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-sermons.ps1
```

The task is named `ImpactRecapSync`. It runs while that Windows user is logged in, including with the screen locked. A sleeping PC wakes for it when Allow wake timers is enabled in Power Options. The log is `%LOCALAPPDATA%\impact-recap\sync.log`.

## Model and cost

`data/prompt.yaml` sets the model (`claude-sonnet-5-5`). A sermon is roughly 15k input and 2k output tokens, about 5 cents. A `full` regenerate of the library is about $14. Override per run with `--model` or in `data/config.yml` with `ai_model`.

## Site

Astro 7, static output. Pages:

- `/` latest sermons and an "In Case You Missed It" row
- `/library/` every sermon, with search, tag filter (`?tag=Faith`), sort, and pagination
- `/sermons/<date>_<videoId>/` the recap page with real title, description, and thumbnail in the HTML head
- `/contact/` Netlify form
- `/privacy/`, `/terms/`, and `/accessibility/`
- `/llms.txt` a short map of the public pages for LLM tools. It does not control crawling.

### Contact form

The contact page posts to Netlify Forms. There is no separate JavaScript submit handler. Without JavaScript, the form still posts to `/contact/?sent=1`.

- Form name: `contact`
- Honeypot field: `fax` (hidden off-screen, not with `display: none`)
- The visitor's subject is stored as `topic`. A hidden `subject` input sets the notification subject to `[Jocal.dev] New inquiry - %{siteName} - #%{submissionId}`. Leave those `%{...}` placeholders as written.
- Google reCAPTCHA v2, the "I'm not a robot" checkbox, is enabled with `data-netlify-recaptcha`. The checkbox does not render in `npm run dev`. It appears on a Netlify deploy, and form detection must be turned on in the Netlify UI.
- After a deploy, send a test message and confirm it under Forms. The notification subject can only be confirmed in that email.

The privacy policy states that the form uses Google reCAPTCHA.

Old URLs (`/sermons/<slug>/video.html`, `/library.html`, `/contact.html`) redirect via `netlify.toml`.

The design is the original Bootstrap 4 stylesheet (`src/styles/style.css`). jQuery and Slick were replaced by small scripts in `src/scripts/`.

## Troubleshooting

- **A run skips a new sermon with "no retrievable transcript"**: captions may not be ready yet; the next run retries. If it persists for every video on GitHub Actions, YouTube is blocking that runner; use the local schedule above. A proxy in `config.yml` is only for a machine whose own IP is blocked.
- **A sermon failed validation**: read `data/failed/<videoId>.txt`, then re-run with `-i <videoId>`.
- **Netlify build fails**: `npm run build` locally shows the Zod error and which file in `content/sermons/` is malformed.
- **A sermon has a placeholder title**: run `--mode repair`.
