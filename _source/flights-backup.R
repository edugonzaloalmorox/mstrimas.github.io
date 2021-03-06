---
  layout: post
title: "Mapping the Longest Commericial Flights in R"
published: true
excerpt: >
  Mapping the longest regularly scheduled commercial flights in the world using
R and ggplot2.
category: spatial
tags: r spatial gis
---
  
  ```{r echo = F, include = F, eval = F}
setwd("_source/")
```

```{r setup, echo = F}
opts_chunk$set(cache.path = "cache/long-flights/")
```

On more than one occasion I've taken the brutally long-haul flight from Toronto to Hong Kong with Air Canada. Given that I'm totally unable to sleep on planes, almost 16 hours crammed into a tiny economy class seat is pretty rough! This got me thinking: what is the longest regularly scheduled, commericial long-haul flight?

Wikipedia has the answer (no surprise) in the form of a table listing the [top 30 longest flights by distance](https://en.wikipedia.org/wiki/Non-stop_flight#Longest_flights). Turns out the longest flight is from Dallas to Syndey, clocking in at almost 17hours. This is 1.5 hours longer than my Hong Kong-Toronto flight, which comes in at number 24 on the list.
                                                                                                               
                                                                                                               Of course, I couldn't resist scraping these data from Wikipedia and mapping the flights. I'm trying to improve my ggplot skills, so I'll stick to this package for the visualization.
                                                                                                               
                                                                                                               ## Required packages
                                                                                                               
                                                                                                               ```{r packages, cahce=F}
                                                                                                               library(sp)
                                                                                                               library(raster)
                                                                                                               library(rgeos)
                                                                                                               library(geosphere)
                                                                                                               library(plyr)
                                                                                                               library(dplyr)
                                                                                                               library(rvest)
                                                                                                               library(stringr)
                                                                                                               library(tidyr)
                                                                                                               library(broom)
                                                                                                               library(lubridate)
                                                                                                               library(ggplot2)
                                                                                                               library(ggmap)
                                                                                                               library(ggrepel)
                                                                                                               library(ggalt)
                                                                                                               ```
                                                                                                               
                                                                                                               # Scraping and cleaning
                                                                                                               
                                                                                                               The `rvest` package makes web scraping a breeze. I just read the html, extract out any tables, pick the first table on the page (this is the only one I'm interested in), and parse it into a dataframe with `html_table()`.

```{r wiki-data, cache=T}
flights <- read_html('https://en.wikipedia.org/wiki/Non-stop_flight') %>% 
  html_nodes('.wikitable') %>% 
  .[[1]] %>% 
  html_table(fill = TRUE)
```

As usual there are some issues with the imported data. First, the Wikipedia table has cells spanning multiple rows corresponding to flights on the same route with different airlines. The `rvest` explicitely states that it can't handle rows spanning multiple columns. In addition, the column headers are not nice variable names.

<img src="/img/multi-row-cell.png" style="display: block; margin: auto;" />

I fix these issues below.

```{r fix-cell-issue}
# variable names
names(flights) <- c("rank", "from", "to", "airline", "flight_no", "distance",
"duration", "aircraft", "first_flight")
# cells spanning multiple rows
row_no <- which(is.na(flights$first_flight))
problem_rows <- flights[row_no, ]
fixed_rows <- flights[row_no - 1, ]
fixed_rows$rank <- problem_rows[, 1]
fixed_rows$airline <- problem_rows[, 2]
fixed_rows$flight_no <- problem_rows[, 3]
fixed_rows$duration <- problem_rows[, 4]
fixed_rows$aircraft <- problem_rows[, 5]
flights <- flights[-row_no, ]
flights <- rbind(flights, fixed_rows) %>% 
arrange(rank)
```

The next step is cleaning the data, and there are a variety of issues here:
1. Footnotes need to be cleaned out of some cells 
2. Destinations sometimes have city and airport
3. Some routes have multiple flight numbers for the same airline
4. Distances are given in three units all within the same cell
5. Durations aren't in a nice format to work with
5. Some routes have different durations for winter and summer

Nothing `stringr` and some regular expressions can't handle!

```{r clean}
flights <- flights %>% 
mutate(rank = as.integer(str_extract(rank, "^[:digit:]+")),
from = str_extract(from, "^[[:alpha:] ]+"),
to = str_extract(to, "^[[:alpha:] ]+"))
# make multiple flight numbers comma separated
flights$flight_no <- str_replace_all(flights$flight_no, "[:space:]", "") %>% 
str_extract_all("[:alpha:]+[:digit:]+") %>% 
laply(paste, collapse = ",")
# only consider distances in km, convert to integer
flights$distance <- str_extract(flights$distance, "^[0-9,]+") %>% 
str_replace(",", "") %>% 
as.integer
# convert duration to minutes and separate into summer/winter schedules
flights <- str_match_all(flights$duration, "([:digit:]{2}) hr ([:digit:]{2}) min") %>% 
llply(function(x) {60 * as.integer(x[, 2]) + as.integer(x[, 3])}) %>% 
llply(function(x) c(x, x)[1:2]) %>% 
do.call(rbind, .) %>% 
data.frame %>% 
setNames(c("duration_summer", "duration_winter")) %>% 
mutate(duration_max = pmax(duration_summer, duration_winter)) %>% 
cbind(flights, .)
# first_flight to proper date
flights$first_flight <- str_extract(flights$first_flight, "^[0-9-]+") %>% 
ymd %>% 
as.Date
flights <- flights %>% 
mutate(id = paste(from, to, sep = "-")) %>% 
dplyr::select(rank, id, from, to, airline, flight_no, distance, 
duration = duration_max, duration_summer, duration_winter,
first_flight)
```

Now the table is in a nice clean format and ready for display.

```{r flight-table}
dplyr::select(flights, rank, id, airline, distance, duration) %>% 
kable(format.args =  list(big.mark = ','),
col.names = c("rank", "route", "airline", "distance (km)", "duration (min)"))
```

# Geocoding

If I'm going to map these flights, I'll need coordinates for each city in the dataset. Fortunately, the `ggmaps` package has a function for geocoding locations based on their name using Google Maps.

```{r geocode}
cities <- c(flights$from, flights$to) %>% 
unique
cities[cities == "Melbourne"] <- "Melbourne, Australia"
cities <- cities %>% 
cbind(city = ., geocode(., output = "latlon", source = "google"))
cities <- cities %>% 
mutate(city = as.character(city),
city = ifelse(city == "Melbourne, Australia", "Melbourne", city))
```

Now I bring these coordinates into the `flights` dataframe.

```{r flight-coords}
flights <- flights %>% 
left_join(cities, by = c("from" = "city")) %>% 
left_join(cities, by = c("to" = "city")) %>% 
rename(lng_from = lon.x, lat_from = lat.x, lng_to = lon.y, lat_to = lat.y)
```

# Flight paths

A [great circle](https://en.wikipedia.org/wiki/Great_circle) is the path on a spherical surface (such as the Earth) that gives the shortest distance between two points. Although I have no way of knowing what the actual flight path is for these routes, it's likely to be reasonably approximated by a great circle. First I subset the flights dataset to only include unique routes.

```{r flight-subset}
flights_unique <- flights %>% 
  group_by(id) %>% 
  filter(row_number(desc(duration)) == 1)
```

Then I use the `geosphere` package to get great circle routes for each of the above flights. Since flights over the pacific cross the International Date Line, I use the `breakAtDateLine = TRUE` so ensure the great circle lines are broken as they cross.

```{r gc}
gc_routes <- gcIntermediate(flights_unique[c("lng_from", "lat_from")],
                            flights_unique[c("lng_to", "lat_to")],
                            n = 360, addStartEnd = TRUE, sp = TRUE, 
                            breakAtDateLine = TRUE)
gc_routes <- SpatialLinesDataFrame(gc_routes,
                                   data.frame(id = flights_unique$id,
                                              stringsAsFactors = FALSE))
row.names(gc_routes) <- gc_routes$id
```

The `geosphere` package also provides a function to calculate the maximum latitude reached on a great circle route. This will be useful for identifying routes that pass close to the north pole. I also identify routes crossing the international date line. These routes may need to be mapped with a different projection.

```{r max-lat}
max_lat <- gcMaxLat(flights_unique[c("lng_from", "lat_from")],
                    flights_unique[c("lng_to", "lat_to")])
flights_unique$max_lat <- max_lat[, "lat"]
date_line <- readWKT("LINESTRING(180 -90, 180 90)", p4s = projection(gc_routes))
flights_unique$cross_dl <- gIntersects(gc_routes, date_line, byid=T) %>% 
  as.logical
```

# Global map

As a background on which to map the flight paths, I'll use the global map provided by [Natural Earth](http://www.naturalearthdata.com). First I download, unzip, and load shapefiles for country boundaries, graticules, and a bounding box.

```{r boundaries, cache = T}
base_url <- 'http://www.naturalearthdata.com/http//www.naturalearthdata.com/download/110m/'
tf <- tempfile()
download.file(paste0(base_url, 'cultural/ne_110m_admin_0_countries.zip'), tf)
unzip(tf, exdir = 'data/long-flights/', overwrite = TRUE)
unlink(tf)
download.file(paste0(base_url, 'physical/ne_110m_graticules_all.zip'), tf)
unzip(tf, exdir = 'data/long-flights/', overwrite = TRUE)
unlink(tf)

world_wgs <- shapefile('data/long-flights/ne_110m_admin_0_countries.shp')
bbox_wgs <- shapefile('data/long-flights/ne_110m_wgs84_bounding_box.shp')
grat_wgs <- shapefile('data/long-flights/ne_110m_graticules_20.shp')
```

This shapfile is more granular than I require, so I aggregate it so that each ISO alpha-2 code corresponds to a single polygon.

```{r dissolve}
world_wgs <- subset(world_wgs, iso_a2 != "AQ")
world_wgs <- gUnaryUnion(world_wgs, id = world_wgs$iso_a2)
```

These shapefiles are currently in unprojected coordinates (i.e. lat/long), so I project them to the [Winkel tripel projection](https://en.wikipedia.org/wiki/Winkel_tripel_projection), a nice compromise projection for global maps, which is used by National Geographic.

```{r wt}
world_wt <- spTransform(world_wgs, '+proj=wintri')
bbox_wt <- spTransform(bbox_wgs, '+proj=wintri')
grat_wt <- spTransform(grat_wgs, '+proj=wintri')
```

`ggplot` can't handle spatial objects directly, it only works with data frames. So, I use the `tidy()` function from the `broom()` package to convert each spatial object to a data frame ready for plotting.

```{r fortify}
world_wt_df <- tidy(world_wt)
bbox_wt_df <- tidy(bbox_wt)
grat_wt_df <- tidy(grat_wt)
```

Finally, I project and `fortify()` the routes and cities.

```{r cities-rotues}
cities_wgs <- cities
coordinates(cities_wgs) <- ~ lon + lat
projection(cities_wgs) <- projection(world_wgs)
cities_wt <- spTransform(cities_wgs, projection(world_wt))
cities_wt_df <- as.data.frame(cities_wt, stringsAsFactors = FALSE)

gc_routes_wt <- spTransform(gc_routes, projection(world_wt))
gc_routes_wt_df <- tidy(gc_routes_wt)

world_wgs_df <- tidy(world_wgs)
bbox_wgs_df <- tidy(bbox_wgs)
grat_wgs_df <- tidy(grat_wgs)
cities_wgs_df <- as.data.frame(cities_wgs, stringsAsFactors = FALSE)
gc_routes_wgs_df <- tidy(gc_routes)
```

# Mapping

Now that all the data are prepared, I'll create the map. I build it up in steps here.

```{r map, fig.width=960/96, fig.height=600/96}
set.seed(1)
pole_routes <- with(flights_unique, id[max_lat > 60 & cross_dl & lat_to > 0])
cross_dl <- flights_unique$id[flights_unique$cross_dl]
ggplot() +
geom_polygon(data = bbox_wt_df, aes(long, lat, group = group), 
fill = "light blue") +
geom_path(data = grat_wt_df, aes(long, lat, group = group, fill = NULL), 
linetype = "dashed", color = "grey70", size = 0.25) +
geom_polygon(data = world_wt_df, aes(long, lat, group = group), 
fill = "#f2f2f2", color = "grey70", size = 0.1) +
geom_point(data = cities_wt_df, aes(lon, lat), color = "grey20", size = 0.5) +
geom_path(data = filter(gc_routes_wt_df, TRUE), 
aes(long, lat, group = group), alpha = 0.5, color = "#fa6900") +
geom_text_repel(data = cities_wt_df, aes(lon, lat, label = city),
segment.color = "grey20", segment.size = 0.25,
box.padding = unit(0.1, 'lines'), force = 0.5,
fontface = "bold", size = 3, color = "grey20") +
coord_equal() +
theme_nothing()
```

```{r map, fig.width=960/96, fig.height=600/96}
set.seed(1)
pole_routes <- with(flights_unique, id[max_lat > 60 & cross_dl & lat_to > 0])
pole_routes <- with(flights_unique, id[max_lat > 60 & cross_dl & lat_to > 0])
cross_dl <- flights_unique$id[flights_unique$cross_dl]
ggplot() +
# geom_polygon(data = bbox_wgs_df, aes(long, lat, group = group),
#              color = "grey20", fill = "light blue") +
# geom_path(data = grat_wgs_df, aes(long, lat, group = group, fill = NULL),
#           linetype = "dashed", color = "grey70", size = 0.25) +
geom_polygon(data = world_wgs_df, aes(long, lat, group = group), 
fill = "#f2f2f2", color = "grey70", size = 0.1) +
geom_point(data = cities_wgs_df, aes(lon, lat), color = "grey20", size = 0.5) +
geom_path(data = filter(gc_routes_wgs_df, id %in% cross_dl), 
aes(long, lat, group = group), alpha = 0.5, color = "#fa6900") +
# geom_text_repel(data = cities_wgs_df, aes(lon, lat, label = city),
#                 segment.color = "grey20", segment.size = 0.25,
#                 box.padding = unit(0.1, 'lines'), force = 0.5,
#                 fontface = "bold", size = 3, color = "grey20") +
#ggalt::coord_proj("+proj=wintri") +
coord_proj("+proj=wintri +lon_0=150") +
#ggalt::coord_proj("+proj=aeqd +lat_0=80 +lon_0=0") +
theme_nothing()

world <- map_data("world")
world <- world[world$region != "Antarctica",]
ggplot() + 
geom_map(data=world, map=world, aes(x=long, y=lat, map_id=region)) +
geom_point(aes(100, 45), col = "red") +
geom_text_repel(aes(100, 45), label = "Point Label") +
coord_proj("+proj=wintri")

l1 <- readWKT("LINESTRING(0 0,1 1)")
l2 <- readWKT("LINESTRING(0 0.5,1 0.5)")
plot(l1)
lines(l2)
gIntersection(l2, l1, byid = TRUE) %>% 
disaggregate %>% 
plot
?rgeos::gNode
```