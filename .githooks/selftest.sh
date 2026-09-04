#!/usr/bin/env bash
#
# selftest: proves the pre-push gate actually rejects what it claims to reject.
#
# A gate nobody has watched fail is a gate nobody knows works. Each case below
# builds a throwaway repository, produces exactly one kind of bad history, and
# feeds the hook the same stdin git would feed it on a real push:
#
#     <local ref> <local sha> <remote ref> <remote sha>
#
# The forbidden literals are BUILT AT RUNTIME from octal escapes. This file is
# committed, so the hook scans it too; if the literals appeared here directly the
# suite would make the repository unpushable. Case 0 checks the constructed
# strings really do match the hook's pattern, so the escaping cannot rot into a
# test that passes by testing nothing.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-push"
ZERO='0000000000000000000000000000000000000000'
CANON_NAME='Paul Bezilla'
CANON_EMAIL='bezilla@protonmail.com'

# Built from octal escapes so this file contains none of them literally.
TERM_ASSISTANT="$(printf 'C\154aude')"
TERM_VENDOR="$(printf 'Anthrop\151c')"
TERM_TRAILER="$(printf 'Co-Auth\157red-By')"

pass=0
fail=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# Build a throwaway repo with one clean commit. Echoes its path.
new_repo() {
	local d
	d="$(mktemp -d)"
	git -C "$d" init -q -b main
	git -C "$d" config user.name  "$CANON_NAME"
	git -C "$d" config user.email "$CANON_EMAIL"
	printf 'clean\n' > "$d/README.md"
	git -C "$d" add -- README.md
	git -C "$d" commit -q -m 'Base commit'
	printf '%s' "$d"
}

# run_hook <repo> <remote_sha>  -> echoes exit status
run_hook() {
	local d="$1" base="$2" tip
	tip="$(git -C "$d" rev-parse HEAD)"
	( cd "$d" && printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | "$HOOK" origin >/dev/null 2>&1 )
	printf '%s' "$?"
}

# --- case 0: the escaping is real ---------------------------------------------
pattern="$(grep -m1 '^FORBIDDEN=' "$HOOK" | sed "s/^FORBIDDEN='//; s/'$//")"
miss=0
for t in "$TERM_ASSISTANT" "$TERM_VENDOR" "$TERM_TRAILER"; do
	printf '%s\n' "$t" | grep -qiE "$pattern" || miss=$((miss + 1))
done
if [ "$miss" -eq 0 ]; then
	ok 'runtime-built literals still match the hook pattern'
else
	bad "$miss runtime-built literal(s) no longer match the pattern -- the suite is testing nothing"
fi

# --- case 1: canonical identity passes ----------------------------------------
d="$(new_repo)"
printf 'a change\n' > "$d/file.txt"
git -C "$d" add -- file.txt
git -C "$d" commit -q -m 'Add a file'
rc="$(run_hook "$d" "$ZERO")"
[ "$rc" = '0' ] && ok 'canonical identity, clean tree: accepted' \
                || bad "canonical identity was REJECTED (rc=$rc) -- the gate blocks good history"
rm -rf "$d"

# --- case 2: wrong author fails -----------------------------------------------
d="$(new_repo)"
base="$(git -C "$d" rev-parse HEAD)"
printf 'x\n' > "$d/file.txt"
git -C "$d" add -- file.txt
GIT_AUTHOR_NAME='Somebody Else' GIT_AUTHOR_EMAIL='somebody@example.invalid' \
	git -C "$d" commit -q -m 'Wrong author'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'wrong author: rejected' || bad 'wrong AUTHOR was accepted'
rm -rf "$d"

# --- case 3: wrong committer fails --------------------------------------------
# Distinct from case 2: server-side merges rewrite the committer while leaving
# the author intact, so checking only the author would miss every merge-button
# commit.
d="$(new_repo)"
base="$(git -C "$d" rev-parse HEAD)"
printf 'x\n' > "$d/file.txt"
git -C "$d" add -- file.txt
GIT_COMMITTER_NAME='Some Service' GIT_COMMITTER_EMAIL='noreply@example.invalid' \
	git -C "$d" commit -q -m 'Wrong committer'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'wrong committer: rejected' || bad 'wrong COMMITTER was accepted'
rm -rf "$d"

# --- case 4: attribution trailer in the message fails -------------------------
d="$(new_repo)"
base="$(git -C "$d" rev-parse HEAD)"
printf 'x\n' > "$d/file.txt"
git -C "$d" add -- file.txt
git -C "$d" commit -q -m "Add a file

${TERM_TRAILER}: ${TERM_ASSISTANT} <noreply@example.invalid>"
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'attribution trailer in message: rejected' \
                 || bad 'attribution TRAILER was accepted'
rm -rf "$d"

# --- case 5: attribution string in the tree fails -----------------------------
d="$(new_repo)"
base="$(git -C "$d" rev-parse HEAD)"
printf 'written by %s\n' "$TERM_VENDOR" > "$d/notes.txt"
git -C "$d" add -- notes.txt
git -C "$d" commit -q -m 'Add notes'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'attribution string in tree: rejected' \
                 || bad 'attribution string in the TREE was accepted'
rm -rf "$d"

# --- case 6: added then deleted inside one push range fails --------------------
# The tip tree is clean. Only the intermediate commit is dirty, and that commit
# would still be published. A hook that checked only the tip would pass this.
d="$(new_repo)"
base="$(git -C "$d" rev-parse HEAD)"
printf 'written by %s\n' "$TERM_ASSISTANT" > "$d/oops.txt"
git -C "$d" add -- oops.txt
git -C "$d" commit -q -m 'Add a file that should not exist'
git -C "$d" rm -q -- oops.txt
git -C "$d" commit -q -m 'Remove it again'
tip_clean=0
git -C "$d" grep -qiE "$pattern" HEAD -- . 2>/dev/null || tip_clean=1
rc="$(run_hook "$d" "$base")"
if [ "$rc" != '0' ] && [ "$tip_clean" = '1' ]; then
	ok 'forbidden term added then deleted in one range: rejected (tip tree was clean)'
elif [ "$tip_clean" != '1' ]; then
	bad 'case 6 is not testing what it claims: the tip tree still contains the term'
else
	bad 'added-then-deleted term was ACCEPTED -- only the tip is being checked'
fi
rm -rf "$d"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
