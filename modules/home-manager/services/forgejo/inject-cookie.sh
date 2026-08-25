#!/usr/bin/env bash
# Injects a Forgejo session cookie into a Firefox profile's cookies.sqlite
# Usage: inject-cookie.sh <cookies_db> <cookie_name> <session_value> <cookie_host> [remember_value] <sqlite3_bin>
set -eu

cookies_db="$1"
cookie_name="$2"
session_value="$3"
cookie_host="$4"
remember_value="${5:-}"
sqlite3="$6"

expiry=$(( ($(date +%s) + 315360000) * 1000 ))  # milliseconds
now_usec=$(( $(date +%s%N) / 1000 ))  # microseconds

# Query actual column names from the table
cols=$("$sqlite3" "$cookies_db" "PRAGMA table_info(moz_cookies);" 2>/dev/null | cut -d'|' -f2 | tr '\n' ' ')

# Build column list dynamically (only include columns that exist)
insert_cols="originAttributes, name, value, host, path, expiry, lastAccessed, creationTime, isSecure, isHttpOnly"
val_base="'', '$cookie_name', '$session_value', '$cookie_host', '/', $expiry, $now_usec, $now_usec, 0, 1"

for col in inBrowserElement; do
  if echo "$cols" | grep -q "$col"; then
    insert_cols="$insert_cols, $col"
    val_base="$val_base, 0"
  fi
done
if echo "$cols" | grep -q "sameSite"; then
  insert_cols="$insert_cols, sameSite"
  val_base="$val_base, 256"
fi
if echo "$cols" | grep -q "rawSameSite"; then
  insert_cols="$insert_cols, rawSameSite"
  val_base="$val_base, 0"
fi
if echo "$cols" | grep -q "schemeMap"; then
  insert_cols="$insert_cols, schemeMap"
  val_base="$val_base, 1"
fi
if echo "$cols" | grep -q "isPartitionedAttributeSet"; then
  insert_cols="$insert_cols, isPartitionedAttributeSet"
  val_base="$val_base, 0"
fi
if echo "$cols" | grep -q "updateTime"; then
  insert_cols="$insert_cols, updateTime"
  val_base="$val_base, $now_usec"
fi

# Remove old cookies and insert session cookie
"$sqlite3" "$cookies_db" \
  "DELETE FROM moz_cookies WHERE host IN ('$cookie_host', '.$cookie_host') AND name IN ('$cookie_name', 'persistent');" \
  "INSERT INTO moz_cookies ($insert_cols) VALUES ($val_base);"

# Insert remember-me cookie if available
if [ -n "$remember_value" ]; then
  rem_val="'', 'persistent', '$remember_value', '$cookie_host', '/', $expiry, $now_usec, $now_usec, 0, 1"
  for col in inBrowserElement; do
    if echo "$cols" | grep -q "$col"; then
      rem_val="$rem_val, 0"
    fi
  done
  if echo "$cols" | grep -q "sameSite"; then
    rem_val="$rem_val, 256"
  fi
  if echo "$cols" | grep -q "rawSameSite"; then
    rem_val="$rem_val, 0"
  fi
  if echo "$cols" | grep -q "schemeMap"; then
    rem_val="$rem_val, 1"
  fi
  if echo "$cols" | grep -q "isPartitionedAttributeSet"; then
    rem_val="$rem_val, 0"
  fi
  if echo "$cols" | grep -q "updateTime"; then
    rem_val="$rem_val, $now_usec"
  fi

  "$sqlite3" "$cookies_db" \
    "INSERT INTO moz_cookies ($insert_cols) VALUES ($rem_val);"
fi

echo "Cookie injected successfully"
