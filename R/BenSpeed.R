#' Ben_Speed: Automate Data Transform Approach (SQL first, Chunk second, Memory last)
#'
#' This function automatically chooses how to process data based on:
#'   - whether the pipeline is fully SQL-friendly (push it to DuckDB),
#'   - otherwise, if data is large but not SQL-friendly, do chunk-based row transforms,
#'   - otherwise, if data is small enough, do in-memory dplyr,
#'   - optionally accept a file path for large data ingestion without loading everything into memory.
#'
#' @param input Either:
#'    1) a data frame (or lazy dplyr object), or
#'    2) a character file path (e.g., "data.csv")
#' @param processing_func A function that takes a dataframe and returns a transformed dataframe,
#'        ideally using dplyr verbs. E.g.:
#'        function(x) x %>% filter(...) %>% mutate(...) %>% arrange(...) ...
#' @param memory_threshold_gb If the data is below this size, do a simple in-memory approach.
#' @param reserve_cores Number of CPU cores to keep free (default: 2).
#' @param reserve_ram GB of RAM to keep free (default: 4).
#' @param max_chunk_gb Max chunk size in chunk-based approach (default: 0.5).
#' @param duckdb_file Path to a DuckDB file if using SQL approach (default: "ben_speed.duckdb").
#' @param temp_dir Temporary directory for chunk-based processing.
#'
#' @return The final transformed dataframe.
#' @export
Ben_Speed <- function(input,
                      processing_func,
                      memory_threshold_gb = 2,
                      reserve_cores = 2,
                      reserve_ram = 4,
                      max_chunk_gb = 0.5,
                      duckdb_file = "ben_speed.duckdb",
                      temp_dir = NULL)
{
  ## --- Load essential packages here (in real usage, do it in DESCRIPTION).
  library(dplyr)
  library(purrr)
  
  cat("=== Ben_Speed: Start ===\n")
  
  ## --- Step 0: Handle temp_dir
  if (is.null(temp_dir)) {
    temp_dir <- file.path(getwd(), "PackaBen_Temp")
  }
  dir.create(temp_dir, showWarnings = FALSE, recursive = TRUE)
  
  ## --- Step 1: Determine if 'input' is a file path or a data frame/object
  is_file <- is.character(input) && length(input) == 1 && file.exists(input)
  is_df <- (is.data.frame(input) || is_tibble(input))
  # (Optional) detect if it's a lazy dplyr object, e.g. dbplyr::tbl()
  # is_lazy <- inherits(input, "tbl_dbi")  # or something similar
  
  ## --- Step 2A: If 'input' is a file path, we do not have a loaded DF yet
  if (is_file) {
    cat("Ben_Speed: Input is a file -> Attempt to load via SQL or chunk read.\n")
    
    # We'll assume it's a CSV for now; if it's Parquet or something else,
    # you can adapt the logic or check the file extension.
    # 1) We can attempt to ingest file into DuckDB directly
    #    This can handle large files without fully loading them:
    big_df_size_gb <- file.size(input) / 1e9
    cat("File size approx:", round(big_df_size_gb, 2), "GB\n")
    
    # Decide if we want to do a SQL approach or chunk-based approach
    # But we first need to know if 'processing_func' is SQL-friendly:
    
    if (is_sql_compatible(processing_func)) {
      cat("Ben_Speed: Will ingest file into DuckDB & run pipeline.\n")
      # connect to DuckDB
      library(DBI)
      library(duckdb)
      
      con <- dbConnect(duckdb::duckdb(), duckdb_file)
      
      # We'll create a table from the file without loading fully
      # e.g. using something like: dbExecute(con, "CREATE TABLE temp_data AS SELECT * FROM 'data.csv'")
      # But let's assume we have a helper that does it:
      create_sql_from_file(con, input, "temp_data")
      
      # Now apply pipeline in SQL
      lazy_tbl <- dplyr::tbl(con, "temp_data")
      sql_result <- apply_pipeline_sql(lazy_tbl, processing_func)
      final_result <- collect(sql_result)
      
      dbDisconnect(con)
      cat("=== Ben_Speed: Completed SQL from file input. ===\n")
      return(final_result)
      
    } else {
      # Not SQL-friendly -> do chunk-based read from CSV
      cat("Ben_Speed: Not SQL-friendly pipeline -> chunk-based read from file.\n")
      chunked_result <- chunk_based_read_csv_and_process(
        file_path = input,
        processing_func = processing_func,
        reserve_cores = reserve_cores,
        reserve_ram = reserve_ram,
        max_chunk_gb = max_chunk_gb,
        temp_dir = temp_dir
      )
      cat("=== Ben_Speed: Completed chunk-based from file input. ===\n")
      return(chunked_result)
    }
    
  } else {
    ## --- Step 2B: Input is presumably in-memory data frame (or something similar)
    # Let's figure out how big it is:
    df_size_bytes <- object.size(input)
    df_size_gb <- as.numeric(df_size_bytes) / 1e9
    cat("Ben_Speed: In-memory input approx size:", round(df_size_gb, 2), "GB\n")
    
    # Step 3: Check if pipeline is SQL-friendly:
    if (is_sql_compatible(processing_func)) {
      # If data is large, let's prefer pushing to DuckDB
      if (df_size_gb > memory_threshold_gb) {
        cat("Ben_Speed: Data is large + pipeline is SQL-friendly -> using DuckDB.\n")
        library(DBI)
        library(duckdb)
        con <- dbConnect(duckdb::duckdb(), duckdb_file)
        dbWriteTable(con, "temp_data", input, overwrite = TRUE)
        
        lazy_tbl <- dplyr::tbl(con, "temp_data")
        sql_result <- apply_pipeline_sql(lazy_tbl, processing_func)
        final_result <- collect(sql_result)
        
        dbDisconnect(con)
        cat("=== Ben_Speed: Completed SQL approach for large in-memory data. ===\n")
        return(final_result)
      } else {
        cat("Ben_Speed: Data is small enough -> we could do in-memory or SQL. Let's do in-memory.\n")
        # If you want to default to SQL anyway, you can. But let's do memory for small data.
        final_result <- processing_func(input)
        cat("=== Ben_Speed: Completed in-memory approach (small data). ===\n")
        return(final_result)
      }
    } else {
      # The pipeline is not fully SQL-friendly
      # Check the data size. If it's large, do chunk-based; if small, do normal memory dplyr.
      if (df_size_gb > memory_threshold_gb) {
        cat("Ben_Speed: Large data + not SQL-friendly -> chunk-based approach.\n")
        final_result <- chunk_based_in_memory(
          input_df = input,
          processing_func = processing_func,
          reserve_cores = reserve_cores,
          reserve_ram = reserve_ram,
          max_chunk_gb = max_chunk_gb,
          temp_dir = temp_dir
        )
        cat("=== Ben_Speed: Completed chunk-based approach for big data. ===\n")
        return(final_result)
      } else {
        cat("Ben_Speed: Small data + not SQL-friendly -> normal in-memory.\n")
        final_result <- processing_func(input)
        cat("=== Ben_Speed: Completed in-memory approach. ===\n")
        return(final_result)
      }
    }
  }
  
  # If we get here (somehow):
  stop("Ben_Speed: Could not determine approach. Please debug your input or pipeline.")
}
