# TCG multiplayer server

The server reads `catalog/catalog.json`, the exact versioned manifest published
by the Godot client project's **Card Editor -> Publish catalog** action.
Commit that file with server releases. Artwork and sound binaries stay in the
client; the server needs only the manifest and authoritative gameplay records.

Clients must match the server catalog hash. Decks submit IDs and the version;
the server ignores client stats/effects and resolves IDs from its own catalog.
Summons also resolve from this catalog, even when not present in either deck.
Stable IDs preserve saved deck references across balance changes.

Publish workflow: save drafts in the client project, click Publish catalog,
copy the generated catalog/catalog.json here, commit/push to main for Railway,
then distribute the matching exported client. Do not copy user save folders.

The initial catalog contains the current eight cards. Further test execution
was intentionally stopped at the user's request; the user will playtest.
