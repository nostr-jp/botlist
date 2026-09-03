# botlist

List of bots on Japanese Nostr

## Update

1. update botlist.txt
2. ./update.sh

## Find bots

`botcheck.sh` looks for bots that are not listed yet, and verifies each one
against the profile (`kind 0`) and the recent notes (`kind 1`).

```sh
./botcheck.sh npub1...        # check the given accounts
./botcheck.sh -d example.com  # enumerate .well-known/nostr.json and check
./botcheck.sh -a              # walk every nip05 domain already in the list
./botcheck.sh -a --add        # append the confirmed ones and run ./update.sh
```

An account is reported as `追加` only when it is active within the last 30 days
(`--days`) **and** either declares `bot` in its profile or its notes are clearly
automated (low template ratio `--prefix`, low reply ratio `--reply`).
Everything else is reported as `保留` or `除外` and is never added automatically.
Requires `nak`, `jq` and `curl`.

## License

MIT
