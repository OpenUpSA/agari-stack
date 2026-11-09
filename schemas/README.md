# Schemas

Reference schemas kept with the stack so they survive even if the repos they
originated in move or change.

| File(s) | Origin | Status |
| --- | --- | --- |
| `agari-index-mapping.json` | `agari-helm/helm/elasticsearch/configs/` (legacy genomics stack) | **Not applied.** Defines the old ICGC-era `agari-index` document (analysis/file/study/sample/experiment) written by Song/Arranger/Folio. The platform replaced those services and indexes isolates instead. Kept for reference only. |
| `cholera.json`, `klebsiella.json`, `malariaHuman.json`, `malariaVector.json`, `mpox.json`, `sarscov.json` | `agari-datagen/schemas/` | The per-pathogen TSV column schemas. A TSV validated against one of these becomes `isolate_data`, whose keys are flattened into the top level of the search document. |

The mapping that **is** applied to Elasticsearch lives in
`charts/elasticsearch/configs/agari-samples-mapping.json` — it matches the
document `agari-platform/apps/search/backend.py: isolate_document()` actually
writes to the `agari-samples` index, and is installed by the chart's
index-template Job (`indexDefaults.mappingFile` in the chart's values).
