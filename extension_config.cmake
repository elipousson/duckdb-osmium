# This file is included by DuckDB's build system. It specifies which extension to load

# Extension from this repo
duckdb_extension_load(osmium
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)

# As of DuckDB 2.0, loading an extension only builds it; linking is explicit.
duckdb_extension_statically_link(osmium)

# Any extra extensions that should be built
# e.g.: duckdb_extension_load(json)