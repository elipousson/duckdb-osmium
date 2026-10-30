# duckdb-osmium

An extension for [duckdb](https://duckdb.org) that allows reading OpenStreetMap data in OSM XML and OSM PBF formats using [libosmium](https://osmcode.org/libosmium).

DuckDB's first-party [`spatial` extension](https://duckdb.org/docs/stable/core_extensions/spatial/overview) can also read OSM PBF files using the [`ST_ReadOSM()`](https://duckdb.org/docs/stable/core_extensions/spatial/functions#st_readosm) function. However, this method returns rows in OSM's native data model (Nodes, Ways, and Relations). `duckdb-osmium`, in contrast, uses libosmium to reconstruct geometries for OSM elements and returns data including a geometry column containing Points, LineStrings, or Polygons/MultiPolygons.

This extension supports predicate pushdown (so elements that don't match the WHERE clause won't be processed) and projection pushdown (so that if you don't SELECT the geometry column in your query, geometry construction is skipped internally).

## Installation

Run this in a DuckDB shell to install the extension:

```
INSTALL osmium FROM community;
```

This downloads the compiled extension from the [DuckDB Community Extensions](https://duckdb.org/community_extensions/) repository.

## Examples

Get the OSM IDs, names, and Point geometries of all `place=city` nodes:

```sql
LOAD osmium;

SELECT id, tags['name'] as name, geometry
FROM 'example.osm.pbf'
WHERE kind = 'node'
  AND tags['place'] = 'city';
```

Copy the OSM type, OSM ID, tags, and Polygon geometries of all `building=*` areas to a GeoJSON file:

```sql
LOAD osmium;
LOAD spatial;

COPY (
  SELECT type, id, tags, geometry
  FROM 'example.osm.pbf'
  WHERE kind = 'area'
    AND tags['building'] IS NOT NULL
) TO 'buildings.geojson' WITH (FORMAT GDAL, DRIVER GeoJSON);
```

Calculate the total length of roads, grouped by `surface` tag:

```sql
LOAD osmium;
LOAD spatial;

-- tells DuckDB not to assume lat,lon order for ST_Length_Spheroid()
SET geometry_always_xy = true;

SELECT
    tags['surface'] AS surface,
    SUM(ST_Length_Spheroid(geometry)) AS total_length_m
FROM 'example.osm.pbf'
WHERE kind = 'line'
  AND tags['highway'] IS NOT NULL
GROUP BY surface
ORDER BY total_length_m DESC;
```

## Schema

The following columns are available:

- `kind` - the constructed type; one of `node`, `line`, `area`, or `relation` (see next section)
- `type` - the original OSM type; one of `node`, `way`, or `relation`
- `id` - the OSM ID (unique among elements of the same type; for a globally unique key you want `(type, id)`)
- `tags` - the element's tags, as a `MAP(VARCHAR, VARCHAR)`; untagged elements are included by default, but you can add `WHERE cardinality(tags) > 0` to exclude them
- `geometry` - the constructed geometry; a Point, LineString, Polygon, or MultiPolygon depending on `kind` (NULL for `relation` rows or if the element's geometry could not be properly constructed)
- `version` - the element's version number, which OSM increments each time it is modified (`UINTEGER`)
- `timestamp` - the time of the element's last edit, as a `TIMESTAMP WITH TIME ZONE` in UTC
- `changeset` - the ID of the changeset the element was last edited in (`UINTEGER`)
- `uid` - the numeric ID of the user who last edited the element (`UINTEGER`)
- `username` - the display name of the user who last edited the element (`VARCHAR`)
- `refs` - for `relation` rows, the member element IDs as a `BIGINT[]` (NULL for other kinds)
- `ref_roles` - for `relation` rows, the member roles as a `VARCHAR[]`, aligned with `refs` (NULL for other kinds)
- `ref_types` - for `relation` rows, the member types as a `VARCHAR[]` (each `node`, `way`, or `relation`), aligned with `refs` (NULL for other kinds)

The `version`, `timestamp`, `changeset`, `uid`, and `username` columns come from OSM element metadata, which is optional: files can be written without it, and individual fields can be absent (for example, edits with redacted authorship carry no `uid` or `username`). Any absent field is returned as NULL.

## Disambiguating lines and areas

Closed ways in OSM can represent either lines or polygons. Which interpretation is indended is implied by the element's tags. For example, a closed way with `highway=roundabout` represents a LineString; one with `building=house` represents a Polygon.

This extension does not have any opinion on which tags imply features are lines or areas; it's up to you to specify which you want in your query. This is what the `kind` column is for. It has four possible values:
- `node`: an OSM node; its `geometry` will be a `Point`
- `line`: an open Way, or a closed way that is not tagged `area=yes`; its geometry will be a `LineString`
- `area`: a closed Way that is not tagged `area=no`, or a Relation with `type=multipolygon` or `type=boundary`. Its geometry will be a `Polygon` or `MultiPolygon`
- `relation`: other Relation types; they have NULL geometry

It's important to understand that closed ways which are not tagged `area=yes` or `area=no` are fundamentally ambiguous; the correct interpretation has to be guessed based on the way's other tags. **This extension will emit these ways twice**, once with `kind = 'line'` and a LineString geometry, and once as `kind = 'area'` and a Polygon geometry. It's up to you to filter the results with a WHERE clause to get the interpretation you want.

## Pushdown and performance

The extension reads the file sequentially and skips work for rows that your query can't return. Which parts of a `WHERE` clause are pushed into the scan (and therefore avoid constructing geometry or emitting rows) is limited to the following:

- `kind` and `type`: `=`, `IN (...)`, and `OR` of those on the same column
- `id`: `=`, `IN (...)`, and `OR` of those
- tags: `tags['key'] IS NOT NULL`, `tags['key'] = 'value'`, `tags['key'] IN ('a', 'b')`, and `OR` groups of these
- tag count: comparisons of `cardinality(tags)` with a non-negative integer, such as `cardinality(tags) > 0`

Multiple pushed-down predicates are ANDed together. Any other predicate is still applied correctly, but by DuckDB after rows are produced.

**Spatial predicates are not pushed down.** A filter like `ST_Intersects(geometry, ...)` or a bounding-box test is evaluated after the geometry has been built, so it does not make the scan cheaper. OSM PBF files have no spatial index, so the whole file is still read. If you only need a small area, extract it first with a tool like [osmium extract](https://osmcode.org/osmium-tool/manual.html#creating-geographic-extracts).

Projection pushdown works per column: if you don't select `geometry`, no geometry is built, and the same goes for the metadata columns (`version`, `timestamp`, `changeset`, `uid`, `username`) and the `refs`, `ref_roles` and `ref_types` columns.

### Node location index

Ways have no coordinates of their own, only the IDs of their nodes. To build a LineString or Polygon, the extension needs a lookup from node ID to location. It builds this index with one extra pass over the nodes in the file the first time a query needs it. Queries that read only nodes or non-area relations, or that don't select `geometry`, do not need it.

The index is cached for the lifetime of the database, keyed on the file path, size, modification time and index settings, so later queries on the same file reuse it. It is rebuilt if the file changes.

For in-memory index types, the index counts towards DuckDB's `memory_limit`, and DuckDB may evict it to make room (it is then rebuilt on the next query). File-backed index types don't count towards `memory_limit`.

Two settings control the index:

```sql
-- Index implementation. Any index type supported by libosmium can be used,
-- for example flex_mem (the default), sparse_mem_array, or sparse_file_array.
SET osmium_index_type = 'sparse_file_array';

-- File to use for file-backed index types (dense_file_array, sparse_file_array).
SET osmium_index_path = '/path/to/node-index.tmp';
```

The right choice depends on the size of your file and how much memory you have. Memory-backed indexes are faster; file-backed ones let you read very large files (such as a full planet extract) without holding the index in RAM. See the [libosmium](https://osmcode.org/libosmium) documentation on node location indexes for how the types trade off.

**Be careful with the `dense_*` types on small files.** A dense index is sized by the highest node ID it has to cover, not by the number of nodes in the file, and current OSM node IDs are in the billions. In testing, `dense_file_array` created a ~31 GB (sparse) file when reading a file with under 2,000 elements, and `dense_mem_array` got the process killed. Dense indexes only make sense for very large extracts. The default `flex_mem` switches between sparse and dense storage on its own and is a good starting point.

## How geometries are built

- **Nodes** become `Point`s.
- **Open ways** become `LineString`s, using locations from the node index.
- **Closed ways** that aren't tagged `area=no` can also be built as `Polygon`s (see the previous section for why these are emitted twice).
- **Relations with `type=multipolygon` or `type=boundary`** become `kind = 'area'` rows with a `Polygon` or `MultiPolygon` geometry. These are assembled by libosmium's area assembler using its default settings, which joins the member ways' segments into outer and inner rings. The extension reads the relations first to find which member ways it needs, then assembles each relation as its member ways are read from the file.

Elements whose geometry can't be built are not dropped. They are returned with a NULL `geometry`, and their tags and metadata are still populated. This happens when:

- a way refers to a node that is missing from the file (common in extracts that cut ways at the boundary)
- a multipolygon or boundary relation refers to a member way that is missing from the file
- a multipolygon or boundary relation has no way members, or its ways can't be joined into valid rings

You can find them with `WHERE geometry IS NULL`, or exclude them with `geometry IS NOT NULL`. The `test/sql/incomplete.test` file shows these cases against a small fixture.

## License

This code is available under the MIT License; see the LICENSE file for details.
