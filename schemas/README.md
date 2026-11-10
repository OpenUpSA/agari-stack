# Schemas

Reference schemas kept with the stack so they survive even if the repos they
originated in move or change.

| File(s) | Origin | Status |
| --- | --- | --- |
| `cholera.json`, `klebsiella.json`, `malariaHuman.json`, `malariaVector.json`, `mpox.json`, `sarscov.json` | `agari-datagen/schemas/` | The per-pathogen TSV column schemas. A TSV validated against one of these becomes `isolate_data`, whose keys are flattened into the top level of the search document. |

The only mapping is `charts/elasticsearch/configs/agari-index-mapping.json` -
**the index body pulled from the server** (mappings *and* settings,
including the `lowercase_normalizer` the mappings reference), with one local
repair described below. It ships with the chart (`indexDefaults.mappingFile`)
and is applied by the index-template Job, which merges two environment
adaptations into it:

* `number_of_shards` / `number_of_replicas` come from the chart's values - a
  single-node dev cluster cannot hold the file's `replicas: 1`;
* `visibility` is pinned to `keyword` - the platform's access filter runs a
  `terms` query on it with values like `semi-private`, which a dynamically
  mapped `text` field would tokenize into `semi`+`private` and never match.

## Local repair: the dynamic templates

The server copy's dynamic templates never fired. Their `match` patterns use
`|` alternation (`lineage*|clade*`), but Elasticsearch's wildcard matcher
treats `|` as a literal character, so **every** string field fell through to
`catch_all_strings` and was mapped `text`. Aggregating or sorting on a `text`
field is a hard error - `Text fields are not optimised for operations that
require per-document field data` - so the SPA's filter facets and column sorts
came back as `503` from `/search/`.

The chart's copy therefore sets `match_pattern: "regex"` and rewrites those
patterns as regexes (Elasticsearch matches them against the *whole* field
name, so `n50` still means exactly `n50`). Three deliberate deviations from
the server copy:

* `age_fields` is `.*_age|age`, not `*age*` - `lineage_clade_name`,
  `infectious_agent` and `*_stage` all contain "age", and mapping them `integer`
  with `ignore_malformed` would silently discard every value;
* `dates_flexible` is `.*_date|date.*|.*_at|.*At`, not `*date*` - the broad
  pattern also matched `updated_by` and `validate_*`;
* `catch_all_strings` and `long_text_fields` map `keyword` (keeping a `.text`
  subfield) rather than `text`, so no field can hit the fielddata error at all.
  `other_numeric_fields` was added for the UI's numeric columns that arrive as
  strings (`breadth_of_coverage_value`, `diagnostic_pcr_Ct_value_1`, ...);
  `fasta_files` lost `index: false`, which made `term`/`wildcard` queries on
  those fields error.

Wildcard search stays case-insensitive because the SPA sends
`case_insensitive: true`, and filters still work because the platform strips
the `.keyword` suffix before the query reaches the cluster.

**After changing this file:** `scripts/deploy.sh` re-applies the template, but
existing indices keep the mapping they were born with (`PUT _mapping` only ever
adds fields). Delete the index and reindex from Postgres - the database is the
source of truth:

```sh
kubectl exec -n agari deploy/agari-elasticsearch -- curl -sS -X DELETE localhost:9200/agari-samples
kubectl exec -n agari deploy/agari-platform-web -c web -- python manage.py shell -c "
from apps.search.backend import get_backend, isolate_document
from apps.submissions.models import Isolate
qs = Isolate.objects.select_related('submission','submission__project','submission__project__pathogen').filter(deleted_at__isnull=True)
print(get_backend().reindex([isolate_document(i) for i in qs.iterator()], recreate=True))"
```
