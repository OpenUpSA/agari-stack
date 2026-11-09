# Schemas

Reference schemas kept with the stack so they survive even if the repos they
originated in move or change.

| File(s) | Origin | Status |
| --- | --- | --- |
| `agari-index-mapping.json` | `agari-helm/helm/elasticsearch/configs/` (legacy genomics stack) | **Not applied.** Defines the old ICGC-era `agari-index` document (analysis/file/study/sample/experiment) written by Song/Arranger/Folio. The platform replaced those services and indexes isolates instead. Kept for reference only. |
| `cholera.json`, `klebsiella.json`, `malariaHuman.json`, `malariaVector.json`, `mpox.json`, `sarscov.json` | `agari-datagen/schemas/` | The per-pathogen TSV column schemas. A TSV validated against one of these becomes `isolate_data`, whose keys are flattened into the top level of the search document. |

The mapping that **is** applied to Elasticsearch is
`charts/elasticsearch/configs/agari-index-mapping.json` - despite sharing a
name with the legacy file above, this is **the current index body pulled from
the server** (mappings *and* settings, including the `lowercase_normalizer` the
mappings reference). It ships with the chart (`indexDefaults.mappingFile`) and
is applied by the index-template Job, which merges two environment adaptations
into it so the file stays byte-identical to the server's copy:

* `number_of_shards` / `number_of_replicas` come from the chart's values - a
  single-node dev cluster cannot hold the file's `replicas: 1`;
* `visibility` is pinned to `keyword` - the platform's access filter runs a
  `terms` query on it with values like `semi-private`, which a dynamically
  mapped `text` field would tokenize into `semi`+`private` and never match.
