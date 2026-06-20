#!/usr/bin/env bash
# resolve_repo.sh — normalize a --repo source of ANY kind into a LOCAL directory
# that deploy-all.sh's existing tar→S3 path can package unchanged.
#
# Supported --repo forms:
#   • local dir   /path/to/repo  ./repo  ~/repo        → used as-is
#   • git URL     https://github.com/org/repo(.git)    → shallow clone
#                 https://gitlab.com/org/repo(.git)
#                 git@host:org/repo.git  ssh://…  git://…  *.git
#   • S3 tarball  s3://bucket/key.tar.gz | .tgz         → download + extract
#   • S3 prefix   s3://bucket/prefix/                   → recursive sync
#
# Everything downstream (codegraph indexing, the HTTP bridge, blue-green refresh)
# operates on the LOCAL copy, so once we land a directory the source kind no
# longer matters. Idempotency is preserved downstream: the S3 artifact ETag
# signature drives genuine-reuse-vs-refresh, independent of where bytes came from.
#
# These functions are pure/side-effect-light so scripts/tests can source + call
# them. classify_repo_source / repo_subdir_from_source do NO network I/O (safe in
# --dry-run and unit tests); only fetch_repo_source touches the network.

# classify_repo_source <value> → prints: local | git | s3 | unknown
classify_repo_source() {
  local v="$1"
  # An existing local path wins over URL-shape heuristics: a local bare-repo mirror
  # dir literally named `repo.git/` is a LOCAL dir, not a URL to clone. Check the
  # filesystem FIRST (but not for s3:// which never names a local path).
  if [[ "$v" != s3://* && -e "$v" ]]; then echo local; return; fi
  case "$v" in
    s3://*)                         echo s3 ;;
    git@*|ssh://*|git://*)          echo git ;;
    *.git|*.git/)                   echo git ;;
    https://github.com/*|http://github.com/*)   echo git ;;
    https://gitlab.com/*|http://gitlab.com/*)    echo git ;;
    https://*.googlesource.com/*)   echo git ;;
    https://bitbucket.org/*|http://bitbucket.org/*) echo git ;;
    *)
      # A path that exists on disk is local; anything else is unknown (caller errors).
      if [[ -e "$v" ]]; then echo local; else echo unknown; fi
      ;;
  esac
}

# repo_subdir_from_source <value> <kind> → default on-host subdir NAME (no slashes,
# no extensions). Used when --repo-subdir isn't given. Network-free.
repo_subdir_from_source() {
  local v="$1" kind="$2" base
  case "$kind" in
    git)
      base="${v%/}"; base="${base##*/}"; base="${base%.git}"
      ;;
    s3)
      base="${v%/}"; base="${base##*/}"
      base="${base%.tar.gz}"; base="${base%.tgz}"; base="${base%.tar}"
      # An s3 prefix like s3://bucket/teamcode/ → "teamcode"; a bucket root
      # s3://bucket → "bucket". Fall back to a stable name if it came out empty.
      ;;
    *)
      base="$(basename "$v")"
      ;;
  esac
  [[ -n "$base" ]] || base="repo"
  echo "$base"
}

# fetch_repo_source <value> <kind> <region> <target_dir> [git_ref]
# Populates <target_dir> with the repo content so that <target_dir> IS the repo
# root (any single-wrapper dir from a tarball is flattened away). The caller names
# <target_dir> after REPO_SUBDIR, so deploy-all's existing `tar -C dirname basename`
# yields a tarball whose top-level dir == REPO_SUBDIR (what bootstrap.sh expects).
# <target_dir> must NOT pre-exist for git (git creates it); for s3 it is created.
# All human logs go to stderr. Returns 1 with an actionable message on any error.
fetch_repo_source() {
  local v="$1" kind="$2" region="$3" target="$4" ref="${5:-}"
  case "$kind" in
    git)
      # SECURITY: reject git transports that can execute arbitrary commands. git's
      # `ext::` / `fd::` remote helpers run a shell command as the "transport", and a
      # source starting with `-` would be parsed as a git OPTION (e.g. --upload-pack=).
      # We only ever want to fetch code, so refuse those forms outright (cross-review).
      case "$v" in
        -*|ext::*|fd::*) say err "refusing unsafe git source '$v' (leading '-' or ext::/fd:: transport)"; return 1 ;;
      esac
      # Validate the ref to a conservative charset so it can't smuggle a git option
      # (e.g. a ref of "--upload-pack=…"). Branches/tags/SHAs all fit this.
      if [[ -n "$ref" && ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        say err "invalid --repo-ref '$ref' (allowed: letters, digits, . _ / -)"; return 1
      fi
      say info "cloning git repo (shallow): $v${ref:+ @ $ref}" >&2
      rm -rf "$target"   # git clone refuses a non-empty existing dir
      # `--` terminates option parsing so the URL/path can never be read as a flag.
      if [[ -n "$ref" ]]; then
        # --branch takes a branch OR tag. An arbitrary commit SHA fails it, so fall
        # back to a full clone + checkout (covers any ref form).
        if ! git clone --depth 1 --branch "$ref" -- "$v" "$target" >&2 2>&1; then
          say warn "shallow --branch '$ref' failed (likely a commit SHA, not a branch/tag); retrying full clone + checkout" >&2
          rm -rf "$target"
          git clone -- "$v" "$target" >&2 2>&1 || { say err "git clone failed: $v"; return 1; }
          ( cd "$target" && git checkout --quiet "$ref" ) >&2 2>&1 || { say err "git checkout '$ref' failed"; return 1; }
        fi
      else
        git clone --depth 1 -- "$v" "$target" >&2 2>&1 || { say err "git clone failed: $v (check URL / network / credentials)"; return 1; }
      fi
      rm -rf "$target/.git"   # dead weight; deploy excludes it from the tarball anyway
      ;;
    s3)
      mkdir -p "$target"
      if [[ "$v" == *.tar.gz || "$v" == *.tgz || "$v" == *.tar ]]; then
        say info "downloading S3 tarball: $v" >&2
        local tb scratch
        tb="$(mktemp /tmp/repo-src.XXXX.tar.gz)"
        scratch="$(mktemp -d)"
        aws s3 cp "$v" "$tb" --region "$region" >&2 || { say err "s3 cp failed: $v"; rm -rf "$tb" "$scratch"; return 1; }
        tar xzf "$tb" -C "$scratch" >&2 2>&1 || { say err "extract failed: $v (not a gzip tar?)"; rm -rf "$tb" "$scratch"; return 1; }
        rm -f "$tb"
        # Flatten a single wrapper dir so <target> is the repo root either way.
        local entries
        mapfile -t entries < <(find "$scratch" -mindepth 1 -maxdepth 1 -printf '%f\n')
        if [[ "${#entries[@]}" -eq 1 && -d "$scratch/${entries[0]}" ]]; then
          mv "$scratch/${entries[0]}"/* "$scratch/${entries[0]}"/.[!.]* "$target"/ 2>/dev/null || true
        else
          mv "$scratch"/* "$scratch"/.[!.]* "$target"/ 2>/dev/null || true
        fi
        rm -rf "$scratch"
      else
        say info "syncing S3 prefix: $v" >&2
        aws s3 sync "$v" "$target" --region "$region" >&2 || { say err "s3 sync failed: $v"; return 1; }
      fi
      # Guard: an empty target means a bad key/prefix — fail loud, not a 0-file deploy.
      if [[ -z "$(ls -A "$target" 2>/dev/null)" ]]; then
        say err "S3 source produced an EMPTY tree: $v (wrong key/prefix?)"; return 1
      fi
      ;;
    *)
      say err "fetch_repo_source: unsupported kind '$kind' (local needs no fetch)"
      return 1
      ;;
  esac
}
