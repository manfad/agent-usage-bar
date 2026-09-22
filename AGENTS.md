# Publishing your usage to AUB

This file is for coding agents. If you are an AI agent (Codex, Gemini CLI, Cursor, Claude Code,
Copilot, anything else) and your product has a usage or billing endpoint, you can add yourself to
this app by writing one folder. No code changes, no rebuild, no pull request. Everything you need
is on this page.

## What the app is

AUB (Agent-Usage-Bar) is a macOS menu-bar app. It shows, for each agent it knows about, how much of that
agent's allowance is **left** — one horizontal bar per limit, with the remaining figure beside it
and the reset underneath:

```
Claude    5h limit
          ▓▓▓▓░░░░░░░░░░   29%
            Resets in 45m

          Weekly limit
          ▓░░░░░░░░░░░░░    7%
             Resets Sep 28
```

Grok and Claude are compiled in. Everything else is a **provider folder** discovered at runtime.
Providers are re-read on every refresh, which happens every 15 minutes, and when the user opens
the menu if the last reading is more than 2 minutes old. A folder added while the app is running
appears without a restart.

## Where to put your provider

```
$AGENT_USAGE_HOME/providers/<id>/       # if AGENT_USAGE_HOME is set
~/.config/agent-usage/providers/<id>/   # otherwise
```

Rules:

- **The folder name is your agent id.** Use something short and stable: `cursor`, `gemini-cli`,
  `codex`. It is the key the user's ordering and hide settings are stored under, so renaming the
  folder loses those.
- The folder must contain `provider.json`. It may also contain a fetch script and an icon.
- Using an id that is already built in (`grok`, `claude`) **replaces** that built-in, in its place
  in the list. Do not do this by accident.
- A folder is silently ignored if it has no `provider.json`, if that file is not valid JSON, if it
  has no `name`, or if it describes neither way of fetching. Silently: the user sees nothing at
  all, not an error. If your provider does not appear, that is the first thing to check.
- Folders whose name starts with `.` are skipped.
- Providers are listed in folder-name order, after the built-ins.

## provider.json

Two ways to produce numbers. **Mode A** runs a command you supply. **Mode B** describes an HTTP
call declaratively and maps the response. Pick one; if both are present, `fetch` wins.

```json
{
  "name": "Cursor",
  "icon": "icon.svg",
  "color": "#D97757",

  "fetch": "./fetch.sh",

  "request": {
    "url": "https://api.example.com/usage",
    "method": "GET",
    "headers": { "Authorization": "Bearer {{token}}" }
  },
  "token": { "env": "EXAMPLE_API_KEY" },
  "sessions": [
    {
      "id": "weekly",
      "name": "Weekly limit",
      "kind": "window",
      "usedPercent": "config.creditUsagePercent",
      "resetsAt": "config.currentPeriod.end"
    }
  ]
}
```

### Common fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `name` | string | **yes** | What the user sees beside your bars and in Settings. A folder with no `name` is ignored. Two short words at most: the label column is narrow and wraps to two lines, then truncates. |
| `icon` | string | no | Filename of an SVG in your folder, relative to it. Absolute paths and `~` work too. Missing file means the fallback `cpu` symbol, not an error. |
| `color` | string | no | Hex tint applied to your icon on light backgrounds only; dark mode uses the label colour. `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or without the `#`. Omit it if your mark is black or white by brand. |
| `fetch` | string | mode A | Command that prints the normalized JSON. |
| `request` | object | mode B | The one HTTP call to make. |
| `token` | object | mode B | Where `{{token}}` comes from. Only needed if you use the placeholder. |
| `sessions` | array | mode B | How to read rows out of the response. Mode B with an empty or missing `sessions` is ignored. |

Unknown fields are ignored, so you cannot break the app by adding your own keys, but you also
cannot rely on them.

## Mode A: a fetch command

```json
{ "name": "Cursor", "fetch": "./fetch.sh" }
```

`fetch` is run through `/bin/sh` with the working directory set to your provider folder, so all
three of these work:

- `./fetch.sh` — a file in your folder. It runs even without the executable bit.
- `/usr/local/bin/my-usage-tool` — an absolute path.
- `my-cli usage --json | jq '{sessions: .limits}'` — a shell one-liner.

Contract:

- Print the normalized JSON (below) on **stdout** and exit **0**.
- You get **20 seconds**. Past that the process is killed and the row reads `<name> script failed`.
- **stderr is discarded.** Do not use it to signal anything; use the `error` field.
- A non-zero exit, a timeout, or empty stdout all read as `<name> script failed`.
- The environment is inherited from the app, with `HOME` and `PATH` guaranteed, and
  `/opt/homebrew/bin` and `/usr/local/bin` appended to `PATH` so tools like `jq` are found when
  the app is launched from Finder rather than a shell. Do not assume anything else about `PATH`,
  and do not assume the user's shell profile has been sourced: it has not.
- Read credentials from a file or an environment variable. Never write one back, and never print
  a token, not even to stderr.

Mode A is the right choice when the API needs more than one call, a signature, pagination, or
arithmetic. Reach for mode B only when one plain request answers the question.

## Mode B: a declarative request

```json
{
  "name": "Example",
  "request": {
    "url": "https://api.example.com/v1/usage",
    "method": "GET",
    "headers": {
      "Authorization": "Bearer {{token}}",
      "x-api-version": "2026-01-01"
    }
  },
  "token": { "file": "~/.example/auth.json", "path": "credentials.accessToken" },
  "sessions": [
    { "id": "weekly", "name": "Weekly limit", "usedPercent": "usage.percent",
      "resetsAt": "usage.period.end" }
  ]
}
```

### `request`

| Field | Required | Notes |
| --- | --- | --- |
| `url` | yes | `{{token}}` in it is substituted. |
| `method` | no | Defaults to `GET`, upper-cased. There is no request body, so anything else is of limited use. |
| `headers` | no | `{{token}}` in any value is substituted. `Accept: application/json` is sent unless you set your own `Accept`. |

The call times out after 30 seconds. `401` or `403` reads as `Sign-in expired`; any other non-200
reads as `Couldn't reach <name>`.

### `token`

Supply **exactly one** source. `path` is optional and reads the token out of the JSON that source
produces; without `path`, the whole trimmed value is the token.

```jsonc
// Four alternatives. Your manifest carries one of them.
"token": { "env": "EXAMPLE_API_KEY" }
"token": { "file": "~/.example/auth.json", "path": "credentials.accessToken" }
"token": { "file": "~/.example/token" }
"token": { "command": "/usr/bin/security find-generic-password -s \"Example-credentials\" -w",
           "path": "oauth.accessToken" }
```

- `env` — an environment variable. Remember that a GUI app does not see variables exported in the
  user's shell profile, so this suits a launch-agent environment more than a developer's `.zshrc`.
- `file` — a path, with `~` expanded and relative paths resolved against your folder.
- `command` — run the same way as `fetch`, with the same 20-second limit. This is how you reach a
  keychain item: shell out to `/usr/bin/security`. Do not expect the app to call the Security
  framework for you; it deliberately does not, because that prompts the user for their login
  password.

The token is read, substituted and dropped. It is never logged, cached or written back.

### Dotted paths

Every value in `sessions`, and `token.path`, is a dotted path into parsed JSON:

| Path | Resolves to |
| --- | --- |
| `config.currentPeriod.end` | Nested object keys. |
| `data.0.results.0.amount.value` | A numeric component indexes an array. Object keys are tried first. |
| `*.key` | `*` takes the first value of an object, by sorted key. Written for a file with one entry under an unpredictable name. |
| `data.*.results.*.amount.value` | On an array, `*` takes the first element. |

A path that does not resolve, or resolves to `null`, counts as missing. A session whose
measurement is missing is **dropped**, not shown as zero, so a mapping typo makes a row vanish.

### `sessions`

Each entry maps one row. `id` is a literal string; everything else named below is a path.

| Field | Kind | Required | Meaning |
| --- | --- | --- | --- |
| `id` | both | **yes** | Literal, stable, unique within your provider. |
| `name` | both | no | Literal. Defaults to `id`, which looks like a bug, so set it. |
| `kind` | both | no | `"window"` (default) or `"credits"`. |
| `usedPercent` | window | one of these two | Path to the share **consumed**, 0–100. |
| `remainingPercent` | window | one of these two | Path to the share **left**, 0–100, for APIs that report it that way. Inverted internally. If both are mapped, `usedPercent` wins. |
| `used` | credits | **yes** | Path to the amount spent. |
| `cap` | credits | no | Path to the allowance. |
| `unit` | credits | no | **Literal**, not a path. Defaults to `"$"`. |
| `resetsAt` | both | no | Path to an ISO 8601 string. |

## The normalized JSON contract

This is what a mode A command prints. Mode B mapping produces exactly this shape internally, so
both modes behave identically from here on. If you are writing mode A, this section is the whole
specification.

```json
{
  "sessions": [
    {
      "id": "five_hour",
      "name": "5h limit",
      "kind": "window",
      "usedPercent": 26,
      "resetsAt": "2026-09-22T05:00:00Z"
    },
    {
      "id": "weekly",
      "name": "Weekly limit",
      "kind": "window",
      "remainingPercent": 16,
      "resetsAt": "2026-09-26T08:00:00Z"
    },
    {
      "id": "credits",
      "name": "API credits",
      "kind": "credits",
      "used": 12.4,
      "cap": 50,
      "unit": "$",
      "resetsAt": "2026-10-01T00:00:00Z"
    }
  ],
  "error": "Sign-in expired"
}
```

- `sessions` is an array of rows, shown in the order you give them.
- `id` is required and must be unique. If two rows share an id, the first usable one wins.
- `name` falls back to `id`.
- `kind` defaults to `"window"`. An unrecognised kind is treated as a window.
- A window row carries `usedPercent` or `remainingPercent`, as the two rows above show. Send the
  one your API already reports and let the app invert it; do not compute `100 - x` yourself.
- Numbers may be JSON numbers or numeric strings: `26` and `"26"` are both read as 26. `NaN` and
  infinities are rejected.
- `resetsAt` is optional ISO 8601, with or without fractional seconds. An unparseable value is
  treated as absent: the row still shows, just with no reset line.
- `error` is optional and only used **when no row parsed**. With usable rows present it is
  ignored, so you cannot show a warning alongside numbers. With no rows it becomes the grey line
  under your name, which is the right way to say "the user needs to sign in again".

### `window` — a refilling allowance

Needs a percentage on a **0–100** scale. Not 0–1. Report it whichever way your API already does:

- `usedPercent` — the share **consumed**. `usedPercent: 26` draws a 74% full bar labelled `74%`.
- `remainingPercent` — the share **left**. `remainingPercent: 74` draws the same row.

Both are clamped to 0–100, and `usedPercent` wins if you send both. Getting the direction wrong
inverts the bar and is the easiest mistake to make here, so check a known value before you ship:
a nearly-unused allowance must show a nearly-full bar and a high figure.

### `credits` — an amount already spent

Needs `used`. `cap` and `unit` are optional.

| | With `cap` | Without `cap` |
| --- | --- | --- |
| Bar | Drains: `(cap - used) / cap` | Empty track, no fill — there is nothing to measure against |
| Figure | What is left: `cap - used` | What was spent: `used` |
| Caption | `used $12.40 of $50.00` | `used this period` |

`unit` defaults to `"$"`. `$`, `€` and `£` lead the number with two decimals (`$37.60`). Any other
unit trails it as a grouped integer (`1,240 tokens`). Grouping and the decimal separator follow
the user's locale. A `cap` of zero or less is treated as absent.

A reset is appended to either caption: `used $12.40 of $50.00 · Resets Oct 1`.

### How resets are worded

You supply a timestamp; the app writes the copy, in the user's timezone and locale.

| Time until `resetsAt` | Shown as |
| --- | --- |
| Under a minute, or already past | `Resets soon` |
| Under an hour | `Resets in 45m` |
| Under 24 hours | `Resets in 3h 20m`, `Resets in 3h` |
| 24 hours or more | `Resets Sep 26` |

Send the real end of the window in UTC or with an offset. Do not pre-format it, do not send a
duration, and do not send a local time with no offset.

## The icon

One SVG in your folder, named by `icon`.

- **24×24** with `viewBox="0 0 24 24"`. Other sizes load, but 24 is what everything else uses.
- **Single colour**, drawn with `fill="currentColor"` (or `stroke="currentColor"` for a line
  mark). The app loads it as a template image and tints it: only the shape matters, and the colour
  in the file is discarded. Multi-colour artwork will flatten to a silhouette, so do not send a
  gradient logo and expect it to survive.
- Keep it a solid, legible mark at 22pt. Hairlines disappear. `stroke-width` around 1.7 with
  `stroke-linecap="round"` reads well; see the built-in marks for the house style.
- No external references, no embedded raster images, no CSS classes, no `<style>` block.
- Put the brand colour in `provider.json` as `color`, not in the SVG.

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
  <path d="M4 12h3l2.5-6 2.5 12 2.5-9 2 3h3.5" fill="none" stroke="currentColor"
        stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
```

## Minimal worked example

Two files. This is a complete, working provider.

`~/.config/agent-usage/providers/acme/provider.json`:

```json
{ "name": "Acme", "fetch": "./fetch.sh" }
```

`~/.config/agent-usage/providers/acme/fetch.sh`:

```sh
#!/bin/sh
set -eu

[ -n "${ACME_API_KEY:-}" ] || {
  echo '{ "sessions": [], "error": "Set ACME_API_KEY" }'
  exit 0
}

response=$(curl -sS --max-time 15 -H "Authorization: Bearer $ACME_API_KEY" \
  https://api.acme.example/v1/usage) || {
  echo '{ "sessions": [], "error": "Couldn'"'"'t reach Acme" }'
  exit 0
}

percent=$(printf '%s' "$response" | jq '.limits.weekly.used_percent')
resets=$(printf '%s' "$response" | jq -r '.limits.weekly.resets_at')

cat <<JSON
{ "sessions": [
    { "id": "weekly", "name": "Weekly limit", "kind": "window",
      "usedPercent": ${percent}, "resetsAt": "${resets}" }
  ] }
JSON
```

Then `chmod +x fetch.sh`. Note the shape of the failure paths: print an `error` and **exit 0**, so
the user reads `Set ACME_API_KEY` instead of `Acme script failed`.

## Testing your provider

Work outside-in, and do not start with the app.

**1. Run your script by hand and validate its output.** This catches most mistakes.

```sh
cd ~/.config/agent-usage/providers/acme
./fetch.sh | jq .
```

`jq` failing means the app will read `Couldn't read usage`. Check the exit status too, since a
script that prints good JSON and then exits non-zero still fails:

```sh
./fetch.sh > /tmp/out.json; echo "exit=$?"; jq . /tmp/out.json
```

Then check the app's own rules against the output: is every `id` unique, is your percentage on a
0–100 scale and pointing the right way (`usedPercent` for consumed, `remainingPercent` for left),
is `resetsAt` a real ISO 8601 instant with an offset, and does every credits row have `used`?

**2. Prove discovery against a throwaway home**, so you are not editing the user's real config
while you iterate:

```sh
mkdir -p /tmp/au-test/providers
cp -R ~/.config/agent-usage/providers/acme /tmp/au-test/providers/
AGENT_USAGE_HOME=/tmp/au-test ./agent-usage --preview
```

`--preview` opens a plain window and fetches live, which is what you want. Note that `--sample`
shows fixed demo data and **never** calls your provider, so it cannot tell you anything about it.

**3. Read the failure text.** Every problem surfaces as one grey line under your name, and each
one points at a different cause:

| Shown | Means |
| --- | --- |
| Your provider is absent entirely | The folder was ignored: no `provider.json`, invalid JSON, no `name`, or neither `fetch` nor a complete `request` |
| `<name> script failed` | Mode A exited non-zero, timed out after 20s, or printed nothing |
| `Couldn't read usage` | Output was not JSON, or no row was usable and you set no `error` |
| `Not signed in` | The `token` source was missing or empty: no such file, unset variable, failed `command`, or a `path` that did not resolve to a non-empty string |
| `Couldn't read sign-in` | The token file exists but could not be read, or its contents are not JSON while `path` is set |
| `Sign-in expired` | Mode B got a 401 or 403 |
| `Couldn't reach <name>` | Mode B timed out, failed to connect, or returned another non-200 |
| `provider.json is incomplete` | Mode B uses `{{token}}` but the manifest has no `token` |

**4. Check both appearances.** Your `color` is used in light mode only. Confirm the mark is
legible against a dark menu too.

## Checklist

- [ ] Folder name is a short, stable id, and is not `grok` or `claude` unless you mean to replace one.
- [ ] `provider.json` is valid JSON with a `name`, and exactly one of `fetch` or `request` + `sessions`.
- [ ] Mode A prints the normalized JSON on stdout, exits 0, finishes inside 20 seconds, and reports trouble through `error` rather than stderr or a non-zero exit.
- [ ] Window rows carry `usedPercent` (share consumed) or `remainingPercent` (share left), on a 0–100 scale, not 0–1, and the direction is verified against a known value.
- [ ] Every credits row has `used`; `cap` is included when the API publishes one, and `unit` is set when it is not dollars.
- [ ] Every `id` is unique and stable across refreshes.
- [ ] `resetsAt` is a real ISO 8601 instant with a timezone, not a duration and not pre-formatted text.
- [ ] No secret is printed, logged or written back; tokens are read from a file, an environment variable or a `command`.
- [ ] The icon is a 24×24 single-colour SVG using `currentColor`, and the brand colour lives in `color`.
- [ ] Verified by running the script by hand, then under `AGENT_USAGE_HOME` with `--preview`.
