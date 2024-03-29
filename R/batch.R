#' Batch Geocode Parsed Addresses
#'
#' @description
#' Provides access to the US Census Bureau batch endpoints for locations and
#' geographies. The function implements iteration and optional parallelization
#' in order to geocode datasets larger than the API limit of 1,000 and more
#' efficiently than sending 10,000 per request. It also supports multiple outputs,
#' including (optionally, if \code{sf} is installed,) \code{sf} class objects.
#'
#' @param .data data.frame containing columns with structured address data
#' @param id Optional String - Name of column containing unique ID
#' @param street String - Name of column containing street address
#' @param city Optional String - Name of column containing city
#' @param state Optional String - Name of column containing state
#' @param zip Optional String - Name of column containing zip code
#' @param return One of 'locations' or 'geographies' denoting returned information
#'     from the API. If you would like Census geography data, you must specify
#'     a valid vintage for your benchmark.
#' @param benchmark Optional Census benchmark to geocode against. To obtain current
#'     valid benchmarks, use the \code{cxy_benchmarks()} function.
#' @param vintage Optional Census vintage to geocode against. You may use the
#'     \code{cxy_vintages()} function to obtain valid vintages.
#' @param timeout Numeric, in minutes, how long until request times out
#' @param parallel Integer, number of cores greater than one if parallel requests
#'     are desired. All operating systems now use a SOCK cluster, and the
#'     dependencies are not longer suggested packages. Instead, they are
#'     installed by default. Note that this value may not represent more cores
#'     than the system reports are available. If it is larger, the maximum number
#'     of available cores will be used.
#' @param class One of 'dataframe' or 'sf' denoting the output class. 'sf' will only return matched addresses.
#' @param output One of 'simple' or 'full' denoting the returned columns. Simple returns just coordinates.
#'
#' @return A data.frame or sf object containing geocoded results
#'
#' @details
#' Parallel requests are supported across platforms. If supported (POSIX platforms) the process is forked, otherwise a SOCK cluster is used (Windows).
#' You may not specify more cores than the system reports are available
#'
#' @examples
#' # load data
#' x <- stl_homicides[1:10,]
#'
#' # geocode
#' cxy_geocode(x, street = 'street_address', city = 'city', state = 'state', zip = 'postal_code',
#'    return = 'locations', class = 'dataframe', output = 'simple')
#'
#' @export
cxy_geocode <- function(.data, id = NULL, street, city = NULL, state = NULL, zip = NULL, return = 'locations', benchmark = 'Public_AR_Current', vintage = NULL, timeout = 30, parallel = 1, class = 'dataframe', output = 'simple'){

  # Check Specification of Arguments
  if(missing(.data) | missing(street)){
    stop('`.data` and `street` are required arguments')
  }
  if(!is.null(id) && any(duplicated(.data[[id]]))){
    stop('Rows in the `id` column are not unique')
  }
  if(!return %in% c('locations', 'geographies')){
    stop("`return` must be one of 'locations' or 'geographies'")
  }
  if(return == 'locations' & !is.null(vintage)){
    warning("Vintage ignored for return = 'locations'")
  }
  if(return == 'geographies' & is.null(vintage)){
    stop("`vintage` must be specified for return = 'geographies'")
  }
  if(!class %in% c('dataframe', 'sf')){
    stop("`class` must be one of 'dataframe' or 'sf'")
  }
  if(class == 'sf' & (nzchar(find.package(package = "sf", quiet = TRUE)) != TRUE)){
    stop("Please install the 'sf' package to use the sf output feature")
  }
  if(!output %in% c('simple', 'full')){
    stop("`output` must be one of 'simple' or 'full'")
  }

  # validate benchmark
  test <- cxy_benchmarks()

  if (benchmark %in% test$benchmarkName == FALSE){
    stop("Invalid benchmark provided. Please use 'cxy_benchmarks()' to identify currently accepted benchmark values.")
  }

  # Warn for Omission
  if(is.null(city) | is.null(state) | is.null(zip)){
    warning('Omission of `city`, `state` or `zip` greatly reduces the speed and accuracy of the geocoder.')
  }

  # Check Parallel Configuration
  if(parallel > 1){

    # this gets around calling it as foreach::%dopar% below which sometimes errors
    `%dopar%` <- foreach::`%dopar%`

    # Check Number of Cores
    avail_cores <- parallel::detectCores()
    if(parallel > avail_cores){

      warning('More cores specified than are available, using ', avail_cores, ' cores instead')
      core_count <- avail_cores

    } else {

      core_count <- parallel

    }

  }

  # Handle NA Arguments
  n <- nrow(.data)

  if(!is.null(id)){
    if(!id %in% names(.data)){
      stop(id, ' is not a defined column name in the data.frame')
    }
    # Need to Sort User Data for Later Column Binding
    .data <- .data[order(.data[[id]]),]
    id <- .data[[id]]
  }else{
    id <- seq(n)
  }

  if(!street %in% names(.data)){
    stop(street, ' is not a defined column name in the data.frame')
  }

  if(!is.null(city)){
    if(!city %in% names(.data)){
      stop(city, ' is not a defined column name in the data.frame')
    }
    city <- .data[[city]]
  }else{
    city <- rep_len(NA, n)
  }

  if(!is.null(state)){
    if(!state %in% names(.data)){
      stop(state, ' is not a defined column name in the data.frame')
    }
    state <- .data[[state]]
  }else{
    state <- rep_len(NA, n)
  }

  if(!is.null(zip)){
    if(!zip %in% names(.data)){
      stop(zip, ' is not a defined column name in the data.frame')
    }
    zip <- .data[[zip]]
  }else{
    zip <- rep_len(NA, n)
  }

  # Build a Data.frame
  df <- data.frame(
    id = id,
    street = .data[[street]],
    city = city,
    state = state,
    zip = zip,
    stringsAsFactors = FALSE
  )

  # Extract unique addresses
  uniq <- df[which(!duplicated(paste(df$street, df$city, df$state, df$zip))),]


  if(parallel > 1){
    # Split by Core Count, Maximizing the Size of Batches
    # Calculate Split Factor (Halve Batch Sizes until appropriately under threshold)
    splt_fac <- core_count
    while (nrow(uniq) / splt_fac > 1000) {
      splt_fac <- 2 * splt_fac
    }

    batches <- split(uniq, rep_len(seq(splt_fac), nrow(uniq)) )

    # Prevent Warning for Undeclared Global Variable
    i = NULL

    # create and register a cluster to run - sequential is safer, though not necessary
    cl <- parallel::makeCluster(core_count, setup_strategy = 'sequential')
    doParallel::registerDoParallel(cl)

    # replace foreach + dopar gives you a parallel workflow, like mclapply
    results <- foreach::foreach(i = 1:length(batches), .export = 'batch_geocoder') %dopar% {
      batch_geocoder(batches[[i]], return, timeout, benchmark, vintage)
    }

    # however, you do need to stop the cluster.
    parallel::stopCluster(cl)

  } else { # Non Parallel
    # Split and Iterate
    batches <- split(uniq, (seq(nrow(uniq))-1) %/% 1000 )
    results <- lapply(batches, batch_geocoder,
                      return, timeout, benchmark, vintage)

  }

  # Row Bind the List of Responses
  api_output <- do.call(rbind, results)

  # Join Results with unique
  uniq_join <- merge(uniq, api_output, by = 'id' , all.x = TRUE, sort = TRUE)

  # Join Uniq with original df and sort
  all_join <- merge(df, uniq_join, by = c('street', 'city', 'state', 'zip'), all.x = TRUE)
  all_join <- all_join[order(all_join$id.x),]

  # Add cxy_ prefix to names
  names(all_join) <- paste0('cxy_', names(all_join))
  # Coerce to Numeric Cooridates
  all_join$cxy_lat <- as.numeric(all_join$cxy_lat)
  all_join$cxy_lon <- as.numeric(all_join$cxy_lon)


  # Output Type
  if(output == 'simple'){
    if(return == 'geographies'){
      return_df <- cbind(.data, all_join[,c('cxy_lon', 'cxy_lat', 'cxy_state_id', 'cxy_county_id', 'cxy_tract_id', 'cxy_block_id')])
    }else{
      return_df <- cbind(.data, all_join[,c('cxy_lon', 'cxy_lat')])
    }
  }
  else if(output == 'full'){
    if(return == 'geographies'){
      return_df <- cbind(.data, all_join[,c('cxy_address', 'cxy_status', 'cxy_quality', 'cxy_matched_address', 'cxy_tiger_line_id', 'cxy_tiger_side', 'cxy_lon', 'cxy_lat', 'cxy_state_id', 'cxy_county_id', 'cxy_tract_id', 'cxy_block_id')])
    }else{
      return_df <- cbind(.data, all_join[,c('cxy_address', 'cxy_status', 'cxy_quality', 'cxy_matched_address', 'cxy_tiger_line_id', 'cxy_tiger_side', 'cxy_lon', 'cxy_lat')])
    }
  }

  # Optionally, Return an SF Object
  if(class == 'sf'){
    valid <- return_df[which(!is.na(return_df$cxy_lat)),]
    sf <- sf::st_as_sf(valid, coords = c('cxy_lon', 'cxy_lat'), crs = 4269) # NAD83

    # Message Number of Rows Removed
    if (nrow(return_df) - nrow(valid) > 0){
      message(nrow(return_df) - nrow(valid), ' rows removed to create an sf object. These were addresses that the geocoder could not match.')
    }

    return(sf)
  }

  return(return_df)
}
