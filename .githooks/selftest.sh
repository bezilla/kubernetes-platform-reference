#!/usr/bin/env bash
#
# selftest: proves the pre-push gate rejects what it claims to reject, and --
# just as important -- accepts what it claims to accept.
#
# A gate nobody has watched fail is a gate nobody knows works, and a gate only
# ever watched to fail could be one that refuses everything, which breaks a
# repository just as completely. Each case builds a throwaway repository,
# produces exactly one kind of history, and feeds the hook the same stdin git
# would feed it on a real push:
#
#     <local ref> <local sha> <remote ref> <remote sha>
#
# Every case captures the hook's status with `|| rc=$?` rather than running it
# bare and reading `$?`. That is not style. CI runs its steps under
# `bash -eo pipefail`, where a bare non-zero command kills the step before the
# assertion is reached, so a suite written the other way reports nothing on
# precisely the cases it exists to prove. This file is run under -e, under plain
# bash and through its shebang, and must give identical results under all three.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-push"
ZERO='0000000000000000000000000000000000000000'
CANON_NAME='Paul Bezilla'
CANON_EMAIL='bezilla@protonmail.com'
CANON="${CANON_NAME} <${CANON_EMAIL}>"

pass=0
fail=0

ok()  { printf '  \033[32mok\033[0m   %-60s rc=%s\n' "$1" "${2:-0}"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %-60s rc=%s\n' "$1" "${2:-?}"; fail=$((fail + 1)); }

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

commit_msg() {
	local d="$1" msg="$2"
	printf 'x %s\n' "$RANDOM" > "$d/file.txt"
	git -C "$d" add -- file.txt
	git -C "$d" commit -q -m "$msg"
}

# Push-range mode, as git invokes it.
run_hook() {
	local d="$1" base="$2" tip rc=0
	tip="$(git -C "$d" rev-parse HEAD)"
	( cd "$d" && printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" \
		| "$HOOK" origin >/dev/null 2>&1 ) || rc=$?
	printf '%s' "$rc"
}

# Push-range mode for a tag ref.
run_hook_tag() {
	local d="$1" tagname="$2" obj rc=0
	obj="$(git -C "$d" rev-parse "refs/tags/${tagname}")"
	( cd "$d" && printf 'refs/tags/%s %s refs/tags/%s %s\n' "$tagname" "$obj" "$tagname" "$ZERO" \
		| "$HOOK" origin >/dev/null 2>&1 ) || rc=$?
	printf '%s' "$rc"
}

# --all-history mode, as the CI job invokes it.
run_hook_all() {
	local d="$1" rc=0
	( cd "$d" && "$HOOK" --all-history >/dev/null 2>&1 ) || rc=$?
	printf '%s' "$rc"
}

# --- 1: a clean commit is accepted --------------------------------------------
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file'
rc="$(run_hook "$d" "$base")"
[ "$rc" = '0' ] && ok 'clean commit: accepted' "$rc" \
                || bad 'clean commit was REJECTED -- the gate blocks good history' "$rc"
rm -rf "$d"

# --- 2: wrong author is rejected ----------------------------------------------
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
printf 'x\n' > "$d/file.txt"; git -C "$d" add -- file.txt
GIT_AUTHOR_NAME='Somebody Else' GIT_AUTHOR_EMAIL='somebody@example.invalid' \
	git -C "$d" commit -q -m 'Wrong author'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'wrong author: rejected' "$rc" || bad 'wrong AUTHOR was accepted' "$rc"
rm -rf "$d"

# --- 3: wrong committer is rejected -------------------------------------------
# Distinct from case 2: every server-side merge mode rewrites the committer and
# leaves the author intact, so checking only the author misses all of them.
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
printf 'x\n' > "$d/file.txt"; git -C "$d" add -- file.txt
GIT_COMMITTER_NAME='Some Service' GIT_COMMITTER_EMAIL='noreply@example.invalid' \
	git -C "$d" commit -q -m 'Wrong committer'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'wrong committer: rejected' "$rc" || bad 'wrong COMMITTER was accepted' "$rc"
rm -rf "$d"

# --- 4: a trailer key outside the allowlist is rejected -----------------------
# Reviewed-by is innocuous and is still refused. That is the allowlist working:
# the rule is "these three and nothing else", not a list of things to fear.
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file

Reviewed-by: Someone Else <someone@example.invalid>'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'disallowed trailer key: rejected' "$rc" \
                 || bad 'a trailer OUTSIDE the allowlist was accepted' "$rc"
rm -rf "$d"

# --- 5: Signed-off-by with the canonical identity is accepted -----------------
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" "Add a file

Signed-off-by: ${CANON}"
rc="$(run_hook "$d" "$base")"
[ "$rc" = '0' ] && ok 'Signed-off-by, canonical identity: accepted' "$rc" \
                || bad 'the permitted sign-off was REJECTED' "$rc"
rm -rf "$d"

# --- 6: Signed-off-by naming anyone else is rejected --------------------------
# The key alone is not enough. A sign-off asserts who stands behind the commit,
# so its value is checked as strictly as the author field.
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file

Signed-off-by: Someone Else <someone@example.invalid>'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'Signed-off-by, different identity: rejected' "$rc" \
                 || bad 'a sign-off naming somebody else was accepted' "$rc"
rm -rf "$d"

# --- 7: Verified takes free text ----------------------------------------------
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file

Verified: 9/9 Synced and Healthy, zero pods outside Running/Completed.'
rc="$(run_hook "$d" "$base")"
[ "$rc" = '0' ] && ok 'Verified, free text: accepted' "$rc" \
                || bad 'Verified was REJECTED -- published history carries it' "$rc"
rm -rf "$d"

# --- 8: Measured takes free text ----------------------------------------------
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file

Measured: 0 with kubeconform, 0 without (2 skips), 1 with CI=1 and without.'
rc="$(run_hook "$d" "$base")"
[ "$rc" = '0' ] && ok 'Measured, free text: accepted' "$rc" \
                || bad 'Measured was REJECTED -- published history carries it' "$rc"
rm -rf "$d"

# --- 9: an unlisted evidence key is rejected ----------------------------------
# Tested reads exactly like Verified and Measured and is refused anyway, because
# the allowlist is a list and not a vibe. This is the accepted cost of a tight
# allowlist: the next evidence word needs a one-line change before it can land.
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file

Tested: every case green on three Kubernetes versions.'
rc="$(run_hook "$d" "$base")"
[ "$rc" != '0' ] && ok 'unlisted evidence key (Tested): rejected' "$rc" \
                 || bad 'an unlisted evidence key was accepted -- allowlist is not tight' "$rc"
rm -rf "$d"

# --- 10: a mid-message Key: Value line is not a trailer -----------------------
# git parses only the LAST paragraph as trailers. The SAME word is prose here
# and a trailer in case 7, which is the surprising part and the reason this
# gate uses git's parser rather than a ^Key: regex.
d="$(new_repo)"; base="$(git -C "$d" rev-parse HEAD)"
commit_msg "$d" 'Add a file

Verified: this line is not in the final paragraph.

So it is prose, and this paragraph is what makes it so.'
rc="$(run_hook "$d" "$base")"
[ "$rc" = '0' ] && ok 'mid-message Key: Value, not a trailer: accepted' "$rc" \
                || bad 'ordinary prose was treated as a trailer and REJECTED' "$rc"
rm -rf "$d"

# --- 11: an annotated tag with the wrong tagger is rejected -------------------
d="$(new_repo)"
GIT_COMMITTER_NAME='Some Service' GIT_COMMITTER_EMAIL='noreply@example.invalid' \
	git -C "$d" tag -a v9.9.9 -m 'Release nine'
rc="$(run_hook_tag "$d" 'v9.9.9')"
[ "$rc" != '0' ] && ok 'annotated tag, wrong tagger: rejected' "$rc" \
                 || bad 'a tag tagged by somebody else was accepted' "$rc"
rm -rf "$d"

# --- 12: a correct annotated tag is accepted ----------------------------------
d="$(new_repo)"
git -C "$d" tag -a v1.0.0 -m 'Release one'
rc="$(run_hook_all "$d")"
[ "$rc" = '0' ] && ok 'annotated tag, canonical tagger: accepted' "$rc" \
                || bad 'a correctly tagged release was REJECTED' "$rc"
rm -rf "$d"

# --- 13: a disallowed trailer in a tag ANNOTATION is rejected -----------------
# Without this, a tag is a place to put a trailer the commit gate refused.
d="$(new_repo)"
git -C "$d" tag -a v2.0.0 -m 'Release two

Reviewed-by: Someone Else <someone@example.invalid>'
rc="$(run_hook_all "$d")"
[ "$rc" != '0' ] && ok 'disallowed trailer in a tag annotation: rejected' "$rc" \
                 || bad 'a tag annotation carried a disallowed trailer' "$rc"
rm -rf "$d"

printf '\n%d as expected, %d unexpected\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
