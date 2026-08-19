#!/usr/bin/env bash
set -Eeuo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MONGO_CONTAINER_NAME="${MONGO_CONTAINER_NAME:-mongodb}"
DATABASE="${DATABASE:-BifrostDB}"

RETENTION_HOURS="${RETENTION_HOURS:-48}"
BATCH_SIZE="${BATCH_SIZE:-5000}"

COMPACT_AFTER_DELETE="${COMPACT_AFTER_DELETE:-1}"
DELETE_WITHOUT_EXECUTION_DATE="${DELETE_WITHOUT_EXECUTION_DATE:-0}"

LOG_DIR="/u01/scripts/log"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/cleanmongoDB_$(date '+%Y%m%d_%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "############################################################"
echo "START $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "############################################################"

echo "[INFO] Container: $MONGO_CONTAINER_NAME"
echo "[INFO] Database: $DATABASE"
echo "[INFO] Retention hours: $RETENTION_HOURS"
echo "[INFO] Batch size: $BATCH_SIZE"
echo "[INFO] Compact after delete: $COMPACT_AFTER_DELETE"
echo "[INFO] Delete without executionDateTime: $DELETE_WITHOUT_EXECUTION_DATE"

if ! docker ps --format '{{.Names}}' | grep -qx "$MONGO_CONTAINER_NAME"; then
  echo "[ERROR] Container $MONGO_CONTAINER_NAME nao esta em execucao"
  exit 1
fi

CUTOFF_UTC="$(date -u -d "-${RETENTION_HOURS} hours" '+%Y-%m-%dT%H:%M:%SZ')"

echo "[INFO] Data de corte UTC: $CUTOFF_UTC"
echo "[INFO] Regra: apagar executionDateTime < $CUTOFF_UTC"

docker exec -i "$MONGO_CONTAINER_NAME" mongo "$DATABASE" --quiet <<MONGO
var collections = ["messages", "deadletters", "deadlettersHistory"];
var cutoff = ISODate("$CUTOFF_UTC");
var batchSize = $BATCH_SIZE;
var compactAfterDelete = "$COMPACT_AFTER_DELETE" === "1";
var deleteWithoutExecutionDate = "$DELETE_WITHOUT_EXECUTION_DATE" === "1";

print("[INFO] Mongo database: " + db.getName());
print("[INFO] Cutoff UTC: " + cutoff.toISOString());

function countSafe(collection, query) {
  try {
    return collection.count(query);
  } catch (e) {
    print("[ERROR] Falha ao contar collection=" + collection.getName() + " erro=" + e.message);
    return -1;
  }
}

function printStats(collectionName, label) {
  var collection = db.getCollection(collectionName);

  try {
    var s = collection.stats();

    print(
      "[STATS_" + label + "] " +
      collectionName +
      " count=" + s.count +
      " sizeGB=" + (s.size / 1024 / 1024 / 1024).toFixed(2) +
      " storageSizeGB=" + (s.storageSize / 1024 / 1024 / 1024).toFixed(2)
    );
  } catch (e) {
    print("[WARN] Falha stats collection=" + collectionName + " erro=" + e.message);
  }
}

function ensureIndex(collectionName) {
  try {
    db.getCollection(collectionName).createIndex(
      { executionDateTime: 1 },
      { background: true }
    );

    print("[INFO] Indice OK: " + collectionName + ".executionDateTime");
  } catch (e) {
    print("[WARN] Falha indice collection=" + collectionName + " erro=" + e.message);
  }
}

function deleteByQuery(collectionName, query, label) {
  var collection = db.getCollection(collectionName);
  var totalDeleted = 0;
  var batch = 0;

  while (true) {
    var ids = collection
      .find(query, { _id: 1 })
      .limit(batchSize)
      .map(function(doc) {
        return doc._id;
      });

    if (ids.length === 0) {
      break;
    }

    batch++;

    var result = db.runCommand({
      delete: collectionName,
      deletes: [
        {
          q: { _id: { \$in: ids } },
          limit: 0
        }
      ],
      writeConcern: {
        w: 1,
        wtimeout: 60000
      }
    });

    if (result.ok !== 1) {
      print("[ERROR] Falha delete collection=" + collectionName + " label=" + label);
      printjson(result);
      throw new Error("Falha delete " + collectionName);
    }

    totalDeleted += result.n || 0;

    print(
      "[DELETE] collection=" + collectionName +
      " label=" + label +
      " batch=" + batch +
      " deleted_batch=" + (result.n || 0) +
      " deleted_total=" + totalDeleted
    );

    sleep(100);
  }

  return totalDeleted;
}

collections.forEach(function(collectionName) {
  print("------------------------------------------------------------");
  print("[INFO] Limpando collection: " + collectionName);

  ensureIndex(collectionName);
  printStats(collectionName, "BEFORE");

  var collection = db.getCollection(collectionName);

  var oldQuery = {
    executionDateTime: {
      \$lt: cutoff
    }
  };

  var withoutDateQuery = {
    \$or: [
      { executionDateTime: { \$exists: false } },
      { executionDateTime: null }
    ]
  };

  var totalBefore = countSafe(collection, {});
  var oldBefore = countSafe(collection, oldQuery);
  var withoutDateBefore = countSafe(collection, withoutDateQuery);

  print("[COUNT_BEFORE] collection=" + collectionName + " total=" + totalBefore + " old=" + oldBefore + " without_executionDateTime=" + withoutDateBefore);

  var deletedOld = deleteByQuery(collectionName, oldQuery, "old");

  var deletedWithoutDate = 0;

  if (deleteWithoutExecutionDate) {
    deletedWithoutDate = deleteByQuery(collectionName, withoutDateQuery, "without_executionDateTime");
  }

  var totalAfter = countSafe(collection, {});
  var oldAfter = countSafe(collection, oldQuery);
  var withoutDateAfter = countSafe(collection, withoutDateQuery);

  print("[COUNT_AFTER] collection=" + collectionName + " total=" + totalAfter + " old=" + oldAfter + " without_executionDateTime=" + withoutDateAfter);
  print("[SUMMARY] collection=" + collectionName + " deleted_old=" + deletedOld + " deleted_without_executionDateTime=" + deletedWithoutDate);

  if (oldAfter !== 0) {
    print("[ERROR] Ainda existem documentos antigos em " + collectionName + ": " + oldAfter);
    throw new Error("Limpeza incompleta em " + collectionName);
  }

  if (compactAfterDelete && (deletedOld > 0 || deletedWithoutDate > 0)) {
    print("[INFO] Compactando collection: " + collectionName);
    var compactResult = db.runCommand({ compact: collectionName });
    printjson(compactResult);
  } else {
    print("[INFO] Compact ignorado collection=" + collectionName);
  }

  printStats(collectionName, "AFTER");
});

print("[INFO] Processo de limpeza concluido com sucesso.");
MONGO

echo "############################################################"
echo "END $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "############################################################"

find "$LOG_DIR" -maxdepth 1 -name 'cleanmongoDB_*.log' -type f -mtime +30 -delete || true