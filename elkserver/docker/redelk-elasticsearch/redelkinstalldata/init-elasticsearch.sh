#!/usr/bin/env bash
#
# Part of RedELK
# Init script for RedELK elasticsearch image
#
# Authors:
#   - Outflank B.V. / Marc Smeets
#   - Lorenzo Bernardi (@fastlorenzo)
#

if [[ ! -f $CERTS_DIR_ES/bundle.zip ]]; then
  echo "[*] Generating RedELK certificates"
  bin/elasticsearch-certutil cert --silent --pem --in /usr/share/elasticsearch/config/instances.yml -out $CERTS_DIR_ES/bundle.zip;
  unzip $CERTS_DIR_ES/bundle.zip -d $CERTS_DIR_ES;
fi;
if [[ ! -f $CERTS_DIR_ES/redelk-logstash/redelk-logstash.pkcs8.key ]]; then
  echo "[*] Converting logstash private key to pkcs8"
  openssl pkcs8 -in $CERTS_DIR_ES/redelk-logstash/redelk-logstash.key -topk8 -nocrypt -out $CERTS_DIR_ES/redelk-logstash/redelk-logstash.pkcs8.key
fi
chown -R 1000:0 $CERTS_DIR_ES
chmod u+rwX,g+rX,o-rwx $CERTS_DIR_ES
READY=1
while [[ $READY -ne 0 ]]; do
  echo "[*] Waiting for Elasticsearch to be up"
  curl $ES_URL/ --cacert $CERTS_DIR_ES/ca/ca.crt -s -u elastic:$ELASTIC_PASSWORD >/dev/null 2>&1
  READY=$?
  sleep 1
done

# Install ILM policy and index templates BEFORE creating the redelk_ingest user.
# Logstash authenticates as redelk_ingest and creates daily indices (rtops-*, redirtraffic-*,
# etc.) with manage_template => false. If an index is created before its template exists,
# ES dynamic-maps string fields (e.g. redir.backend.name) as text + .keyword, permanently
# breaking aggregations on that index. By installing templates here — before the ingest
# user exists — we guarantee logstash can never write a document before the templates are
# in place. This is the only hard ordering guarantee available in the container graph.
TEMPLATE_DIR="/usr/share/elasticsearch/redelkinstalldata/templates"
if [[ -d "$TEMPLATE_DIR" ]]; then
  echo "[*] Installing RedELK ILM policy"
  curl -X PUT "$ES_URL/_ilm/policy/redelk" --cacert $CERTS_DIR_ES/ca/ca.crt -s -u elastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data-binary @"$TEMPLATE_DIR/redelk_elasticsearch_ilm.json"
  echo "[*] Installing RedELK index templates"
  for tf in "$TEMPLATE_DIR"/redelk_elasticsearch_template_*.json; do
    name=$(basename "$tf" .json | sed 's/redelk_elasticsearch_template_//')
    curl -X POST "$ES_URL/_template/$name" --cacert $CERTS_DIR_ES/ca/ca.crt -s -u elastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data-binary @"$tf"
  done
else
  echo "[!] RedELK template directory $TEMPLATE_DIR not found — index templates will be installed by redelk-base (race window open)"
fi

echo "[*] Setting password for user kibana_system"
curl -XPOST $ES_URL/_security/user/kibana_system/_password --cacert $CERTS_DIR_ES/ca/ca.crt -s -uelastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data "{\"password\":\"$CREDS_kibana_system\"}"
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echoerror "[X] Error setting password for user kibana_system (Error Code: $ERROR)."
fi

echo "[*] Setting password for user logstash_system"
curl -XPOST $ES_URL/_security/user/logstash_system/_password --cacert $CERTS_DIR_ES/ca/ca.crt -s -uelastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data "{\"password\":\"$CREDS_logstash_system\"}"
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echoerror "[X] Error setting password for user logstash_system (Error Code: $ERROR)."
fi

echo "[*] Creating redelk_ingest role"
curl -XPOST  $ES_URL/_security/role/redelk_ingest --cacert $CERTS_DIR_ES/ca/ca.crt -s -uelastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data-binary @- << EOF
{
  "cluster": ["monitor","cluster:admin/xpack/monitoring/bulk","manage_ilm"],
  "indices": [
    {
      "names": ["rtops*","redirtraffic*","credentials-*","bluecheck-*","email-*","implantsdb","auditbeat*","filebeat*","packetbeat*","apm*","heartbeat*","nagioscheckbeat*","metricbeat*",".monitor*"],
      "privileges": ["create","read","write","monitor","index","manage","delete","manage_ilm"]
    }
  ],
  "run_as":[]
}
EOF
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echoerror "[X] Error creating redelk_ingest role (Error Code: $ERROR)."
fi

echo "[*] Creating redelk_ingest user"
curl -XPOST  $ES_URL/_security/user/redelk_ingest --cacert $CERTS_DIR_ES/ca/ca.crt -s -uelastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data-binary @- << EOF
{
  "password": "$CREDS_redelk_ingest",
  "roles": ["redelk_ingest"],
  "full_name": "RedELK Ingest"
}
EOF
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echoerror "[X] Error creating redelk_ingest user (Error Code: $ERROR)."
fi

echo "[*] Creating redelk user"
curl -XPOST  $ES_URL/_security/user/redelk --cacert $CERTS_DIR_ES/ca/ca.crt -s -uelastic:$ELASTIC_PASSWORD -H 'Content-Type: application/json' --data-binary @- << EOF
{
  "password": "$CREDS_redelk",
  "roles": ["superuser"],
  "full_name": "RedELK Operator"
}
EOF
ERROR=$?
if [ $ERROR -ne 0 ]; then
    echoerror "[X] Error creating redelk user (Error Code: $ERROR)."
fi
