#!/bin/bash

set -e

export PATH=$HOME/bin:$HOME/go/bin:$PATH
cat botlist.txt | while read LINE; do
  if [ ! -e $LINE.json ]; then
    PK=$(nak decode $LINE | jq -r .pubkey)
    cat /dev/null | nak req -k 0 -a $PK wss://yabu.me wss://relay-jp.nostr.wirednet.jp wss://nos.lol wss://relay.nostr.band 2> /dev/null | jq -r '.content|fromjson' > $LINE.json
    if [ ! -s $LINE.json ]; then
      jo "pubkey=$LINE" "name=null"
      continue
    fi
  fi
  DISPLAY_NAME=$(cat $LINE.json | jq -r .display_name)
  NAME=$(cat $LINE.json | jq -r .name)
  if [ "$DISPLAY_NAME" == "null" -o "$DISPLAY_NAME" == "" ]; then
    jo "pubkey=$LINE" "name=$NAME"
  else
    jo "pubkey=$LINE" "name=$DISPLAY_NAME"
  fi
done | jq --sort-keys --slurp '.' > botlist.json
