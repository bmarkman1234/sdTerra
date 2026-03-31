# =========================================================
# San Diego County Terrain + Precipitation Map
# Full script with:
#   1) ggplot static map
#   2) rayshader rendered map
#
# Notes:
# - You need a San Diego County boundary file locally.
# - This version uses elevation as a placeholder "precipitation proxy"
#   so the script can run end-to-end.
# - Replace the proxy section later with real PRISM precipitation.
# =========================================================

# -----------------------------
# 0. Install packages if needed
# -----------------------------
install.packages(c(
  "sf", "terra", "elevatr", "ggplot2", "dplyr",
  "viridis", "rayshader", "raster"
 ))

library(sf)
library(terra)
library(elevatr)
library(ggplot2)
library(dplyr)
library(viridis)
library(rayshader)
library(raster)

# -----------------------------
# 1. User file paths
# -----------------------------
sd_boundary_path <- "data_raw/sd_county_boundary.geojson"

ggplot_output_path    <- "outputs/sd_county_ggplot_map.png"
rayshader_output_path <- "outputs/sd_county_rayshader_map.png"

# -----------------------------
# 2. Create output folder
# -----------------------------
dir.create("outputs", showWarnings = FALSE, recursive = TRUE)

# -----------------------------
# 3. Read San Diego County boundary
# -----------------------------
sd <- st_read(sd_boundary_path, quiet = TRUE)

# Reproject to California Albers
sd <- st_transform(sd, 3310)
sd_vect <- vect(sd)

# -----------------------------
# 4. Download DEM
# -----------------------------
# z = 9 or 10 is a decent starting point.
# If too slow, drop to 8. If too coarse, try 10.
dem_raw <- get_elev_raster(
  locations = sd,
  z = 9,
  clip = "locations"
)

dem <- rast(dem_raw)

# Project DEM to county CRS
dem <- project(dem, "EPSG:3310")

# Crop and mask to county
dem <- crop(dem, sd_vect)
dem <- mask(dem, sd_vect)

# Aggregate for speed
dem_small <- aggregate(dem, fact = 2, fun = mean, na.rm = TRUE)

# -----------------------------
# 5. Create hillshade
# -----------------------------
slope  <- terrain(dem_small, v = "slope", unit = "radians")
aspect <- terrain(dem_small, v = "aspect", unit = "radians")
hill   <- shade(slope, aspect, angle = 45, direction = 315)

# -----------------------------
# 6. Placeholder precipitation proxy
# -----------------------------
# This uses elevation as a stand-in so you can test the workflow.
# Replace this block later with a real PRISM raster.
ppt <- dem_small

ppt_min <- global(ppt, "min", na.rm = TRUE)[1, 1]
ppt_max <- global(ppt, "max", na.rm = TRUE)[1, 1]

ppt_norm <- (ppt - ppt_min) / (ppt_max - ppt_min)

# -----------------------------
# 7. Convert rasters to data frames for ggplot
# -----------------------------
hill_df <- as.data.frame(hill, xy = TRUE, na.rm = TRUE)
ppt_df  <- as.data.frame(ppt_norm, xy = TRUE, na.rm = TRUE)

names(hill_df)[3] <- "hillshade"
names(ppt_df)[3]  <- "ppt"

map_df <- left_join(hill_df, ppt_df, by = c("x", "y"))

# Clamp hillshade just in case
map_df$hillshade <- pmax(pmin(map_df$hillshade, 1), 0)

# -----------------------------
# 8. ggplot static map
# -----------------------------
p <- ggplot() +
  geom_raster(
    data = map_df,
    aes(x = x, y = y, fill = ppt, alpha = hillshade)
  ) +
  scale_fill_viridis_c(
    name = "Relative\nmoisture",
    option = "C",
    direction = -1
  ) +
  scale_alpha(range = c(0.45, 0.95), guide = "none") +
  geom_sf(data = sd, fill = NA, color = "grey15", linewidth = 0.35) +
  coord_sf(datum = NA) +
  labs(
    title = "Terrain and moisture gradient in San Diego County",
    subtitle = "Shaded relief with placeholder moisture proxy",
    caption = "Boundary: local file | DEM: elevatr/USGS | Moisture layer: elevation proxy"
  ) +
  theme_void() +
  theme(
    plot.title = element_text(size = 20, face = "bold"),
    plot.subtitle = element_text(size = 11),
    plot.caption = element_text(size = 8),
    legend.position = c(0.88, 0.22),
    legend.title = element_text(size = 9),
    legend.text = element_text(size = 8)
  )

print(p)

ggsave(
  filename = ggplot_output_path,
  plot = p,
  width = 10,
  height = 8,
  dpi = 300,
  bg = "white"
)

# -----------------------------
# 9. Prepare data for rayshader
# -----------------------------
# Convert terra raster to raster package object first
dem_raster <- raster(dem_small)

# rayshader needs a matrix
dem_mat <- raster_to_matrix(dem_raster)

# -----------------------------
# 10. Build color overlay for rayshader
# -----------------------------
# Convert normalized raster values to colors
ppt_vals <- values(ppt_norm)

pal <- colorRampPalette(c(
  "#e8d9a8",  # tan
  "#c8d36b",  # yellow-green
  "#5dbb63",  # green
  "#2c7fb8"   # blue
))

color_breaks <- 256
ppt_cuts <- cut(ppt_vals, breaks = color_breaks, include.lowest = TRUE)
ppt_cols <- pal(color_breaks)[ppt_cuts]

# Rebuild into raster dimensions
nrows <- nrow(dem_small)
ncols <- ncol(dem_small)

ppt_matrix <- matrix(ppt_cols, nrow = nrows, ncol = ncols, byrow = TRUE)

# rayshader matrix orientation sometimes needs flipping
ppt_matrix <- ppt_matrix[nrow(ppt_matrix):1, ]

# -----------------------------
# 11. Create rayshader map
# -----------------------------
base_map <- sphere_shade(dem_mat, texture = "desert")

ray_shadow  <- ray_shade(dem_mat, zscale = 15, sunaltitude = 35, sunangle = 315)
amb_shadow  <- ambient_shade(dem_mat, zscale = 15)

final_map <- base_map |>
  add_overlay(ppt_matrix, alphalayer = 0.65) |>
  add_shadow(ray_shadow, 0.35) |>
  add_shadow(amb_shadow, 0.20)

# Plot in R viewer
plot_map(final_map)

# Save high-res 2D rayshader image
png(
  filename = rayshader_output_path,
  width = 2400,
  height = 1800,
  res = 300
)
plot_map(final_map)
dev.off()

# -----------------------------
# 12. Optional 3D preview
# -----------------------------
# Uncomment if you want a 3D render window.
# render_3d(
#   final_map,
#   dem_mat,
#   zscale = 15,
#   fov = 0,
#   theta = -45,
#   phi = 45,
#   zoom = 0.7,
#   windowsize = c(1000, 800)
# )

cat("Saved ggplot map to:", ggplot_output_path, "\n")
cat("Saved rayshader map to:", rayshader_output_path, "\n")