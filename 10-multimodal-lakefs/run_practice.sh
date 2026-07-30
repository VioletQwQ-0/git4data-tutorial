#!/usr/bin/env bash
# =============================================================================
# Git4Data Part 10 — end-to-end practice: lakeFS (files) × MatrixOne (metadata)
#
# Proves the two version worlds compose into one reproducible training set (an
#   image-classification dataset; label = safe / nsfw):
#   - lakeFS holds the image files; we ingest on a branch, commit, merge to main
#     -> a real lakeFS commit id (the FILE version).
#   - MatrixOne holds the metadata (pointer + commit + hashes + label + license);
#     we dedup / decontaminate / integrity-check / curate in SQL, register the
#     (metadata snapshot, lakeFS commit) binding, THEN snapshot the db so the
#     binding is frozen inside the snapshot (the METADATA version).
#   - REPRODUCE: read a train row's pointer+commit from the snapshot, fetch that
#     exact file back from lakeFS at that commit.
#   Note: lakeFS merge and MatrixOne merge are each atomic on their own side;
#   there is no cross-system transaction here (the file side merges first).
#
# Start the two services first (defaults match these). Pin the lakeFS version
# for a reproducible run:
#   docker run -d --name lakefs -p 8000:8000 \
#     -e LAKEFS_INSTALLATION_USER_NAME=admin \
#     -e LAKEFS_INSTALLATION_ACCESS_KEY_ID=AKIAIOSFOLKFSSAMPLES \
#     -e LAKEFS_INSTALLATION_SECRET_ACCESS_KEY=wJalrXUtnFEMI0000EXAMPLEKEY0000000000 \
#     -e LAKEFS_DATABASE_TYPE=local -e LAKEFS_BLOCKSTORE_TYPE=local \
#     -e LAKEFS_AUTH_ENCRYPT_SECRET_KEY=a-string-used-to-encrypt-secrets-0001 \
#     treeverse/lakefs:1.84.0 run
#   docker run -d --name matrixone -p 6001:6001 matrixorigin/matrixone:4.1.0
# Verified on lakeFS 1.84.0 (local) + MatrixOne 4.1.0.
# =============================================================================
set -euo pipefail

LAKEFS="${LAKEFS_ENDPOINT:-http://127.0.0.1:8000}/api/v1"
AUTH="${LAKEFS_KEY:-AKIAIOSFOLKFSSAMPLES}:${LAKEFS_SECRET:-wJalrXUtnFEMI0000EXAMPLEKEY0000000000}"
MOH="${MO_HOST:-127.0.0.1}"; MOP="${MO_PORT:-6001}"
MO(){ mysql -h "$MOH" -P "$MOP" -uroot -p111 --table "$@"; }       # pretty output
MO_RAW(){ mysql -h "$MOH" -P "$MOP" -uroot -p111 -N -B "$@"; }     # tab-separated, no headers
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "### 1. lakeFS: create repo + ingest branch, upload objects, commit, merge to main"
# create the repo once (a fresh local namespace per repo); reuse it on re-runs
curl -sf -u "$AUTH" -X POST "$LAKEFS/repositories" -H 'Content-Type: application/json' \
  -d '{"name":"media","storage_namespace":"local://media","default_branch":"main"}' >/dev/null 2>&1 || true
# reset the ingest branch so each run starts clean
curl -s  -u "$AUTH" -X DELETE "$LAKEFS/repositories/media/branches/ingest" >/dev/null 2>&1 || true
curl -sf -u "$AUTH" -X POST "$LAKEFS/repositories/media/branches" -H 'Content-Type: application/json' \
  -d '{"name":"ingest","source":"main"}' >/dev/null

# 10 objects. #9 is an EXACT duplicate of #1 (same bytes). #10 is a NEAR duplicate
# of #3 (different bytes, same perceptual hash). Content is tiny stand-in "bytes".
declare -a PATHS=(img/000001.jpg img/000002.jpg img/000003.jpg img/000004.jpg img/000005.jpg \
                  img/000006.jpg img/000007.jpg img/000008.jpg mirror/000001.jpg aug/000003.jpg)
declare -a BYTES=(img-1-bytes img-2-bytes img-3-bytes img-4-bytes img-5-bytes \
                  img-6-bytes img-7-bytes img-8-bytes img-1-bytes img-3-bytes-aug)
declare -a PHASH=(ph-1 ph-2 ph-3 ph-4 ph-5 ph-6 ph-7 ph-8 ph-1 ph-3)
declare -a CHASH
for i in "${!PATHS[@]}"; do
  printf '%s' "${BYTES[$i]}" > "$WORK/o"
  CHASH[$i]="sha256-$(shasum -a 256 "$WORK/o" | cut -c1-12)"
  curl -sf -u "$AUTH" -X POST "$LAKEFS/repositories/media/branches/ingest/objects?path=${PATHS[$i]}" \
       -F "content=@$WORK/o" >/dev/null
done
curl -sf -u "$AUTH" -X POST "$LAKEFS/repositories/media/branches/ingest/commits" \
  -H 'Content-Type: application/json' -d '{"message":"ingest 2026w30"}' >/dev/null
COMMIT=$(curl -sf -u "$AUTH" -X POST "$LAKEFS/repositories/media/refs/ingest/merge/main" \
  -H 'Content-Type: application/json' -d '{"message":"publish 2026w30"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['reference'])")
echo "    lakeFS main commit (the BYTE version) = $COMMIT"

echo "### 2. MatrixOne: load metadata rows that POINT at those bytes @ that commit"
{
echo "DROP SNAPSHOT IF EXISTS mm_dataset_v1; DROP DATABASE IF EXISTS mm_practice;"
echo "CREATE DATABASE mm_practice; USE mm_practice;"
echo "CREATE TABLE samples (sample_id BIGINT PRIMARY KEY, object_uri VARCHAR(256), object_commit VARCHAR(64),"
echo "  content_hash VARCHAR(64), phash VARCHAR(64), label VARCHAR(16), license VARCHAR(16));"
for i in "${!PATHS[@]}"; do
  id=$((i+1))
  lic="'cc0'"; [ "$id" = 6 ] && lic="'unknown'"             # #6 unknown license
  lab="'safe'"; [ "$id" = 7 ] && lab="'nsfw'"; [ "$id" = 5 ] && lab=NULL   # #5 not labeled
  echo "INSERT INTO samples VALUES ($id,'lakefs://media/main/${PATHS[$i]}','$COMMIT','${CHASH[$i]}','${PHASH[$i]}',$lab,$lic);"
done
echo "CREATE TABLE eval_hashes (content_hash VARCHAR(64) PRIMARY KEY);"
echo "INSERT INTO eval_hashes VALUES ('${CHASH[1]}');"   # #2 is a benchmark image
} | MO >/dev/null
echo "    loaded 10 metadata rows"

echo "### 3. metadata-side SQL: dedup / decontaminate / integrity, then data-curation + snapshot"
MO <<SQL
USE mm_practice;
SELECT 'exact_dup_groups' k, COUNT(*) v FROM (SELECT content_hash FROM samples GROUP BY content_hash HAVING COUNT(*)>1) t
UNION ALL SELECT 'near_dup_groups', COUNT(*) FROM (SELECT phash FROM samples GROUP BY phash HAVING COUNT(DISTINCT content_hash)>1) t
UNION ALL SELECT 'contaminated', COUNT(*) FROM samples s WHERE EXISTS(SELECT 1 FROM eval_hashes e WHERE e.content_hash=s.content_hash)
UNION ALL SELECT 'unlabeled', COUNT(*) FROM samples WHERE label IS NULL;

CREATE TABLE dataset_membership (sample_id BIGINT PRIMARY KEY, split_name VARCHAR(16));
INSERT INTO dataset_membership
SELECT s.sample_id, CASE WHEN s.sample_id%5=0 THEN 'test' WHEN s.sample_id%5=1 THEN 'valid' ELSE 'train' END
FROM samples s
WHERE s.label IS NOT NULL AND s.license<>'unknown'
  AND NOT EXISTS(SELECT 1 FROM eval_hashes e WHERE e.content_hash=s.content_hash)
  AND s.sample_id=(SELECT MIN(s2.sample_id) FROM samples s2 WHERE s2.content_hash=s.content_hash);
SELECT split_name, COUNT(*) FROM dataset_membership GROUP BY split_name ORDER BY split_name;
SQL

# real integrity: list the commit's objects and anti-join the pointers (a NULL
# check alone can't tell whether the referenced file actually exists).
curl -sf -u "$AUTH" "$LAKEFS/repositories/media/refs/main/objects/ls?amount=1000&presign=false" \
  | python3 -c "import sys,json;[print(o['path']) for o in json.load(sys.stdin)['results'] if o.get('path_type','object')=='object']" > "$WORK/objs"
{ echo "USE mm_practice; DROP TABLE IF EXISTS lakefs_objects; CREATE TABLE lakefs_objects(path VARCHAR(256));"
  while read -r p; do echo "INSERT INTO lakefs_objects VALUES ('$p');"; done < "$WORK/objs"; } | MO >/dev/null
echo "    real integrity (existence) check — pointers with no object at the commit:"
MO <<SQL
USE mm_practice;
SELECT COUNT(*) AS dangling FROM samples s
WHERE NOT EXISTS (SELECT 1 FROM lakefs_objects o WHERE s.object_uri = CONCAT('lakefs://media/main/', o.path));
SQL

# Register the binding FIRST, then snapshot -> the commit is INSIDE the snapshot.
MO <<SQL >/dev/null
USE mm_practice;
DROP TABLE lakefs_objects;
CREATE TABLE dataset_registry (dataset_version VARCHAR(32) PRIMARY KEY, metadata_snapshot VARCHAR(64), lakefs_repo VARCHAR(64), lakefs_commit VARCHAR(64), n_samples BIGINT, note VARCHAR(128));
INSERT INTO dataset_registry SELECT 'mm_v1','mm_dataset_v1','media','$COMMIT',COUNT(*),'metadata snapshot x lakeFS commit' FROM dataset_membership;
CREATE SNAPSHOT mm_dataset_v1 FOR DATABASE mm_practice;
SQL
echo "    bound (frozen inside the snapshot): metadata snapshot mm_dataset_v1  ×  lakeFS commit ${COMMIT:0:12}…"

echo "### 4. REPRODUCE: read a train row from the snapshot, fetch its exact bytes from lakeFS"
read -r URI RCOMMIT < <(MO_RAW <<SQL
USE mm_practice;
SELECT s.object_uri, s.object_commit
FROM samples {SNAPSHOT='mm_dataset_v1'} s JOIN dataset_membership {SNAPSHOT='mm_dataset_v1'} m ON s.sample_id=m.sample_id
WHERE m.split_name='train' ORDER BY s.sample_id LIMIT 1;
SQL
)
OBJPATH="${URI#lakefs://media/main/}"
echo "    train row -> $URI  @  ${RCOMMIT:0:12}…"
BYTES_BACK=$(curl -sf -u "$AUTH" "$LAKEFS/repositories/media/refs/$RCOMMIT/objects?path=$OBJPATH")
echo "    bytes fetched from lakeFS at that commit = \"$BYTES_BACK\""
echo "### DONE — metadata snapshot × lakeFS commit reproduced the actual bytes."
