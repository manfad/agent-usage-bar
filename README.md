# AUB (Agent-Usage-Bar)

AUB is a macOS menu-bar app that shows how much of each coding agent's allowance is left. Grok and
Claude are built in and read the sign-in the CLI already wrote; anything else you add yourself as
a provider folder, with no rebuild.

```sh
make app          # builds "AUB.app"
swift test        # runs the tests
./agent-usage --sample    # a window with sample data, no network
./agent-usage --preview   # a window with live data
```

## Adding a provider

Drop a folder in `$AGENT_USAGE_HOME/providers/<id>/`, or in
`~/.config/agent-usage/providers/<id>/` when that variable is unset. The folder name is the agent
id, it must hold a `provider.json`, and it is re-read on every refresh, so a provider added while
the app is running appears without a restart. A folder whose id matches a built-in replaces it.

A provider gets its numbers one of two ways: `"fetch"` names a command that prints normalized
JSON, or `"request"` describes one HTTP call and `"sessions"` maps dotted paths in the response
onto rows. A row is either a `window` (a refilling allowance, measured in percent) or `credits`
(money, spent or left, with an optional cap and unit).

A window row reports its percentage whichever way its API already does: `usedPercent` for the
share consumed, as Claude reports it, or `remainingPercent` for the share left, as Grok reports
it. Both are 0–100, and a remaining figure is inverted internally, so the two are interchangeable
in both modes and in the normalized JSON.

A credits row works the same way round: send `used` when your API reports spend, `remaining` when
it reports a balance; add `cap` if there is an allowance. A balance with no cap shows as a plain
figure with an empty track, which is what prepaid API billing looks like.

```json
{
  "name": "Cursor",
  "icon": "icon.svg",
  "color": "#D97757",
  "fetch": "./fetch.sh"
}
```

**[AGENTS.md](AGENTS.md) is the full specification**: every field of both modes, the normalized
JSON contract, how percentages and resets are read, how to draw the icon, how to test a provider,
and what each failure line means. It is written to be handed to a coding agent as-is.

Worked examples live in `examples/providers/`. `grok` and `claude` there reproduce the built-ins
declaratively; `openai-api` is a fetch-script template.
